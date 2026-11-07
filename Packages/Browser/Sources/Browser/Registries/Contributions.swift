import AppKit
import FSCore
import Foundation
import UniformTypeIdentifiers

public struct BrowserMenuEntry {
    public var id: String
    public var title: String
    public var symbolName: String?
    public var commandID: String?
    public var action: (@MainActor (BrowserContext) -> Void)?
    public var isEnabled: Bool
    public var isChecked: Bool
    public var children: [BrowserMenuEntry]
    public var isSeparator: Bool

    public init(id: String, title: String, symbolName: String? = nil, commandID: String? = nil, action: (@MainActor (BrowserContext) -> Void)? = nil,
                isEnabled: Bool = true, isChecked: Bool = false, children: [BrowserMenuEntry] = []) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.commandID = commandID
        self.action = action
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
        self.isSeparator = false
    }

    public static func separator(id: String = UUID().uuidString) -> BrowserMenuEntry {
        var e = BrowserMenuEntry(id: id, title: "")
        e.isSeparator = true
        return e
    }
}

@MainActor
final class MenuActionBox: NSObject {
    let isEnabled: Bool
    let run: @MainActor () -> Void
    init(isEnabled: Bool, run: @escaping @MainActor () -> Void) {
        self.isEnabled = isEnabled
        self.run = run
    }
}

@MainActor
final class ContributionMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = ContributionMenuTarget()

    @objc func performContribution(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuActionBox)?.run()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        ((menuItem.representedObject as? MenuActionBox)?.isEnabled) ?? (menuItem.submenu != nil)
    }
}

@MainActor
enum ContributionMenus {
    static func items(from entries: [BrowserMenuEntry], owner: String, context: BrowserContext, registries: BrowserRegistries) -> [NSMenuItem] {
        entries.map { item(from: $0, owner: owner, context: context, registries: registries) }
    }

    static func item(from entry: BrowserMenuEntry, owner: String, context: BrowserContext, registries: BrowserRegistries) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        let ref = entry.commandID.map { CommandRegistry.reference($0, owner: owner) }
        var enabled = entry.isEnabled
        if let ref, entry.action == nil { enabled = enabled && registries.commands.isEnabled(ref, context: context) }
        let item = NSMenuItem(title: entry.title, action: #selector(ContributionMenuTarget.performContribution(_:)), keyEquivalent: "")
        item.target = ContributionMenuTarget.shared
        item.state = entry.isChecked ? .on : .off
        if let symbol = entry.symbolName { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.title) }
        if !entry.children.isEmpty {
            let sub = NSMenu(title: entry.title)
            sub.autoenablesItems = true
            for c in items(from: entry.children, owner: owner, context: context, registries: registries) { sub.addItem(c) }
            item.submenu = sub
            item.action = nil
            item.representedObject = nil
            return item
        }
        let action = entry.action
        item.representedObject = MenuActionBox(isEnabled: enabled) { [weak registries] in
            if let action { action(context) } else if let ref, let registries { registries.commands.run(ref, context: context) }
        }
        if let ref, let chord = registries.keyBindings.chord(forCommand: ref) { item.toolTip = "\(entry.title) (\(chord))" }
        return item
    }
}

public struct ToolbarItemAppearance {
    public var title: String?
    public var symbolName: String?
    public var toolTip: String?
    public var accessibilityLabel: String?
    public var isEnabled: Bool

    public init(title: String? = nil, symbolName: String? = nil, toolTip: String? = nil, accessibilityLabel: String? = nil, isEnabled: Bool = true) {
        self.title = title
        self.symbolName = symbolName
        self.toolTip = toolTip
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
    }
}

public struct ToolbarItemSpec: BrowserContribution {
    public enum Placement: Hashable, Sendable {
        case beforeSearch
        case end
        case after(String)
        case before(String)
    }

    public enum Kind {
        case button
        case menu(@MainActor (BrowserContext) -> [BrowserMenuEntry])
    }

    public var id: String
    public var title: String
    public var paletteLabel: String?
    public var toolTip: String?
    public var symbolName: String?
    public var accessibilityLabel: String?
    public var placement: Placement
    public var kind: Kind
    public var commandID: String?
    public var action: (@MainActor (BrowserContext) -> Void)?
    public var appearance: (@MainActor (BrowserContext) -> ToolbarItemAppearance)?
    public var toolbarIdentifier: String?
    public var defaultOrder: Int

    public init(id: String, title: String, paletteLabel: String? = nil, toolTip: String? = nil, symbolName: String? = nil, accessibilityLabel: String? = nil,
                placement: Placement = .beforeSearch, kind: Kind = .button, commandID: String? = nil, action: (@MainActor (BrowserContext) -> Void)? = nil,
                appearance: (@MainActor (BrowserContext) -> ToolbarItemAppearance)? = nil, toolbarIdentifier: String? = nil, defaultOrder: Int = 0) {
        self.id = id
        self.title = title
        self.paletteLabel = paletteLabel
        self.toolTip = toolTip
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
        self.placement = placement
        self.kind = kind
        self.commandID = commandID
        self.action = action
        self.appearance = appearance
        self.toolbarIdentifier = toolbarIdentifier
        self.defaultOrder = defaultOrder
    }
}

