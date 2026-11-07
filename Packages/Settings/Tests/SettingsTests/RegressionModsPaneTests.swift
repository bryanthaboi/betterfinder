import AppKit
import Integration
import XCTest
@testable import Settings

final class SnapshotDrivenController: ModManagementControlling, @unchecked Sendable {
    let lock = NSLock()
    var fetched: ModIndexSnapshot?
    var index: ModIndexSnapshot
    var indexError: String?
    var refusal: PreflightResultSummary?
    var installed = InstalledMod(id: "ada@tool", title: "Tool", author: "Ada", version: "1.0.0")

    init(index: ModIndexSnapshot) { self.index = index }

    func listInstalled() async throws -> [InstalledMod] {
        lock.withLock {
            var mod = installed
            if let listing = fetched?.listings.first(where: { $0.id == mod.id }), listing.version != mod.version { mod.availableUpdate = listing }
            return [mod]
        }
    }

    func fetchIndex() async throws -> ModIndexSnapshot {
        try lock.withLock {
            if let indexError { throw ModManagementError.indexUnavailable(indexError) }
            fetched = index
            return index
        }
    }

    func preflight(id: String) async throws -> PreflightResultSummary { PreflightResultSummary(modID: id, version: "1", ok: true) }

    func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> InstalledMod {
        throw ModManagementError.installRefused("\(listing.title) failed preflight: TS2322")
    }

    func enable(id: String) async throws -> InstalledMod { installed }
    func disable(id: String) async throws -> InstalledMod { installed }
    func uninstall(id: String, deleteData: Bool) async throws {}

    func update(id: String, approvedPermissionIDs: Set<String>) async throws -> InstalledMod {
        throw ModManagementError.installRefused("Tool failed preflight: TS2322")
    }

    func preflightRefusal(for listingID: String) -> PreflightResultSummary? { lock.withLock { refusal } }
}

@MainActor
final class RegressionModsPaneTests: XCTestCase {
    let newer = ModListing(id: "ada@tool", title: "Tool", author: "Ada", version: "2.0.0")

    func testInstalledRowsPickUpUpdatesAfterIndexLoads() async {
        let controller = SnapshotDrivenController(index: ModIndexSnapshot(listings: [newer]))
        let model = ModsPaneModel(controller: controller)
        await model.reloadAll()
        XCTAssertEqual(model.installedMod(id: "ada@tool")?.availableUpdate?.version, "2.0.0")
    }

    func testIndexFailureKeepsInstalledAndCachedRows() async {
        let controller = SnapshotDrivenController(index: ModIndexSnapshot(listings: [newer]))
        let model = ModsPaneModel(controller: controller)
        await model.reloadAll()
        controller.indexError = "offline"
        await model.reloadIndex()
        XCTAssertEqual(model.listings.map(\.id), ["ada@tool"])
        XCTAssertEqual(model.installed.count, 1)
        XCTAssertTrue(model.indexRefreshError?.contains("offline") == true)
    }

    func testExpiredIndexExplainsBlockedUpdate() async {
        let controller = SnapshotDrivenController(index: ModIndexSnapshot(listings: [newer], isExpired: true))
        let model = ModsPaneModel(controller: controller)
        await model.reloadAll()
        let mod = model.installedMod(id: "ada@tool")!
        XCTAssertNotNil(mod.availableUpdate)
        XCTAssertEqual(model.updateBlockReason(for: mod), "The index has expired; refresh it to update")
        XCTAssertFalse(model.beginUpdate("ada@tool"))
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(model.phase.isIdle)
    }

