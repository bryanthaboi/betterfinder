import XCTest
@testable import Updates

final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _installs = 0
    var installs: Int { lock.withLock { _installs } }

    func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate {
        progress(1)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return PreparedUpdate(release: release, appURL: dir.appendingPathComponent("New.app"), stagingDirectory: dir)
    }

    func install(_ prepared: PreparedUpdate) throws {
        lock.withLock { _installs += 1 }
    }
}

@MainActor
final class RegressionInstallGateTests: XCTestCase {
    var suite = ""
    var defaults: UserDefaults!

    override func setUp() async throws {
        (defaults, suite) = makeDefaults()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func release() -> UpdateRelease {
        UpdateRelease(tag: "v9.9.9", version: SemanticVersion("9.9.9")!, name: "9.9.9", notes: "", pageURL: nil, publishedAt: nil, zipAsset: nil, dmgAsset: nil)
    }

    func makeController(gate: (@MainActor () async -> Bool)?, terminated: @escaping @MainActor () -> Void) -> (UpdateController, FakeInstaller) {
        let controller = UpdateController(preferences: UpdatePreferences(defaults: defaults))
        let installer = FakeInstaller()
        controller.makeInstaller = { _, _ in installer }
        controller.terminateHandler = terminated
        controller.installGate = gate
        controller.setStateForTesting(.available(release()))
        return (controller, installer)
    }

    func testRefusedGateNeverLaunchesInstallerOrTerminates() async {
        var terminated = 0
        var gateCalls = 0
        let (controller, installer) = makeController(gate: { gateCalls += 1; return false }, terminated: { terminated += 1 })
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertEqual(gateCalls, 1)
        XCTAssertEqual(installer.installs, 0)
        XCTAssertEqual(terminated, 0)
        XCTAssertEqual(controller.state, .available(release()))
        XCTAssertFalse(controller.isWaitingForInstallGate)
    }

    func testInstallerRunsOnlyAfterGatePasses() async {
        var terminated = 0
        var installsSeenByGate = -1
        var installerRef: FakeInstaller?
        let (controller, installer) = makeController(gate: {
            installsSeenByGate = installerRef?.installs ?? -1
            return true
        }, terminated: { terminated += 1 })
        installerRef = installer
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertEqual(installsSeenByGate, 0)
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(terminated, 1)
    }

    func testWaitingFlagIsSetWhileGatePending() async {
        var observed = false
        var controllerRef: UpdateController?
        let (controller, _) = makeController(gate: {
            observed = controllerRef?.isWaitingForInstallGate ?? false
            return false
        }, terminated: {})
        controllerRef = controller
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertTrue(observed)
        XCTAssertEqual(UpdatePhase(.verifying(release()), waiting: true).kind, .waiting)
    }

    func testNoGateKeepsExistingBehavior() async {
        var terminated = 0
        let (controller, installer) = makeController(gate: nil, terminated: { terminated += 1 })
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(terminated, 1)
    }

    func testReleaseNotesGroupListsAndSeparateBlocks() {
        let blocks = MarkdownBlocks.parse("# Title\n\nIntro\n\n- one\n- two\n1. three\n\nOutro")
        let groups = ReleaseNotesView.groups(blocks)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[2].count, 3)
        XCTAssertEqual(ReleaseNotesView.blockSpacing, 16)
        XCTAssertEqual(ReleaseNotesView.listItemSpacing, 8)
    }

    func testPhaseAnnouncementsOnlyForTerminalStates() {
        XCTAssertNil(UpdatePhase(.downloading(release(), 0.4)).announcement)
        XCTAssertEqual(UpdatePhase(.downloading(release(), 0.4)), UpdatePhase(.downloading(release(), 0.9)))
        XCTAssertNotNil(UpdatePhase(.failed("x")).announcement)
        XCTAssertNotNil(UpdatePhase(.upToDate(SemanticVersion("1.0.0")!)).announcement)
    }
}

@MainActor
final class RegressionInstallGateCancelTests: XCTestCase {
    func testCancellingWhileGateWaitsRestoresAvailable() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = UpdateRelease(tag: "v9.9.9", version: SemanticVersion("9.9.9")!, name: "9.9.9", notes: "", pageURL: nil, publishedAt: nil, zipAsset: nil, dmgAsset: nil)
        let controller = UpdateController(preferences: UpdatePreferences(defaults: defaults))
        let installer = FakeInstaller()
        controller.makeInstaller = { _, _ in installer }
        var terminated = 0
        controller.terminateHandler = { terminated += 1 }
        controller.installGate = {
            controller.cancelWork()
            return true
        }
        controller.setStateForTesting(.available(release))
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertEqual(installer.installs, 0)
        XCTAssertEqual(terminated, 0)
        XCTAssertEqual(controller.state, .available(release))
    }
}
