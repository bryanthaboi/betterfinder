import UniformTypeIdentifiers
import XCTest
@testable import Integration

final class FakeHandlers: FolderHandlerService {
    var handlers: [String: String] = [:]
    var failing: Set<String> = []
    var setCalls: [(String, String)] = []

    func handlerBundleID(for type: UTType) -> String? { handlers[type.identifier] }

    func setHandler(bundleID: String, appURL: URL?, for type: UTType) async throws {
        if failing.contains(type.identifier) { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "declined"]) }
        setCalls.append((type.identifier, bundleID))
        handlers[type.identifier] = bundleID
    }
}

final class FakeRunner: SystemCommandRunner {
    var relaunched: [String] = []
    func relaunchApplication(bundleID: String) async throws { relaunched.append(bundleID) }
}

final class FakeProbe: DirectoryProbing {
    var results: [String: DirectoryProbeResult] = [:]
    func probe(_ url: URL) -> DirectoryProbeResult { results[url.lastPathComponent] ?? .readable }
}

struct FakeVolumes: VolumeProviding {
    var list: [VolumeDescriptor] = []
    func mountedVolumes() -> [VolumeDescriptor] { list }
}

struct FakeAutomation: AutomationChecking {
    var code: OSStatus
    func finderStatus(askUserIfNeeded: Bool) -> OSStatus { code }
}

final class IntegrationTests: XCTestCase {
    let ours = "com.test.betterfinder"

    func freshDefaults() -> UserDefaults {
        let name = "IntegrationTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func makeController(prefs: InMemoryPreferencesWriter, handlers: FakeHandlers, defaults: UserDefaults) -> DefaultFileManagerController {
        DefaultFileManagerController(bundleID: ours, appURL: URL(fileURLWithPath: "/Applications/BetterFinder.app"), preferences: prefs, handlers: handlers, defaults: defaults)
    }

    func testClassifyFolder() {
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertEqual(IncomingOpenRequest.classify(tmp), .openFolder(tmp))
    }

