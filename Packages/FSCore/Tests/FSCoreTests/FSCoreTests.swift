import XCTest
@testable import FSCore

final class FSCoreTests: XCTestCase {
    func testListsTempDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hi".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        let items = try DirectoryLister.list(dir)
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "sub"])
        XCTAssertTrue(items.first { $0.name == "sub" }!.isDirectory)
    }

    func testFolderSizeComesFromTheIndex() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let dir = temp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data(count: 10_000).write(to: dir.appendingPathComponent("a.bin"))
        let database = temp.appendingPathComponent("index.sqlite")
        let daemon = try SizeIndexDaemon(databaseURL: database)
        defer { daemon.stop() }
        let engine = SizeEngine(databaseURL: database, control: daemon)
        var last = SizeResult()
        var seen = 0
        for await r in await engine.size(of: dir) { last = r; seen += 1 }
        XCTAssertGreaterThan(seen, 0)
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(last.logicalBytes, 10_000)
        XCTAssertEqual(engine.snapshot(of: [dir, temp.appendingPathComponent("missing")]).map { $0?.logicalBytes }, [10_000, nil])
    }
}
