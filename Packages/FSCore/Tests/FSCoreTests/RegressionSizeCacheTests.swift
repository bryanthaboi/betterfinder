import XCTest
import Darwin
@testable import FSCore

final class RegressionSizeCacheTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SizeIndexLocation.canonical(url)
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
        let before = try [tree, a, deep, b].map { try writer.stamp($0) }
        for url in [tree, a, deep, b, tree] { try writer.prioritize(url) }
        XCTAssertEqual(try writer.flagged(), [])
        XCTAssertEqual(try writer.processBatch(), 0)
        XCTAssertEqual(try [tree, a, deep, b].map { try writer.stamp($0) }, before)
        for url in [tree, a, deep, b] { XCTAssertEqual(reader.size(for: url)?.state, .complete) }
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1500)
        XCTAssertEqual(try writer.count("roots"), 1)
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
        let untouched = try [b, inner].map { try writer.stamp($0) }

        try Data(count: 3000).write(to: deep.appendingPathComponent("f"))
        try writer.refresh(deep)
        XCTAssertEqual(reader.size(for: tree)?.state, .stale)
        XCTAssertEqual(reader.size(for: tree)?.isCounting, false)
        XCTAssertEqual(reader.size(for: a)?.state, .stale)
        XCTAssertEqual(reader.size(for: b)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1500)

        try writer.prioritize(b)
        try writer.prioritize(tree)
        XCTAssertEqual(try writer.flagged(), ["\(deep.path)|0"])
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 3500)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 3000)
        XCTAssertEqual(reader.size(for: b)?.logicalBytes, 500)
        XCTAssertEqual(try [b, inner].map { try writer.stamp($0) }, untouched)
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
        XCTAssertEqual(try writer.flagged(), ["\(a.path)|0"])
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
        XCTAssertEqual(try writer.flagged(), ["\(tree.path)|0"])
        XCTAssertEqual(reader.size(for: tree)?.isCounting, true)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1500)
    }
}
