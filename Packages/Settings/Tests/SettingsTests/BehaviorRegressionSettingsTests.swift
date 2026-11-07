import AppKit
import Combine
import Integration
import SwiftUI
import Theming
import UniformTypeIdentifiers
import XCTest
@testable import Settings

struct AXNode {
    let object: NSObject

    init(_ object: NSObject) { self.object = object }

    private func fetch(_ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    var role: String? { fetch("accessibilityRole") as? String }
    var subrole: String? { fetch("accessibilitySubrole") as? String }
    var label: String? { fetch("accessibilityLabel") as? String }
    var title: String? { fetch("accessibilityTitle") as? String }
    var help: String? { fetch("accessibilityHelp") as? String }
    var placeholder: String? { fetch("accessibilityPlaceholderValue") as? String }
    var value: Any? { fetch("accessibilityValue") }
    var valueText: String? { value.map { "\($0)" } }
    var valueDescription: String? { fetch("accessibilityValueDescription") as? String }
    var frame: NSRect { (fetch("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    var isEnabled: Bool {
        guard object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return true }
        return object.value(forKey: "accessibilityEnabled") as? Bool ?? true
    }
    var children: [AXNode] { ((fetch("accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(AXNode.init) } }
    var descendants: [AXNode] { [self] + children.flatMap(\.descendants) }
    var exposedStrings: [String] {
        [label, title, help, placeholder, valueText, valueDescription, fetch("accessibilityIdentifier") as? String].compactMap { $0 }
    }

    @discardableResult
    func press() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

@MainActor
final class HostedSwiftUI {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init<Content: View>(_ view: Content, size: NSSize) {
        _ = NSApplication.shared
        NSApp.perform(Selector(("accessibilitySetEnhancedUserInterfaceAttribute:")), with: NSNumber(value: true))
        host = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        pump()
    }

    func pump(_ seconds: TimeInterval = 0.15) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    func settle(_ seconds: TimeInterval = 0.15) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        host.layoutSubtreeIfNeeded()
    }

    func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await settle()
        return true
    }

    var root: AXNode { AXNode(host) }
    var nodes: [AXNode] { root.descendants }

    func node(_ role: String, _ label: String) -> AXNode? {
        nodes.first { $0.role == role && $0.label == label }
    }

    func heading(_ text: String) -> AXNode? {
        nodes.first { $0.role == "AXHeading" && ($0.label == text || $0.valueText == text) }
    }

    func texts(_ text: String) -> [AXNode] {
        nodes.filter { $0.role == "AXStaticText" && $0.valueText == text }
    }

    var progressIndicators: [AXNode] {
        nodes.filter { $0.role == "AXBusyIndicator" || $0.role == "AXProgressIndicator" }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        NSApp.perform(Selector(("accessibilitySetEnhancedUserInterfaceAttribute:")), with: NSNumber(value: false))
    }
}

@MainActor
final class PublishedWork: ObservableObject {
    @Published var count = 0
}

@MainActor
final class BehaviorRegressionActiveWorkGateTests: XCTestCase {
    func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func gate(_ work: PublishedWork, asked: @escaping () -> Void = {}) -> ActiveWorkGate {
        ActiveWorkGate(
            activeCount: { work.count },
            cancelAll: {},
            counts: work.$count.eraseToAnyPublisher(),
            ask: { _, _ in asked(); return .waitUntilFinished }
        )
    }

    func testQuitWhenFinishedFiresWhenQueueDrainsWhileAlertIsOpen() {
        let count = CurrentValueSubject<Int, Never>(2)
        let g = ActiveWorkGate(
            activeCount: { count.value },
            cancelAll: {},
            counts: count.eraseToAnyPublisher(),
            ask: { _, _ in
                count.value = 0
                return .waitUntilFinished
            }
        )
        XCTAssertEqual(g.terminationDecision(), .quitWhenIdle)
        var quits = 0
        g.quitWhenIdle { quits += 1 }
        pump()
        XCTAssertEqual(quits, 1)
        XCTAssertFalse(g.isQuitPending)
        count.value = 1
        count.value = 0
        pump()
        XCTAssertEqual(quits, 1)
    }

    func testWillSetEmissionDeliversOnlyOnceActiveCountReadsZero() {
        let work = PublishedWork()
        work.count = 1
        var asks = 0
        let g = gate(work) { asks += 1 }
        XCTAssertEqual(g.terminationDecision(), .quitWhenIdle)
        var seen: [Int] = []
        var reentrant: ActiveWorkGate.TerminationDecision?
        g.quitWhenIdle {
            seen.append(work.count)
            reentrant = g.terminationDecision()
        }
        work.count = 0
        XCTAssertEqual(seen, [])
        pump()
        XCTAssertEqual(seen, [0])
        XCTAssertEqual(reentrant, .proceed)
        XCTAssertEqual(asks, 1)
        XCTAssertFalse(g.isQuitPending)
    }

    func testWorkRestartingBeforeDeliveryKeepsWaiting() {
        let work = PublishedWork()
        work.count = 1
        let g = gate(work)
        var quits = 0
        g.quitWhenIdle { quits += 1 }
        work.count = 0
        work.count = 1
        pump()
        XCTAssertEqual(quits, 0)
        XCTAssertTrue(g.isQuitPending)
        work.count = 0
        pump()
        XCTAssertEqual(quits, 1)
        XCTAssertFalse(g.isQuitPending)
    }

    func testCancelPendingQuitBeforeDeliveryPreventsQuit() {
        let work = PublishedWork()
        work.count = 1
        let g = gate(work)
        var quits = 0
        g.quitWhenIdle { quits += 1 }
        work.count = 0
        g.cancelPendingQuit()
        pump()
        XCTAssertEqual(quits, 0)
        XCTAssertFalse(g.isQuitPending)
        work.count = 1
        work.count = 0
        pump()
        XCTAssertEqual(quits, 0)
    }

    func testUpdateWaitIgnoresTransientIdleEmission() async {
        let work = PublishedWork()
        work.count = 1
        let g = gate(work)
        var result: Bool?
        let task = Task { @MainActor in result = await g.confirm(.update) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        work.count = 0
        work.count = 1
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(result)
        work.count = 0
        await task.value
        XCTAssertEqual(result, true)
    }
}

@MainActor
final class BehaviorRegressionModSettingsAccessibilityTests: XCTestCase {
    func testNumericAndSecretFieldsKeepTheirTitlesAndNeverExposeTheDraft() throws {
        let schema = try ModSettingsSchema.decode(from: Data(#"""
        {"schemaVersion":1,"fields":[
          {"key":"retries","type":"integer","title":"Retry count","min":0,"max":5,"default":1},
          {"key":"uploads","type":"integer","title":"Parallel uploads","default":3},
          {"key":"ratio","type":"number","title":"Blend ratio","min":0,"max":1,"default":0.5},
          {"key":"timeout","type":"number","title":"Timeout seconds","default":2.5},
          {"key":"token","type":"secret","title":"API token","placeholder":"Paste your token"},
          {"key":"password","type":"secret","title":"Backup password"}
        ]}
        """#.utf8))
        let suite = "BehaviorRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = "stored-value-9431"
        let draft = "hunter2-DRAFT-7781"
        let store = try ModSettingsStore(modID: "ada@test", schema: schema, defaults: defaults, secrets: InMemorySecretStore())
        try store.setSecret(stored, for: "password")
        let model = ModSettingsFormModel(store: store)
        var announced: [String] = []
        model.announce = { announced.append($0) }
        model.secretDrafts["token"] = draft
        let hosted = HostedSwiftUI(ModSettingsFormView(model: model).frame(width: 520, height: 900), size: NSSize(width: 520, height: 900))
        defer { hosted.close() }

        XCTAssertEqual(hosted.node("AXTextField", "Retry count")?.valueText, "1")
        XCTAssertEqual(hosted.node("AXIncrementor", "Retry count")?.valueText, "1")
        XCTAssertEqual(hosted.node("AXTextField", "Parallel uploads")?.valueText, "3")
        XCTAssertEqual(hosted.node("AXIncrementor", "Parallel uploads")?.valueText, "3")
        XCTAssertNotNil(hosted.node("AXSlider", "Blend ratio"))
        XCTAssertNotNil(hosted.node("AXTextField", "Timeout seconds"))
        for title in ["Retry count", "Parallel uploads", "Blend ratio", "Timeout seconds", "API token", "Backup password"] {
            XCTAssertFalse(hosted.nodes.contains { ($0.label ?? "").contains("\(title), \(title)") }, title)
        }

        let token = hosted.node("AXTextField", "API token")
        XCTAssertEqual(token?.subrole, "AXSecureTextField")
        XCTAssertEqual(token?.valueText, "Not set")
        XCTAssertEqual(token?.placeholder, "Paste your token")
        let password = hosted.node("AXTextField", "Backup password")
        XCTAssertEqual(password?.subrole, "AXSecureTextField")
        XCTAssertEqual(password?.valueText, "Stored in Keychain")
        XCTAssertEqual(hosted.node("AXButton", "Save API token")?.isEnabled, true)
        XCTAssertEqual(hosted.node("AXButton", "Remove API token")?.isEnabled, false)
        XCTAssertEqual(hosted.node("AXButton", "Save Backup password")?.isEnabled, false)
        XCTAssertEqual(hosted.node("AXButton", "Remove Backup password")?.isEnabled, true)
        XCTAssertFalse(hosted.nodes.contains { $0.role == "AXButton" && ($0.label == "Save" || $0.label == "Remove") })
        assertNothingExposes([draft, stored], in: hosted)

        XCTAssertTrue(hosted.node("AXButton", "Save API token")?.press() == true)
        hosted.pump()
        XCTAssertEqual(hosted.node("AXTextField", "API token")?.valueText, "Stored in Keychain")
        XCTAssertEqual(hosted.node("AXButton", "Remove API token")?.isEnabled, true)
        XCTAssertEqual(hosted.node("AXButton", "Save API token")?.isEnabled, false)
        XCTAssertTrue(hosted.node("AXButton", "Remove Backup password")?.press() == true)
        hosted.pump()
        XCTAssertEqual(hosted.node("AXTextField", "Backup password")?.valueText, "Not set")
        XCTAssertEqual(announced, ["API token saved", "Backup password removed"])
        assertNothingExposes([draft, stored], in: hosted)
        XCTAssertFalse(announced.contains { $0.contains(draft) || $0.contains(stored) })
    }

    func assertNothingExposes(_ secrets: [String], in hosted: HostedSwiftUI, file: StaticString = #filePath, line: UInt = #line) {
        let nodes = hosted.nodes
        XCTAssertGreaterThan(nodes.count, 10, file: file, line: line)
        for node in nodes {
            for text in node.exposedStrings {
                for secret in secrets {
                    XCTAssertFalse(text.contains(secret), "\(node.role ?? "?") exposes \(text)", file: file, line: line)
                }
            }
        }
    }
}

final class FlowGate: @unchecked Sendable {
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

final class FlowModController: ModManagementControlling, @unchecked Sendable {
    let listing: ModListing
    let installGate = FlowGate()
    let preflightGate = FlowGate()
    private let lock = NSLock()
    private var _installError: String?
    private var _enableError: String?
    var installError: String? {
        get { lock.withLock { _installError } }
        set { lock.withLock { _installError = newValue } }
    }
    var enableError: String? {
        get { lock.withLock { _enableError } }
        set { lock.withLock { _enableError = newValue } }
    }

    init(listing: ModListing) { self.listing = listing }

    func mod(enabled: Bool) -> InstalledMod {
        InstalledMod(id: listing.id, title: listing.title, author: listing.author, version: listing.version, isEnabled: enabled, permissions: listing.permissions)
    }

    func listInstalled() async throws -> [InstalledMod] { [] }
    func fetchIndex() async throws -> ModIndexSnapshot { ModIndexSnapshot(listings: [listing]) }

    func preflight(id: String) async throws -> PreflightResultSummary {
        await preflightGate.wait()
        return PreflightResultSummary(modID: id, version: listing.version, ok: true, checks: [PreflightCheck(name: "types", state: .pass)])
    }

    func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> InstalledMod {
        await installGate.wait()
        if let installError { throw NSError(domain: "BehaviorRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: installError]) }
        return mod(enabled: false)
    }

    func enable(id: String) async throws -> InstalledMod {
        if let enableError { throw NSError(domain: "BehaviorRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: enableError]) }
        return mod(enabled: true)
    }

    func disable(id: String) async throws -> InstalledMod { mod(enabled: false) }
    func uninstall(id: String, deleteData: Bool) async throws {}
    func update(id: String, approvedPermissionIDs: Set<String>) async throws -> InstalledMod { mod(enabled: false) }
}

@MainActor
final class BehaviorRegressionModFlowAccessibilityTests: XCTestCase {
    let listing = ModListing(id: "ada@tool", title: "Tool", author: "Ada", version: "1.0.0",
                             permissions: [PermissionSummary(id: "net", title: "Network: https://api.example.com", reason: "Uploads reports.", risk: .medium)])

    struct Flow {
        let controller: FlowModController
        let model: ModsPaneModel
        let hosted: HostedSwiftUI
        let events: Events
    }

    @MainActor
    final class Events {
        var announced: [String] = []
        var focused: [String] = []
    }

    func start() async -> Flow {
        let controller = FlowModController(listing: listing)
        let model = ModsPaneModel(controller: controller)
        let events = Events()
        model.announce = { events.announced.append($0) }
        model.headingFocusRequested = { events.focused.append($0) }
        await model.reloadAll()
        XCTAssertTrue(model.beginInstall(model.listings[0]))
        let hosted = HostedSwiftUI(ModInstallFlowSheet(model: model), size: NSSize(width: 460, height: 560))
        await hosted.settle()
        XCTAssertNotNil(hosted.heading("Install Tool"))
        XCTAssertNotNil(hosted.node("AXButton", "Allow and Install"))
        return Flow(controller: controller, model: model, hosted: hosted, events: events)
    }

    func testInstallPreflightAndEnableMoveFocusOffRemovedButtonsAndAnnounceOnce() async {
        let flow = await start()
        defer { flow.hosted.close() }
        let hosted = flow.hosted

        XCTAssertTrue(hosted.node("AXButton", "Allow and Install")?.press() == true)
        guard await hosted.waitUntil({ if case .installing = flow.model.phase { return true }; return false }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNil(hosted.node("AXButton", "Allow and Install"))
        XCTAssertNil(hosted.node("AXButton", "Cancel"))
        XCTAssertNotNil(hosted.heading("Install Tool"))
        XCTAssertEqual(hosted.progressIndicators.map(\.label), ["Installing Tool"])
        XCTAssertEqual(flow.events.focused, ["Install Tool"])
        XCTAssertEqual(flow.events.announced, [])

        flow.controller.installGate.open()
        guard await hosted.waitUntil({ flow.model.phase == .preflighting(modID: "ada@tool") }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNotNil(hosted.heading("Running preflight"))
        XCTAssertEqual(hosted.progressIndicators.map(\.label), ["Running preflight for Tool"])
        XCTAssertEqual(flow.events.focused, ["Install Tool", "Running preflight"])
        XCTAssertEqual(flow.events.announced, [])

        flow.controller.preflightGate.open()
        guard await hosted.waitUntil({ if case .finished = flow.model.phase { return true }; return false }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNotNil(hosted.heading("Ready to enable"))
        XCTAssertTrue(hosted.progressIndicators.isEmpty)
        XCTAssertEqual(flow.events.focused.last, "Ready to enable")
        XCTAssertEqual(flow.events.announced, ["Preflight passed. Ready to enable."])
        let enable = hosted.node("AXButton", "Enable")
        XCTAssertEqual(enable?.isEnabled, true)

        XCTAssertTrue(enable?.press() == true)
        guard await hosted.waitUntil({ flow.model.phase.isIdle }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNil(hosted.node("AXButton", "Enable"))
        XCTAssertEqual(flow.model.installedMod(id: "ada@tool")?.isEnabled, true)
        XCTAssertEqual(flow.events.announced, ["Preflight passed. Ready to enable.", "Tool enabled"])
        XCTAssertEqual(flow.events.focused, ["Install Tool", "Running preflight", "Ready to enable"])
    }

    func testInstallFailureReplacesActionsAndAnnouncesOnce() async {
        let flow = await start()
        defer { flow.hosted.close() }
        let hosted = flow.hosted
        flow.controller.installError = "Download failed: connection reset"
        flow.controller.installGate.open()

        XCTAssertTrue(hosted.node("AXButton", "Allow and Install")?.press() == true)
        guard await hosted.waitUntil({ if case .failed = flow.model.phase { return true }; return false }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNil(hosted.node("AXButton", "Allow and Install"))
        XCTAssertNotNil(hosted.heading("Something went wrong"))
        XCTAssertNotNil(hosted.node("AXButton", "Close"))
        XCTAssertTrue(hosted.progressIndicators.isEmpty)
        XCTAssertEqual(flow.events.focused.last, "Something went wrong")
        XCTAssertEqual(flow.events.announced, ["Install failed. Download failed: connection reset"])

        XCTAssertTrue(hosted.node("AXButton", "Close")?.press() == true)
        guard await hosted.waitUntil({ flow.model.phase.isIdle }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertEqual(flow.events.announced.count, 1)
    }

    func testEnableFailureIsAnnouncedOnceWithoutCallingItAnInstallFailure() async {
        let flow = await start()
        defer { flow.hosted.close() }
        let hosted = flow.hosted
        flow.controller.installGate.open()
        flow.controller.preflightGate.open()
        flow.controller.enableError = "The mod host refused to start Tool"

        XCTAssertTrue(hosted.node("AXButton", "Allow and Install")?.press() == true)
        guard await hosted.waitUntil({ if case .finished = flow.model.phase { return true }; return false }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertTrue(hosted.node("AXButton", "Enable")?.press() == true)
        guard await hosted.waitUntil({ if case .failed = flow.model.phase { return true }; return false }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNil(hosted.node("AXButton", "Enable"))
        XCTAssertNotNil(hosted.heading("Something went wrong"))
        XCTAssertEqual(flow.events.focused.last, "Something went wrong")
        XCTAssertEqual(flow.events.announced, ["Preflight passed. Ready to enable.", "Something went wrong. The mod host refused to start Tool"])
    }

    func testCancellingReviewClosesWithoutAnnouncement() async {
        let flow = await start()
        defer { flow.hosted.close() }
        XCTAssertTrue(flow.hosted.node("AXButton", "Cancel")?.press() == true)
        guard await flow.hosted.waitUntil({ flow.model.phase.isIdle }) else { return XCTFail("\(flow.model.phase)") }
        XCTAssertNil(flow.hosted.node("AXButton", "Cancel"))
        XCTAssertNil(flow.hosted.heading("Install Tool"))
        XCTAssertEqual(flow.events.announced, [])
        XCTAssertEqual(flow.events.focused, [])
    }
}

final class FakeFolderHandlers: FolderHandlerService {
    var handler: String? = "com.apple.finder"
    var setCalls = 0
    func handlerBundleID(for type: UTType) -> String? { handler }
    func setHandler(bundleID: String, appURL: URL?, for type: UTType) async throws { setCalls += 1 }
}

final class FakeCommandRunner: SystemCommandRunner {
    var relaunches = 0
    func relaunchApplication(bundleID: String) async throws { relaunches += 1 }
}

struct ReadableProbe: DirectoryProbing {
    func probe(_ url: URL) -> DirectoryProbeResult { .readable }
}

struct NoVolumes: VolumeProviding {
    func mountedVolumes() -> [VolumeDescriptor] { [] }
}

struct GrantedAutomation: AutomationChecking {
    func finderStatus(askUserIfNeeded: Bool) -> OSStatus { noErr }
}

@MainActor
final class OnboardingFakes {
    let suite = "BehaviorRegression.onboarding.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences = InMemoryPreferencesWriter()
    let tweakPreferences = InMemoryPreferencesWriter()
    let handlers = FakeFolderHandlers()
    let runner = FakeCommandRunner()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BehaviorRegression-\(UUID().uuidString)", isDirectory: true)
    let defaultModel: DefaultManagerModel
    let permissions: PermissionsModel
    let themes: ThemeManager

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let controller = DefaultFileManagerController(bundleID: "com.example.regression", appURL: directory, preferences: preferences, handlers: handlers, defaults: defaults)
        defaultModel = DefaultManagerModel(controller: controller, tweaks: FinderTweaks(preferences: tweakPreferences, runner: runner, defaults: defaults))
        permissions = PermissionsModel(center: PermissionsCenter(home: directory, prober: ReadableProbe(), volumes: NoVolumes(), automation: GrantedAutomation()))
        themes = ThemeManager(userThemesDirectory: directory.appendingPathComponent("Themes", isDirectory: true), defaults: defaults)
        themes.appliesAppAppearance = false
    }

    func view(step: OnboardingStep = .welcome, finish: @escaping () -> Void = {}, focused: @escaping (String) -> Void = { _ in }) -> OnboardingView {
        OnboardingView(finish: finish, step: step, defaultModel: defaultModel, permissions: permissions, themes: themes, headingFocusRequested: focused)
    }

    var systemDefaultsUntouched: Bool {
        handlers.setCalls == 0 && runner.relaunches == 0
            && preferences.value(forKey: DefaultFileManagerController.fileViewerKey, in: .global) == nil
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class BehaviorRegressionOnboardingTests: XCTestCase {
    let size = NSSize(width: 620, height: 560)

    func progress(_ hosted: HostedSwiftUI) -> AXNode? {
        hosted.nodes.first { $0.label == "Setup progress" }
    }

    func assertStep(_ n: Int, heading: String, in hosted: HostedSwiftUI, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(hosted.heading(heading), heading, file: file, line: line)
        guard let marker = progress(hosted) else { return XCTFail("no progress element", file: file, line: line) }
        XCTAssertEqual(marker.role, "AXProgressIndicator", file: file, line: line)
        XCTAssertEqual(marker.valueDescription ?? marker.valueText, "Step \(n) of 6", file: file, line: line)
        XCTAssertTrue(marker.children.isEmpty, file: file, line: line)
        XCTAssertEqual(hosted.nodes.filter { $0.label == "Setup progress" }.count, 1, file: file, line: line)
        XCTAssertTrue(hosted.texts("\(n) of 6").isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(marker.frame.height, 7 + Spacing.relatedText + 9, file: file, line: line)
    }

    func press(_ label: String, in hosted: HostedSwiftUI, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(hosted.node("AXButton", label)?.press() == true, label, file: file, line: line)
        await hosted.settle(0.25)
    }

    func testContinueAndBackFocusEachStepHeadingAndUpdateTheStepMarker() async {
        let fakes = OnboardingFakes()
        defer { fakes.tearDown() }
        var focused: [String] = []
        var finished = 0
        let hosted = HostedSwiftUI(fakes.view(finish: { finished += 1 }, focused: { focused.append($0) }), size: size)
        defer { hosted.close() }
        await hosted.settle()

        assertStep(1, heading: "Welcome to betterfinder", in: hosted)
        XCTAssertNil(hosted.heading("A native file manager that fixes what Finder gets wrong."))
        XCTAssertEqual(focused, [])
        await press("Get Started", in: hosted)
        assertStep(2, heading: "What betterfinder can replace", in: hosted)
        XCTAssertEqual(focused, ["What betterfinder can replace"])
        await press("Continue", in: hosted)
        assertStep(3, heading: "Make it your default", in: hosted)
        await press("Back", in: hosted)
        assertStep(2, heading: "What betterfinder can replace", in: hosted)
        XCTAssertNil(hosted.heading("Make it your default"))
        await press("Continue", in: hosted)
        await press("Skip", in: hosted)
        assertStep(4, heading: "Permissions", in: hosted)
        await press("Continue", in: hosted)
        assertStep(5, heading: "Pick a theme", in: hosted)
        await press("Continue", in: hosted)
        assertStep(6, heading: "You're set", in: hosted)
        XCTAssertEqual(focused, [
            "What betterfinder can replace", "Make it your default", "What betterfinder can replace",
            "Make it your default", "Permissions", "Pick a theme", "You're set",
        ])
        await press("Start Using betterfinder", in: hosted)
        XCTAssertEqual(finished, 1)
        XCTAssertTrue(fakes.systemDefaultsUntouched)
    }

    func testFooterDotsStayCenteredAndClearOfActionsOnEveryStep() async {
        let fakes = OnboardingFakes()
        defer { fakes.tearDown() }
        let expected: [(OnboardingStep, [String])] = [
            (.welcome, ["Get Started"]),
            (.coverage, ["Back", "Continue"]),
            (.makeDefault, ["Back", "Skip", "Continue"]),
            (.permissions, ["Back", "Skip", "Continue"]),
            (.done, ["Start Using betterfinder"]),
        ]
        var centers: [CGPoint] = []
        for (step, labels) in expected {
            let hosted = HostedSwiftUI(fakes.view(step: step), size: size)
            await hosted.settle(0.25)
            let bounds = hosted.root.frame
            XCTAssertEqual(bounds.width, 620, accuracy: 0.5)
            guard let dots = progress(hosted)?.frame else {
                XCTFail("no dots on \(step)")
                hosted.close()
                continue
            }
            XCTAssertEqual(dots.midX, bounds.midX, accuracy: 0.5, "\(step)")
            centers.append(CGPoint(x: dots.midX - bounds.minX, y: dots.midY - bounds.minY))
            let footer = hosted.nodes.filter { $0.role == "AXButton" && abs($0.frame.midY - dots.midY) < 30 }
            XCTAssertEqual(Set(footer.compactMap(\.label)), Set(labels), "\(step)")
            for button in footer {
                let gap = button.frame.midX < dots.midX ? dots.minX - button.frame.maxX : button.frame.minX - dots.maxX
                XCTAssertGreaterThanOrEqual(gap, Spacing.control, "\(step) \(button.label ?? "")")
                XCTAssertGreaterThanOrEqual(button.frame.minX, bounds.minX + Spacing.panelPadding - 0.5)
                XCTAssertLessThanOrEqual(button.frame.maxX, bounds.maxX - Spacing.panelPadding + 0.5)
            }
            hosted.close()
        }
        XCTAssertEqual(centers.count, expected.count)
        for c in centers {
            XCTAssertEqual(c.x, centers[0].x, accuracy: 0.5)
            XCTAssertEqual(c.y, centers[0].y, accuracy: 0.5)
        }
        XCTAssertTrue(fakes.systemDefaultsUntouched)
    }
}

final class LayoutModController: ModManagementControlling, @unchecked Sendable {
    let listing: ModListing
    init(listing: ModListing) { self.listing = listing }
    func listInstalled() async throws -> [InstalledMod] { [] }
    func fetchIndex() async throws -> ModIndexSnapshot { ModIndexSnapshot(listings: [listing]) }
    func preflight(id: String) async throws -> PreflightResultSummary { PreflightResultSummary(modID: id, version: "1", ok: true) }
    func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> InstalledMod { throw ModManagementError.installRefused("no") }
    func enable(id: String) async throws -> InstalledMod { throw ModManagementError.notFound(id) }
    func disable(id: String) async throws -> InstalledMod { throw ModManagementError.notFound(id) }
    func uninstall(id: String, deleteData: Bool) async throws {}
    func update(id: String, approvedPermissionIDs: Set<String>) async throws -> InstalledMod { throw ModManagementError.notFound(id) }
}

@MainActor
final class BehaviorRegressionModLayoutTests: XCTestCase {
    static let everyPermissionKind: [PermissionSummary] = [
        PermissionSummary(id: "fs.read", title: "Read files (root: project-sources-and-generated-assets, recursive)", reason: "Read files via gesture-scoped selection handles or a user-picked root.", risk: .medium),
        PermissionSummary(id: "fs.write", title: "Write files (destination: exported-reports-and-compressed-archives)", reason: "Write files into a user-chosen destination, root or selection.", risk: .medium),
        PermissionSummary(id: "net", title: "Network: https://api.really-long-subdomain.example-service.com, https://uploads.another-long-hostname.example.org", reason: "HTTP(S) to listed scheme/host/port/method endpoints; private networks denied unless allowed.", risk: .medium),
        PermissionSummary(id: "process.exec", title: "Run any program with your account's full access", reason: "Curated broker operations, or unrestricted full user-account execution (high trust).", risk: .high),
        PermissionSummary(id: "ui", title: "UI: sidebar, inspector, context-menu, toolbar, status-bar, columns, preview", reason: "Register UI contributions on the listed surfaces.", risk: .low),
        PermissionSummary(id: "ui.override", title: "Reorder, hide or replace host built-ins on sidebar, toolbar and context-menu", reason: "Reorder, hide or replace host built-ins on the listed surfaces.", risk: .high),
        PermissionSummary(id: "ui.selection", title: "Receive passive selection metadata at the full-path level", reason: "Receive passive selection metadata at the declared level.", risk: .low),
        PermissionSummary(id: "credentials", title: "Use Keychain credentials bound to uploads.another-long-hostname.example.org", reason: "Use Keychain credentials as opaque handles bound to listed destinations.", risk: .medium),
        PermissionSummary(id: "storage", title: "Mod-private key/value storage", reason: "Mod-private key/value storage.", risk: .low),
        PermissionSummary(id: "operations.observe", title: "Observe file operations: copy, move, trash, rename, duplicate, compress", reason: "Observe committed file operation outcomes.", risk: .medium),
        PermissionSummary(id: "operations.intercept", title: "Block file operations: trash, delete, move-to-trash-without-confirmation", reason: "Veto file operations before they start (allow or deny).", risk: .high),
    ]

    static let longCategories = ["developer tools and automation", "file management", "appearance and themes", "integrations-with-cloud-storage-providers", "productivity", "accessibility helpers"]

    static let longChecks: [PreflightCheck] = [
        PreflightCheck(name: "manifest-schema-validation", state: .pass),
        PreflightCheck(name: "typescript-type-checking-of-all-scripts", state: .fail),
        PreflightCheck(name: "permission-scope-consistency", state: .pass),
        PreflightCheck(name: "bundle-size-and-asset-limits", state: .skipped),
        PreflightCheck(name: "api-compatibility-range", state: .notRun),
    ]

    func idealSize(_ text: String, _ font: Font) -> NSSize {
        NSHostingView(rootView: Text(text).font(font).fixedSize()).fittingSize
    }

    func assertFullyShown(_ items: [(String, Font)], in hosted: HostedSwiftUI, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = hosted.root.frame
        for (text, font) in items {
            let matches = hosted.texts(text)
            XCTAssertFalse(matches.isEmpty, "missing \(text)", file: file, line: line)
            let ideal = idealSize(text, font)
            for node in matches {
                let f = node.frame
                XCTAssertGreaterThanOrEqual(f.minX, bounds.minX - 0.5, text, file: file, line: line)
                XCTAssertLessThanOrEqual(f.maxX, bounds.maxX + 0.5, text, file: file, line: line)
                XCTAssertGreaterThanOrEqual(f.width * f.height, ideal.width * ideal.height * 0.97, "truncated: \(text) \(f) ideal \(ideal)", file: file, line: line)
            }
        }
        for node in hosted.nodes.dropFirst() where node.frame != .zero {
            XCTAssertLessThanOrEqual(node.frame.maxX, bounds.maxX + 0.5, "\(node.role ?? "") \(node.valueText ?? node.label ?? "") overflows", file: file, line: line)
            XCTAssertGreaterThanOrEqual(node.frame.minX, bounds.minX - 0.5, "\(node.role ?? "") \(node.valueText ?? node.label ?? "") overflows", file: file, line: line)
        }
    }

    func permissionItems(_ permissions: [PermissionSummary]) -> [(String, Font)] {
        permissions.flatMap { p in [(p.title, Font.callout.weight(.semibold)), (p.reason, Font.caption), (p.risk.label, Font.caption2.weight(.semibold))] }
    }

    func assertNoOverlap(_ nodes: [AXNode], file: StaticString = #filePath, line: UInt = #line) {
        for (i, a) in nodes.enumerated() {
            for b in nodes.dropFirst(i + 1) {
                XCTAssertFalse(a.frame.intersects(b.frame), "\(a.valueText ?? "") overlaps \(b.valueText ?? "")", file: file, line: line)
            }
        }
    }

    func detail(categories: [String], permissions: [PermissionSummary]) async -> (HostedSwiftUI, ModsPaneModel) {
        let listing = ModListing(id: "ada@layout", title: "Layout", author: "Ada", version: "1.0.0", summary: "Layout fixture.", categories: categories, permissions: permissions)
        let model = ModsPaneModel(controller: LayoutModController(listing: listing))
        await model.reloadIndex()
        model.selectedListingID = listing.id
        let hosted = HostedSwiftUI(ModListingDetailView(model: model).frame(width: 380, height: 2200), size: NSSize(width: 380, height: 2200))
        await hosted.settle(0.3)
        return (hosted, model)
    }

    func verticalExtent(of texts: [String], in hosted: HostedSwiftUI) -> CGFloat {
        let frames = texts.flatMap { hosted.texts($0) }.map(\.frame)
        guard let top = frames.map(\.maxY).max(), let bottom = frames.map(\.minY).min() else { return 0 }
        return top - bottom
    }

    func testDetailAtMinimumWidthShowsEveryPermissionAndCategoryInFull() async {
        let (hosted, model) = await detail(categories: Self.longCategories, permissions: Self.everyPermissionKind)
        defer { hosted.close() }
        _ = model
        let categories = Self.longCategories.map(\.capitalized)
        assertFullyShown(permissionItems(Self.everyPermissionKind) + categories.map { ($0, Font.caption2.weight(.semibold)) }, in: hosted)
        let badges = categories.flatMap { hosted.texts($0) }
        XCTAssertEqual(badges.count, categories.count)
        assertNoOverlap(badges)
        XCTAssertGreaterThan(Set(badges.map { Int($0.frame.midY.rounded()) }).count, 1)
        assertNoOverlap(Self.everyPermissionKind.flatMap { hosted.texts($0.title) })

        let (short, shortModel) = await detail(categories: ["tools", "files"], permissions: Self.everyPermissionKind.map { PermissionSummary(id: $0.id, title: String($0.id.prefix(8)), reason: "Short.", risk: $0.risk) })
        defer { short.close() }
        _ = shortModel
        let longCategoryExtent = verticalExtent(of: categories, in: hosted)
        let shortCategoryExtent = verticalExtent(of: ["Tools", "Files"], in: short)
        XCTAssertGreaterThan(longCategoryExtent, shortCategoryExtent + 10)
        let longPermissionExtent = verticalExtent(of: Self.everyPermissionKind.flatMap { [$0.title, $0.reason] }, in: hosted)
        let shortPermissionExtent = verticalExtent(of: Self.everyPermissionKind.map { String($0.id.prefix(8)) } + ["Short."], in: short)
        XCTAssertGreaterThan(longPermissionExtent, shortPermissionExtent + 40)
    }

    func testInstalledRowListsEveryPermissionInFull() async {
        let mod = InstalledMod(id: "ada@layout", title: "Layout", author: "Ada", version: "1.0.0", permissions: Self.everyPermissionKind)
        let model = ModsPaneModel(controller: LayoutModController(listing: ModListing(id: "x@y", title: "X", author: "Y", version: "1")))
        let width: CGFloat = 400
        let hosted = HostedSwiftUI(InstalledModRow(model: model, mod: mod, uninstallTarget: .constant(nil)).frame(width: width), size: NSSize(width: width, height: 1600))
        defer { hosted.close() }
        await hosted.settle(0.3)
        XCTAssertNotNil(hosted.heading("Permissions") ?? hosted.texts("Permissions").first)
        assertFullyShown(permissionItems(Self.everyPermissionKind), in: hosted)
        assertNoOverlap(Self.everyPermissionKind.flatMap { hosted.texts($0.title) })
    }

    func testPreflightCheckBadgesWrapInsteadOfTruncating() async {
        let result = PreflightResultSummary(modID: "ada@layout", version: "1.0.0", ok: false, checks: Self.longChecks,
                                            diagnostics: [PreflightDiagnostic(severity: .error, code: "BF2001", message: "TS2322: Type 'string' is not assignable to type 'number' in scripts/main.ts", file: "scripts/main.ts", pointer: "12:7", fix: "Convert the value with Number() before returning it")])
        let width: CGFloat = 340
        let hosted = HostedSwiftUI(DiagnosticsList(result: result).frame(width: width), size: NSSize(width: width, height: 900))
        defer { hosted.close() }
        await hosted.settle(0.3)
        let labels = Self.longChecks.map { "\($0.name): \($0.state.rawValue)" }
        assertFullyShown(labels.map { ($0, Font.caption2.weight(.semibold)) }, in: hosted)
        let badges = labels.flatMap { hosted.texts($0) }
        XCTAssertEqual(badges.count, labels.count)
        assertNoOverlap(badges)
        XCTAssertGreaterThan(Set(badges.map { Int($0.frame.midY.rounded()) }).count, 1)
    }
}
