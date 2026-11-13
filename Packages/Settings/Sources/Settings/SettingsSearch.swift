import Foundation
import Integration
import SwiftUI

enum GeneralSection: String, CaseIterable, Identifiable, Hashable {
    case windows, listing, terminal, privacy, visor, keyboard, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Windows"
        case .listing: return "Listing"
        case .terminal: return "Terminal"
        case .privacy: return "Privacy"
        case .visor: return "Visor"
        case .keyboard: return "Keyboard"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .windows: return "macwindow"
        case .listing: return "list.bullet.rectangle"
        case .terminal: return "terminal"
        case .privacy: return "hand.raised"
        case .visor: return "rectangle.bottomhalf.inset.filled"
        case .keyboard: return "keyboard"
        case .updates: return "arrow.down.circle"
        }
    }
}

struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let keywords: String
    let paneID: String
    let paneTitle: String
    let section: String
    let generalSection: GeneralSection?

    init(_ id: String, _ title: String, keywords: String = "", pane: String, paneTitle: String, section: String) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.paneID = pane
        self.paneTitle = paneTitle
        self.section = section
        self.generalSection = nil
    }

    init(_ id: String, _ title: String, keywords: String = "", general: GeneralSection) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.paneID = SettingsPaneID.general
        self.paneTitle = "General"
        self.section = general.title
        self.generalSection = general
    }

    func matches(_ query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = "\(title) \(keywords) \(section) \(paneTitle)"
        return tokens.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

enum SettingsSearchIndex {
    static let general: [SettingsSearchEntry] = [
        .init("newWindow", "New window opens at", keywords: "home desktop documents custom folder start location", general: .windows),
        .init("openInTabs", "Open folders in tabs in the active window", keywords: "dock other apps new window tab", general: .windows),
        .init("sidebarIcons", "Color sidebar icons", keywords: "colour colorful", general: .windows),
        .init("dualSidebars", "A sidebar for each pane in dual pane", keywords: "right split two panes", general: .windows),
        .init("login", "Open betterfinder at login", keywords: "startup launch boot login items", general: .windows),
        .init("density", "Density", keywords: "compact regular comfortable row height size spacing", general: .listing),
        .init("foldersFirst", "Folders first", keywords: "sort order directories top", general: .listing),
        .init("hiddenFiles", "Show hidden files", keywords: "dotfiles invisible dot", general: .listing),
        .init("coloredLabels", "Colored labels", keywords: "tags tint colour row", general: .listing),
        .init("columnFit", "Fit column widths to names in column view", keywords: "auto width columns browser", general: .listing),
        .init("folderSizes", "Calculate folder sizes", keywords: "size directory total", general: .listing),
        .init("networkSizes", "Also on network volumes", keywords: "folder sizes smb nas server remote", general: .listing),
        .init("sizeShown", "Size shown", keywords: "size on disk logical allocated bytes", general: .listing),
        .init("terminal", "Open in Terminal uses", keywords: "iterm ghostty warp kitty wezterm alacritty shell console app", general: .terminal),
        .init("homeName", "Home folder name", keywords: "privacy hide username tilde path bar title screenshot", general: .privacy),
        .init("visor", "Global hotkey slides the visor in", keywords: "totalfinder drop down dock bottom", general: .visor),
        .init("visorShortcut", "Visor shortcut", keywords: "hotkey keyboard reset key combo", general: .visor),
        .init("visorDoubleTap", "Double-tap ⌥ also toggles it", keywords: "option alt double tap visor", general: .visor),
        .init("visorSpaces", "Show on all Spaces", keywords: "visor desktops mission control", general: .visor),
        .init("visorDock", "Show above the Dock", keywords: "visor dock overlap", general: .visor),
        .init("visorTerminal", "Open in Terminal opens a terminal on the right half of the visor", keywords: "integrated terminal split shell console built in", general: .visor),
        .init("visorShell", "Visor terminal shell", keywords: "zsh bash fish nu nushell pwsh profile shell terminal", general: .visor),
        .init("visorWindows", "Open all new windows in the visor", keywords: "tabs single window dock", general: .visor),
        .init("windowsKeys", "Windows keys", keywords: "return enter f2 rename backspace f5 refresh delete trash pc explorer shortcuts", general: .keyboard),
        .init("hotkey", "Global hotkey opens a new window", keywords: "shortcut keyboard combo", general: .keyboard),
        .init("autoUpdate", "Check for updates automatically", keywords: "update version check now", general: .updates),
        .init("crashReports", "Offer to send a crash report after a crash", keywords: "crash report github issue privacy", general: .updates),
    ]

    static var otherPanes: [SettingsSearchEntry] {
        var out: [SettingsSearchEntry] = []
        let d = SettingsPaneID.defaultFileManager
        out.append(.init("makeDefault", "Make betterfinder my default", keywords: "default file manager finder reveal show in finder", pane: d, paneTitle: "Default", section: "Default file manager"))
        out.append(.init("restoreFinder", "Restore Finder as default", keywords: "undo revert finder", pane: d, paneTitle: "Default", section: "Default file manager"))
        for tweak in FinderTweaks.Tweak.allCases {
            out.append(.init("tweak.\(tweak)", tweak.title, keywords: "finder tweak", pane: d, paneTitle: "Default", section: "Finder tweaks"))
        }
        let a = SettingsPaneID.appearance
        out.append(.init("theme", "Theme", keywords: "appearance colors colours dark light retro font icons accent editor", pane: a, paneTitle: "Appearance", section: "Themes"))
        let p = SettingsPaneID.permissions
        for kind in PermissionKind.allCases {
            out.append(.init("permission.\(kind)", kind.title, keywords: "permission access privacy grant", pane: p, paneTitle: "Permissions", section: "Permissions"))
        }
        let adv = SettingsPaneID.advanced
        out.append(.init("verifyCopies", "Verify copies with a checksum", keywords: "copy hash integrity", pane: adv, paneTitle: "Advanced", section: "File operations"))
        out.append(.init("trashViaFinder", "Move to Trash through Finder", keywords: "put back delete trash", pane: adv, paneTitle: "Advanced", section: "File operations"))
        out.append(.init("indexStatus", "File index status", keywords: "indexer size index", pane: adv, paneTitle: "Advanced", section: "File index"))
        out.append(.init("pauseIndexing", "Pause indexing", keywords: "indexer cpu battery", pane: adv, paneTitle: "Advanced", section: "File index"))
        out.append(.init("rebuildIndex", "Rebuild index", keywords: "indexer reindex reset", pane: adv, paneTitle: "Advanced", section: "File index"))
        return out
    }

    static func entries(extraPanes: [(id: String, title: String)]) -> [SettingsSearchEntry] {
        general + otherPanes + extraPanes.map {
            .init("pane.\($0.id)", $0.title, keywords: "mod extension plugin", pane: $0.id, paneTitle: $0.title, section: $0.title)
        }
    }

    static func entry(_ id: String) -> SettingsSearchEntry? {
        general.first { $0.id == id }
    }
}

private struct SettingsSearchQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var settingsSearchQuery: String {
        get { self[SettingsSearchQueryKey.self] }
        set { self[SettingsSearchQueryKey.self] = newValue }
    }
}

private struct SearchableRow: ViewModifier {
    let id: String
    @Environment(\.settingsSearchQuery) private var query

    func body(content: Content) -> some View {
        if query.isEmpty || SettingsSearchIndex.entry(id)?.matches(query) != false {
            content.id(id)
        }
    }
}

extension View {
    func settingsRow(_ id: String) -> some View {
        modifier(SearchableRow(id: id))
    }
}
