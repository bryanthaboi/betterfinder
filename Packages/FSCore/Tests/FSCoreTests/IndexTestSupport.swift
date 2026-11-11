import Foundation
import Darwin
@testable import FSCore

extension SizeIndexWriter {
    func flagged() throws -> [String] {
        var ids: [(Int64, Int64)] = []
        try db.each("SELECT id,flags FROM dirs WHERE flags&?!=0", args: [.int(IndexFlag.scan)]) { ids.append((IndexDatabase.int($0, 0), IndexDatabase.int($0, 1))) }
        return try ids.compactMap { id, flags in
            try path(of: id).map { "\($0)|\(flags & IndexFlag.recursive != 0 ? 1 : 0)" }
        }.sorted()
    }

    func stamp(_ url: URL) throws -> Double? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return try db.first("SELECT scanned_at FROM dirs WHERE inode=?", args: [.int(Int64(bitPattern: UInt64(st.st_ino)))]) { IndexDatabase.real($0, 0) }
    }

    func count(_ table: String) throws -> Int {
        Int(try db.first("SELECT count(*) FROM \(table)", args: []) { IndexDatabase.int($0, 0) } ?? 0)
    }

    func drain() throws {
        while try processBatch() > 0 {}
    }
}
