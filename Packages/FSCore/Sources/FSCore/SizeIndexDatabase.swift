import Foundation
import CSQLite

public enum SizeIndexState: String, Sendable { case partial, stale, complete }

public struct IndexedSize: Sendable, Equatable {
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let items: Int
    public let state: SizeIndexState
    public let scannedAt: Date
    public var pendingFolders: Int = 0
    public var unscannedFolders: Int = 0
    public var unreadableFolders: Int = 0
    public var bytes: Int64 { allocatedBytes }
    public var isCounting: Bool { unscannedFolders > 0 }
}

public enum SizeIndexLocation {
    public static var database: URL {
        DemoEnvironment.home.appendingPathComponent("Library/Application Support/betterfinder/FileIndex.sqlite")
    }
    public static var embeddedDatabase: URL {
        DemoEnvironment.home.appendingPathComponent("Library/Application Support/betterfinder/FileIndex.local.sqlite")
    }
    public static var legacyDatabase: URL {
        DemoEnvironment.home.appendingPathComponent("Library/Application Support/betterfinder/SizeIndex.sqlite")
    }
    public static func removeLegacyDatabase() {
        let base = legacyDatabase.path
        for suffix in ["", "-wal", "-shm"] { unlink(base + suffix) }
    }
    static let dataPrefix = "/System/Volumes/Data"
    public static func canonical(_ url: URL) -> URL {
        let path: String
        if let resolved = realpath(url.path, nil) {
            path = String(cString: resolved)
            free(resolved)
        } else { path = url.standardizedFileURL.path }
        return URL(fileURLWithPath: stripDataPrefix(path))
    }
    static func stripDataPrefix(_ path: String) -> String {
        if path == dataPrefix { return "/" }
        return path.hasPrefix(dataPrefix + "/") ? String(path.dropFirst(dataPrefix.count)) : path
    }
}

final class IndexDatabase {
    var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    init(_ url: URL, readOnly: Bool = false, cacheKiB: Int = 1024, mmapBytes: Int64 = 0) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open size index"
            sqlite3_close(handle)
            handle = nil
            throw NSError(domain: "SizeIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        sqlite3_busy_timeout(handle, 3000)
        try exec("PRAGMA cache_size=-\(max(256, cacheKiB)); PRAGMA mmap_size=\(max(0, mmapBytes)); PRAGMA temp_store=MEMORY;")
        if !readOnly { try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=4000; PRAGMA journal_size_limit=67108864;") }
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }
    func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
            throw NSError(domain: "SizeIndex", code: Int(result), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
    func exec(_ sql: String) throws { try check(sqlite3_exec(handle, sql, nil, nil, nil)) }
    func run(_ sql: String, _ values: [String] = []) throws {
        try run(sql, args: values.map { .text($0) })
    }
    func row(_ sql: String, _ values: [String] = []) throws -> [String]? {
        let s = try prepared(sql, values.map { .text($0) })
        defer { sqlite3_reset(s) }
        let result = sqlite3_step(s)
        try check(result)
        guard result == SQLITE_ROW else { return nil }
        return (0..<sqlite3_column_count(s)).map { sqlite3_column_text(s, $0).map { String(cString: $0) } ?? "" }
    }
    func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try work(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    enum Arg {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func prepared(_ sql: String, _ args: [Arg]) throws -> OpaquePointer {
        let s: OpaquePointer
        if let existing = statements[sql] { s = existing } else {
            var prepared: OpaquePointer?
            try check(sqlite3_prepare_v2(handle, sql, -1, &prepared, nil))
            s = prepared!
            statements[sql] = s
        }
        sqlite3_reset(s)
        sqlite3_clear_bindings(s)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case .text(let v): try check(sqlite3_bind_text(s, index, v, -1, Self.transient))
            case .int(let v): try check(sqlite3_bind_int64(s, index, v))
            case .real(let v): try check(sqlite3_bind_double(s, index, v))
            case .null: try check(sqlite3_bind_null(s, index))
            }
        }
        return s
    }

    func run(_ sql: String, args: [Arg]) throws {
        let s = try prepared(sql, args)
        defer { sqlite3_reset(s) }
        try check(sqlite3_step(s))
    }

    func each(_ sql: String, args: [Arg], _ body: (OpaquePointer) throws -> Void) throws {
        let s = try prepared(sql, args)
        defer { sqlite3_reset(s) }
        while true {
            let r = sqlite3_step(s)
            if r == SQLITE_DONE { return }
            guard r == SQLITE_ROW else { try check(r); return }
            try body(s)
        }
    }

    func first<T>(_ sql: String, args: [Arg], _ body: (OpaquePointer) throws -> T) throws -> T? {
        let s = try prepared(sql, args)
        defer { sqlite3_reset(s) }
        let r = sqlite3_step(s)
        if r == SQLITE_DONE { return nil }
        guard r == SQLITE_ROW else { try check(r); return nil }
        return try body(s)
    }

    func changes() -> Int { Int(sqlite3_changes(handle)) }

    func lastInsertID() -> Int64 { sqlite3_last_insert_rowid(handle) }

    static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }

    static func real(_ s: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(s, i) }

    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }

