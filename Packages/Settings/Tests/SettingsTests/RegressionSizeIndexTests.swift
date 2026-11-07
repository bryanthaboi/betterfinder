import XCTest
@testable import Settings

@MainActor
final class FakeSizeIndex: SizeIndexControlling {
    var isIndexingPaused = false
    var availability: SizeIndexAvailability = .available
    var ack = true
    var pauseRequests: [Bool] = []
    var rebuilds = 0

    func setIndexingPaused(_ paused: Bool) {}
    func rebuildIndex() {}
    func refreshAvailability() async -> SizeIndexAvailability { availability }

    func requestPause(_ paused: Bool) async -> Bool {
        pauseRequests.append(paused)
        if ack { isIndexingPaused = paused }
        return ack
    }

    func requestRebuild() async -> Bool {
        rebuilds += 1
        return ack
    }
}

@MainActor
final class RegressionSizeIndexTests: XCTestCase {
    func testRebuildStartedOnlyAfterAcknowledgement() async {
        let fake = FakeSizeIndex()
        fake.ack = false
        let model = SizeIndexSettingsModel(controller: fake)
        await model.requestRebuild()
        XCTAssertEqual(fake.rebuilds, 1)
        guard case .failed = model.rebuild else { return XCTFail("expected failure, got \(model.rebuild)") }
        fake.ack = true
        await model.requestRebuild()
        XCTAssertEqual(model.rebuild, .started)
    }

    func testPauseNotPersistedWhenHelperRejects() async {
        let fake = FakeSizeIndex()
        fake.ack = false
        let model = SizeIndexSettingsModel(controller: fake)
        await model.setPaused(true)
        XCTAssertFalse(model.paused)
        XCTAssertNotNil(model.pauseError)
        fake.ack = true
        await model.setPaused(true)
        XCTAssertTrue(model.paused)
        XCTAssertNil(model.pauseError)
    }

    func testUnavailableHelperDisablesControlsAndExplainsFallback() async {
        let fake = FakeSizeIndex()
        fake.availability = .notInstalled("in-app")
        let model = SizeIndexSettingsModel(controller: fake)
        await model.refresh()
        XCTAssertFalse(model.controlsEnabled)
        XCTAssertEqual(model.availability.explanation, "in-app")
        await model.requestRebuild()
        await model.setPaused(true)
        XCTAssertEqual(fake.rebuilds, 0)
        XCTAssertTrue(fake.pauseRequests.isEmpty)
        XCTAssertEqual(model.rebuild, .idle)
    }

    func testNoOpControllerReportsSuccessfulDefaults() async {
        let noop = NoOpSizeIndexController()
        let ok = await noop.requestPause(true)
        XCTAssertTrue(ok)
        XCTAssertTrue(noop.isIndexingPaused)
        XCTAssertEqual(noop.availability, .available)
    }

    func testApprovalStateExplainsLoginItems() {
        XCTAssertTrue(SizeIndexAvailability.requiresApproval.explanation?.contains("Login Items") == true)
    }
}
