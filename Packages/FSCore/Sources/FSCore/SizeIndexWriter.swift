import Foundation
import Darwin

public final class SizeIndexWriter {
    static let schemaVersion: Int64 = 2
    let db: IndexDatabase
    private let bulk = BulkDirectory()
    private let databasePath: String
    private var volumeIDs: [Int32: String] = [:]

    struct Delta {
        var alloc: Int64 = 0
        var logical: Int64 = 0
        var items: Int64 = 0
        var multi: Int64 = 0
        var dirs: Int64 = 0
        var unscanned: Int64 = 0
        var partial: Int64 = 0

        static prefix func - (d: Delta) -> Delta {
            Delta(alloc: -d.alloc, logical: -d.logical, items: -d.items, multi: -d.multi, dirs: -d.dirs, unscanned: -d.unscanned, partial: -d.partial)
        }

        static func += (a: inout Delta, b: Delta) {
            a.alloc += b.alloc; a.logical += b.logical; a.items += b.items; a.multi += b.multi
            a.dirs += b.dirs; a.unscanned += b.unscanned; a.partial += b.partial
        }
    }

    private struct Existing {
        var inode: String
        var isDir: Bool
        var alloc: Int64
        var logical: Int64
        var multi: Bool
    }

    private struct Found {
        var name: String
        var inode: String
        var isDir: Bool
        var alloc: Int64
        var logical: Int64
        var multi: Bool
        var links: Int64
    }

    private struct ChildRow {
        var parent: String?
        var path: String?
        var contribution: Delta
        var selfPending: Int64
    }

