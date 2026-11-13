import FSCore
import Foundation

public enum SettingsKey {
    public static let openFoldersInTabs = "openFoldersInTabs"
    public static let terminalAppPath = "terminalAppPath"
    public static let terminalBundleID = "terminalBundleID"
    public static let homeFolderNameStyle = HomeNameDisplay.styleKey
    public static let homeFolderNameCustom = HomeNameDisplay.customKey
    public static let newWindowLocation = "newWindowLocation"
    public static let newWindowCustomPath = "newWindowCustomPath"
    public static let openAtLogin = "openAtLogin"
    public static let foldersFirst = "foldersFirst"
    public static let showHiddenFiles = "showHiddenFiles"
    public static let calculateFolderSizes = "calculateFolderSizes"
    public static let calculateFolderSizesOnNetwork = "calculateFolderSizesOnNetwork"
    public static let showAllocatedSize = "showAllocatedSize"
    public static let returnOpens = "returnOpens"
    public static let verifyCopies = "verifyCopies"
    public static let trashViaFinder = "trashViaFinder"
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"
    public static let coloredLabels = "coloredLabels"
    public static let columnAutoWidth = "columnAutoWidth"
    public static let colorSidebarIcons = "colorSidebarIcons"
    public static let dualPaneSidebars = "dualPaneSidebars"
    public static let visorDoubleTapOption = "visorDoubleTapOption"
    public static let visorAllSpaces = "visorAllSpaces"
    public static let visorAboveDock = "visorAboveDock"
    public static let visorTerminal = "visorTerminalOpenInTerminal"
    public static let visorOpensWindows = "visorOpensNewWindows"
    public static let visorTerminalShell = "visorTerminalShell"
}

public enum NewWindowLocation: String, CaseIterable, Identifiable, Sendable {
    case home
    case desktop
    case documents
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .custom: return "Custom folder…"
        }
    }

    public static func resolve(defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let choice = NewWindowLocation(rawValue: defaults.string(forKey: SettingsKey.newWindowLocation) ?? "") ?? .home
        switch choice {
        case .home: return home
        case .desktop: return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents: return home.appendingPathComponent("Documents", isDirectory: true)
        case .custom:
            if let path = defaults.string(forKey: SettingsKey.newWindowCustomPath), !path.isEmpty {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return home
        }
    }
}

public struct TerminalChoice: Identifiable, Hashable, Sendable {
    public var name: String
    public var bundleID: String
    public var path: String

    public var id: String { path }

    public static let systemBundleID = "com.apple.Terminal"
    public static let systemPath = "/System/Applications/Utilities/Terminal.app"

    public static let known: [(name: String, bundleID: String)] = [
        ("iTerm", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("Hyper", "co.zeit.hyper"),
    ]

    public static func installed(lookup: (String) -> URL?) -> [TerminalChoice] {
        known.compactMap { entry in
            lookup(entry.bundleID).map { TerminalChoice(name: entry.name, bundleID: entry.bundleID, path: $0.path) }
        }
    }

    public static func displayName(path: String, fileManager: FileManager = .default) -> String {
        guard !path.isEmpty, fileManager.fileExists(atPath: path) else { return "Terminal" }
        let name = fileManager.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    public static func store(path: String, bundleID: String?, in defaults: UserDefaults = .standard) {
        if path.isEmpty || path == systemPath || bundleID == systemBundleID {
            defaults.set("", forKey: SettingsKey.terminalAppPath)
            defaults.removeObject(forKey: SettingsKey.terminalBundleID)
        } else {
            defaults.set(path, forKey: SettingsKey.terminalAppPath)
            if let bundleID, !bundleID.isEmpty { defaults.set(bundleID, forKey: SettingsKey.terminalBundleID) } else { defaults.removeObject(forKey: SettingsKey.terminalBundleID) }
        }
    }
}

public enum SettingsDefaults {
    public static let registered: [String: Any] = [
        SettingsKey.newWindowLocation: NewWindowLocation.home.rawValue,
        SettingsKey.newWindowCustomPath: "",
        SettingsKey.calculateFolderSizes: true,
        SettingsKey.calculateFolderSizesOnNetwork: false,
        SettingsKey.showAllocatedSize: true,
        SettingsKey.foldersFirst: false,
        SettingsKey.showHiddenFiles: false,
        SettingsKey.returnOpens: false,
        SettingsKey.verifyCopies: false,
        SettingsKey.trashViaFinder: false,
        SettingsKey.hasCompletedOnboarding: false,
        SettingsKey.openFoldersInTabs: false,
        SettingsKey.terminalAppPath: "",
        SettingsKey.homeFolderNameStyle: HomeNameStyle.real.rawValue,
        SettingsKey.homeFolderNameCustom: "",
        SettingsKey.coloredLabels: false,
        SettingsKey.columnAutoWidth: true,
        SettingsKey.colorSidebarIcons: false,
        SettingsKey.dualPaneSidebars: false,
        SettingsKey.visorDoubleTapOption: false,
        SettingsKey.visorAllSpaces: true,
        SettingsKey.visorAboveDock: false,
        SettingsKey.visorTerminal: false,
        SettingsKey.visorOpensWindows: false,
    ]

    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: registered)
    }
}

