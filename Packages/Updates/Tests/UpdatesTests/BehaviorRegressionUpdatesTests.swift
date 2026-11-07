import AppKit
import XCTest
@testable import Updates

struct UpdatesAXNode {
    let object: NSObject

    init(_ object: NSObject) { self.object = object }

    private func fetch(_ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    var role: String? { fetch("accessibilityRole") as? String }
    var label: String? { fetch("accessibilityLabel") as? String }
    var valueText: String? { fetch("accessibilityValue").map { "\($0)" } }
    var valueDescription: String? { fetch("accessibilityValueDescription") as? String }
    var isEnabled: Bool {
        guard object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return true }
        return object.value(forKey: "accessibilityEnabled") as? Bool ?? true
    }
    var children: [UpdatesAXNode] { ((fetch("accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(UpdatesAXNode.init) } }
    var descendants: [UpdatesAXNode] { [self] + children.flatMap(\.descendants) }

    @discardableResult
    func press() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

final class ScriptedInstaller: UpdateInstalling, @unchecked Sendable {
    enum Script {
        case succeed
        case fail(String)
        case blockUntilCancelled(Double)
    }

    private let lock = NSLock()
    private let script: Script
    private var _installs = 0
    var installs: Int { lock.withLock { _installs } }

    init(_ script: Script) { self.script = script }

    func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate {
        switch script {
        case .succeed:
            progress(1)
        case .fail(let message):
            throw NSError(domain: "BehaviorRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        case .blockUntilCancelled(let fraction):
            progress(fraction)
            while true { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return PreparedUpdate(release: release, appURL: dir.appendingPathComponent("Never.app"), stagingDirectory: dir)
    }

    func install(_ prepared: PreparedUpdate) throws {
        lock.withLock { _installs += 1 }
    }
}

final class UpdatesFlowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

@MainActor
final class BehaviorRegressionUpdateViewAccessibilityTests: XCTestCase {
    var suite = ""
    var defaults: UserDefaults!
    var announced: [String] = []
    var focused: [String] = []
    var terminated = 0
    var windowController: UpdateWindowController?

    let release = UpdateRelease(tag: "v9.9.9", version: SemanticVersion("9.9.9")!, name: "9.9.9", notes: "Fixes.", pageURL: nil, publishedAt: nil, zipAsset: nil, dmgAsset: nil)

    override func setUp() async throws {
        (defaults, suite) = makeDefaults()
        announced = []
        focused = []
        terminated = 0
        _ = NSApplication.shared
        NSApp.perform(Selector(("accessibilitySetEnhancedUserInterfaceAttribute:")), with: NSNumber(value: true))
    }

    override func tearDown() async throws {
        windowController?.window?.orderOut(nil)
        windowController?.close()
        windowController = nil
        NSApp.perform(Selector(("accessibilitySetEnhancedUserInterfaceAttribute:")), with: NSNumber(value: false))
        defaults.removePersistentDomain(forName: suite)
    }

    func host(_ installer: ScriptedInstaller, state: UpdateState) async -> UpdateController {
        let controller = UpdateController(preferences: UpdatePreferences(defaults: defaults))
        controller.makeInstaller = { _, _ in installer }
        controller.terminateHandler = { [unowned self] in terminated += 1 }
        controller.accessibilityEvents = UpdateAccessibilityEvents(
            announce: { [unowned self] in announced.append($0) },
            headingFocusRequested: { [unowned self] in focused.append($0) }
        )
        controller.setStateForTesting(state)
        let wc = UpdateWindowController(controller: controller)
        wc.window?.orderFront(nil)
        windowController = wc
        await settle()
        return controller
    }

    var nodes: [UpdatesAXNode] {
        guard let view = windowController?.window?.contentView else { return [] }
        return UpdatesAXNode(view).descendants
    }

    func button(_ label: String) -> UpdatesAXNode? { nodes.first { $0.role == "AXButton" && $0.label == label } }
    func heading(_ text: String) -> UpdatesAXNode? { nodes.first { $0.role == "AXHeading" && ($0.label == text || $0.valueText == text) } }
    var progress: [UpdatesAXNode] { nodes.filter { $0.role == "AXBusyIndicator" || $0.role == "AXProgressIndicator" } }

    func settle(_ seconds: TimeInterval = 0.2) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        windowController?.window?.contentView?.layoutSubtreeIfNeeded()
    }

    func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await settle()
        return true
    }

    func testCancellingDownloadMovesFocusOffCancelAndAnnouncesTheResultOnce() async {
        let release = self.release
        let installer = ScriptedInstaller(.blockUntilCancelled(0.3))
        let controller = await host(installer, state: .available(release))
        XCTAssertNotNil(heading("betterfinder 9.9.9 is available"))
        XCTAssertTrue(progress.isEmpty)

        controller.installAndRelaunch()
        guard await waitUntil({ controller.state == .downloading(release, 0.3) }) else { return XCTFail("\(controller.state)") }
        XCTAssertNotNil(heading("Downloading betterfinder 9.9.9…"))
        XCTAssertEqual(progress.map(\.role), ["AXProgressIndicator"])
        XCTAssertEqual(progress.first?.label, "Downloading betterfinder 9.9.9")
        XCTAssertNil(button("Install & Relaunch"))
        XCTAssertEqual(focused, ["Downloading betterfinder 9.9.9…"])
        XCTAssertEqual(announced, [])

        XCTAssertTrue(button("Cancel")?.press() == true)
        guard await waitUntil({ controller.state == .available(release) }) else { return XCTFail("\(controller.state)") }
        XCTAssertNil(button("Cancel"))
        XCTAssertTrue(progress.isEmpty)
        XCTAssertNotNil(heading("betterfinder 9.9.9 is available"))
        XCTAssertEqual(focused, ["Downloading betterfinder 9.9.9…", "betterfinder 9.9.9 is available"])
        XCTAssertEqual(announced, ["betterfinder 9.9.9 is available"])
        XCTAssertEqual(installer.installs, 0)
        XCTAssertEqual(terminated, 0)
    }

    func testDownloadFailureReplacesProgressAndAnnouncesOnce() async {
        let installer = ScriptedInstaller(.fail("Archive checksum mismatch"))
        let controller = await host(installer, state: .available(release))
        controller.installAndRelaunch()
        guard await waitUntil({ controller.state == .failed("Archive checksum mismatch") }) else { return XCTFail("\(controller.state)") }
        await settle()
        XCTAssertNotNil(heading("Update failed"))
        XCTAssertTrue(progress.isEmpty)
        XCTAssertNil(button("Cancel"))
        XCTAssertNil(button("Install & Relaunch"))
        XCTAssertNotNil(button("Try Again"))
        XCTAssertNotNil(button("Close"))
        XCTAssertEqual(focused.last, "Update failed")
        XCTAssertEqual(announced, ["Update failed. Archive checksum mismatch"])
        XCTAssertEqual(installer.installs, 0)
        XCTAssertEqual(terminated, 0)
    }

    func testWaitingForFileOperationsIsLabeledAndCancelUpdateRestoresAvailable() async {
        let release = self.release
        let installer = ScriptedInstaller(.succeed)
        let gate = UpdatesFlowGate()
        let controller = await host(installer, state: .available(release))
        controller.installGate = {
            await gate.wait()
            return true
        }
        controller.installAndRelaunch()
        guard await waitUntil({ controller.isWaitingForInstallGate }) else { return XCTFail("\(controller.state)") }
        XCTAssertNotNil(heading("Waiting to install betterfinder 9.9.9…"))
        XCTAssertEqual(progress.map(\.label), ["Waiting for file operations to finish"])
        XCTAssertEqual(focused.last, "Waiting to install betterfinder 9.9.9…")
        XCTAssertEqual(announced, ["Waiting for file operations to finish before installing"])

        XCTAssertTrue(button("Cancel Update")?.press() == true)
        gate.open()
        guard await waitUntil({ controller.state == .available(release) && !controller.isWaitingForInstallGate }) else { return XCTFail("\(controller.state)") }
        XCTAssertNil(button("Cancel Update"))
        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(focused.last, "betterfinder 9.9.9 is available")
        XCTAssertEqual(announced, ["Waiting for file operations to finish before installing", "betterfinder 9.9.9 is available"])
        XCTAssertEqual(installer.installs, 0)
        XCTAssertEqual(terminated, 0)
    }

    func testCheckingAndInstallingPhasesNameTheirProgress() async {
        let controller = await host(ScriptedInstaller(.succeed), state: .checking)
        XCTAssertEqual(progress.map(\.label), ["Checking for updates"])
        XCTAssertEqual(progress.first?.role, "AXBusyIndicator")
        XCTAssertNotNil(button("Cancel"))

        controller.setStateForTesting(.upToDate(SemanticVersion("1.0.0")!))
        await settle()
        XCTAssertNil(button("Cancel"))
        XCTAssertTrue(progress.isEmpty)
        XCTAssertNotNil(heading("You're up to date"))
        XCTAssertEqual(focused, ["You're up to date"])
        XCTAssertEqual(announced, ["betterfinder is up to date"])

        controller.setStateForTesting(.verifying(release))
        await settle()
        XCTAssertEqual(progress.map(\.label), ["Verifying betterfinder 9.9.9"])
        controller.setStateForTesting(.installing(release))
        await settle()
        XCTAssertEqual(progress.map(\.label), ["Installing betterfinder 9.9.9"])
        XCTAssertNotNil(heading("Installing betterfinder 9.9.9…"))
        XCTAssertTrue(nodes.filter { $0.role == "AXButton" }.isEmpty)
        XCTAssertEqual(focused, ["You're up to date", "Verifying betterfinder 9.9.9…", "Installing betterfinder 9.9.9…"])
        XCTAssertEqual(announced, ["betterfinder is up to date"])
    }
}
