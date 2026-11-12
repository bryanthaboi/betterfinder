import Foundation
import Darwin

public final class SizeIndexWriter {
    static let schemaVersion: Int64 = 3
    static let focusLimit = 256
    let db: IndexDatabase
    private let databasePath: String
    private let excluded: Set<String>
    private var pool: [BulkDirectory] = [BulkDirectory()]
    private var volumeCache: [Int32: (id: Int64, at: UInt64)] = [:]
    private var parentCache: [Int64: Int64] = [:]
    private var pathCache: [Int64: String] = [:]
    private var deltas: [Int64: Delta] = [:]
    private var rootCache: [String]?
    private var depth = 0
    private var chunk = 64
    private var pathEpoch = 0
    private(set) var focus: [Int64] = []

    public var readBudget: TimeInterval = 0
    public var rescanInterval: TimeInterval = 0
    public var rescanIntervalPerItem: TimeInterval = 0
    public private(set) var isCooling = false

    public var scanWidth = 1 {
        didSet {
            scanWidth = max(1, min(scanWidth, 8))
            while pool.count < scanWidth { pool.append(BulkDirectory()) }
        }
    }

    struct Delta {
        var alloc: Int64 = 0
        var logical: Int64 = 0
        var items: Int64 = 0
        var pending: Int64 = 0
        var fresh: Int64 = 0
        var partial: Int64 = 0

        var isZero: Bool { alloc == 0 && logical == 0 && items == 0 && pending == 0 && fresh == 0 && partial == 0 }
        var changesSize: Bool { alloc != 0 || logical != 0 || items != 0 }

        static prefix func - (d: Delta) -> Delta {
            Delta(alloc: -d.alloc, logical: -d.logical, items: -d.items, pending: -d.pending, fresh: -d.fresh, partial: -d.partial)
        }

        static func += (a: inout Delta, b: Delta) {
            a.alloc += b.alloc; a.logical += b.logical; a.items += b.items
            a.pending += b.pending; a.fresh += b.fresh; a.partial += b.partial
        }
    }

    private struct Node {
        var id: Int64
        var parent: Int64
        var flags: Int64
    }

