import XCTest
@testable import Updates

final class FailingInstaller: UpdateInstalling, @unchecked Sendable {
    func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return PreparedUpdate(release: release, appURL: dir.appendingPathComponent("New.app"), stagingDirectory: dir)
    }

    func install(_ prepared: PreparedUpdate) throws {
        throw UpdateError.installFailed("swap refused")
    }
}

@MainActor
final class RegressionRelaunchTests: XCTestCase {
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

    func testTerminateHandlerCanWaitOnTheMainQueue() async {
        let controller = UpdateController(preferences: UpdatePreferences(defaults: defaults))
        let installer = FakeInstaller()
        controller.makeInstaller = { _, _ in installer }
        var terminated = 0
        var mainQueueDrained = false
        controller.terminateHandler = {
            terminated += 1
            var replied = false
            DispatchQueue.main.async { replied = true }
            let deadline = Date().addingTimeInterval(3)
            while !replied, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            mainQueueDrained = replied
        }
        controller.setStateForTesting(.available(release()))
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(terminated, 1)
        XCTAssertTrue(mainQueueDrained)
    }

    func testFailedInstallSurfacesErrorAndNeverTerminates() async {
        let controller = UpdateController(preferences: UpdatePreferences(defaults: defaults))
        controller.makeInstaller = { _, _ in FailingInstaller() }
        var terminated = 0
        controller.terminateHandler = { terminated += 1 }
        controller.setStateForTesting(.available(release()))
        controller.installAndRelaunch()
        await controller.pendingWork?.value
        XCTAssertEqual(terminated, 0)
        XCTAssertEqual(controller.state, .failed(UpdateError.installFailed("swap refused").localizedDescription))
    }
}
