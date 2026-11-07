import XCTest
import Darwin
@testable import FSCore

final class RegressionReconcileTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rescan(_ writer: SizeIndexWriter, _ url: URL) throws {
        try writer.enqueue(path: url.path, recursive: false)
        while try writer.processBatch() > 0 {}
    }

    func testWideDirectoryRescanRemovesUnseenAcrossBatches() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for i in 0..<1500 { try Data(count: 10).write(to: tree.appendingPathComponent(String(format: "f%05d", i))) }
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.items, 1500)
        for i in stride(from: 0, to: 1500, by: 2) { try FileManager.default.removeItem(at: tree.appendingPathComponent(String(format: "f%05d", i))) }
        try Data(count: 1000).write(to: tree.appendingPathComponent("f00001"))
        try Data(count: 3).write(to: tree.appendingPathComponent("zz-new"))
        try rescan(writer, tree)
        XCTAssertEqual(reader.size(for: tree)?.items, 751)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 749 * 10 + 1000 + 3)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(try writer.db.row("SELECT count(*) FROM entries")?[0], "751")
        XCTAssertEqual(try writer.db.row("SELECT count(*) FROM temp.multi_work")?[0], "0")
    }

    func testRenameWithinDirectoryKeepsChildTotals() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let child = tree.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(count: 77).write(to: child.appendingPathComponent("file"))
        for i in 0..<300 { try Data(count: 1).write(to: tree.appendingPathComponent("pad-\(i)")) }
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 377)
        let renamed = tree.appendingPathComponent("a-new-name")
        try FileManager.default.moveItem(at: child, to: renamed)
        try rescan(writer, tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 377)
        XCTAssertEqual(reader.size(for: tree)?.items, 302)
        XCTAssertEqual(reader.size(for: renamed)?.logicalBytes, 77)
    }

    func testRemovedSubtreeWithHardLinksReleasesSharedBytes() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let keep = tree.appendingPathComponent("keep")
        let gone = tree.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gone.appendingPathComponent("deep"), withIntermediateDirectories: true)
        for i in 0..<20 {
            let original = keep.appendingPathComponent("o\(i)")
            try Data(count: 1000).write(to: original)
            try FileManager.default.linkItem(at: original, to: gone.appendingPathComponent("deep/l\(i)"))
        }
        try Data(count: 5000).write(to: gone.appendingPathComponent("solo"))
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 25000)
        XCTAssertEqual(reader.size(for: gone)?.logicalBytes, 25000)
        try FileManager.default.removeItem(at: gone)
        try rescan(writer, tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 20000)
        XCTAssertEqual(reader.size(for: keep)?.logicalBytes, 20000)
        XCTAssertEqual(try writer.db.row("SELECT count(*) FROM temp.multi_work")?[0], "0")
    }

    func testUnreadableDirectoryKeepsPreviousEntries() throws {
        let temp = try temporary()
        defer {
            chmod(temp.appendingPathComponent("tree").path, 0o755)
            try? FileManager.default.removeItem(at: temp)
        }
        let tree = temp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for i in 0..<10 { try Data(count: 10).write(to: tree.appendingPathComponent("f\(i)")) }
        let database = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 100)
        guard getuid() != 0 else { return }
        XCTAssertEqual(chmod(tree.path, 0o000), 0)
        try rescan(writer, tree)
        chmod(tree.path, 0o755)
        XCTAssertEqual(try writer.db.row("SELECT count(*) FROM entries")?[0], "10")
        XCTAssertEqual(reader.size(for: tree)?.state, .partial)
    }
}
