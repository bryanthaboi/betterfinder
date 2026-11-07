import Foundation
import SQLite3

public struct TrashJournalEntry: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let originalURL: URL
    public let trashedURL: URL
    public let date: Date
}

public enum TrashJournalError: Error, LocalizedError {
    case openFailed(String)
    case statementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "Could not open the trash journal: \(m)"
        case .statementFailed(let m): return "Trash journal error: \(m)"
        }
    }
}

public enum PutBackError: Error, LocalizedError {
    case noRecord(URL)
    case missing(URL)

    public var errorDescription: String? {
        switch self {
        case .noRecord(let u): return "“\(u.lastPathComponent)” has no recorded original location."
        case .missing(let u): return "“\(u.lastPathComponent)” is no longer in the Trash."
        }
    }
}

public struct PutBackReport: Sendable {
    public var restored: [(trashed: URL, restored: URL)] = []
    public var failures: [(trashed: URL, error: Error)] = []
    public init() {}
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class TrashJournal: @unchecked Sendable {
    public static let defaultDatabaseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("betterfinder/trash.sqlite")
    }()

    public static let shared: TrashJournal = {
        if let j = try? TrashJournal(databaseURL: defaultDatabaseURL) { return j }
        return (try? TrashJournal(databasePath: ":memory:"))!
    }()

    private let lock = NSLock()
    private var db: OpaquePointer?

    public convenience init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(databasePath: databaseURL.path)
    }

    public init(databasePath: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw TrashJournalError.openFailed(msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try exec("""
        CREATE TABLE IF NOT EXISTS entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            original_path TEXT NOT NULL,
            trashed_path TEXT NOT NULL,
            trashed_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS entries_trashed_path ON entries(trashed_path);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TrashJournalError.statementFailed(msg)
        }
    }

    private static func key(_ url: URL) -> String {
        let std = url.standardizedFileURL
        return std.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(std.lastPathComponent).path
    }

    @discardableResult
    public func record(originalURL: URL, trashedURL: URL, date: Date = Date()) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO entries (original_path, trashed_path, trashed_at) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw TrashJournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.key(originalURL), -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, Self.key(trashedURL), -1, sqliteTransient)
        sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TrashJournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func readRows(_ stmt: OpaquePointer?) -> [TrashJournalEntry] {
        var rows: [TrashJournalEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let original = String(cString: sqlite3_column_text(stmt, 1))
            let trashed = String(cString: sqlite3_column_text(stmt, 2))
            let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            rows.append(TrashJournalEntry(id: id, originalURL: URL(fileURLWithPath: original), trashedURL: URL(fileURLWithPath: trashed), date: date))
        }
        return rows
    }

    public func entry(forTrashedURL url: URL) -> TrashJournalEntry? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, original_path, trashed_path, trashed_at FROM entries WHERE trashed_path = ? ORDER BY id DESC LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.key(url), -1, sqliteTransient)
        return readRows(stmt).first
    }

    public func entries() -> [TrashJournalEntry] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, original_path, trashed_path, trashed_at FROM entries ORDER BY id DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        return readRows(stmt)
    }

    public func remove(trashedURL url: URL) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM entries WHERE trashed_path = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.key(url), -1, sqliteTransient)
        sqlite3_step(stmt)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? exec("DELETE FROM entries")
    }

    @discardableResult
    public func purgeMissing() -> Int {
        let rows = entries()
        var removed = 0
        for row in rows where !FS.exists(row.trashedURL) && !Self.isOnUnavailableVolume(row.trashedURL) {
            remove(trashedURL: row.trashedURL)
            removed += 1
        }
        return removed
    }

    static func isOnUnavailableVolume(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return false }
        return !FS.exists(URL(fileURLWithPath: "/Volumes/" + parts[2]))
    }

    public func putBack(_ trashedURLs: [URL]) -> PutBackReport {
        var report = PutBackReport()
        let fm = FileManager.default
        for trashed in trashedURLs {
            guard let entry = entry(forTrashedURL: trashed) else {
                report.failures.append((trashed, PutBackError.noRecord(trashed)))
                continue
            }
            guard FS.exists(trashed) else {
                report.failures.append((trashed, PutBackError.missing(trashed)))
                continue
            }
            do {
                let parent = entry.originalURL.deletingLastPathComponent()
                if !FS.exists(parent) { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
                var target = entry.originalURL
                if FS.exists(target) {
                    target = FileOperationQueue.uniqueDestination(for: target.lastPathComponent, in: parent)
                }
                try fm.moveItem(at: trashed, to: target)
                remove(trashedURL: trashed)
                report.restored.append((trashed, target))
            } catch {
                report.failures.append((trashed, error))
            }
        }
        return report
    }
}