    static func bytes(_ s: OpaquePointer, _ i: Int32) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: sqlite3_column_text(s, i), count: Int(sqlite3_column_bytes(s, i)))
    }
}

enum IndexFlag {
    static let scan: Int64 = 1
    static let fresh: Int64 = 2
    static let partial: Int64 = 4
    static let recursive: Int64 = 8
    static let detached: Int64 = 16
    static let hidden: Int64 = 32
    static let deferred: Int64 = 64
    static let denied: Int64 = 128
}

enum IndexVolume {
    static func identifier(forPath path: String) -> String? {
        if let uuid = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString { return uuid }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mount = withUnsafePointer(to: &fs.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return "mount:" + mount
    }
}

public final class SizeIndexReader: @unchecked Sendable {
    private let db: IndexDatabase
    private let lock = NSLock()
    private var volumes: [Int32: (id: Int64?, at: UInt64)] = [:]
    let fileIdentity: (dev: Int32, ino: UInt64)

    public init(databaseURL: URL = SizeIndexLocation.database) throws {
        db = try IndexDatabase(databaseURL, readOnly: true, cacheKiB: 2048)
        var st = stat()
        fileIdentity = stat(databaseURL.path, &st) == 0 ? (st.st_dev, UInt64(st.st_ino)) : (0, 0)
    }

    private static let query = "SELECT alloc+multi_alloc,logical+multi_logical,items,pending,fresh,partial,scanned_at FROM dirs WHERE vol=? AND inode=?"

    private func volume(_ device: Int32, path: String) -> Int64? {
        let now = DispatchTime.now().uptimeNanoseconds
        if let known = volumes[device], now &- known.at < (known.id == nil ? 250_000_000 : 15_000_000_000) { return known.id }
        var id: Int64?
        if let uuid = IndexVolume.identifier(forPath: path) {
            id = (try? db.first("SELECT id FROM volumes WHERE uuid=?", args: [.text(uuid)]) { IndexDatabase.int($0, 0) }) ?? nil
        }
        volumes[device] = (id, now)
        return id
    }

    private func lookup(_ url: URL) -> IndexedSize? {
        let path = url.path
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, let vol = volume(st.st_dev, path: path) else { return nil }
        return (try? db.first(Self.query, args: [.int(vol), .int(Int64(bitPattern: UInt64(st.st_ino)))]) { s -> IndexedSize in
            let pending = IndexDatabase.int(s, 3), fresh = IndexDatabase.int(s, 4), partial = IndexDatabase.int(s, 5)
            let state: SizeIndexState = pending > 0 || fresh > 0 ? .stale : (partial > 0 ? .partial : .complete)
            return IndexedSize(allocatedBytes: max(0, IndexDatabase.int(s, 0)), logicalBytes: max(0, IndexDatabase.int(s, 1)), items: Int(max(0, IndexDatabase.int(s, 2))),
                               state: state, scannedAt: Date(timeIntervalSince1970: IndexDatabase.real(s, 6)),
                               pendingFolders: Int(max(0, pending)), unscannedFolders: Int(max(0, fresh)), unreadableFolders: Int(max(0, partial)))
        }) ?? nil
    }

    public func size(for url: URL) -> IndexedSize? {
        lock.lock()
        defer { lock.unlock() }
        return lookup(url)
    }

    public func sizes(for urls: [URL]) -> [IndexedSize?] {
        var out: [IndexedSize?] = []
        out.reserveCapacity(urls.count)
        var start = 0
        while start < urls.count {
            let end = min(urls.count, start + 64)
            lock.lock()
            for url in urls[start..<end] { out.append(lookup(url)) }
            lock.unlock()
            start = end
        }
        return out
    }

    public var isUsable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ((try? db.first("SELECT 1 FROM sqlite_master WHERE name='dirs'", args: []) { _ in true }) ?? nil) == true
    }
}
