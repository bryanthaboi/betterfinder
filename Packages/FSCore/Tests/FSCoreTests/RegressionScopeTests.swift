import CoreServices
import XCTest
import Darwin
@testable import FSCore

final class RegressionScopeTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pending(_ writer: SizeIndexWriter) throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        try writer.db.each("SELECT path,recursive FROM pending", args: []) { s in
            out[IndexDatabase.text(s, 0) ?? ""] = IndexDatabase.int(s, 1) != 0
        }
        return out
    }

    private func cursor(_ writer: SizeIndexWriter, device: Int32) throws -> String? {
        try writer.db.row("SELECT event_id FROM volumes WHERE device=?", [String(device)])?[0]
    }

    private func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

    private let fakeDevice: Int32 = 987_654
    private let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)
    private let fileEvent = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    private let dirEvent = UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)

    private func makeWriter(_ temp: URL, roots: [String]) throws -> (SizeIndexWriter, SizeIndexEvents) {
        let writer = try SizeIndexWriter(databaseURL: temp.appendingPathComponent("index.sqlite"))
        for root in roots { try writer.db.run("INSERT INTO roots VALUES(?)", [root]) }
        try writer.db.exec("DELETE FROM pending")
        try writer.db.run("INSERT INTO volumes VALUES(?,?,?,?)", ["fake-volume", String(fakeDevice), "journal", "1"])
        return (writer, SizeIndexEvents(writer: writer, queue: DispatchQueue(label: "regression-scope")))
    }

    func testExactRootAndSiblingPrefix() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (writer, _) = try makeWriter(temp, roots: ["/bf-test-fake/a/b"])
        XCTAssertTrue(try writer.contains("/bf-test-fake/a/b"))
        XCTAssertTrue(try writer.contains("/bf-test-fake/a/b/c/file"))
        XCTAssertFalse(try writer.contains("/bf-test-fake/a/bc"))
        XCTAssertFalse(try writer.contains("/bf-test-fake/a/bc/file"))
        XCTAssertFalse(try writer.contains("/bf-test-fake/a"))
        XCTAssertFalse(try writer.contains("/"))
    }

    func testRootScopeContainsDescendants() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (writer, events) = try makeWriter(temp, roots: ["/"])
        XCTAssertTrue(try writer.contains("/"))
        XCTAssertTrue(try writer.contains("/bf-test-fake"))
        XCTAssertTrue(try writer.contains("/bf-test-fake/x/file"))
        _ = events.apply([.init(path: "bf-test-fake/x/file", flags: fileEvent, id: 42)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try pending(writer), ["/bf-test-fake/x": false])
        XCTAssertEqual(try cursor(writer, device: fakeDevice), "42")
    }

    func testSiblingPrefixEventsAreIgnoredButAdvanceCursor() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (writer, events) = try makeWriter(temp, roots: ["/bf-test-fake/a/b"])
        _ = events.apply([
            .init(path: "bf-test-fake/a/bc", flags: mustScan, id: 10),
            .init(path: "bf-test-fake/a/bc/file", flags: fileEvent, id: 11),
        ], device: fakeDevice, mount: "/")
        XCTAssertEqual(try pending(writer), [:])
        XCTAssertEqual(try cursor(writer, device: fakeDevice), "11")
    }

    func testRootDirectoryEventDoesNotEnqueueUnindexedParent() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (writer, events) = try makeWriter(temp, roots: ["/bf-test-fake/a/b"])
        _ = events.apply([
            .init(path: "bf-test-fake/a/b", flags: dirEvent, id: 5),
            .init(path: "bf-test-fake/a/b/c/file", flags: fileEvent, id: 6),
        ], device: fakeDevice, mount: "/")
        XCTAssertEqual(try pending(writer), ["/bf-test-fake/a/b": false, "/bf-test-fake/a/b/c": false])
    }

    func testAncestorMustScanSubDirsEnqueuesCoveredRoots() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (writer, events) = try makeWriter(temp, roots: ["/bf-test-fake/home/user", "/bf-test-fake/home/user/Projects", "/bf-test-fake/homework", "/bf-test-fake/other"])
        _ = events.apply([.init(path: "bf-test-fake/home", flags: mustScan, id: 77)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try pending(writer), ["/bf-test-fake/home/user": true])
        XCTAssertEqual(try cursor(writer, device: fakeDevice), "77")
        try writer.db.exec("DELETE FROM pending")
        _ = events.apply([.init(path: "", flags: mustScan, id: 78)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try pending(writer), ["/bf-test-fake/home/user": true, "/bf-test-fake/homework": true, "/bf-test-fake/other": true])
    }

    func testAncestorMustScanSubDirsSkipsRootsOnOtherDevices() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = SizeIndexLocation.canonical(temp).path
        let (writer, events) = try makeWriter(temp, roots: [root])
        var st = stat()
        XCTAssertEqual(stat(root, &st), 0)
        _ = events.apply([.init(path: relative(temp.deletingLastPathComponent().path), flags: mustScan, id: 3)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try pending(writer), [:])
        _ = events.apply([.init(path: relative(temp.deletingLastPathComponent().path), flags: mustScan, id: 4)], device: st.st_dev, mount: "/")
        XCTAssertEqual(try pending(writer), [root: true])
    }

    func testAncestorMustScanSubDirsRefreshesIndexedTotals() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let indexed = tree.appendingPathComponent("indexed")
        try FileManager.default.createDirectory(at: indexed, withIntermediateDirectories: true)
        try Data(count: 100).write(to: indexed.appendingPathComponent("a"))
        let database = temp.appendingPathComponent("index.sqlite")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(indexed)
        XCTAssertEqual(reader.size(for: indexed)?.logicalBytes, 100)
        try Data(count: 50).write(to: indexed.appendingPathComponent("nested-later"))
        var st = stat()
        XCTAssertEqual(stat(indexed.path, &st), 0)
        let events = SizeIndexEvents(writer: writer, queue: DispatchQueue(label: "regression-scope"))
        _ = events.apply([.init(path: relative(tree.path), flags: mustScan, id: 9)], device: st.st_dev, mount: "/")
        XCTAssertEqual(try pending(writer)[SizeIndexLocation.canonical(indexed).path], true)
        XCTAssertNil(try pending(writer)[SizeIndexLocation.canonical(tree).path])
        while try writer.processBatch() > 0 {}
        XCTAssertEqual(reader.size(for: indexed)?.logicalBytes, 150)
        XCTAssertEqual(reader.size(for: indexed)?.state, .complete)
        XCTAssertNil(reader.size(for: tree))
    }
}
