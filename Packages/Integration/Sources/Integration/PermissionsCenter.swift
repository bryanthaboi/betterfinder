import AppKit
import ApplicationServices
import Foundation

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case desktop
    case documents
    case downloads
    case removableVolumes
    case networkVolumes
    case fullDiskAccess
    case automationFinder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: return "Desktop folder"
        case .documents: return "Documents folder"
        case .downloads: return "Downloads folder"
        case .removableVolumes: return "Removable volumes"
        case .networkVolumes: return "Network volumes"
        case .fullDiskAccess: return "Full Disk Access"
        case .automationFinder: return "Automation (Finder)"
        }
    }

    public var explanation: String {
        switch self {
        case .desktop, .documents, .downloads:
            return "Needed to list the contents of this folder."
        case .removableVolumes:
            return "Needed to browse USB drives and other removable disks."
        case .networkVolumes:
            return "Needed to browse SMB, AFP and other network shares."
        case .fullDiskAccess:
            return "Lets betterfinder browse everything, including Mail, Safari and system-protected folders. It can't be requested in code; enable it in System Settings."
        case .automationFinder:
            return "Needed only to trash through Finder (real Put Back) and a few Finder-integrated actions."
        }
    }

    public var settingsPane: SettingsPane {
        switch self {
        case .fullDiskAccess: return .fullDiskAccess
        case .automationFinder: return .automation
        default: return .filesAndFolders
        }
    }

    public var canBePromptedInApp: Bool {
        switch self {
        case .fullDiskAccess: return false
        default: return true
        }
    }
}

public enum SettingsPane: String, Sendable {
    case fullDiskAccess = "Privacy_AllFiles"
    case filesAndFolders = "Privacy_FilesAndFolders"
    case automation = "Privacy_Automation"

    public var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

public enum PermissionState: String, Sendable {
    case granted
    case denied
    case notDetermined
    case notApplicable
    case unknown
}

public struct PermissionStatus: Identifiable, Equatable, Sendable {
    public var kind: PermissionKind
    public var state: PermissionState
    public var detail: String?
    public var id: String { kind.rawValue }

    public init(kind: PermissionKind, state: PermissionState, detail: String? = nil) {
        self.kind = kind
        self.state = state
        self.detail = detail
    }
}

public enum DirectoryProbeResult: Sendable {
    case readable
    case denied
    case missing
}

public protocol DirectoryProbing {
    func probe(_ url: URL) -> DirectoryProbeResult
}

public struct FileManagerDirectoryProbe: DirectoryProbing {
    public init() {}

    public func probe(_ url: URL) -> DirectoryProbeResult {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .readable
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain {
                if ns.code == NSFileReadNoPermissionError { return .denied }
                if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return .missing }
            }
            if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
                if posix.code == Int(EPERM) || posix.code == Int(EACCES) { return .denied }
                if posix.code == Int(ENOENT) { return .missing }
            }
            if ns.domain == NSPOSIXErrorDomain {
                if ns.code == Int(EPERM) || ns.code == Int(EACCES) { return .denied }
                if ns.code == Int(ENOENT) { return .missing }
            }
            return .denied
        }
    }
}

public struct VolumeDescriptor: Sendable, Equatable {
    public var url: URL
    public var isRemovable: Bool
    public var isNetwork: Bool

    public init(url: URL, isRemovable: Bool, isNetwork: Bool) {
        self.url = url
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork
    }
}

public protocol VolumeProviding {
    func mountedVolumes() -> [VolumeDescriptor]
}

public struct WorkspaceVolumeProvider: VolumeProviding {
    public init() {}

    public func mountedVolumes() -> [VolumeDescriptor] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path != "/" else { return nil }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isLocal = v?.volumeIsLocal ?? true
            let removable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false) || (v?.volumeIsInternal == false)
            return VolumeDescriptor(url: url, isRemovable: isLocal && removable, isNetwork: !isLocal)
        }
    }
}

public protocol AutomationChecking {
    func finderStatus(askUserIfNeeded: Bool) -> OSStatus
}

public struct AppleEventAutomationChecker: AutomationChecking {
    public init() {}

    public func finderStatus(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: FinderTweaks.finderBundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
    }
}

