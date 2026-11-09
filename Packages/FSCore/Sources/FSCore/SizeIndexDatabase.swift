import Foundation
import CSQLite

public enum SizeIndexState: String, Sendable { case partial, stale, complete }

public struct IndexedSize: Sendable, Equatable {
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let items: Int
    public let state: SizeIndexState
    public let scannedAt: Date
    public var bytes: Int64 { allocatedBytes }
}

public enum SizeIndexLocation {
    public static var database: URL {
        DemoEnvironment.home.appendingPathComponent("Library/Application Support/betterfinder/SizeIndex.sqlite")
    }
    public static func canonical(_ url: URL) -> URL {
        let path: String
        if let resolved = realpath(url.path, nil) {
            path = String(cString: resolved)
            free(resolved)
        } else { path = url.standardizedFileURL.path }
        let prefix = "/System/Volumes/Data"
        return URL(fileURLWithPath: path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path)
    }
}

final class IndexDatabase {
    var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    init(_ url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open size index"
            sqlite3_close(handle)
            handle = nil
            throw NSError(domain: "SizeIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        sqlite3_busy_timeout(handle, 3000)
        try exec("PRAGMA cache_size=-1024; PRAGMA mmap_size=0; PRAGMA temp_store=FILE;")
        if !readOnly { try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=1000; PRAGMA main.cache_spill=256;") }
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
    func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let existing = statements[sql] { statement = existing } else {
            var prepared: OpaquePointer?
            try check(sqlite3_prepare_v2(handle, sql, -1, &prepared, nil))
            statement = prepared!
            statements[sql] = statement
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (i, value) in values.enumerated() {
            try check(sqlite3_bind_text(statement, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
        return statement
    }
    func run(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values)
        defer { sqlite3_reset(s) }
        try check(sqlite3_step(s))
    }
    func row(_ sql: String, _ values: [String] = []) throws -> [String]? {
        let s = try statement(sql, values)
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

    static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }

    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
}

public final class SizeIndexReader: @unchecked Sendable {
    private let db: IndexDatabase
    private let lock = NSLock()
    public init(databaseURL: URL = SizeIndexLocation.database) throws { db = try IndexDatabase(databaseURL, readOnly: true) }
    public func size(for url: URL) -> IndexedSize? {
        lock.lock()
        defer { lock.unlock() }
        let url = SizeIndexLocation.canonical(url)
        var st = stat()
        guard lstat(url.path, &st) == 0,
              let row = try? db.row("SELECT total_alloc,total_logical,item_count,state,scanned_at FROM directories WHERE path=? AND inode=?", [url.path, String(st.st_ino)]),
              let allocated = Int64(row[0]), let logical = Int64(row[1]), let count = Int(row[2]), let state = SizeIndexState(rawValue: row[3]), let time = Double(row[4]) else { return nil }
        return IndexedSize(allocatedBytes: allocated, logicalBytes: logical, items: count, state: state, scannedAt: Date(timeIntervalSince1970: time))
    }
}
