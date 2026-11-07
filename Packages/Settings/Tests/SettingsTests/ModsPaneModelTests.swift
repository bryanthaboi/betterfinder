import XCTest
@testable import Settings

@MainActor
final class ModsPaneModelTests: XCTestCase {
    func make(_ controller: PreviewModManagementController = PreviewModManagementController()) -> (ModsPaneModel, PreviewModManagementController) {
        let model = ModsPaneModel(controller: controller)
        model.openFolder = { _ in }
        return (model, controller)
    }

    func listing(_ id: String, in model: ModsPaneModel) -> ModListing { model.listings.first { $0.id == id }! }

    func testLoadsInstalledAndIndex() async {
        let (model, _) = make()
        XCTAssertEqual(model.installedState, .idle)
        await model.reloadAll()
        XCTAssertEqual(model.installedState, .loaded)
        XCTAssertEqual(model.indexState, .loaded)
        XCTAssertEqual(model.installed.count, 2)
        XCTAssertEqual(model.listings.count, PreviewModManagementController.sampleListings.count)
    }

    func testIndexFailureKeepsInstalledAndReportsError() async {
        let controller = PreviewModManagementController()
        controller.setIndexFailure("offline")
        let (model, _) = make(controller)
        await model.reloadAll()
        XCTAssertEqual(model.installedState, .loaded)
        guard case .failed(let message) = model.indexState else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("offline"))
        controller.setIndexFailure(nil)
        await model.reloadIndex()
        XCTAssertEqual(model.indexState, .loaded)
    }

    func testSearchFilterAndSort() async {
        let (model, _) = make()
        await model.reloadIndex()
        XCTAssertFalse(model.filteredListings.contains { $0.id == "eve@future-only" })
        model.compatibleOnly = false
        XCTAssertTrue(model.filteredListings.contains { $0.id == "eve@future-only" })

        model.search = "git"
        XCTAssertEqual(model.filteredListings.map(\.id), ["ada@git-status"])
        model.search = "  PREVIEW "
        XCTAssertEqual(model.filteredListings.map(\.id), ["ben@markdown-preview"])
        model.search = ""

        model.categoryFilter = "THEME"
        XCTAssertEqual(model.filteredListings.map(\.id), ["cleo@neon-pack"])
        model.categoryFilter = nil

        model.sortOrder = .name
        let names = model.filteredListings.map(\.title)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        model.sortOrder = .author
        XCTAssertEqual(model.filteredListings.first?.author, "Ada")
        model.sortOrder = .recentlyUpdated
        XCTAssertEqual(model.filteredListings.first?.id, "ada@git-status")
        XCTAssertEqual(model.categories, Array(Set(model.listings.flatMap(\.categories))).sorted())
    }

    func testInstallFlowHappyPath() async {
        let (model, controller) = make()
        await model.reloadAll()
        let md = listing("ben@markdown-preview", in: model)
        XCTAssertNil(model.installBlockReason(for: md))
        XCTAssertTrue(model.beginInstall(md))
        guard case .reviewingPermissions(let op) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(op.permissionsToReview.map(\.id), ["files.read.selection"])
        XCTAssertEqual(controller.calls.filter { $0.hasPrefix("install") }, [])

        await model.approveAndRun()
        guard case .finished(let id, let result) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(id, md.id)
        XCTAssertTrue(result.allowsEnable)
        XCTAssertTrue(model.finishedModCanBeEnabled)
        XCTAssertEqual(model.installedMod(id: md.id)?.isEnabled, false)
        XCTAssertEqual(controller.calls.suffix(2), ["install:\(md.id)", "preflight:\(md.id)"])

        await model.enableFinishedMod()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.installedMod(id: md.id)?.isEnabled, true)
    }

    func testInstallBlockedByPreflightError() async {
        let controller = PreviewModManagementController()
        let md = PreviewModManagementController.sampleListings.first { $0.id == "ben@markdown-preview" }!
        controller.setPreflightOutcome(PreviewModManagementController.failingResult(id: md.id, version: md.version), forID: md.id)
        let (model, _) = make(controller)
        await model.reloadAll()

        XCTAssertTrue(model.beginInstall(listing(md.id, in: model)))
        await model.approveAndRun()
        guard case .finished(_, let result) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertFalse(result.allowsEnable)
        XCTAssertEqual(result.errorCount, 1)
        XCTAssertFalse(model.finishedModCanBeEnabled)

        await model.enableFinishedMod()
        guard case .finished = model.phase else { return XCTFail("enable must not leave the finished phase: \(model.phase)") }
        XCTAssertFalse(controller.calls.contains("enable:\(md.id)"))

        let mod = model.installedMod(id: md.id)!
        XCTAssertFalse(model.canEnable(mod))
        XCTAssertNotNil(model.enableBlockReason(for: mod))
        await model.setEnabled(md.id, true)
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.installedMod(id: md.id)?.isEnabled, false)
        XCTAssertFalse(controller.calls.contains("enable:\(md.id)"))

        XCTAssertTrue(model.cancelFlow())
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.isInstalled(listing(md.id, in: model)))
    }

    func testIncompletePreflightAlsoBlocksEnable() async {
        let controller = PreviewModManagementController()
        let md = PreviewModManagementController.sampleListings.first { $0.id == "ben@markdown-preview" }!
        controller.setPreflightOutcome(
            PreflightResultSummary(modID: md.id, version: md.version, ok: true, checks: [PreflightCheck(name: "schema", state: .pass), PreflightCheck(name: "dryRun", state: .skipped)]),
            forID: md.id
        )
        let (model, _) = make(controller)
        await model.reloadAll()
        model.beginInstall(listing(md.id, in: model))
        await model.approveAndRun()
        XCTAssertFalse(model.finishedModCanBeEnabled)
        XCTAssertEqual(model.enableBlockReason(for: model.installedMod(id: md.id)!), "Preflight didn't complete")
    }

    func testEnableRequiresPreflightFirst() async {
        let controller = PreviewModManagementController()
        controller.setPreflightOutcome(PreviewModManagementController.failingResult(id: "local@scratch", version: "0.0.1"), forID: "local@scratch")
        let (model, _) = make(controller)
        await model.reloadAll()
        XCTAssertEqual(model.installBlockReason(for: listing("cleo@neon-pack", in: model)), "Already installed")
        XCTAssertFalse(model.beginInstall(listing("cleo@neon-pack", in: model)))

        let local = model.installedMod(id: "local@scratch")!
        XCTAssertEqual(model.enableBlockReason(for: local), "Fix 1 preflight error")
        await model.setEnabled(local.id, true)
        XCTAssertFalse(controller.calls.contains("enable:local@scratch"))

        await model.runPreflight(local.id)
        XCTAssertNotNil(model.installedMod(id: local.id)?.lastPreflight?.ranAt)
        XCTAssertEqual(model.installedMod(id: local.id)?.lastPreflight?.errorCount, 1)
        XCTAssertFalse(controller.calls.contains("enable:local@scratch"))
    }

    func testModWithNoPreflightCannotBeEnabled() async {
        let mod = InstalledMod(id: "fresh", title: "Fresh", author: "a", version: "1")
        let (model, controller) = make(PreviewModManagementController(installed: [mod]))
        await model.reloadInstalled()
        XCTAssertEqual(model.enableBlockReason(for: mod), "Run preflight first")
        await model.setEnabled("fresh", true)
        XCTAssertNotNil(model.actionError)
        XCTAssertFalse(controller.calls.contains("enable:fresh"))
    }

    func testRerunningPreflightThatNowPassesUnblocksEnable() async {
        let controller = PreviewModManagementController()
        let (model, _) = make(controller)
        await model.reloadAll()
        XCTAssertFalse(model.canEnable(model.installedMod(id: "local@scratch")!))
        controller.setPreflightOutcome(PreviewModManagementController.passingResult(id: "local@scratch", version: "0.0.1"), forID: "local@scratch")
        await model.runPreflight("local@scratch")
        XCTAssertTrue(model.canEnable(model.installedMod(id: "local@scratch")!))
        await model.setEnabled("local@scratch", true)
        XCTAssertEqual(model.installedMod(id: "local@scratch")?.isEnabled, true)
        await model.setEnabled("local@scratch", false)
        XCTAssertEqual(model.installedMod(id: "local@scratch")?.isEnabled, false)
    }

    func testFailedInstallReportsAndAllowsRetry() async {
        let controller = PreviewModManagementController()
        controller.setInstallFails("ben@markdown-preview")
        let (model, _) = make(controller)
        await model.reloadAll()
        let md = listing("ben@markdown-preview", in: model)
        model.beginInstall(md)
        await model.approveAndRun()
        guard case .failed(let message, let modID) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertNil(modID)
        XCTAssertTrue(message.contains("verification"))
        XCTAssertFalse(model.isInstalled(md))
        XCTAssertTrue(model.cancelFlow())

        controller.setInstallFails("ben@markdown-preview", false)
        XCTAssertTrue(model.beginInstall(md))
        await model.approveAndRun()
        XCTAssertTrue(model.isInstalled(md))
    }

    func testCannotStartSecondFlowOrInstallExpiredIndexOrIncompatible() async {
        let (model, controller) = make()
        await model.reloadAll()
        XCTAssertTrue(model.beginInstall(listing("ben@markdown-preview", in: model)))
        XCTAssertFalse(model.beginInstall(listing("dan@trash-guard", in: model)))
        XCTAssertTrue(model.cancelFlow())

        XCTAssertFalse(model.beginInstall(listing("eve@future-only", in: model)))
        XCTAssertEqual(model.installBlockReason(for: listing("eve@future-only", in: model)), "Requires mod API 2.0.")

        controller.setIndex(ModIndexSnapshot(listings: PreviewModManagementController.sampleListings, fetchedAt: .distantPast, isExpired: true, isOffline: true))
        await model.reloadIndex()
        XCTAssertFalse(model.beginInstall(listing("ben@markdown-preview", in: model)))
        XCTAssertNotNil(model.installBlockReason(for: listing("ben@markdown-preview", in: model)))
    }

    func testApproveWithoutReviewDoesNothing() async {
        let (model, controller) = make()
        await model.reloadAll()
        await model.approveAndRun()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(controller.calls.contains { $0.hasPrefix("install") })
        await model.enableFinishedMod()
        XCTAssertEqual(model.phase, .idle)
    }

    func testHighRiskPermissionsAreAllListedForReview() async {
        let (model, _) = make()
        await model.reloadAll()
        let guardMod = listing("dan@trash-guard", in: model)
        XCTAssertEqual(guardMod.highestRisk, .high)
        model.beginInstall(guardMod)
        guard case .reviewingPermissions(let op) = model.phase else { return XCTFail() }
        XCTAssertEqual(op.permissionsToReview.count, 2)
        XCTAssertTrue(op.permissionsToReview.allSatisfy { !$0.reason.isEmpty })
    }

    func testUpdateFlowReviewsOnlyNewPermissionsAndRequiresPreflight() async {
        let (model, controller) = make()
        await model.reloadAll()
        XCTAssertTrue(model.beginUpdate("cleo@neon-pack"))
        guard case .reviewingPermissions(let op) = model.phase else { return XCTFail() }
        XCTAssertEqual(op.kind, .update(modID: "cleo@neon-pack"))
        XCTAssertTrue(op.permissionsToReview.isEmpty)
        await model.approveAndRun()
        guard case .finished(_, let result) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(result.allowsEnable)
        XCTAssertEqual(model.installedMod(id: "cleo@neon-pack")?.version, "2.0.0")
        XCTAssertEqual(model.installedMod(id: "cleo@neon-pack")?.isEnabled, false)
        XCTAssertNil(model.installedMod(id: "cleo@neon-pack")?.availableUpdate)
        XCTAssertEqual(controller.calls.suffix(2), ["update:cleo@neon-pack", "preflight:cleo@neon-pack"])
        XCTAssertFalse(model.beginUpdate("cleo@neon-pack"))
    }

    func testUninstallWithAndWithoutData() async {
        let (model, controller) = make()
        await model.reloadAll()
        await model.uninstall("local@scratch", deleteData: true)
        XCTAssertNil(model.installedMod(id: "local@scratch"))
        XCTAssertEqual(controller.dataDeletedFor, ["local@scratch"])
        await model.uninstall("cleo@neon-pack", deleteData: false)
        XCTAssertTrue(model.installed.isEmpty)
        XCTAssertEqual(controller.dataDeletedFor, ["local@scratch"])
        await model.uninstall("ghost", deleteData: false)
        XCTAssertNotNil(model.actionError)
    }

    func testShowFolderUsesInjectedOpener() async {
        let (model, _) = make()
        await model.reloadAll()
        var opened: [URL] = []
        model.openFolder = { opened.append($0) }
        model.showFolder(for: model.installedMod(id: "cleo@neon-pack")!)
        XCTAssertEqual(opened.count, 1)
        var noFolder = model.installedMod(id: "cleo@neon-pack")!
        noFolder.folderURL = nil
        model.showFolder(for: noFolder)
        XCTAssertEqual(opened.count, 1)
    }

    func testCannotCancelWhileBusy() async {
        let controller = PreviewModManagementController(latencyNanoseconds: 150_000_000)
        let (model, _) = make(controller)
        await model.reloadAll()
        model.beginInstall(listing("ben@markdown-preview", in: model))
        let run = Task { await model.approveAndRun() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.phase.isBusy)
        XCTAssertFalse(model.cancelFlow())
        XCTAssertFalse(model.beginInstall(listing("dan@trash-guard", in: model)))
        await run.value
        XCTAssertTrue(model.cancelFlow())
    }

    func testPreflightSummaryHelpers() {
        let ok = PreviewModManagementController.passingResult(id: "a", version: "1")
        XCTAssertTrue(ok.allowsEnable)
        XCTAssertEqual(ok.headline, "Passed preflight")
        var warned = ok
        warned.diagnostics = [PreflightDiagnostic(severity: .warning, code: "W", message: "m")]
        XCTAssertTrue(warned.allowsEnable)
        XCTAssertEqual(warned.headline, "Passed with 1 warning")
        let bad = PreviewModManagementController.failingResult(id: "a", version: "1")
        XCTAssertFalse(bad.allowsEnable)
        XCTAssertEqual(bad.warningCount, 1)
        var contradictory = ok
        contradictory.diagnostics = [PreflightDiagnostic(severity: .error, code: "E", message: "m")]
        XCTAssertFalse(contradictory.allowsEnable)
        var notOK = ok
        notOK.ok = false
        XCTAssertFalse(notOK.allowsEnable)
    }
}
