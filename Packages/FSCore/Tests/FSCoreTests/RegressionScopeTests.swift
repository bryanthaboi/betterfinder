import CoreServices
import XCTest
import Darwin
@testable import FSCore

final class RegressionScopeTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SizeIndexLocation.canonical(url)
    }

    private func cursor(_ writer: SizeIndexWriter, device: Int32) throws -> String? {
        try writer.db.first("SELECT event_id FROM volumes WHERE device=?", args: [.int(Int64(device))]) { IndexDatabase.text($0, 0) } ?? nil
    }

    private func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

    private func device(_ url: URL) -> Int32 {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        return st.st_dev
    }

    private let fakeDevice: Int32 = 987_654
    private let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)
    private let fileEvent = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    private let dirEvent = UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)

    private func makeWriter(_ temp: URL, roots: [URL]) throws -> (SizeIndexWriter, SizeIndexEvents) {
        let writer = try SizeIndexWriter(databaseURL: temp.appendingPathComponent("index.sqlite"))
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writer.addRoot(root)
        }
        try writer.drain()
        try writer.db.run("INSERT INTO volumes(uuid,device,journal,event_id) VALUES(?,?,?,?)", ["fake-volume", String(fakeDevice), "journal", "1"])
        return (writer, SizeIndexEvents(writer: writer, queue: DispatchQueue(label: "regression-scope")))
    }

    func testExactRootAndSiblingPrefix() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("a/b")
        let (writer, _) = try makeWriter(temp, roots: [root])
        XCTAssertTrue(try writer.contains(root.path))
        XCTAssertTrue(try writer.contains(root.path + "/c/file"))
        XCTAssertFalse(try writer.contains(root.path + "c"))
        XCTAssertFalse(try writer.contains(root.path + "c/file"))
        XCTAssertFalse(try writer.contains(temp.appendingPathComponent("a").path))
        XCTAssertFalse(try writer.contains("/"))
    }

    func testEventsMarkTheContainingFolderAndAdvanceCursor() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("root")
        let inner = root.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let (writer, events) = try makeWriter(temp, roots: [root])
        XCTAssertEqual(try writer.flagged(), [])
        try Data(count: 9).write(to: inner.appendingPathComponent("file"))
        _ = events.apply([.init(path: relative(inner.path) + "/file", flags: fileEvent, id: 42)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try writer.flagged(), ["\(inner.path)|0"])
        XCTAssertEqual(try cursor(writer, device: fakeDevice), "42")
        try writer.drain()
        XCTAssertEqual(try SizeIndexReader(databaseURL: temp.appendingPathComponent("index.sqlite")).size(for: root)?.logicalBytes, 9)
    }

    func testEventForUndiscoveredFolderMarksNearestIndexedAncestor() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("root")
        let (writer, events) = try makeWriter(temp, roots: [root])
        let fresh = root.appendingPathComponent("new/deeper")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data(count: 5).write(to: fresh.appendingPathComponent("f"))
        _ = events.apply([.init(path: relative(fresh.path) + "/f", flags: fileEvent, id: 7)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try writer.flagged(), ["\(root.path)|0"])
        try writer.drain()
        let reader = try SizeIndexReader(databaseURL: temp.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(reader.size(for: root)?.logicalBytes, 5)
        XCTAssertEqual(reader.size(for: fresh)?.logicalBytes, 5)
        XCTAssertEqual(reader.size(for: root)?.state, .complete)
    }

    func testSiblingPrefixEventsAreIgnoredButAdvanceCursor() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("a/b")
        let sibling = temp.appendingPathComponent("a/bc")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let (writer, events) = try makeWriter(temp, roots: [root])
        _ = events.apply([
            .init(path: relative(sibling.path), flags: mustScan, id: 10),
            .init(path: relative(sibling.path) + "/file", flags: fileEvent, id: 11),
        ], device: fakeDevice, mount: "/")
        XCTAssertEqual(try writer.flagged(), [])
        XCTAssertEqual(try cursor(writer, device: fakeDevice), "11")
    }

    func testRootDirectoryEventDoesNotEnqueueUnindexedParent() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("a/b")
        let inner = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let (writer, events) = try makeWriter(temp, roots: [root])
        _ = events.apply([
            .init(path: relative(root.path), flags: dirEvent, id: 5),
            .init(path: relative(inner.path) + "/file", flags: fileEvent, id: 6),
        ], device: fakeDevice, mount: "/")
        XCTAssertEqual(Set(try writer.flagged()), ["\(root.path)|0", "\(inner.path)|0"])
    }

    func testAncestorMustScanSubDirsEnqueuesCoveredRoots() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let user = temp.appendingPathComponent("home/user")
        let projects = user.appendingPathComponent("Projects")
        let homework = temp.appendingPathComponent("homework")
        let other = temp.appendingPathComponent("other")
        let (writer, events) = try makeWriter(temp, roots: [user, projects, homework, other])
        XCTAssertEqual(try writer.count("roots"), 3)
        let actual = device(temp)
        _ = events.apply([.init(path: relative(temp.appendingPathComponent("home").path), flags: mustScan, id: 77)], device: actual, mount: "/")
        XCTAssertEqual(try writer.flagged(), ["\(user.path)|1"])
        try writer.drain()
        _ = events.apply([.init(path: relative(temp.path), flags: mustScan, id: 78)], device: actual, mount: "/")
        XCTAssertEqual(Set(try writer.flagged()), ["\(user.path)|1", "\(homework.path)|1", "\(other.path)|1"])
    }

    func testAncestorMustScanSubDirsSkipsRootsOnOtherDevices() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("root")
        let (writer, events) = try makeWriter(temp, roots: [root])
        _ = events.apply([.init(path: relative(temp.path), flags: mustScan, id: 3)], device: fakeDevice, mount: "/")
        XCTAssertEqual(try writer.flagged(), [])
        _ = events.apply([.init(path: relative(temp.path), flags: mustScan, id: 4)], device: device(root), mount: "/")
        XCTAssertEqual(try writer.flagged(), ["\(root.path)|1"])
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
        let events = SizeIndexEvents(writer: writer, queue: DispatchQueue(label: "regression-scope"))
        _ = events.apply([.init(path: relative(tree.path), flags: mustScan, id: 9)], device: device(indexed), mount: "/")
        XCTAssertEqual(try writer.flagged(), ["\(indexed.path)|1"])
        try writer.drain()
        XCTAssertEqual(reader.size(for: indexed)?.logicalBytes, 150)
        XCTAssertEqual(reader.size(for: indexed)?.state, .complete)
        XCTAssertNil(reader.size(for: tree))
    }

    func testDroppedEventsReverifyWithoutLosingTotals() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("root")
        let inner = root.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(count: 300).write(to: inner.appendingPathComponent("f"))
        let (writer, events) = try makeWriter(temp, roots: [root])
        let reader = try SizeIndexReader(databaseURL: temp.appendingPathComponent("index.sqlite"))
        _ = events.apply([.init(path: "", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped), id: 90)], device: fakeDevice, mount: "/")
        XCTAssertEqual(reader.size(for: root)?.logicalBytes, 300)
        XCTAssertEqual(reader.size(for: inner)?.logicalBytes, 300)
        XCTAssertEqual(reader.size(for: inner)?.state, .complete)
        XCTAssertEqual(reader.size(for: root)?.isCounting, false)
        try writer.drain()
        XCTAssertEqual(reader.size(for: root)?.state, .complete)
        XCTAssertEqual(reader.size(for: root)?.logicalBytes, 300)
    }
}