    public init(databaseURL: URL = SizeIndexLocation.database, cacheKiB: Int = 16384) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        databasePath = SizeIndexLocation.canonical(databaseURL).path
        excluded = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        db = try IndexDatabase(databaseURL, cacheKiB: cacheKiB)
        for suffix in ["", "-wal", "-shm"] { chmod(databaseURL.path + suffix, 0o600) }
        try migrate()
    }

    private func migrate() throws {
        let version = try db.first("PRAGMA user_version", args: []) { IndexDatabase.int($0, 0) } ?? 0
        guard version != Self.schemaVersion else { return }
        var objects: [(type: String, name: String)] = []
        try db.each("SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND type IN ('trigger','view','table')", args: []) { s in
            objects.append((IndexDatabase.text(s, 0) ?? "", IndexDatabase.text(s, 1) ?? ""))
        }
        try db.transaction {
            for kind in ["trigger", "view", "table"] {
                for object in objects where object.type == kind {
                    try db.exec("DROP \(kind.uppercased()) IF EXISTS \"\(object.name.replacingOccurrences(of: "\"", with: "\"\""))\"")
                }
            }
            try db.exec("""
            CREATE TABLE volumes(id INTEGER PRIMARY KEY,uuid TEXT NOT NULL UNIQUE,device INTEGER,journal TEXT,event_id TEXT);
            CREATE TABLE roots(path TEXT PRIMARY KEY);
            CREATE TABLE dirs(id INTEGER PRIMARY KEY,vol INTEGER NOT NULL,inode INTEGER NOT NULL,parent INTEGER NOT NULL DEFAULT 0,name TEXT NOT NULL,flags INTEGER NOT NULL DEFAULT 0,
              own_alloc INTEGER NOT NULL DEFAULT 0,own_logical INTEGER NOT NULL DEFAULT 0,own_items INTEGER NOT NULL DEFAULT 0,
              alloc INTEGER NOT NULL DEFAULT 0,logical INTEGER NOT NULL DEFAULT 0,items INTEGER NOT NULL DEFAULT 0,
              multi_alloc INTEGER NOT NULL DEFAULT 0,multi_logical INTEGER NOT NULL DEFAULT 0,
              pending INTEGER NOT NULL DEFAULT 0,fresh INTEGER NOT NULL DEFAULT 0,partial INTEGER NOT NULL DEFAULT 0,scanned_at REAL NOT NULL DEFAULT 0,
              listed_at REAL NOT NULL DEFAULT 0,sig INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX dirs_identity ON dirs(vol,inode);
            CREATE INDEX dirs_parent ON dirs(parent);
            CREATE INDEX dirs_todo ON dirs(parent) WHERE pending>0;
            CREATE TABLE files(dir INTEGER NOT NULL,name TEXT NOT NULL,PRIMARY KEY(dir,name)) WITHOUT ROWID;
            CREATE TABLE links(dir INTEGER NOT NULL,inode INTEGER NOT NULL,n INTEGER NOT NULL,PRIMARY KEY(dir,inode)) WITHOUT ROWID;
            CREATE TABLE multi(vol INTEGER NOT NULL,inode INTEGER NOT NULL,alloc INTEGER NOT NULL,logical INTEGER NOT NULL,PRIMARY KEY(vol,inode)) WITHOUT ROWID;
            CREATE TABLE anc(dir INTEGER NOT NULL,inode INTEGER NOT NULL,refs INTEGER NOT NULL,PRIMARY KEY(dir,inode)) WITHOUT ROWID;
            CREATE INDEX anc_inode ON anc(inode);
            PRAGMA user_version=\(Self.schemaVersion);
            """)
        }
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        if depth > 0 { return try work() }
        try db.exec("BEGIN IMMEDIATE")
        depth = 1
        do {
            let value = try work()
            try flush()
            depth = 0
            try db.exec("COMMIT")
            return value
        } catch {
            depth = 0
            deltas.removeAll()
            parentCache.removeAll()
            pathCache.removeAll()
            volumeCache.removeAll()
            rootCache = nil
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private func flush() throws {
        guard !deltas.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for (id, d) in deltas where !d.isZero {
            if d.changesSize {
                try db.run("UPDATE dirs SET alloc=alloc+?,logical=logical+?,items=items+?,pending=pending+?,fresh=fresh+?,partial=partial+?,scanned_at=? WHERE id=?",
                           args: [.int(d.alloc), .int(d.logical), .int(d.items), .int(d.pending), .int(d.fresh), .int(d.partial), .real(now), .int(id)])
            } else {
                try db.run("UPDATE dirs SET pending=pending+?,fresh=fresh+?,partial=partial+? WHERE id=?", args: [.int(d.pending), .int(d.fresh), .int(d.partial), .int(id)])
            }
        }
        deltas.removeAll(keepingCapacity: true)
    }

    private func forgetPaths() {
        pathCache.removeAll(keepingCapacity: true)
        pathEpoch &+= 1
    }

    private func parent(of id: Int64) throws -> Int64 {
        if let known = parentCache[id] { return known }
        let found = try db.first("SELECT parent FROM dirs WHERE id=?", args: [.int(id)]) { IndexDatabase.int($0, 0) } ?? 0
        if parentCache.count > 262_144 { parentCache.removeAll(keepingCapacity: true) }
        parentCache[id] = found
        return found
    }

    func chain(_ id: Int64) throws -> [Int64] {
        var out: [Int64] = []
        var current = id
        while current != 0 && out.count < 4096 {
            out.append(current)
            current = try parent(of: current)
        }
        return out
    }

    private func bump(_ start: Int64, _ d: Delta) throws {
        guard !d.isZero else { return }
        var current = start
        var hops = 0
        while current != 0 && hops < 4096 {
            deltas[current, default: Delta()] += d
            current = try parent(of: current)
            hops += 1
        }
    }

    private func totals(of id: Int64) throws -> Delta {
        var d = try db.first("SELECT alloc,logical,items,pending,fresh,partial FROM dirs WHERE id=?", args: [.int(id)]) { s in
            Delta(alloc: IndexDatabase.int(s, 0), logical: IndexDatabase.int(s, 1), items: IndexDatabase.int(s, 2),
                  pending: IndexDatabase.int(s, 3), fresh: IndexDatabase.int(s, 4), partial: IndexDatabase.int(s, 5))
        } ?? Delta()
        if let waiting = deltas[id] { d += waiting }
        return d
    }

    private func setFlags(_ id: Int64, clear: Int64 = 0, set: Int64 = 0) throws {
        try db.run("UPDATE dirs SET flags=(flags&~?)|? WHERE id=?", args: [.int(clear), .int(set), .int(id)])
    }

    private func mark(_ id: Int64, recursive: Bool) throws {
        guard let flags = try db.first("SELECT flags FROM dirs WHERE id=?", args: [.int(id)], { IndexDatabase.int($0, 0) }) else { return }
        let wanted = IndexFlag.scan | (recursive ? IndexFlag.recursive : 0)
        guard flags & wanted != wanted else { return }
        try setFlags(id, set: wanted)
        if flags & IndexFlag.scan == 0 { try bump(id, Delta(pending: 1)) }
    }

    private func volumeID(device: Int32, path: String) throws -> Int64 {
        let now = DispatchTime.now().uptimeNanoseconds
        if let known = volumeCache[device], now &- known.at < 60_000_000_000 { return known.id }
        guard let uuid = IndexVolume.identifier(forPath: path) else { throw POSIXError(.ENOTSUP) }
        let id: Int64
        if let existing = try db.first("SELECT id FROM volumes WHERE uuid=?", args: [.text(uuid)], { IndexDatabase.int($0, 0) }) {
            id = existing
            try db.run("UPDATE volumes SET device=NULL WHERE device=? AND id!=?", args: [.int(Int64(device)), .int(id)])
            try db.run("UPDATE volumes SET device=? WHERE id=? AND device IS NOT ?", args: [.int(Int64(device)), .int(id), .int(Int64(device))])
        } else {
            try db.run("UPDATE volumes SET device=NULL WHERE device=?", args: [.int(Int64(device))])
            try db.run("INSERT INTO volumes(uuid,device) VALUES(?,?)", args: [.text(uuid), .int(Int64(device))])
            id = db.lastInsertID()
        }
        volumeCache[device] = (id, now)
        return id
    }

    func forgetVolumes() { volumeCache.removeAll() }

    public func relax() {
        parentCache.removeAll()
        pathCache.removeAll()
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA shrink_memory;")
    }

    private func identity(_ path: String) -> (device: Int32, inode: Int64, hidden: Bool)? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (st.st_dev, Int64(bitPattern: UInt64(st.st_ino)), st.st_flags & UInt32(UF_HIDDEN) != 0)
    }

    private func node(vol: Int64, inode: Int64) throws -> Node? {
        try db.first("SELECT id,parent,flags FROM dirs WHERE vol=? AND inode=?", args: [.int(vol), .int(inode)]) { s in
            Node(id: IndexDatabase.int(s, 0), parent: IndexDatabase.int(s, 1), flags: IndexDatabase.int(s, 2))
        }
    }

    private func node(at path: String) throws -> Node? {
        guard let who = identity(path), let vol = try? volumeID(device: who.device, path: path) else { return nil }
        return try node(vol: vol, inode: who.inode)
    }

    private func insert(vol: Int64, inode: Int64, parent: Int64, name: String, hidden: Bool) throws -> Int64 {
        let flags = IndexFlag.scan | IndexFlag.fresh | (hidden ? IndexFlag.hidden : 0)
        try db.run("INSERT INTO dirs(vol,inode,parent,name,flags,pending,fresh) VALUES(?,?,?,?,?,1,1)",
                   args: [.int(vol), .int(inode), .int(parent), .text(name), .int(flags)])
        let id = db.lastInsertID()
        parentCache[id] = parent
        return id
    }

    func path(of id: Int64) throws -> String? {
        if let known = pathCache[id] { return known }
        guard let (parent, name, flags) = try db.first("SELECT parent,name,flags FROM dirs WHERE id=?", args: [.int(id)], {
            (IndexDatabase.int($0, 0), IndexDatabase.text($0, 1) ?? "", IndexDatabase.int($0, 2))
        }) else { return nil }
        let result: String
        if parent == 0 {
            guard flags & IndexFlag.detached == 0 else { return nil }
            result = name
        } else {
            guard let base = try path(of: parent) else { return nil }
            result = base == "/" ? "/" + name : base + "/" + name
        }
        if pathCache.count > 65_536 { forgetPaths() }
        pathCache[id] = result
        return result
    }

    private func rootPaths() throws -> [String] {
        if let rootCache { return rootCache }
        var found: [String] = []
        try db.each("SELECT path FROM roots ORDER BY path", args: []) { s in
            if let path = IndexDatabase.text(s, 0) { found.append(path) }
        }
        rootCache = found
        return found
    }

    func contains(_ path: String) throws -> Bool {
        for root in try rootPaths() {
            if root == "/" ? path.hasPrefix("/") : (path == root || path.hasPrefix(root + "/")) { return true }
        }
        return false
    }

    func roots(within path: String, device: Int32? = nil) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var kept: [String] = []
        for root in try rootPaths() where root.hasPrefix(prefix) {
            if kept.contains(where: { root.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { continue }
            if let device {
                var st = stat()
                if stat(root, &st) == 0 && st.st_dev != device { continue }
            }
            kept.append(root)
        }
        return kept
    }

    func excludes(_ path: String) -> Bool { excluded.contains(path) }

    private func insertRoot(_ path: String) throws {
        let prefix = path == "/" ? "/" : path + "/"
        try db.run("DELETE FROM roots WHERE path!=?1 AND substr(path,1,length(?2))=?2", args: [.text(path), .text(prefix)])
        try db.run("INSERT OR IGNORE INTO roots VALUES(?)", args: [.text(path)])
        rootCache = nil
    }

    private func ensureTop(_ path: String) throws -> Int64? {
        guard let who = identity(path) else { return nil }
        let vol = try volumeID(device: who.device, path: path)
        if let found = try node(vol: vol, inode: who.inode) {
            if found.parent == 0 {
                try db.run("UPDATE dirs SET name=?1 WHERE id=?2 AND name IS NOT ?1", args: [.text(path), .int(found.id)])
                if db.changes() > 0 { forgetPaths() }
                if found.flags & IndexFlag.detached != 0 {
                    try setFlags(found.id, clear: IndexFlag.detached)
                    try mark(found.id, recursive: true)
                }
            }
            return found.id
        }
        try db.run("INSERT INTO dirs(vol,inode,parent,name,flags,pending,fresh) VALUES(?,?,0,?,?,1,1)",
                   args: [.int(vol), .int(who.inode), .text(path), .int(IndexFlag.scan | IndexFlag.fresh)])
        return db.lastInsertID()
    }

    private func materialize(_ path: String) throws -> Int64? {
        var missing: [(name: String, inode: Int64, hidden: Bool, device: Int32)] = []
        var current = path
        var base: Int64 = 0
        var baseVolume: Int64 = 0
        var baseDevice: Int32 = 0
        while true {
            guard try contains(current), let who = identity(current) else { return nil }
            let vol = try volumeID(device: who.device, path: current)
            if let found = try node(vol: vol, inode: who.inode), found.flags & IndexFlag.detached == 0 {
                base = found.id
                baseVolume = vol
                baseDevice = who.device
                break
            }
            guard current != "/" else { return nil }
            let name = (current as NSString).lastPathComponent
            missing.append((name, who.inode, who.hidden || name.hasPrefix("."), who.device))
            current = (current as NSString).deletingLastPathComponent
        }
        guard !missing.isEmpty else { return base }
        guard missing.allSatisfy({ $0.device == baseDevice }) else { return nil }
        try mark(base, recursive: false)
        var parent = base
        for part in missing.reversed() {
            if let other = try node(vol: baseVolume, inode: part.inode) {
                try adopt(other.id, under: parent, name: part.name, hidden: part.hidden)
                parent = other.id
            } else {
                let id = try insert(vol: baseVolume, inode: part.inode, parent: parent, name: part.name, hidden: part.hidden)
                try bump(parent, Delta(pending: 1, fresh: 1))
                parent = id
            }
        }
        return parent
    }

    @discardableResult func touch(_ path: String, recursive: Bool, retryDenied: Bool = true) throws -> Int64? {
        var current = path
        while true {
            guard try contains(current) else { return nil }
            if let found = try node(at: current) {
                let deep = recursive && current == path
                if retryDenied || deep || found.flags & IndexFlag.denied == 0 { try mark(found.id, recursive: deep) }
                if found.flags & IndexFlag.detached == 0 { return found.id }
            }
            guard current != "/" else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private func resolve(_ path: String) throws -> Int64? {
        if let found = try node(at: path), found.flags & IndexFlag.detached == 0 { return found.id }
        guard identity(path) != nil else { return nil }
        if try contains(path), let id = try materialize(path) { return id }
        try insertRoot(path)
        return try ensureTop(path)
    }

    private func pushFocus(_ id: Int64) {
        focus.removeAll { $0 == id }
        focus.insert(id, at: 0)
        if focus.count > Self.focusLimit { focus.removeLast(focus.count - Self.focusLimit) }
    }

    public func addRoot(_ url: URL, allowNetwork: Bool = false) throws {
        if !allowNetwork && VolumeInfo.isNetworkVolume(url) { return }
        let path = SizeIndexLocation.canonical(url).path
        try transaction {
            if try contains(path) {
                if try rootPaths().contains(path) { _ = try ensureTop(path) }
                return
            }
            try insertRoot(path)
            _ = try ensureTop(path)
        }
    }

    public func prioritize(_ url: URL) throws {
        let path = SizeIndexLocation.canonical(url).path
        try transaction {
            if let id = try resolve(path) { pushFocus(id) }
        }
    }

    public func focus(on urls: [URL]) throws {
        var ids: [Int64] = []
        var seen = Set<Int64>()
        try transaction {
            for url in urls.prefix(Self.focusLimit) {
                guard let id = try resolve(SizeIndexLocation.canonical(url).path), seen.insert(id).inserted else { continue }
                ids.append(id)
                let denied = try db.first("SELECT flags FROM dirs WHERE id=?", args: [.int(id)]) { IndexDatabase.int($0, 0) & IndexFlag.denied != 0 } ?? false
                if denied { try mark(id, recursive: false) }
            }
        }
        focus = Array((ids + focus.filter { !seen.contains($0) }).prefix(Self.focusLimit))
    }

    public func refresh(_ url: URL) throws {
        let path = SizeIndexLocation.canonical(url).path
        try transaction {
            if let id = try touch(path, recursive: false) { pushFocus(id) }
        }
    }

    @discardableResult func mark(path: String, recursive: Bool) throws -> Int64? {
        try transaction {
            if let id = try touch(path, recursive: recursive) { return id }
            return try rootPaths().contains(path) ? try ensureTop(path) : nil
        }
    }

    public func enqueue(path: String, recursive: Bool, priority: Int = 0) throws {
        let path = SizeIndexLocation.canonical(URL(fileURLWithPath: path)).path
        if let id = try mark(path: path, recursive: recursive), priority > 0 { pushFocus(id) }
    }

    public func refresh(paths: [String]) throws {
        try transaction {
            for path in paths.prefix(Self.focusLimit) {
                if let id = try touch(SizeIndexLocation.canonical(URL(fileURLWithPath: path)).path, recursive: false) { pushFocus(id) }
            }
        }
    }

    public func scan(_ url: URL) throws {
        try addRoot(url, allowNetwork: true)
        try enqueue(path: SizeIndexLocation.canonical(url).path, recursive: true)
        while try processBatch() > 0 { try Task.checkCancellation() }
        while try collectGarbage(olderThan: 0) > 0 {}
    }

    public func rebuild() throws {
        try transaction {
            for root in try rootPaths() { _ = try ensureTop(root) }
            var tops: [Int64] = []
            try db.each("SELECT id FROM dirs WHERE parent=0 AND flags&?=0", args: [.int(IndexFlag.detached)]) { tops.append(IndexDatabase.int($0, 0)) }
            for id in tops { try mark(id, recursive: true) }
        }
    }

    public var directoryCount: Int {
        Int((try? db.first("SELECT count(*) FROM dirs", args: []) { IndexDatabase.int($0, 0) }) ?? 0)
    }

    public var pendingCount: Int {
        Int((try? db.first("SELECT coalesce(sum(pending),0) FROM dirs WHERE parent=0 AND flags&?=0", args: [.int(IndexFlag.detached)]) { IndexDatabase.int($0, 0) }) ?? 0)
    }

    public var hasBulkWork: Bool {
        if !focus.isEmpty { return true }
        return ((try? db.first("SELECT 1 FROM dirs WHERE parent=0 AND fresh>0 AND flags&?=0 LIMIT 1", args: [.int(IndexFlag.detached)]) { _ in true }) ?? nil) == true
    }

    @discardableResult public func processNext() throws -> Bool {
        try processBatch(limit: 1) > 0
    }

    @discardableResult public func processBatch(limit: Int = 1024, budget: TimeInterval = 0.25) throws -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        let budgetNanos = UInt64(max(0, budget) * 1_000_000_000)
        let ceiling = max(1, limit)
        var count = 0
        var cancelled = false
        try transaction {
            while count < ceiling {
                let work = try collect(min(ceiling - count, max(scanWidth * 2, min(chunk, scanWidth * 64))))
                if work.isEmpty { break }
                let began = DispatchTime.now().uptimeNanoseconds
                let epoch = pathEpoch
                let listings = IndexScanner.readAll(work, width: scanWidth, pool: pool, skipping: excluded, budget: readBudget)
                let spent = DispatchTime.now().uptimeNanoseconds - began
                if spent > 150_000_000 { chunk = max(2, chunk / 2) } else if spent < 40_000_000 { chunk = min(512, chunk * 2) }
                for (item, listing) in zip(work, listings) {
                    if listing.status == .cancelled { cancelled = true; continue }
                    if listing.status == .skipped { continue }
                    count += 1
                    if listing.status == .gone, epoch != pathEpoch { continue }
                    try apply(item, listing)
                }
                try flush()
                if cancelled || DispatchTime.now().uptimeNanoseconds - start > budgetNanos { break }
            }
        }
        if cancelled { throw CancellationError() }
        return count
    }

    private enum Pass { case focused, unscanned, upkeep }

    private func collect(_ limit: Int) throws -> [IndexWork] {
        var out: [IndexWork] = []
        var seen = Set<Int64>()
        isCooling = false
        if !focus.isEmpty {
            var kept: [Int64] = []
            for id in focus {
                guard let pending = try db.first("SELECT pending FROM dirs WHERE id=?", args: [.int(id)], { IndexDatabase.int($0, 0) }), pending > 0 else { continue }
                kept.append(id)
                if out.count < limit, try path(of: id) != nil { try gather(from: id, into: &out, seen: &seen, limit: limit, pass: .focused) }
            }
            focus = kept
        }
        guard out.count < limit else { return out }
        var tops: [(id: Int64, fresh: Int64)] = []
        try db.each("SELECT id,fresh FROM dirs WHERE parent=0 AND pending>0 AND flags&?=0", args: [.int(IndexFlag.detached)]) {
            tops.append((IndexDatabase.int($0, 0), IndexDatabase.int($0, 1)))
        }
        for top in tops where top.fresh > 0 && out.count < limit { try gather(from: top.id, into: &out, seen: &seen, limit: limit, pass: .unscanned) }
        let adopting = try db.first("SELECT 1 FROM dirs WHERE parent=0 AND flags&?!=0 LIMIT 1", args: [.int(IndexFlag.detached)]) { _ in true } ?? false
        for top in tops where out.count < limit { try gather(from: top.id, into: &out, seen: &seen, limit: limit, pass: adopting ? .focused : .upkeep) }
        return out
    }

    private func gather(from root: Int64, into out: inout [IndexWork], seen: inout Set<Int64>, limit: Int, pass: Pass) throws {
        var stack = [root]
        let now = Date().timeIntervalSince1970
        let children = pass == .unscanned ? "SELECT id FROM dirs WHERE parent=? AND pending>0 AND fresh>0 LIMIT ?" : "SELECT id FROM dirs WHERE parent=? AND pending>0 LIMIT ?"
        while out.count < limit, let id = stack.popLast() {
            guard let (flags, inode, pending, fresh, listed, items) = try db.first("SELECT flags,inode,pending,fresh,listed_at,own_items FROM dirs WHERE id=?", args: [.int(id)], {
                (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1), IndexDatabase.int($0, 2), IndexDatabase.int($0, 3), IndexDatabase.real($0, 4), IndexDatabase.int($0, 5))
            }), pending > 0, pass != .unscanned || fresh > 0 else { continue }
            let own: Int64 = flags & IndexFlag.scan != 0 ? 1 : 0
            let unscanned = flags & IndexFlag.fresh != 0
            if own == 1, flags & IndexFlag.deferred == 0, pass != .unscanned || unscanned, !seen.contains(id) {
                let rest = unscanned || pass != .upkeep || rescanInterval <= 0 ? 0 : max(rescanInterval, Double(items) * rescanIntervalPerItem)
                if rest > 0, now - listed < rest, now >= listed {
                    isCooling = true
                } else if let path = try path(of: id) {
                    seen.insert(id)
                    out.append(IndexWork(id: id, path: path, inode: inode))
                }
            }
            guard pending > own else { continue }
            try db.each(children, args: [.int(id), .int(Int64(limit - out.count + 16))]) { stack.append(IndexDatabase.int($0, 0)) }
        }
    }

    private func adjust(_ dir: Int64, vol: Int64, inode: Int64, by count: Int64) throws {
        guard count != 0 else { return }
        let size = try db.first("SELECT alloc,logical FROM multi WHERE vol=? AND inode=?", args: [.int(vol), .int(inode)]) { (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1)) } ?? (0, 0)
        if count > 0 {
            let refs = try db.first("INSERT INTO anc(dir,inode,refs) VALUES(?,?,?) ON CONFLICT(dir,inode) DO UPDATE SET refs=refs+excluded.refs RETURNING refs",
                                    args: [.int(dir), .int(inode), .int(count)]) { IndexDatabase.int($0, 0) } ?? 0
            if refs == count {
                try db.run("UPDATE dirs SET multi_alloc=multi_alloc+?,multi_logical=multi_logical+? WHERE id=?", args: [.int(size.0), .int(size.1), .int(dir)])
            }
        } else {
            guard let refs = try db.first("UPDATE anc SET refs=refs+? WHERE dir=? AND inode=? RETURNING refs", args: [.int(count), .int(dir), .int(inode)], { IndexDatabase.int($0, 0) }) else { return }
            if refs <= 0 {
                try db.run("DELETE FROM anc WHERE dir=? AND inode=?", args: [.int(dir), .int(inode)])
                try db.run("UPDATE dirs SET multi_alloc=multi_alloc-?,multi_logical=multi_logical-? WHERE id=?", args: [.int(size.0), .int(size.1), .int(dir)])
            }
        }
    }

    private func resize(vol: Int64, inode: Int64, alloc: Int64, logical: Int64) throws {
        guard let old = try db.first("SELECT alloc,logical FROM multi WHERE vol=? AND inode=?", args: [.int(vol), .int(inode)], { (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1)) }) else {
            try db.run("INSERT INTO multi(vol,inode,alloc,logical) VALUES(?,?,?,?)", args: [.int(vol), .int(inode), .int(alloc), .int(logical)])
            return
        }
        guard old.0 != alloc || old.1 != logical else { return }
        var holders: [Int64] = []
        try db.each("SELECT a.dir FROM anc a JOIN dirs d ON d.id=a.dir WHERE a.inode=? AND d.vol=?", args: [.int(inode), .int(vol)]) { holders.append(IndexDatabase.int($0, 0)) }
        for holder in holders {
            try db.run("UPDATE dirs SET multi_alloc=multi_alloc+?,multi_logical=multi_logical+? WHERE id=?", args: [.int(alloc - old.0), .int(logical - old.1), .int(holder)])
        }
        try db.run("UPDATE multi SET alloc=?,logical=? WHERE vol=? AND inode=?", args: [.int(alloc), .int(logical), .int(vol), .int(inode)])
    }

    private func forgetShared(vol: Int64, inode: Int64) throws {
        let held = try db.first("SELECT 1 FROM anc a JOIN dirs d ON d.id=a.dir WHERE a.inode=? AND d.vol=? LIMIT 1", args: [.int(inode), .int(vol)]) { _ in true } ?? false
        if !held { try db.run("DELETE FROM multi WHERE vol=? AND inode=?", args: [.int(vol), .int(inode)]) }
    }

    private func sharedRefs(of id: Int64) throws -> [(inode: Int64, refs: Int64)] {
        var out: [(Int64, Int64)] = []
        try db.each("SELECT inode,refs FROM anc WHERE dir=?", args: [.int(id)]) { out.append((IndexDatabase.int($0, 0), IndexDatabase.int($0, 1))) }
        return out
    }

    private func volume(of id: Int64) throws -> Int64 {
        try db.first("SELECT vol FROM dirs WHERE id=?", args: [.int(id)]) { IndexDatabase.int($0, 0) } ?? 0
    }

    private func detach(_ id: Int64) throws {
        guard let parent = try db.first("SELECT parent FROM dirs WHERE id=?", args: [.int(id)], { IndexDatabase.int($0, 0) }), parent != 0 else { return }
        let contribution = try totals(of: id)
        let refs = try sharedRefs(of: id)
        try bump(parent, -contribution)
        if !refs.isEmpty {
            let vol = try volume(of: id)
            let lineage = try chain(parent)
            for ref in refs { for ancestor in lineage { try adjust(ancestor, vol: vol, inode: ref.inode, by: -ref.refs) } }
        }
        try db.run("UPDATE dirs SET parent=0,flags=(flags&~?)|?,scanned_at=? WHERE id=?",
                   args: [.int(IndexFlag.deferred), .int(IndexFlag.detached), .real(Date().timeIntervalSince1970), .int(id)])
        parentCache[id] = 0
        forgetPaths()
    }

    private func adopt(_ id: Int64, under parent: Int64, name: String, hidden: Bool) throws {
        guard id != parent, let old = try db.first("SELECT parent FROM dirs WHERE id=?", args: [.int(id)], { IndexDatabase.int($0, 0) }) else { return }
        let above = try chain(parent)
        if let index = above.firstIndex(of: id), index > 0 {
            try mark(id, recursive: false)
            try detach(above[index - 1])
        }
        let contribution = try totals(of: id)
        let refs = try sharedRefs(of: id)
        let vol = refs.isEmpty ? 0 : try volume(of: id)
        if old != 0 {
            try bump(old, -contribution)
            if !refs.isEmpty {
                let lineage = try chain(old)
                for ref in refs { for ancestor in lineage { try adjust(ancestor, vol: vol, inode: ref.inode, by: -ref.refs) } }
            }
            try mark(old, recursive: false)
        }
        try db.run("UPDATE dirs SET parent=?,name=?,flags=(flags&~?)|? WHERE id=?",
                   args: [.int(parent), .text(name), .int(IndexFlag.detached | IndexFlag.deferred | IndexFlag.hidden), .int(hidden ? IndexFlag.hidden : 0), .int(id)])
        parentCache[id] = parent
        forgetPaths()
        try bump(parent, contribution)
        if !refs.isEmpty {
            let lineage = try chain(parent)
            for ref in refs { for ancestor in lineage { try adjust(ancestor, vol: vol, inode: ref.inode, by: ref.refs) } }
        }
    }

    private func apply(_ work: IndexWork, _ listing: IndexListing) throws {
        guard let row = try db.first("SELECT parent,flags,vol,own_alloc,own_logical,own_items,sig FROM dirs WHERE id=?", args: [.int(work.id)], { s in
            (parent: IndexDatabase.int(s, 0), flags: IndexDatabase.int(s, 1), vol: IndexDatabase.int(s, 2),
             alloc: IndexDatabase.int(s, 3), logical: IndexDatabase.int(s, 4), items: IndexDatabase.int(s, 5), signature: IndexDatabase.int(s, 6))
        }) else { return }
        let now = Date().timeIntervalSince1970
        let scanning: Int64 = row.flags & IndexFlag.scan != 0 ? 1 : 0
        let fresh: Int64 = row.flags & IndexFlag.fresh != 0 ? 1 : 0
        let wasPartial: Int64 = row.flags & IndexFlag.partial != 0 ? 1 : 0
        var status = listing.status
        if status == .ok, let vol = try? volumeID(device: listing.device, path: work.path), vol != row.vol { status = .gone }

        switch status {
        case .cancelled, .skipped:
            return
        case .gone:
            if row.parent != 0 {
                try setFlags(work.id, set: IndexFlag.deferred)
                try mark(row.parent, recursive: false)
                try db.run("UPDATE dirs SET listed_at=0 WHERE id=?", args: [.int(row.parent)])
            } else {
                try setFlags(work.id, clear: IndexFlag.scan | IndexFlag.recursive, set: fresh == 1 ? IndexFlag.detached : 0)
                try bump(work.id, Delta(pending: -scanning))
                forgetPaths()
            }
            return
        case .unreadable:
            try db.run("UPDATE dirs SET flags=(flags&~?)|?,scanned_at=?,listed_at=? WHERE id=?",
                       args: [.int(IndexFlag.scan | IndexFlag.fresh | IndexFlag.recursive | IndexFlag.deferred), .int(IndexFlag.partial | IndexFlag.denied), .real(now), .real(now), .int(work.id)])
            try bump(work.id, Delta(pending: -scanning, fresh: -fresh, partial: 1 - wasPartial))
            return
        case .ok:
            break
        }

        let recursive = row.flags & IndexFlag.recursive != 0
        var added: Int64 = 0
        var existing: [Int64: (id: Int64, name: String, flags: Int64)] = [:]
        try db.each("SELECT id,inode,name,flags FROM dirs WHERE parent=?", args: [.int(work.id)]) { s in
            existing[IndexDatabase.int(s, 1)] = (IndexDatabase.int(s, 0), IndexDatabase.text(s, 2) ?? "", IndexDatabase.int(s, 3))
        }
        for child in listing.children {
            if let old = existing.removeValue(forKey: child.inode) {
                let visibility = child.hidden ? IndexFlag.hidden : 0
                if old.flags & (IndexFlag.deferred | IndexFlag.hidden) != visibility {
                    try setFlags(old.id, clear: IndexFlag.deferred | IndexFlag.hidden, set: visibility)
                }
                if old.name != child.name || old.name.utf8.count != child.name.utf8.count {
                    try db.run("UPDATE dirs SET name=? WHERE id=?", args: [.text(child.name), .int(old.id)])
                    forgetPaths()
                }
                if recursive { try mark(old.id, recursive: true) }
            } else if let other = try node(vol: row.vol, inode: child.inode) {
                try adopt(other.id, under: work.id, name: child.name, hidden: child.hidden)
                if recursive { try mark(other.id, recursive: true) }
            } else {
                _ = try insert(vol: row.vol, inode: child.inode, parent: work.id, name: child.name, hidden: child.hidden)
                added += 1
            }
        }
        for old in existing.values { try detach(old.id) }

        if fresh == 1 {
            for name in listing.names { try db.run("INSERT OR IGNORE INTO files(dir,name) VALUES(?,?)", args: [.int(work.id), .text(name)]) }
        } else if row.signature != listing.signature {
            var known = Set<String>()
            try db.each("SELECT name FROM files WHERE dir=?", args: [.int(work.id)]) { s in
                if let name = IndexDatabase.text(s, 0) { known.insert(name) }
            }
            for name in listing.names where known.remove(name) == nil {
                try db.run("INSERT OR IGNORE INTO files(dir,name) VALUES(?,?)", args: [.int(work.id), .text(name)])
            }
            for name in known { try db.run("DELETE FROM files WHERE dir=? AND name=?", args: [.int(work.id), .text(name)]) }
        }

        var links: [Int64: Int64] = [:]
        if fresh == 0 {
            try db.each("SELECT inode,n FROM links WHERE dir=?", args: [.int(work.id)]) { links[IndexDatabase.int($0, 0)] = IndexDatabase.int($0, 1) }
        }
        if !listing.shared.isEmpty || !links.isEmpty {
            let lineage = try chain(work.id)
            for (inode, entry) in listing.shared {
                try resize(vol: row.vol, inode: inode, alloc: entry.alloc, logical: entry.logical)
                let previous = links.removeValue(forKey: inode) ?? 0
                guard entry.count != previous else { continue }
                for ancestor in lineage { try adjust(ancestor, vol: row.vol, inode: inode, by: entry.count - previous) }
                try db.run("INSERT INTO links(dir,inode,n) VALUES(?,?,?) ON CONFLICT(dir,inode) DO UPDATE SET n=excluded.n", args: [.int(work.id), .int(inode), .int(entry.count)])
            }
            for (inode, previous) in links {
                for ancestor in lineage { try adjust(ancestor, vol: row.vol, inode: inode, by: -previous) }
                try db.run("DELETE FROM links WHERE dir=? AND inode=?", args: [.int(work.id), .int(inode)])
                try forgetShared(vol: row.vol, inode: inode)
            }
        }

        let partial: Int64 = listing.partial ? 1 : 0
        try bump(work.id, Delta(alloc: listing.alloc - row.alloc, logical: listing.logical - row.logical, items: listing.items - row.items,
                                pending: added - scanning, fresh: added - fresh, partial: partial - wasPartial))
        try db.run("UPDATE dirs SET own_alloc=?,own_logical=?,own_items=?,flags=(flags&~?)|?,scanned_at=?,listed_at=?,sig=? WHERE id=?",
                   args: [.int(listing.alloc), .int(listing.logical), .int(listing.items),
                          .int(IndexFlag.scan | IndexFlag.fresh | IndexFlag.recursive | IndexFlag.partial | IndexFlag.deferred | IndexFlag.denied), .int(listing.partial ? IndexFlag.partial : 0),
                          .real(now), .real(now), .int(listing.signature), .int(work.id)])
    }

    @discardableResult public func collectGarbage(olderThan age: TimeInterval = 30, budget: Int = 2000) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - age
        var tops: [Int64] = []
        try db.each("SELECT id FROM dirs WHERE parent=0 AND flags&?!=0 AND scanned_at<=? LIMIT 64", args: [.int(IndexFlag.detached), .real(cutoff)]) { tops.append(IndexDatabase.int($0, 0)) }
        guard !tops.isEmpty else { return 0 }
        var remaining = max(1, budget)
        try transaction {
            for top in tops where remaining > 0 { _ = try reap(top, &remaining) }
        }
        return max(1, budget) - remaining
    }

    private func reap(_ id: Int64, _ remaining: inout Int) throws -> Bool {
        while remaining > 0 {
            var children: [Int64] = []
            try db.each("SELECT id FROM dirs WHERE parent=? LIMIT 128", args: [.int(id)]) { children.append(IndexDatabase.int($0, 0)) }
            if children.isEmpty { break }
            for child in children {
                if try !reap(child, &remaining) { return false }
            }
        }
        guard remaining > 0 else { return false }
        try remove(id)
        remaining -= 1
        return true
    }

    private func remove(_ id: Int64) throws {
        guard let (parent, vol) = try db.first("SELECT parent,vol FROM dirs WHERE id=?", args: [.int(id)], { (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1)) }) else { return }
        let contribution = try totals(of: id)
        var links: [(Int64, Int64)] = []
        try db.each("SELECT inode,n FROM links WHERE dir=?", args: [.int(id)]) { links.append((IndexDatabase.int($0, 0), IndexDatabase.int($0, 1))) }
        if !links.isEmpty {
            let lineage = try chain(id)
            for (inode, count) in links { for ancestor in lineage { try adjust(ancestor, vol: vol, inode: inode, by: -count) } }
        }
        if parent != 0 { try bump(parent, -contribution) }
        try db.run("DELETE FROM files WHERE dir=?", args: [.int(id)])
        try db.run("DELETE FROM links WHERE dir=?", args: [.int(id)])
        try db.run("DELETE FROM anc WHERE dir=?", args: [.int(id)])
        try db.run("DELETE FROM dirs WHERE id=?", args: [.int(id)])
        for (inode, _) in links { try forgetShared(vol: vol, inode: inode) }
        deltas[id] = nil
        parentCache[id] = nil
        pathCache[id] = nil
    }
}