public enum SizeIndexAvailability: Equatable, Sendable {
    case available
    case requiresApproval
    case unreachable(String)

    public var isAvailable: Bool { self == .available }

    public var explanation: String? {
        switch self {
        case .available: return nil
        case .requiresApproval: return "The background file indexer needs approval in System Settings → General → Login Items."
        case .unreachable(let reason): return reason
        }
    }
}

@MainActor
public protocol SizeIndexControlling: AnyObject {
    var isIndexingPaused: Bool { get }
    func setIndexingPaused(_ paused: Bool)
    func rebuildIndex()
    var availability: SizeIndexAvailability { get }
    var indexStatus: SizeIndexStatus? { get }
    func refreshAvailability() async -> SizeIndexAvailability
    func requestPause(_ paused: Bool) async -> Bool
    func requestRebuild() async -> Bool
}

public extension SizeIndexControlling {
    var availability: SizeIndexAvailability { .available }
    var indexStatus: SizeIndexStatus? { nil }
    func refreshAvailability() async -> SizeIndexAvailability { availability }
    func requestPause(_ paused: Bool) async -> Bool {
        setIndexingPaused(paused)
        return isIndexingPaused == paused
    }
    func requestRebuild() async -> Bool {
        rebuildIndex()
        return true
    }
}

@MainActor
final class SizeIndexSettingsModel: ObservableObject {
    enum RebuildStatus: Equatable {
        case idle, requesting, started, failed(String)
    }

    @Published private(set) var availability: SizeIndexAvailability
    @Published private(set) var paused: Bool
    @Published private(set) var isChangingPause = false
    @Published private(set) var pauseError: String?
    @Published private(set) var rebuild: RebuildStatus = .idle
    @Published private(set) var status: SizeIndexStatus?

    let controller: SizeIndexControlling

    init(controller: SizeIndexControlling) {
        self.controller = controller
        availability = controller.availability
        paused = controller.isIndexingPaused
    }

    var controlsEnabled: Bool { availability.isAvailable }

    func refresh() async {
        let latest = await controller.refreshAvailability()
        if availability != latest { availability = latest }
        if paused != controller.isIndexingPaused { paused = controller.isIndexingPaused }
        let reported = latest.isAvailable ? controller.indexStatus : nil
        if status != reported { status = reported }
    }

    var statusSummary: String? {
        guard let status else { return nil }
        let total = status.folders.formatted()
        let waiting = status.pendingFolders.formatted()
        if status.isPaused { return status.pendingFolders > 0 ? "Paused · \(waiting) folders waiting" : "Paused · \(total) folders indexed" }
        return status.pendingFolders > 0 ? "Indexing · \(waiting) folders to go · \(total) found" : "Up to date · \(total) folders indexed"
    }

    func setPaused(_ value: Bool) async {
        guard controlsEnabled, !isChangingPause else { return }
        isChangingPause = true
        pauseError = nil
        let ok = await controller.requestPause(value)
        isChangingPause = false
        paused = controller.isIndexingPaused
        if !ok {
            pauseError = value ? "Couldn’t pause the file indexer. It may not be running." : "Couldn’t resume the file indexer. It may not be running."
            availability = await controller.refreshAvailability()
        }
    }

    func requestRebuild() async {
        guard controlsEnabled, rebuild != .requesting else { return }
        rebuild = .requesting
        if await controller.requestRebuild() {
            rebuild = .started
        } else {
            rebuild = .failed("The file indexer didn’t respond, so the rebuild didn’t start.")
            availability = await controller.refreshAvailability()
        }
    }
}

@MainActor
public final class NoOpSizeIndexController: SizeIndexControlling {
    public private(set) var isIndexingPaused = false

    public init() {}

    public func setIndexingPaused(_ paused: Bool) { isIndexingPaused = paused }
    public func rebuildIndex() {}
}

public enum SettingsCopy {
    public static let visorHelp = "A betterfinder window docked to the bottom of the screen. It slides away when you switch apps unless you pin it. Window > Show Visor works without the hotkey."
    public static let windowsKeysHelp = "Return opens, F2 renames, Backspace goes up, F5 refreshes and Delete moves to the Trash. Copy to Other Pane moves to ⇧F5. Mac shortcuts keep working."
}
