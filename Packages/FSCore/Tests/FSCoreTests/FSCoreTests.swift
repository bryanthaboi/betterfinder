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

    func testFolderSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 10_000).write(to: dir.appendingPathComponent("a.bin"))
        var last = SizeResult()
        for await r in await SizeEngine().size(of: dir) { last = r }
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(last.logicalBytes, 10_000)
    }
}