public struct PermissionsCenter {
    public let home: URL
    public let prober: DirectoryProbing
    public let volumes: VolumeProviding
    public let automation: AutomationChecking

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        prober: DirectoryProbing = FileManagerDirectoryProbe(),
        volumes: VolumeProviding = WorkspaceVolumeProvider(),
        automation: AutomationChecking = AppleEventAutomationChecker()
    ) {
        self.home = home
        self.prober = prober
        self.volumes = volumes
        self.automation = automation
    }

    public static let shared = PermissionsCenter()

    public func allStatuses() -> [PermissionStatus] {
        PermissionKind.allCases.map(status(for:))
    }

    public func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .desktop: return folderStatus(kind, "Desktop")
        case .documents: return folderStatus(kind, "Documents")
        case .downloads: return folderStatus(kind, "Downloads")
        case .removableVolumes: return volumeStatus(kind, matching: { $0.isRemovable })
        case .networkVolumes: return volumeStatus(kind, matching: { $0.isNetwork })
        case .fullDiskAccess: return fullDiskStatus()
        case .automationFinder: return automationStatus(askUserIfNeeded: false)
        }
    }

    public func requestAutomation() -> PermissionStatus {
        automationStatus(askUserIfNeeded: true)
    }

    public func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsPane.url)
    }

    public static func settingsURL(for kind: PermissionKind) -> URL { kind.settingsPane.url }

    private func folderStatus(_ kind: PermissionKind, _ name: String) -> PermissionStatus {
        let url = home.appendingPathComponent(name, isDirectory: true)
        switch prober.probe(url) {
        case .readable: return PermissionStatus(kind: kind, state: .granted)
        case .denied: return PermissionStatus(kind: kind, state: .denied, detail: "Access to \(name) was denied")
        case .missing: return PermissionStatus(kind: kind, state: .unknown, detail: "\(name) doesn't exist")
        }
    }

    private func volumeStatus(_ kind: PermissionKind, matching: (VolumeDescriptor) -> Bool) -> PermissionStatus {
        let matches = volumes.mountedVolumes().filter(matching)
        guard !matches.isEmpty else {
            return PermissionStatus(kind: kind, state: .notApplicable, detail: "None mounted right now")
        }
        let results = matches.map { prober.probe($0.url) }
        if results.contains(.denied) {
            return PermissionStatus(kind: kind, state: .denied, detail: "Access was denied on at least one volume")
        }
        if results.contains(.readable) { return PermissionStatus(kind: kind, state: .granted) }
        return PermissionStatus(kind: kind, state: .unknown)
    }

    private func fullDiskStatus() -> PermissionStatus {
        let probes = ["Library/Safari", "Library/Mail"].map { prober.probe(home.appendingPathComponent($0, isDirectory: true)) }
        if probes.contains(.readable) { return PermissionStatus(kind: .fullDiskAccess, state: .granted) }
        if probes.contains(.denied) {
            return PermissionStatus(kind: .fullDiskAccess, state: .denied, detail: "Protected folders can't be read")
        }
        return PermissionStatus(kind: .fullDiskAccess, state: .unknown, detail: "No protected folder available to test")
    }

    private func automationStatus(askUserIfNeeded: Bool) -> PermissionStatus {
        let code = automation.finderStatus(askUserIfNeeded: askUserIfNeeded)
        switch code {
        case noErr: return PermissionStatus(kind: .automationFinder, state: .granted)
        case OSStatus(errAEEventNotPermitted): return PermissionStatus(kind: .automationFinder, state: .denied)
        case OSStatus(errAEEventWouldRequireUserConsent): return PermissionStatus(kind: .automationFinder, state: .notDetermined)
        case OSStatus(procNotFound): return PermissionStatus(kind: .automationFinder, state: .unknown, detail: "Finder isn't running")
        default: return PermissionStatus(kind: .automationFinder, state: .unknown, detail: "Error \(code)")
        }
    }
}

public enum FullDiskAccess {
    public static var isGranted: Bool {
        PermissionsCenter.shared.status(for: .fullDiskAccess).state == .granted
    }

    public static func openSettings() {
        NSWorkspace.shared.open(SettingsPane.fullDiskAccess.url)
    }
}
