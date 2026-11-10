import AppKit
@testable import Browser
import FSCore
import XCTest

final class ItemFilterTests: XCTestCase {
    func testGlobMatching() {
        XCTAssertTrue(ItemFilter.glob("*.zip", matches: "Archive.ZIP"))
        XCTAssertTrue(ItemFilter.glob("*.zip", matches: ".zip"))
        XCTAssertFalse(ItemFilter.glob("*.zip", matches: "archive.zip.part"))
        XCTAssertTrue(ItemFilter.glob("*", matches: "anything"))
        XCTAssertTrue(ItemFilter.glob("*.z", matches: "a.z"))
        XCTAssertFalse(ItemFilter.glob("*.z", matches: "a.zip"))
        XCTAssertTrue(ItemFilter.glob("?eport*.pdf", matches: "Report final.pdf"))
        XCTAssertFalse(ItemFilter.glob("?eport*.pdf", matches: "eport.pdf"))
        XCTAssertTrue(ItemFilter.glob("*a*b*c", matches: "xxaxxbxxc"))
        XCTAssertFalse(ItemFilter.glob("*a*b*c", matches: "xxaxxcxxb"))
        XCTAssertTrue(ItemFilter.isPatternStart("*"))
        XCTAssertTrue(ItemFilter.isPatternStart("?x"))
        XCTAssertFalse(ItemFilter.isPatternStart("a*"))
    }

    @MainActor
    func testFolderModelFiltersInMemoryAndSurvivesChanges() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bf-filter-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.zip", "b.ZIP", "c.txt", "d.md"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8)) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)

        let model = FolderModel(location: .folder(dir))
        let loaded = expectation(description: "loaded")
        model.onLoadingChange = { if !model.isLoading { loaded.fulfill() } }
        model.start()
        wait(for: [loaded], timeout: 10)
        model.onLoadingChange = nil
        XCTAssertEqual(model.items.count, 5)

        var resets = 0
        model.addObserver(self) { change in if case .reset = change { resets += 1 } }
        model.setFilter(ItemFilter(pattern: "*.zip"))
        XCTAssertEqual(model.items.map(\.name).sorted(), ["a.zip", "b.ZIP"])
        XCTAssertEqual(model.filteredOutCount, 3)
        XCTAssertEqual(resets, 1)

        let folderKind = try XCTUnwrap(DirectoryLister.item(for: dir.appendingPathComponent("folder"))).kindDescription
        model.setFilter(ItemFilter(kind: folderKind))
        XCTAssertEqual(model.items.map(\.name), ["folder"])

        model.setFilter(ItemFilter(pattern: "*.zip"))
        let changed = expectation(description: "new zip shows up")
        changed.assertForOverFulfill = false
        model.addObserver(self) { _ in if model.items.contains(where: { $0.name == "e.zip" }) { changed.fulfill() } }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("e.zip").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("f.txt").path, contents: Data("x".utf8))
        wait(for: [changed], timeout: 10)
        XCTAssertEqual(model.items.map(\.name).sorted(), ["a.zip", "b.ZIP", "e.zip"])

        model.setFilter(nil)
        XCTAssertEqual(model.items.count, 7)
        XCTAssertEqual(model.filteredOutCount, 0)
        model.stop()
    }
}