    func testClassifyFileAndPackage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let pkg = dir.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        XCTAssertEqual(IncomingOpenRequest.classify(file), .reveal(file))
        XCTAssertEqual(IncomingOpenRequest.classify(pkg), .reveal(pkg))
        XCTAssertEqual(IncomingOpenRequest.classify(dir), .openFolder(dir))
    }

    func testStatusReflectsState() {
        let prefs = InMemoryPreferencesWriter()
        let handlers = FakeHandlers()
        let c = makeController(prefs: prefs, handlers: handlers, defaults: freshDefaults())
        XCTAssertFalse(c.status().isFullyDefault)
        prefs.setValue(ours, forKey: "NSFileViewer", in: .global)
        XCTAssertTrue(c.status().isFileViewer)
        XCTAssertFalse(c.status().isFolderHandler)
        handlers.handlers[UTType.folder.identifier] = ours
        XCTAssertTrue(c.status().isFullyDefault)
    }

    func testMakeDefaultThenRestoreRoundTripWithPreviousValues() async throws {
        let prefs = InMemoryPreferencesWriter(storage: [.global: ["NSFileViewer": "com.other.viewer"]])
        let handlers = FakeHandlers()
        handlers.handlers[UTType.folder.identifier] = "com.other.manager"
        handlers.handlers[UTType.directory.identifier] = "com.other.dir"
        let c = makeController(prefs: prefs, handlers: handlers, defaults: freshDefaults())

        try await c.makeDefault()
        XCTAssertEqual(prefs.value(forKey: "NSFileViewer", in: .global) as? String, ours)
        XCTAssertEqual(handlers.handlers[UTType.folder.identifier], ours)
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], ours)
        XCTAssertTrue(c.status().isFullyDefault)
        XCTAssertTrue(c.status().hasRestorePoint)

        try await c.restoreFinder()
        XCTAssertEqual(prefs.value(forKey: "NSFileViewer", in: .global) as? String, "com.other.viewer")
        XCTAssertEqual(handlers.handlers[UTType.folder.identifier], "com.other.manager")
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], "com.other.dir")
        XCTAssertFalse(c.status().hasRestorePoint)
    }

    func testRestoreDeletesViewerWhenPreviouslyUnsetAndFallsBackToFinder() async throws {
        let prefs = InMemoryPreferencesWriter()
        let handlers = FakeHandlers()
        let c = makeController(prefs: prefs, handlers: handlers, defaults: freshDefaults())
        try await c.makeDefault()
        try await c.restoreFinder()
        XCTAssertNil(prefs.value(forKey: "NSFileViewer", in: .global))
        XCTAssertEqual(handlers.handlers[UTType.folder.identifier], "com.apple.finder")
    }

    func testMakeDefaultTwiceKeepsOriginalPrevious() async throws {
        let prefs = InMemoryPreferencesWriter(storage: [.global: ["NSFileViewer": "com.other.viewer"]])
        let handlers = FakeHandlers()
        handlers.handlers[UTType.folder.identifier] = "com.other.manager"
        let c = makeController(prefs: prefs, handlers: handlers, defaults: freshDefaults())
        try await c.makeDefault()
        try await c.makeDefault()
        try await c.restoreFinder()
        XCTAssertEqual(prefs.value(forKey: "NSFileViewer", in: .global) as? String, "com.other.viewer")
        XCTAssertEqual(handlers.handlers[UTType.folder.identifier], "com.other.manager")
    }

    func testRequiredHandlerFailureLeavesSystemUntouched() async {
        let prefs = InMemoryPreferencesWriter(storage: [.global: ["NSFileViewer": "com.other.viewer"]])
        let handlers = FakeHandlers()
        handlers.failing = [UTType.folder.identifier]
        let defaults = freshDefaults()
        let c = makeController(prefs: prefs, handlers: handlers, defaults: defaults)
        do {
            try await c.makeDefault()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("declined"))
        }
        XCTAssertEqual(prefs.value(forKey: "NSFileViewer", in: .global) as? String, "com.other.viewer")
        XCTAssertFalse(c.status().hasRestorePoint)
    }

    func testBestEffortFailureProducesWarningOnly() async throws {
        let prefs = InMemoryPreferencesWriter()
        let handlers = FakeHandlers()
        handlers.failing = [UTType.directory.identifier]
        let c = makeController(prefs: prefs, handlers: handlers, defaults: freshDefaults())
        let report = try await c.makeDefault()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(c.status().isFullyDefault)
    }

    func testFinderTweakRevertRestoresExactPreviousValues() async throws {
        let prefs = InMemoryPreferencesWriter(storage: [.app("com.apple.finder"): ["CreateDesktop": true]])
        let runner = FakeRunner()
        let tweaks = FinderTweaks(preferences: prefs, runner: runner, defaults: freshDefaults())
        let finder = PreferencesDomain.app("com.apple.finder")

        XCTAssertFalse(tweaks.isEnabled(.hideDesktopIcons))
        XCTAssertFalse(tweaks.isEnabled(.quitMenuItem))

        try await tweaks.enable(.hideDesktopIcons, relaunchFinder: true)
        try await tweaks.enable(.quitMenuItem)
        XCTAssertEqual(prefs.value(forKey: "CreateDesktop", in: finder) as? Bool, false)
        XCTAssertEqual(prefs.value(forKey: "QuitMenuItem", in: finder) as? Bool, true)
        XCTAssertTrue(tweaks.isEnabled(.hideDesktopIcons))
        XCTAssertEqual(runner.relaunched, ["com.apple.finder"])

        try await tweaks.enable(.hideDesktopIcons)
        try await tweaks.revert(.hideDesktopIcons, relaunchFinder: true)
        try await tweaks.revert(.quitMenuItem)
        XCTAssertEqual(prefs.value(forKey: "CreateDesktop", in: finder) as? Bool, true)
        XCTAssertNil(prefs.value(forKey: "QuitMenuItem", in: finder))
        XCTAssertFalse(tweaks.isEnabled(.hideDesktopIcons))
        XCTAssertEqual(runner.relaunched.count, 2)
    }

    func testRevertAllWithoutRecordRemovesAppliedValue() async throws {
        let prefs = InMemoryPreferencesWriter(storage: [.app("com.apple.finder"): ["QuitMenuItem": true]])
        let tweaks = FinderTweaks(preferences: prefs, runner: FakeRunner(), defaults: freshDefaults())
        try await tweaks.revertAll()
        XCTAssertNil(prefs.value(forKey: "QuitMenuItem", in: .app("com.apple.finder")))
    }

    func testCompatibilityMatrix() {
        let m = RevealCompatibility.matrix
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(Set(m.map(\.id)).count, m.count)
        XCTAssertTrue(m.contains { $0.coverage == .redirected })
        XCTAssertTrue(m.contains { $0.coverage == .notRedirected })
        XCTAssertTrue(m.contains { $0.coverage == .unverified })
    }

    func testPermissionsFolderAndFullDiskStates() {
        let probe = FakeProbe()
        probe.results["Desktop"] = .denied
        probe.results["Safari"] = .denied
        probe.results["Mail"] = .missing
        let center = PermissionsCenter(home: URL(fileURLWithPath: "/Users/test"), prober: probe, volumes: FakeVolumes(), automation: FakeAutomation(code: noErr))
        XCTAssertEqual(center.status(for: .desktop).state, .denied)
        XCTAssertEqual(center.status(for: .documents).state, .granted)
        XCTAssertEqual(center.status(for: .fullDiskAccess).state, .denied)
        XCTAssertEqual(center.status(for: .removableVolumes).state, .notApplicable)
        probe.results["Safari"] = .readable
        XCTAssertEqual(center.status(for: .fullDiskAccess).state, .granted)
    }

    func testPermissionsVolumesAndAutomation() {
        let probe = FakeProbe()
        probe.results["NAS"] = .denied
        let vols = FakeVolumes(list: [
            VolumeDescriptor(url: URL(fileURLWithPath: "/Volumes/USB"), isRemovable: true, isNetwork: false),
            VolumeDescriptor(url: URL(fileURLWithPath: "/Volumes/NAS"), isRemovable: false, isNetwork: true),
        ])
        let center = PermissionsCenter(home: URL(fileURLWithPath: "/Users/test"), prober: probe, volumes: vols, automation: FakeAutomation(code: OSStatus(errAEEventWouldRequireUserConsent)))
        XCTAssertEqual(center.status(for: .removableVolumes).state, .granted)
        XCTAssertEqual(center.status(for: .networkVolumes).state, .denied)
        XCTAssertEqual(center.status(for: .automationFinder).state, .notDetermined)
        XCTAssertEqual(center.allStatuses().count, PermissionKind.allCases.count)
    }

    func testSettingsDeepLinks() {
        for kind in PermissionKind.allCases {
            XCTAssertTrue(PermissionsCenter.settingsURL(for: kind).absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"))
        }
        XCTAssertTrue(PermissionsCenter.settingsURL(for: .fullDiskAccess).absoluteString.hasSuffix("Privacy_AllFiles"))
    }

    func testHotKeyComboDisplayAndCodable() throws {
        XCTAssertEqual(HotKeyCombo.default.displayString, "⌃⌥⌘N")
        let data = try JSONEncoder().encode(HotKeyCombo.default)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyCombo.self, from: data), .default)
    }
}
