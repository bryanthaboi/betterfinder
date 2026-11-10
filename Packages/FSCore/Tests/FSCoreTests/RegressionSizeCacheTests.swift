import XCTest
import Darwin
@testable import FSCore

final class RegressionSizeCacheTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SizeIndexLocation.canonical(url)
    }

    private func stamp(_ writer: SizeIndexWriter, _ url: URL) throws -> String? {
        try XCTUnwrap(try writer.db.row("SELECT scanned_at FROM directories WHERE path=?", [url.path])?[0])
    }

    private func pending(_ writer: SizeIndexWriter) throws -> [String] {
        var rows: [String] = []
        try writer.db.each("SELECT path,recursive,priority FROM pending ORDER BY path", args: []) { s in
            rows.append("\(IndexDatabase.text(s, 0) ?? "")|\(IndexDatabase.int(s, 1))|\(IndexDatabase.int(s, 2))")
        }
        return rows
    }

    private func makeTree(_ temp: URL) throws -> (tree: URL, a: URL, deep: URL, b: URL) {
        let tree = temp.appendingPathComponent("tree")
        let a = tree.appendingPathComponent("a")
        let deep = a.appendingPathComponent("deep")
        let b = tree.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: deep.appendingPathComponent("f"))
        try Data(count: 500).write(to: b.appendingPathComponent("inner/g"))
        return (tree, a, deep, b)
    }

    func testOldCompleteEntryIsServedAsComplete() {
        let old = IndexedSize(allocatedBytes: 4096, logicalBytes: 1000, items: 3, state: .complete, scannedAt: Date(timeIntervalSinceNow: -86400 * 30))
        let result = SizeEngine.result(old)
        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.logicalBytes, 1000)
        let stale = SizeEngine.result(IndexedSize(allocatedBytes: 0, logicalBytes: 0, items: 0, state: .stale, scannedAt: Date()))
        XCTAssertTrue(stale.isStale)
        XCTAssertFalse(stale.isComplete)
    }

    func testPrioritizingUnchangedFolderDoesNotRescan() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (tree, a, deep, b) = try makeTree(temp)
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        let before = try [tree, a, deep, b].map { try stamp(writer, $0) }
        for url in [tree, a, deep, b, tree] { try writer.prioritize(url) }
        XCTAssertEqual(try pending(writer), [])
        XCTAssertEqual(try writer.processBatch(), 0)
        XCTAssertEqual(try [tree, a, deep, b].map { try stamp(writer, $0) }, before)
        for url in [tree, a, deep, b] { XCTAssertEqual(reader.size(for: url)?.state, .complete) }
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1500)
        XCTAssertEqual(try writer.db.row("SELECT count(*) FROM roots")?[0], "1")
    }

    func testChangedBranchOnlyRecomputesThatBranch() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (tree, a, deep, b) = try makeTree(temp)
        let inner = b.appendingPathComponent("inner")
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        let untouched = try [b, inner].map { try stamp(writer, $0) }
        try writer.db.run("DELETE FROM pending")

        try Data(count: 3000).write(to: deep.appendingPathComponent("f"))
        try writer.refresh(deep)
        try writer.db.run("DELETE FROM pending")
        XCTAssertEqual(reader.size(for: tree)?.state, .stale)
        XCTAssertEqual(reader.size(for: a)?.state, .stale)
        XCTAssertEqual(reader.size(for: b)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1500)

        try writer.prioritize(b)
        XCTAssertEqual(try pending(writer), [])
        try writer.prioritize(tree)
        XCTAssertEqual(try pending(writer), ["\(deep.path)|0|10"])
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 3500)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 3000)
        XCTAssertEqual(reader.size(for: b)?.logicalBytes, 500)
        XCTAssertEqual(try [b, inner].map { try stamp(writer, $0) }, untouched)
    }

    func testRefreshOfUnindexedPathMarksNearestIndexedAncestor() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (tree, a, _, b) = try makeTree(temp)
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        let fresh = a.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data(count: 250).write(to: fresh.appendingPathComponent("h"))
        try writer.refresh(fresh)
        XCTAssertEqual(try pending(writer), ["\(a.path)|0|10"])
        XCTAssertEqual(reader.size(for: a)?.state, .stale)
        XCTAssertEqual(reader.size(for: b)?.state, .complete)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1750)
        XCTAssertEqual(reader.size(for: fresh)?.logicalBytes, 250)
    }

    func testPrioritizingUnknownFolderStillScansIt() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (tree, _, _, _) = try makeTree(temp)
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.prioritize(tree)
        XCTAssertEqual(try pending(writer), ["\(tree.path)|1|10"])
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1500)
    }
}
