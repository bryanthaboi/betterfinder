import AppKit
import XCTest
import FSCore
@testable import Browser

@MainActor
final class JunkCleanupTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bf-junk-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SizeIndexLocation.canonical(url)
    }

    private func make(_ url: URL, files: [String: Int] = [:]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, size) in files { try Data(count: size).write(to: url.appendingPathComponent(name)) }
    }

    private func fixture() throws -> (model: JunkCleanupModel, home: URL, leftovers: URL) {
        let temp = try temporary()
        let home = temp.appendingPathComponent("home")
        try make(home.appendingPathComponent("Library/Caches/BigApp"), files: ["blob": 30_000_000])
        try make(home.appendingPathComponent("Library/Caches/OtherApp"), files: ["blob": 25_000_000])
        try make(home.appendingPathComponent("Library/Logs/Chatty"), files: ["old.log": 22_000_000])
        try make(home.appendingPathComponent(".Trash"), files: ["gone": 1_000])
        let leftovers = home.appendingPathComponent("Library/Containers/app/Data/tmp")
        for i in 0..<320 { try make(leftovers.appendingPathComponent("left-\(i)")) }
        let database = temp.appendingPathComponent("index.sqlite")
        try SizeIndexWriter(databaseURL: database).scan(home)
        let model = JunkCleanupModel()
        model.home = home
        model.databaseURL = { database }
        return (model, home, leftovers)
    }

    func testScanChecksNothingAndCleanOnlyTouchesWhatWasTicked() async throws {
        let (model, _, leftovers) = try fixture()
        var trashed: [URL] = []
        var emptied = 0
        model.trashItems = { urls in trashed += urls; return (urls.count, 0) }
        model.emptyTrash = { emptied += 1; return 1 }
        var changes = 0
        model.onChange = { changes += 1 }

        await model.scan()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.groups.map(\.id), ["leftovers", "trash", "caches", "logs"])
        XCTAssertTrue(model.checkedItems.isEmpty)
        XCTAssertTrue(model.selectionSummary.contains("found"))
        XCTAssertGreaterThan(changes, 0)
        let nothing = await model.clean()
        XCTAssertEqual(nothing, JunkCleanupModel.Outcome())
        XCTAssertEqual(nothing.summary, "Nothing was cleaned up.")

        let caches = try XCTUnwrap(model.groups.first { $0.id == "caches" })
        XCTAssertEqual(caches.items.map(\.title), ["BigApp", "OtherApp"])
        model.setChecked(true, item: caches.items[0])
        XCTAssertEqual(model.state(of: caches), .mixed)
        model.setChecked(true, group: caches)
        XCTAssertEqual(model.state(of: caches), .on)
        model.setChecked(false, item: caches.items[1])
        let cluster = try XCTUnwrap(model.groups.first { $0.id == "leftovers" }?.items.first)
        XCTAssertEqual(cluster.emptyFolderCount, 320)
        model.setChecked(true, item: cluster)
        XCTAssertEqual(model.checkedItems.count, 2)
        XCTAssertEqual(model.checkedEmptyFolders, 320)
        XCTAssertEqual(model.checkedBytes, caches.items[0].bytes)
        XCTAssertTrue(model.selectionSummary.hasPrefix("2 selected"))

        let text = JunkCleanupViewController.confirmation(for: model.checkedItems)
        XCTAssertTrue(text.detail.contains("1 item"))
        XCTAssertTrue(text.detail.contains("320 empty folders"))
        XCTAssertFalse(text.detail.contains("asked again"))

        try Data(count: 3).write(to: leftovers.appendingPathComponent("left-7/now-used"))
        let outcome = await model.clean()
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["BigApp"])
        XCTAssertEqual(emptied, 0)
        XCTAssertEqual(outcome, JunkCleanupModel.Outcome(trashed: 1, removedFolders: 319, emptiedTrash: 0, failed: 0))
        XCTAssertEqual(outcome.summary, "Moved 1 item to the Trash, removed 319 empty folders.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: leftovers.path), ["left-7"])
        XCTAssertTrue(model.checkedItems.isEmpty)
        XCTAssertEqual(model.phase, .ready)

        let trash = try XCTUnwrap(model.groups.first { $0.id == "trash" }?.items.first)
        model.setChecked(true, item: trash)
        XCTAssertTrue(JunkCleanupViewController.confirmation(for: model.checkedItems).detail.contains("asked again"))
        let second = await model.clean()
        XCTAssertEqual(emptied, 1)
        XCTAssertEqual(second.emptiedTrash, 1)
        XCTAssertEqual(trashed.count, 1)
    }

    func testFailuresAreCountedAndAMissingIndexIsReported() async throws {
        let (model, _, _) = try fixture()
        model.trashItems = { urls in (0, urls.count) }
        await model.scan()
        let logs = try XCTUnwrap(model.groups.first { $0.id == "logs" })
        model.setChecked(true, group: logs)
        let outcome = await model.clean()
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.summary, "1 couldn’t be cleaned.")

        let missing = JunkCleanupModel()
        let nowhere = try temporary().appendingPathComponent("none.sqlite")
        missing.databaseURL = { nowhere }
        await missing.scan()
        XCTAssertEqual(missing.phase, .unavailable)
        XCTAssertTrue(missing.groups.isEmpty)
    }

    func testWindowListsGroupsWithTotalsAndEnablesCleanUpOnlyWithAPick() async throws {
        _ = NSApplication.shared
        let (model, _, _) = try fixture()
        model.trashItems = { urls in (urls.count, 0) }
        let controller = JunkCleanupViewController(model: model)
        _ = controller.view
        await model.scan()
        controller.render(structureChanged: false)
        XCTAssertEqual(controller.outline.numberOfRows, 4 + 5)
        XCTAssertFalse(controller.cleanButton.isEnabled)
        XCTAssertTrue(controller.emptyLabel.isHidden)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("found"))
        let group = try XCTUnwrap(controller.outline.item(atRow: 0))
        let header = try XCTUnwrap(controller.outlineView(controller.outline, viewFor: controller.outline.tableColumns[0], item: group) as? JunkRowView)
        XCTAssertEqual(header.title.stringValue, "Leftover empty folders")
        XCTAssertEqual(header.amount.stringValue, "320 folders")
        XCTAssertEqual(header.check.state, .off)
        header.onToggle?(true)
        XCTAssertTrue(controller.cleanButton.isEnabled)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("320 empty folders"))
        let row = try XCTUnwrap(controller.outlineView(controller.outline, viewFor: controller.outline.tableColumns[0], item: try XCTUnwrap(controller.outline.item(atRow: 1))) as? JunkRowView)
        XCTAssertEqual(row.check.state, .on)
        XCTAssertEqual(row.title.stringValue, "tmp")
        XCTAssertEqual(JunkCleanupViewController.amount(bytes: 0, folders: 0), "--")
    }
}