@MainActor
public final class ToolbarRegistry: BrowserRegistry<ToolbarItemSpec> {
    public static let shared = ToolbarRegistry()

    public init() { super.init(kind: .toolbar) }

    override public func validate(_ item: ToolbarItemSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A toolbar item needs a title." }
        if case .button = item.kind, item.commandID == nil, item.action == nil { return "A toolbar button needs a command or an action." }
        return nil
    }

    public func toolbarIdentifier(for entry: Entry) -> String {
        entry.item.toolbarIdentifier ?? "bf.contrib.\(entry.qualifiedID)"
    }

    public func entry(forToolbarIdentifier id: String) -> Entry? {
        entries.first { toolbarIdentifier(for: $0) == id }
    }
}

public enum SidebarEntryAction: Hashable, Sendable {
    case navigate(BrowserLocation)
    case navigateProvided(ProvidedLocation)
    case command(String)
}

public struct SidebarEntrySpec: Hashable, Sendable {
    public var id: String
    public var title: String
    public var symbolName: String?
    public var toolTip: String?
    public var action: SidebarEntryAction

    public init(id: String, title: String, symbolName: String? = nil, toolTip: String? = nil, action: SidebarEntryAction) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.toolTip = toolTip
        self.action = action
    }
}

public struct SidebarSectionSpec: BrowserContribution {
    public enum Placement: Hashable, Sendable {
        case afterBuiltIns
        case beforeBuiltIns
        case after(String)
        case before(String)
    }

    public var id: String
    public var title: String
    public var entries: [SidebarEntrySpec]
    public var provider: (@MainActor () -> [SidebarEntrySpec])?
    public var placement: Placement
    public var defaultOrder: Int

    public init(id: String, title: String, entries: [SidebarEntrySpec] = [], provider: (@MainActor () -> [SidebarEntrySpec])? = nil, placement: Placement = .afterBuiltIns, defaultOrder: Int = 0) {
        self.id = id
        self.title = title
        self.entries = entries
        self.provider = provider
        self.placement = placement
        self.defaultOrder = defaultOrder
    }

    @MainActor var resolvedEntries: [SidebarEntrySpec] { provider?() ?? entries }
}

@MainActor
public final class SidebarSectionRegistry: BrowserRegistry<SidebarSectionSpec> {
    public static let shared = SidebarSectionRegistry()

    public init() { super.init(kind: .sidebar) }

    override public func validate(_ item: SidebarSectionSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A sidebar section needs a title." }
        var seen = Set<String>()
        for e in item.entries where !seen.insert(e.id).inserted { return "Duplicate sidebar entry “\(e.id)”." }
        return nil
    }
}

public struct ContextMenuSpec: BrowserContribution {
    public enum Target: Hashable, Sendable {
        case selection
        case background
    }

    public var id: String
    public var targets: Set<Target>
    public var minSelection: Int
    public var maxSelection: Int?
    public var contentTypes: [String]
    public var foldersOnly: Bool
    public var entries: [BrowserMenuEntry]
    public var builder: (@MainActor (BrowserContext) -> [BrowserMenuEntry])?
    public var defaultOrder: Int

    public init(id: String, targets: Set<Target> = [.selection], minSelection: Int = 1, maxSelection: Int? = nil, contentTypes: [String] = [], foldersOnly: Bool = false,
                entries: [BrowserMenuEntry] = [], builder: (@MainActor (BrowserContext) -> [BrowserMenuEntry])? = nil, defaultOrder: Int = 0) {
        self.id = id
        self.targets = targets
        self.minSelection = minSelection
        self.maxSelection = maxSelection
        self.contentTypes = contentTypes
        self.foldersOnly = foldersOnly
        self.entries = entries
        self.builder = builder
        self.defaultOrder = defaultOrder
    }

    @MainActor
    func applies(to context: BrowserContext) -> Bool {
        let sel = context.selection
        if sel.isEmpty { return targets.contains(.background) }
        guard targets.contains(.selection), sel.count >= minSelection else { return false }
        if let maxSelection, sel.count > maxSelection { return false }
        if foldersOnly, !sel.allSatisfy(\.isBrowsableFolder) { return false }
        if !contentTypes.isEmpty {
            let types = contentTypes.compactMap { UTType($0) }
            guard sel.allSatisfy({ item in item.contentType.map { t in types.contains { t.conforms(to: $0) } } ?? false }) else { return false }
        }
        return true
    }
}

@MainActor
public final class ContextMenuRegistry: BrowserRegistry<ContextMenuSpec> {
    public static let shared = ContextMenuRegistry()

    public init() { super.init(kind: .contextMenu) }

    override public func validate(_ item: ContextMenuSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.entries.isEmpty && item.builder == nil { return "A context menu contribution needs entries or a builder." }
        if item.targets.isEmpty { return "A context menu contribution needs at least one target." }
        return nil
    }

    func menuItems(for context: BrowserContext, registries: BrowserRegistries) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for e in visibleEntries where e.item.applies(to: context) {
            let entries = e.item.builder?(context) ?? e.item.entries
            out += ContributionMenus.items(from: entries, owner: e.owner, context: context, registries: registries)
        }
        return out
    }
}