    public init(databaseURL: URL = SizeIndexLocation.database) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        databasePath = SizeIndexLocation.canonical(databaseURL).path
        db = try IndexDatabase(databaseURL)
        for suffix in ["", "-wal", "-shm"] { chmod(databaseURL.path + suffix, 0o600) }
        try migrate()
        try db.exec("""
        PRAGMA temp.cache_size=-512;
        PRAGMA temp.cache_spill=128;
        CREATE TEMP TABLE IF NOT EXISTS seen_names(name TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TEMP TABLE IF NOT EXISTS seen_dirs(inode TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TEMP TABLE IF NOT EXISTS multi_work(inode TEXT,count INTEGER,alloc INTEGER,logical INTEGER);
        """)
    }

    private func migrate() throws {
        let version = try db.first("PRAGMA user_version", args: []) { IndexDatabase.int($0, 0) } ?? 0
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            try db.exec("""
            DROP TRIGGER IF EXISTS count_add;
            DROP TRIGGER IF EXISTS count_remove;
            DROP TRIGGER IF EXISTS file_resize;
            DROP TRIGGER IF EXISTS entry_add;
            DROP TRIGGER IF EXISTS entry_remove;
            DROP TABLE IF EXISTS ancestor_refs;
            DROP TABLE IF EXISTS entries;
            DROP TABLE IF EXISTS files;
            DROP TABLE IF EXISTS directories;
            DROP TABLE IF EXISTS pending;
            CREATE TABLE IF NOT EXISTS volumes(uuid TEXT PRIMARY KEY,device INTEGER,journal TEXT,event_id TEXT);
            CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY);
            CREATE TABLE directories(volume_uuid TEXT NOT NULL,inode TEXT NOT NULL,parent_inode TEXT,name TEXT,path TEXT UNIQUE,
              own_alloc INTEGER NOT NULL DEFAULT 0,own_logical INTEGER NOT NULL DEFAULT 0,own_items INTEGER NOT NULL DEFAULT 0,own_multi INTEGER NOT NULL DEFAULT 0,
              sub_alloc INTEGER NOT NULL DEFAULT 0,sub_logical INTEGER NOT NULL DEFAULT 0,multi_alloc INTEGER NOT NULL DEFAULT 0,multi_logical INTEGER NOT NULL DEFAULT 0,
              total_alloc INTEGER NOT NULL DEFAULT 0,total_logical INTEGER NOT NULL DEFAULT 0,item_count INTEGER NOT NULL DEFAULT 0,multi_count INTEGER NOT NULL DEFAULT 0,
              dir_count INTEGER NOT NULL DEFAULT 1,unscanned INTEGER NOT NULL DEFAULT 1,partial_count INTEGER NOT NULL DEFAULT 0,
              self_pending INTEGER NOT NULL DEFAULT 1,self_partial INTEGER NOT NULL DEFAULT 0,
              scanned_at REAL DEFAULT 0,generation INTEGER DEFAULT 0,state TEXT DEFAULT 'stale',scan_state TEXT DEFAULT 'partial',
              PRIMARY KEY(volume_uuid,inode));
            CREATE INDEX directory_parent ON directories(volume_uuid,parent_inode);
            CREATE TABLE entries(volume_uuid TEXT NOT NULL,parent TEXT NOT NULL,name TEXT NOT NULL,inode TEXT NOT NULL,is_dir INTEGER NOT NULL,
              alloc INTEGER NOT NULL DEFAULT 0,logical INTEGER NOT NULL DEFAULT 0,multi INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(volume_uuid,parent,name));
            CREATE TABLE files(volume_uuid TEXT,inode TEXT,alloc INTEGER,logical INTEGER,links INTEGER,PRIMARY KEY(volume_uuid,inode));
            CREATE TABLE ancestor_refs(volume_uuid TEXT,ancestor TEXT,inode TEXT,refs INTEGER,PRIMARY KEY(volume_uuid,ancestor,inode));
            CREATE INDEX ancestor_refs_inode ON ancestor_refs(volume_uuid,inode);
            CREATE TABLE pending(path TEXT PRIMARY KEY,recursive INTEGER DEFAULT 1,priority INTEGER DEFAULT 0);
            CREATE INDEX pending_priority ON pending(priority);
            INSERT INTO pending(path,recursive,priority) SELECT path,1,0 FROM roots;
            PRAGMA user_version=2;
            """)
        }
    }

    func contains(_ path: String) throws -> Bool {
        try db.first("SELECT 1 FROM roots WHERE ?1=path OR (path='/' AND substr(?1,1,1)='/') OR substr(?1,1,length(path)+1)=path||'/' LIMIT 1", args: [.text(path)]) { _ in true } ?? false
    }

    func roots(within path: String, device: Int32? = nil) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var found: [String] = []
        try db.each("SELECT path FROM roots WHERE substr(path,1,length(?1))=?1 ORDER BY path", args: [.text(prefix)]) { s in
            if let root = IndexDatabase.text(s, 0) { found.append(root) }
        }
        var kept: [String] = []
        var keptSet = Set<String>()
        for root in found {
            var ancestor = root
            var covered = keptSet.contains(root)
            while !covered && ancestor != "/" && !ancestor.isEmpty {
                ancestor = (ancestor as NSString).deletingLastPathComponent
                covered = keptSet.contains(ancestor)
            }
            if covered { continue }
            if let device {
                var st = stat()
                if stat(root, &st) == 0 && st.st_dev != device { continue }
            }
            kept.append(root)
            keptSet.insert(root)
        }
        return kept
    }

    func excludes(_ path: String) -> Bool {
        path == databasePath || path == databasePath + "-wal" || path == databasePath + "-shm"
    }

    public func addRoot(_ url: URL, allowNetwork: Bool = false) throws {
        if !allowNetwork && VolumeInfo.isNetworkVolume(url) { return }
        let path = SizeIndexLocation.canonical(url).path
        let isNew = try db.row("SELECT 1 FROM roots WHERE path=?", [path]) == nil
        try db.run("INSERT OR IGNORE INTO roots VALUES(?)", [path])
        if isNew { try enqueue(path: path, recursive: true, priority: 0) }
    }

    static let prioritizeLimit: Int64 = 4096

    public func prioritize(_ url: URL) throws {
        let path = SizeIndexLocation.canonical(url).path
        var st = stat()
        if lstat(path, &st) == 0, let (volume, inode, unscanned) = try db.first("SELECT volume_uuid,inode,unscanned FROM directories WHERE path=? AND inode=?", args: [.text(path), .text(String(st.st_ino))], {
            (IndexDatabase.text($0, 0) ?? "", IndexDatabase.text($0, 1) ?? "", IndexDatabase.int($0, 2))
        }) {
            guard unscanned > 0 else { return }
            try db.run("""
            WITH RECURSIVE s(i) AS (SELECT ?1 UNION ALL SELECT d.inode FROM directories d JOIN s ON d.parent_inode=s.i WHERE d.volume_uuid=?2 AND d.unscanned>0)
            INSERT INTO pending(path,recursive,priority) SELECT d.path,0,10 FROM s JOIN directories d ON d.volume_uuid=?2 AND d.inode=s.i WHERE d.self_pending=1 AND d.path IS NOT NULL LIMIT ?3
            ON CONFLICT(path) DO UPDATE SET priority=max(priority,excluded.priority)
            """, args: [.text(inode), .text(volume), .int(Self.prioritizeLimit)])
            return
        }
        if try !contains(path) { try db.run("INSERT OR IGNORE INTO roots VALUES(?)", [path]) }
        try enqueue(path: path, recursive: true, priority: 10)
    }

    public func refresh(_ url: URL) throws {
        var path = SizeIndexLocation.canonical(url).path
        while try db.first("SELECT 1 FROM directories WHERE path=?", args: [.text(path)], { _ in true }) == nil {
            guard path != "/", !path.isEmpty else { return }
            path = (path as NSString).deletingLastPathComponent
        }
        try enqueue(path: path, recursive: false, priority: 10)
    }

    public func enqueue(path: String, recursive: Bool, priority: Int = 0) throws {
        let path = SizeIndexLocation.canonical(URL(fileURLWithPath: path)).path
        try insertPending(path, recursive: recursive, priority: Int64(priority))
        guard let (volume, inode, pending) = try db.first("SELECT volume_uuid,inode,self_pending FROM directories WHERE path=?", args: [.text(path)], {
            (IndexDatabase.text($0, 0) ?? "", IndexDatabase.text($0, 1) ?? "", IndexDatabase.int($0, 2))
        }), pending == 0 else { return }
        try db.run("UPDATE directories SET self_pending=1 WHERE volume_uuid=? AND inode=?", args: [.text(volume), .text(inode)])
        try bump(volume, chain: chain(volume, inode), Delta(unscanned: 1), now: nil)
    }

    public func scan(_ url: URL) throws {
        try addRoot(url, allowNetwork: true)
        try enqueue(path: SizeIndexLocation.canonical(url).path, recursive: true)
        while try processBatch() > 0 { try Task.checkCancellation() }
    }

    public func rebuild() throws {
        try db.exec("""
        INSERT INTO pending(path,recursive,priority) SELECT path,1,0 FROM roots WHERE true ON CONFLICT(path) DO UPDATE SET recursive=1;
        UPDATE directories SET self_pending=1,unscanned=dir_count,state=CASE WHEN partial_count>0 THEN 'partial' ELSE 'stale' END;
        """)
    }

    public var directoryCount: Int { (try? db.row("SELECT count(*) FROM directories")).flatMap { Int($0[0]) } ?? 0 }

    public var pendingCount: Int { (try? db.row("SELECT count(*) FROM pending")).flatMap { Int($0[0]) } ?? 0 }

    @discardableResult public func processNext() throws -> Bool {
        try processBatch(limit: 1) > 0
    }

    @discardableResult public func processBatch(limit: Int = 1024, budget: TimeInterval = 0.25) throws -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        let budgetNanos = UInt64(max(0, budget) * 1_000_000_000)
        var count = 0
        var cancelled = false
        try db.exec("BEGIN IMMEDIATE")
        do {
            while count < max(1, limit) {
                guard let work = try nextPending() else { break }
                if try !process(work) { cancelled = true; break }
                count += 1
                if DispatchTime.now().uptimeNanoseconds - start > budgetNanos { break }
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        if cancelled { throw CancellationError() }
        return count
    }

    private func nextPending() throws -> (path: String, recursive: Bool, priority: Int64)? {
        guard let top = try db.first("SELECT max(priority) FROM pending", args: [], { IndexDatabase.isNull($0, 0) ? nil : IndexDatabase.int($0, 0) }), let priority = top else { return nil }
        return try db.first("SELECT path,recursive FROM pending WHERE priority=? ORDER BY rowid LIMIT 1", args: [.int(priority)]) {
            (IndexDatabase.text($0, 0) ?? "", IndexDatabase.int($0, 1) != 0, priority)
        }
    }

    private func process(_ work: (path: String, recursive: Bool, priority: Int64)) throws -> Bool {
        try db.exec("SAVEPOINT directory")
        do {
            try db.run("DELETE FROM pending WHERE path=?", args: [.text(work.path)])
            try autoreleasepool { try reconcile(path: work.path, recursive: work.recursive, priority: work.priority) }
            try db.exec("RELEASE directory")
            return true
        } catch is CancellationError {
            try db.exec("ROLLBACK TO directory")
            try db.exec("RELEASE directory")
            return false
        } catch {
            try db.exec("ROLLBACK TO directory")
            NSLog("Size index reconciliation %@: %@", work.path, String(describing: error))
            try db.run("DELETE FROM pending WHERE path=?", args: [.text(work.path)])
            try markFailed(work.path)
            try db.exec("RELEASE directory")
            return true
        }
    }

    private func markFailed(_ path: String) throws {
        guard let (volume, inode, pending, partial) = try db.first("SELECT volume_uuid,inode,self_pending,self_partial FROM directories WHERE path=?", args: [.text(path)], {
            (IndexDatabase.text($0, 0) ?? "", IndexDatabase.text($0, 1) ?? "", IndexDatabase.int($0, 2), IndexDatabase.int($0, 3))
        }) else { return }
        let now = Date().timeIntervalSince1970
        try db.run("UPDATE directories SET self_pending=0,self_partial=1,scan_state='partial',scanned_at=? WHERE volume_uuid=? AND inode=?", args: [.text(String(now)), .text(volume), .text(inode)])
        try bump(volume, chain: chain(volume, inode), Delta(unscanned: -pending, partial: 1 - partial), now: now)
    }

    private func openDirectory(_ path: String) throws -> Int32 {
        let direct = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if direct >= 0 { return direct }
        if errno != EINVAL { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            fd = next
        }
        return fd
    }

    private func volumeID(_ device: Int32, path: String) throws -> String {
        if let known = volumeIDs[device] { return known }
        guard let id = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { throw POSIXError(.ENOTSUP) }
        volumeIDs[device] = id
        return id
    }

    private func insertPending(_ path: String, recursive: Bool, priority: Int64) throws {
        try db.run("INSERT INTO pending(path,recursive,priority) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET recursive=max(recursive,excluded.recursive),priority=max(priority,excluded.priority)",
                   args: [.text(path), .int(recursive ? 1 : 0), .int(priority)])
    }

    func chain(_ volume: String, _ inode: String) throws -> [String] {
        var out = [inode]
        var seen: Set<String> = [inode]
        var current = inode
        while out.count < 4096, let parent = try db.first("SELECT parent_inode FROM directories WHERE volume_uuid=? AND inode=?", args: [.text(volume), .text(current)], { IndexDatabase.text($0, 0) }),
              let parent, !parent.isEmpty, seen.insert(parent).inserted {
            out.append(parent)
            current = parent
        }
        return out
    }

    private func bump(_ volume: String, chain: [String], _ d: Delta, now: Double?) throws {
        let stamp: IndexDatabase.Arg = now.map { .text(String($0)) } ?? .null
        for id in chain {
            try db.run("""
            UPDATE directories SET sub_alloc=sub_alloc+?1,sub_logical=sub_logical+?2,item_count=item_count+?3,multi_count=multi_count+?4,dir_count=dir_count+?5,
            unscanned=unscanned+?6,partial_count=partial_count+?7,total_alloc=sub_alloc+?1+multi_alloc,total_logical=sub_logical+?2+multi_logical,
            state=CASE WHEN partial_count+?7>0 THEN 'partial' WHEN unscanned+?6>0 THEN 'stale' ELSE 'complete' END,scanned_at=coalesce(?8,scanned_at)
            WHERE volume_uuid=?9 AND inode=?10
            """, args: [.int(d.alloc), .int(d.logical), .int(d.items), .int(d.multi), .int(d.dirs), .int(d.unscanned), .int(d.partial), stamp, .text(volume), .text(id)])
        }
    }

    private func addMulti(_ volume: String, _ ancestor: String, alloc: Int64, logical: Int64) throws {
        try db.run("UPDATE directories SET multi_alloc=multi_alloc+?1,multi_logical=multi_logical+?2,total_alloc=sub_alloc+multi_alloc+?1,total_logical=sub_logical+multi_logical+?2 WHERE volume_uuid=?3 AND inode=?4",
                   args: [.int(alloc), .int(logical), .text(volume), .text(ancestor)])
    }

    private func refs(_ volume: String, chain: [String], inode: String, count: Int64, alloc: Int64, logical: Int64) throws {
        guard count != 0 else { return }
        for ancestor in chain {
            if count > 0 {
                let refs = try db.first("INSERT INTO ancestor_refs VALUES(?,?,?,?) ON CONFLICT(volume_uuid,ancestor,inode) DO UPDATE SET refs=refs+excluded.refs RETURNING refs",
                                        args: [.text(volume), .text(ancestor), .text(inode), .int(count)]) { IndexDatabase.int($0, 0) } ?? 0
                if refs == count { try addMulti(volume, ancestor, alloc: alloc, logical: logical) }
            } else {
                guard let refs = try db.first("UPDATE ancestor_refs SET refs=refs+? WHERE volume_uuid=? AND ancestor=? AND inode=? RETURNING refs",
                                              args: [.int(count), .text(volume), .text(ancestor), .text(inode)], { IndexDatabase.int($0, 0) }) else { continue }
                if refs <= 0 {
                    try db.run("DELETE FROM ancestor_refs WHERE volume_uuid=? AND ancestor=? AND inode=?", args: [.text(volume), .text(ancestor), .text(inode)])
                    try addMulti(volume, ancestor, alloc: -alloc, logical: -logical)
                }
            }
        }
    }

    private func fileSize(_ volume: String, _ inode: String) throws -> (Int64, Int64)? {
        try db.first("SELECT alloc,logical FROM files WHERE volume_uuid=? AND inode=?", args: [.text(volume), .text(inode)]) { (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1)) }
    }

    private func resizeMulti(_ volume: String, inode: String, alloc: Int64, logical: Int64) throws {
        var ancestors: [String] = []
        try db.each("SELECT ancestor FROM ancestor_refs WHERE volume_uuid=? AND inode=?", args: [.text(volume), .text(inode)]) { s in
            if let a = IndexDatabase.text(s, 0) { ancestors.append(a) }
        }
        for a in ancestors { try addMulti(volume, a, alloc: alloc, logical: logical) }
    }

    private func stageSubtreeMulti(_ volume: String, _ root: String) throws {
        try db.run("DELETE FROM temp.multi_work", args: [])
        try db.run("""
        WITH RECURSIVE s(i) AS (SELECT ?1 UNION SELECT d.inode FROM directories d JOIN s ON d.parent_inode=s.i WHERE d.volume_uuid=?2)
        INSERT INTO temp.multi_work(inode,count,alloc,logical)
        SELECT e.inode,count(*),coalesce(f.alloc,max(e.alloc)),coalesce(f.logical,max(e.logical)) FROM entries e JOIN s ON e.parent=s.i
        LEFT JOIN files f ON f.volume_uuid=e.volume_uuid AND f.inode=e.inode WHERE e.volume_uuid=?2 AND e.multi=1 GROUP BY e.inode
        """, args: [.text(root), .text(volume)])
    }

    private func childRow(_ volume: String, _ inode: String) throws -> ChildRow? {
        try db.first("SELECT parent_inode,path,sub_alloc,sub_logical,item_count,multi_count,dir_count,unscanned,partial_count,self_pending FROM directories WHERE volume_uuid=? AND inode=?",
                     args: [.text(volume), .text(inode)]) { s in
            ChildRow(parent: IndexDatabase.text(s, 0), path: IndexDatabase.text(s, 1),
                     contribution: Delta(alloc: IndexDatabase.int(s, 2), logical: IndexDatabase.int(s, 3), items: IndexDatabase.int(s, 4), multi: IndexDatabase.int(s, 5),
                                         dirs: IndexDatabase.int(s, 6), unscanned: IndexDatabase.int(s, 7), partial: IndexDatabase.int(s, 8)),
                     selfPending: IndexDatabase.int(s, 9))
        }
    }

    private func moveMulti(_ volume: String, subtree: String, row: ChildRow, chain: [String], sign: Int64) throws {
        guard row.contribution.multi > 0 else { return }
        try stageSubtreeMulti(volume, subtree)
        defer { try? db.run("DELETE FROM temp.multi_work", args: []) }
        try db.each("SELECT inode,count,alloc,logical FROM temp.multi_work", args: []) { s in
            try refs(volume, chain: chain, inode: IndexDatabase.text(s, 0) ?? "", count: sign * IndexDatabase.int(s, 1), alloc: IndexDatabase.int(s, 2), logical: IndexDatabase.int(s, 3))
        }
    }

    private func claimPath(_ path: String, volume: String, inode: String) throws {
        try db.run("UPDATE directories SET path=NULL WHERE path=?1 AND NOT (volume_uuid=?2 AND inode=?3)", args: [.text(path), .text(volume), .text(inode)])
    }

    private func reconcile(path: String, recursive: Bool, priority: Int64) throws {
        let fd = try openDirectory(path)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(.EIO) }
        let volume = try volumeID(st.st_dev, path: path)
        let inode = String(st.st_ino)
        let now = Date().timeIntervalSince1970
        let name = (path as NSString).lastPathComponent

        if let (ov, oi, parent) = try db.first("SELECT volume_uuid,inode,parent_inode FROM directories WHERE path=?1 AND NOT (volume_uuid=?2 AND inode=?3)", args: [.text(path), .text(volume), .text(inode)], {
            (IndexDatabase.text($0, 0) ?? "", IndexDatabase.text($0, 1) ?? "", IndexDatabase.text($0, 2))
        }) {
            if let parent, !parent.isEmpty, let row = try childRow(ov, oi) {
                let old = try chain(ov, parent)
                try bump(ov, chain: old, -row.contribution, now: now)
                try moveMulti(ov, subtree: oi, row: row, chain: old, sign: -1)
            }
            try db.run("UPDATE directories SET path=NULL,parent_inode=NULL WHERE volume_uuid=? AND inode=?", args: [.text(ov), .text(oi)])
        }
        try db.run("INSERT INTO directories(volume_uuid,inode,name,path) VALUES(?1,?2,?3,?4) ON CONFLICT(volume_uuid,inode) DO UPDATE SET path=excluded.path",
                   args: [.text(volume), .text(inode), .text(name), .text(path)])
        let (selfPending, selfPartial) = try db.first("SELECT self_pending,self_partial FROM directories WHERE volume_uuid=? AND inode=?", args: [.text(volume), .text(inode)]) {
            (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1))
        } ?? (1, 0)
        let lineage = try chain(volume, inode)

        let hasExisting = try db.first("SELECT 1 FROM entries WHERE volume_uuid=? AND parent=? LIMIT 1", args: [.text(volume), .text(inode)]) { _ in true } ?? false
        if hasExisting {
            try db.run("DELETE FROM temp.seen_names", args: [])
            try db.run("DELETE FROM temp.seen_dirs", args: [])
        }

        func existing(_ n: String) throws -> Existing? {
            guard hasExisting else { return nil }
            return try db.first("SELECT inode,is_dir,alloc,logical,multi FROM entries WHERE volume_uuid=? AND parent=? AND name=?", args: [.text(volume), .text(inode), .text(n)]) { s in
                Existing(inode: IndexDatabase.text(s, 0) ?? "", isDir: IndexDatabase.int(s, 1) != 0, alloc: IndexDatabase.int(s, 2), logical: IndexDatabase.int(s, 3), multi: IndexDatabase.int(s, 4) != 0)
            }
        }

        func dirSeen(_ id: String) throws -> Bool {
            guard hasExisting else { return false }
            return try db.first("SELECT 1 FROM temp.seen_dirs WHERE inode=?", args: [.text(id)]) { _ in true } ?? false
        }

        struct StoreError: Error { let underlying: Error }
        var delta = Delta()
        var ownAlloc: Int64 = 0, ownLogical: Int64 = 0, ownItems: Int64 = 0, ownMulti: Int64 = 0
        var partial = false

        func remove(_ n: String, _ e: Existing) throws {
            try db.run("DELETE FROM entries WHERE volume_uuid=? AND parent=? AND name=?", args: [.text(volume), .text(inode), .text(n)])
            ownItems -= 1
            if e.isDir {
                if try !dirSeen(e.inode), let row = try childRow(volume, e.inode), row.parent == inode {
                    delta += -row.contribution
                    try moveMulti(volume, subtree: e.inode, row: row, chain: lineage, sign: -1)
                    try db.run("UPDATE directories SET parent_inode=NULL WHERE volume_uuid=? AND inode=?", args: [.text(volume), .text(e.inode)])
                }
            } else if e.multi {
                ownMulti -= 1
                let size = try fileSize(volume, e.inode) ?? (e.alloc, e.logical)
                try refs(volume, chain: lineage, inode: e.inode, count: -1, alloc: size.0, logical: size.1)
            } else {
                ownAlloc -= e.alloc
                ownLogical -= e.logical
            }
        }

        func add(_ f: Found) throws {
            try db.run("INSERT INTO entries(volume_uuid,parent,name,inode,is_dir,alloc,logical,multi) VALUES(?,?,?,?,?,?,?,?)",
                       args: [.text(volume), .text(inode), .text(f.name), .text(f.inode), .int(f.isDir ? 1 : 0), .int(f.alloc), .int(f.logical), .int(f.multi ? 1 : 0)])
            ownItems += 1
            if f.isDir { return }
            if f.multi {
                ownMulti += 1
                if let old = try fileSize(volume, f.inode), old != (f.alloc, f.logical) {
                    try resizeMulti(volume, inode: f.inode, alloc: f.alloc - old.0, logical: f.logical - old.1)
                }
                try db.run("INSERT INTO files VALUES(?,?,?,?,?) ON CONFLICT(volume_uuid,inode) DO UPDATE SET alloc=excluded.alloc,logical=excluded.logical,links=excluded.links",
                           args: [.text(volume), .text(f.inode), .int(f.alloc), .int(f.logical), .int(f.links)])
                try refs(volume, chain: lineage, inode: f.inode, count: 1, alloc: f.alloc, logical: f.logical)
            } else {
                ownAlloc += f.alloc
                ownLogical += f.logical
            }
        }

        func ensureChild(_ f: Found) throws {
            let child = path == "/" ? "/" + f.name : path + "/" + f.name
            guard let row = try childRow(volume, f.inode) else {
                try claimPath(child, volume: volume, inode: f.inode)
                try db.run("INSERT INTO directories(volume_uuid,inode,parent_inode,name,path) VALUES(?,?,?,?,?)", args: [.text(volume), .text(f.inode), .text(inode), .text(f.name), .text(child)])
                delta += Delta(dirs: 1, unscanned: 1)
                try insertPending(child, recursive: true, priority: priority)
                return
            }
            var needsScan = recursive
            if row.parent != inode {
                if let old = row.parent, !old.isEmpty {
                    let oldChain = try chain(volume, old)
                    try bump(volume, chain: oldChain, -row.contribution, now: now)
                    try moveMulti(volume, subtree: f.inode, row: row, chain: oldChain, sign: -1)
                }
                try claimPath(child, volume: volume, inode: f.inode)
                try db.run("UPDATE directories SET parent_inode=?,name=?,path=? WHERE volume_uuid=? AND inode=?", args: [.text(inode), .text(f.name), .text(child), .text(volume), .text(f.inode)])
                delta += row.contribution
                try moveMulti(volume, subtree: f.inode, row: row, chain: lineage, sign: 1)
                needsScan = true
            } else if row.path != child {
                try claimPath(child, volume: volume, inode: f.inode)
                try db.run("UPDATE directories SET name=?,path=? WHERE volume_uuid=? AND inode=?", args: [.text(f.name), .text(child), .text(volume), .text(f.inode)])
                needsScan = true
            }
            if needsScan {
                try insertPending(child, recursive: true, priority: priority)
                if row.selfPending == 0 {
                    try db.run("""
                    UPDATE directories SET self_pending=1,unscanned=unscanned+1,state=CASE WHEN partial_count>0 THEN 'partial' ELSE 'stale' END WHERE volume_uuid=? AND inode=?
                    """, args: [.text(volume), .text(f.inode)])
                    delta.unscanned += 1
                }
            }
        }

        func handle(_ f: Found) throws {
            if hasExisting {
                try db.run("INSERT OR IGNORE INTO temp.seen_names(name) VALUES(?)", args: [.text(f.name)])
                if f.isDir { try db.run("INSERT OR IGNORE INTO temp.seen_dirs(inode) VALUES(?)", args: [.text(f.inode)]) }
            }
            if let e = try existing(f.name) {
                if e.inode != f.inode || e.isDir != f.isDir || e.multi != f.multi || e.alloc != f.alloc || e.logical != f.logical {
                    try remove(f.name, e)
                    try add(f)
                }
            } else {
                try add(f)
            }
            if f.isDir { try ensureChild(f) }
        }

        do {
            try bulk.read(fd: fd) { entry in
                guard let id = entry.inode, let type = entry.type, let device = entry.device else { partial = true; return }
                if type == 5 { return }
                if device != st.st_dev || (entry.realDevice.map { $0 != UInt32(bitPattern: st.st_dev) } ?? false) || (entry.mount ?? 0) != 0 || (entry.flags ?? 0) & UInt32(SF_FIRMLINK) != 0 { return }
                let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
                if excludes(child) { return }
                let f: Found
                if type == 2 {
                    f = Found(name: entry.name, inode: String(id), isDir: true, alloc: 0, logical: 0, multi: false, links: 1)
                } else {
                    guard let alloc = entry.allocated, let logical = entry.logical else { partial = true; return }
                    let links = Int64(entry.links ?? 1)
                    f = Found(name: entry.name, inode: String(id), isDir: false, alloc: alloc, logical: logical, multi: links > 1, links: links)
                }
                do { try handle(f) } catch { throw StoreError(underlying: error) }
            }
        } catch let e as StoreError { throw e.underlying } catch is CancellationError { throw CancellationError() } catch { partial = true }

        if !partial && hasExisting {
            var last = ""
            while true {
                var batch: [(name: String, entry: Existing)] = []
                try db.each("""
                SELECT name,inode,is_dir,alloc,logical,multi FROM entries WHERE volume_uuid=?1 AND parent=?2 AND name>?3
                AND name NOT IN (SELECT name FROM temp.seen_names) ORDER BY name LIMIT 256
                """, args: [.text(volume), .text(inode), .text(last)]) { s in
                    guard let n = IndexDatabase.text(s, 0) else { return }
                    batch.append((n, Existing(inode: IndexDatabase.text(s, 1) ?? "", isDir: IndexDatabase.int(s, 2) != 0, alloc: IndexDatabase.int(s, 3), logical: IndexDatabase.int(s, 4), multi: IndexDatabase.int(s, 5) != 0)))
                }
                guard let tail = batch.last else { break }
                for item in batch { try remove(item.name, item.entry) }
                last = tail.name
            }
        }

        delta.alloc += ownAlloc
        delta.logical += ownLogical
        delta.items += ownItems
        delta.multi += ownMulti
        let newPartial: Int64 = partial ? 1 : 0
        delta.unscanned -= selfPending
        delta.partial += newPartial - selfPartial
        try db.run("""
        UPDATE directories SET own_alloc=own_alloc+?,own_logical=own_logical+?,own_items=own_items+?,own_multi=own_multi+?,self_pending=0,self_partial=?,scan_state=?,name=? WHERE volume_uuid=? AND inode=?
        """, args: [.int(ownAlloc), .int(ownLogical), .int(ownItems), .int(ownMulti), .int(newPartial), .text(partial ? "partial" : "complete"), .text(name), .text(volume), .text(inode)])
        try bump(volume, chain: lineage, delta, now: now)
    }
}
