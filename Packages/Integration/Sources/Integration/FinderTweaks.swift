import Foundation

public final class FinderTweaks {
    public enum Tweak: String, CaseIterable, Identifiable, Sendable {
        case hideDesktopIcons
        case quitMenuItem

        public var id: String { rawValue }
        public var preferenceKey: String {
            switch self {
            case .hideDesktopIcons: return "CreateDesktop"
            case .quitMenuItem: return "QuitMenuItem"
            }
        }
        public var appliedValue: Bool {
            switch self {
            case .hideDesktopIcons: return false
            case .quitMenuItem: return true
            }
        }
        public var title: String {
            switch self {
            case .hideDesktopIcons: return "Hide Finder's desktop icons"
            case .quitMenuItem: return "Add Quit to Finder's menu"
            }
        }
        public var warning: String {
            switch self {
            case .hideDesktopIcons: return "Finder restarts to apply this. The desktop shows no icons or files, and desktop drag-and-drop stops working."
            case .quitMenuItem: return "Finder restarts to apply this. If you quit Finder, the desktop disappears until it relaunches, which happens at login and whenever an app targets it."
            }
        }
    }

    public static let finderBundleID = "com.apple.finder"

    public let preferences: PreferencesWriter
    public let runner: SystemCommandRunner
    let store: PreviousValueStore

    public init(
        preferences: PreferencesWriter = SystemPreferencesWriter(),
        runner: SystemCommandRunner = WorkspaceCommandRunner(),
        defaults: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.runner = runner
        self.store = PreviousValueStore(defaults: defaults, prefix: "Integration.finderTweak")
    }

    private var domain: PreferencesDomain { .app(Self.finderBundleID) }

    public func isEnabled(_ tweak: Tweak) -> Bool {
        boolValue(preferences.value(forKey: tweak.preferenceKey, in: domain)) == tweak.appliedValue
    }

    public func hasRecordedPrevious(_ tweak: Tweak) -> Bool {
        store.get(tweak.rawValue) != nil
    }

    public func enable(_ tweak: Tweak, relaunchFinder: Bool = false) async throws {
        if !isEnabled(tweak) {
            store.record(tweak.rawValue, value: preferences.value(forKey: tweak.preferenceKey, in: domain))
        }
        preferences.setValue(tweak.appliedValue, forKey: tweak.preferenceKey, in: domain)
        if relaunchFinder { try await self.relaunchFinder() }
    }

    public func revert(_ tweak: Tweak, relaunchFinder: Bool = false) async throws {
        if let record = store.get(tweak.rawValue) {
            preferences.setValue(record.present ? record.value : nil, forKey: tweak.preferenceKey, in: domain)
            store.clear(tweak.rawValue)
        } else if isEnabled(tweak) {
            preferences.setValue(nil, forKey: tweak.preferenceKey, in: domain)
        }
        if relaunchFinder { try await self.relaunchFinder() }
    }

    public func revertAll(relaunchFinder: Bool = false) async throws {
        for t in Tweak.allCases { try await revert(t) }
        if relaunchFinder { try await self.relaunchFinder() }
    }

    public func relaunchFinder() async throws {
        try await runner.relaunchApplication(bundleID: Self.finderBundleID)
    }
}