    func testRefusedInstallKeepsDiagnostics() async {
        let controller = SnapshotDrivenController(index: ModIndexSnapshot(listings: [ModListing(id: "bob@broken", title: "Broken", author: "Bob", version: "1.0.0")]))
        controller.refusal = PreflightResultSummary(modID: "bob@broken", version: "1.0.0", ok: false,
                                                    checks: [PreflightCheck(name: "types", state: .fail)],
                                                    diagnostics: [PreflightDiagnostic(severity: .error, code: "BF2001", message: "TS2322 nope", file: "scripts/main.ts", pointer: "1:3", fix: "Use a number")])
        let model = ModsPaneModel(controller: controller)
        await model.reloadAll()
        XCTAssertTrue(model.beginInstall(model.listings[0]))
        await model.approveAndRun()
        guard case .refused(let op, let result) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(op.listing.id, "bob@broken")
        XCTAssertEqual(result.errorCount, 1)
        let text = result.reportText(title: "Broken")
        XCTAssertTrue(text.contains("TS2322 nope"))
        XCTAssertTrue(text.contains("scripts/main.ts 1:3"))
        XCTAssertTrue(text.contains("Fix: Use a number"))
        XCTAssertTrue(model.cancelFlow())
        XCTAssertTrue(model.phase.isIdle)
    }

    func testFailedInstallWithoutReportStaysGeneric() async {
        let controller = SnapshotDrivenController(index: ModIndexSnapshot(listings: [ModListing(id: "bob@broken", title: "Broken", author: "Bob", version: "1.0.0")]))
        let model = ModsPaneModel(controller: controller)
        await model.reloadAll()
        model.beginInstall(model.listings[0])
        await model.approveAndRun()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testFlowPhaseAnnouncesOnlyResults() {
        let op = ModsPaneModel.Operation(kind: .install, listing: newer, permissionsToReview: [])
        XCTAssertNil(ModFlowPhaseKey(.installing(op)).announcement)
        XCTAssertNotNil(ModFlowPhaseKey(.failed(message: "x", modID: nil)).announcement)
        XCTAssertNotNil(ModFlowPhaseKey(.refused(op, result: PreflightResultSummary(modID: "a", version: "1", ok: false))).announcement)
    }

    func testModSettingsFailureIsAnnouncedWithFieldTitle() throws {
        let schema = try ModSettingsSchema.decode(from: Data(#"{"schemaVersion":1,"fields":[{"key":"count","type":"integer","title":"Retry count","min":0,"max":5,"default":1}]}"#.utf8))
        let suite = "Regression.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = try ModSettingsStore(modID: "ada@test", schema: schema, defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
        let model = ModSettingsFormModel(store: store)
        var announced: [String] = []
        model.announce = { announced.append($0) }
        XCTAssertFalse(model.update("count", .integer(99)))
        XCTAssertEqual(announced.count, 1)
        XCTAssertTrue(announced[0].hasPrefix("Retry count:"))
        XCTAssertFalse(model.update("count", .integer(99)))
        XCTAssertEqual(announced.count, 1)
    }

    func testOnboardingSummaryDescribesActualState() {
        let none = DefaultFileManager.Status(isFileViewer: false, isFolderHandler: false)
        XCTAssertEqual(OnboardingSummary.lines(status: none, skipped: true).map(\.text), ["Your default file manager settings were left unchanged"])
        XCTAssertFalse(OnboardingSummary.lines(status: none, skipped: false)[0].text.contains("Finder is still"))
        let partial = DefaultFileManager.Status(isFileViewer: true, isFolderHandler: false)
        let lines = OnboardingSummary.lines(status: partial, skipped: false).map(\.text)
        XCTAssertTrue(lines.contains("Show in Finder and Reveal open betterfinder"))
        XCTAssertTrue(lines.contains("Opening folders still uses another app"))
        let full = DefaultFileManager.Status(isFileViewer: true, isFolderHandler: true)
        XCTAssertEqual(OnboardingSummary.lines(status: full, skipped: true).count, 1)
    }

    func testProgressDotsExposeStepText() {
        XCTAssertEqual(ProgressDots.stepText(current: 2, count: 6), "Step 3 of 6")
    }

    func testHotKeyRejectionNamesTheRule() {
        XCTAssertTrue(HotKeyRecorder.rejectionMessage(for: .shift).contains("Shift alone"))
        XCTAssertTrue(HotKeyRecorder.rejectionMessage(for: []).contains("⌘, ⌥ or ⌃"))
    }

    func testWindowsKeysCopyNamesEveryMapping() {
        for key in ["Return", "F2", "Backspace", "F5", "Delete", "⇧F5"] {
            XCTAssertTrue(SettingsCopy.windowsKeysHelp.contains(key), key)
        }
    }
}
