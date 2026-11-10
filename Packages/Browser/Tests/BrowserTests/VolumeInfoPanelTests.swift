import AppKit
@testable import Browser
import FSCore
import XCTest

final class VolumeInfoPanelTests: XCTestCase {
    @MainActor
    func testGetInfoOnTheBootVolumeShowsCapacityNotAFolderWalk() throws {
        let model = InfoModel(url: URL(fileURLWithPath: "/"))
        let volume = try XCTUnwrap(model.volume)
        XCTAssertFalse(model.name.isEmpty)
        XCTAssertNotEqual(model.name, "/")
        XCTAssertTrue(model.nameLocked)
        XCTAssertEqual(model.kind, volume.kindText)
        XCTAssertTrue(model.kind.contains("volume"))
        XCTAssertTrue(model.sizeText.hasSuffix("used"))
        XCTAssertTrue(model.sizeDetail.contains("free of"))
        XCTAssertEqual(model.whereText, "/")
        XCTAssertNotEqual(model.sizeText, "calculating…")
    }

    @MainActor
    func testGetInfoOnAnOrdinaryFolderIsUnchanged() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bf-info-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = InfoModel(url: dir)
        XCTAssertNil(model.volume)
        XCTAssertEqual(model.kind, "Folder")
        XCTAssertFalse(model.nameLocked)
    }
}
