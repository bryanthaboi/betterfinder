import Foundation

public enum SettingsKey {
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
    ]

    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: registered)
    }
}

public enum SizeIndexAvailability: Equatable, Sendable {
    case available
    case notInstalled(String)
    case requiresApproval
    case unreachable(String)

    public var isAvailable: Bool { self == .available }

    public var explanation: String? {
        switch self {
        case .available: return nil
        case .notInstalled(let reason): return reason
        case .requiresApproval: return "The background size indexer needs approval in System Settings → General → Login Items."
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
    func refreshAvailability() async -> SizeIndexAvailability
    func requestPause(_ paused: Bool) async -> Bool
    func requestRebuild() async -> Bool
}

public extension SizeIndexControlling {
    var availability: SizeIndexAvailability { .available }
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

    let controller: SizeIndexControlling

    init(controller: SizeIndexControlling) {
        self.controller = controller
        availability = controller.availability
        paused = controller.isIndexingPaused
    }

    var controlsEnabled: Bool { availability.isAvailable }

    func refresh() async {
        availability = await controller.refreshAvailability()
        paused = controller.isIndexingPaused
    }

    func setPaused(_ value: Bool) async {
        guard controlsEnabled, !isChangingPause else { return }
        isChangingPause = true
        pauseError = nil
        let ok = await controller.requestPause(value)
        isChangingPause = false
        paused = controller.isIndexingPaused
        if !ok {
            pauseError = value ? "Couldn’t pause the size indexer. It may not be running." : "Couldn’t resume the size indexer. It may not be running."
            availability = await controller.refreshAvailability()
        }
    }

    func requestRebuild() async {
        guard controlsEnabled, rebuild != .requesting else { return }
        rebuild = .requesting
        if await controller.requestRebuild() {
            rebuild = .started
        } else {
            rebuild = .failed("The size indexer didn’t respond, so the rebuild didn’t start.")
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
    public static let windowsKeysHelp = "Return opens, F2 renames, Backspace goes up, F5 refreshes and Delete moves to the Trash. Copy to Other Pane moves to ⇧F5. Mac shortcuts keep working."
}
