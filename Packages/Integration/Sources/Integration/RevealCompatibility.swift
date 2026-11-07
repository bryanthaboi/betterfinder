import Foundation

public struct RevealEntryPoint: Identifiable, Hashable, Sendable {
    public enum Coverage: String, Sendable {
        case redirected
        case notRedirected
        case unverified

        public var symbol: String {
            switch self {
            case .redirected: return "✓"
            case .notRedirected: return "✗"
            case .unverified: return "?"
            }
        }

        public var label: String {
            switch self {
            case .redirected: return "Opens in betterfinder"
            case .notRedirected: return "Still uses Finder"
            case .unverified: return "Untested, may vary"
            }
        }
    }

    public enum Mechanism: String, Sendable {
        case fileViewerPreference
        case folderHandler
        case both
        case finderInternal
        case systemService
        case appleEvents
        case unknown
    }

    public var id: String
    public var title: String
    public var coverage: Coverage
    public var mechanism: Mechanism
    public var detail: String

    public init(id: String, title: String, coverage: Coverage, mechanism: Mechanism, detail: String) {
        self.id = id
        self.title = title
        self.coverage = coverage
        self.mechanism = mechanism
        self.detail = detail
    }
}

public enum RevealCompatibility {
    public static let matrix: [RevealEntryPoint] = [
        RevealEntryPoint(
            id: "show-in-finder-apps",
            title: "Show in Finder from other apps",
            coverage: .redirected,
            mechanism: .fileViewerPreference,
            detail: "Apps calling activateFileViewerSelecting or selectFile(_:inFileViewerRootedAtPath:), including most AppKit apps, VS Code and other Electron apps, and Chrome downloads."
        ),
        RevealEntryPoint(
            id: "open-dir-terminal",
            title: "open <folder> in Terminal and NSWorkspace.open(folder)",
            coverage: .redirected,
            mechanism: .folderHandler,
            detail: "Goes through the public.folder handler registered with LaunchServices."
        ),
        RevealEntryPoint(
            id: "desktop-double-click",
            title: "Double-clicking a folder on the desktop",
            coverage: .notRedirected,
            mechanism: .finderInternal,
            detail: "The desktop is a Finder window and handles its own clicks."
        ),
        RevealEntryPoint(
            id: "finder-window-double-click",
            title: "Double-clicking inside a Finder window",
            coverage: .notRedirected,
            mechanism: .finderInternal,
            detail: "Finder opens folders itself. Use betterfinder windows instead."
        ),
        RevealEntryPoint(
            id: "open-save-panels",
            title: "Open and Save panels",
            coverage: .notRedirected,
            mechanism: .systemService,
            detail: "Run in a system service process and can't be replaced."
        ),
        RevealEntryPoint(
            id: "dock-stacks",
            title: "Dock folder stacks (Open in Finder)",
            coverage: .unverified,
            mechanism: .unknown,
            detail: "Inconsistent across macOS versions."
        ),
        RevealEntryPoint(
            id: "spotlight-cmd-return",
            title: "Spotlight ⌘↩ (Show in Finder)",
            coverage: .unverified,
            mechanism: .unknown,
            detail: "Not confirmed to honor the file viewer setting."
        ),
        RevealEntryPoint(
            id: "applescript-finder",
            title: "AppleScript or scripts that tell application \"Finder\"",
            coverage: .notRedirected,
            mechanism: .appleEvents,
            detail: "Addressed to Finder by bundle ID and can't be intercepted."
        ),
        RevealEntryPoint(
            id: "finder-only-features",
            title: "AirDrop, Get Info, Trash Put Back, Finder Sync badges",
            coverage: .notRedirected,
            mechanism: .finderInternal,
            detail: "These features only exist inside Finder."
        ),
        RevealEntryPoint(
            id: "apps-own-viewer",
            title: "Apps with their own file viewer setting",
            coverage: .notRedirected,
            mechanism: .fileViewerPreference,
            detail: "Default Folder X, EagleFiler and similar apps override NSFileViewer per app."
        ),
    ]
}
