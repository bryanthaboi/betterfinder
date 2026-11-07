import AppKit
import Theming
import FSCore
import Foundation

@MainActor
public struct BrowserContext {
    public let location: BrowserLocation
    public let providedLocation: ProvidedLocation?
    public let selection: [FileItem]
    public let isDualPane: Bool
    public let windowNumber: Int?
    weak var controller: BrowserWindowController?

    public var selectedURLs: [URL] { selection.map(\.url) }

    public init(location: BrowserLocation, providedLocation: ProvidedLocation? = nil, selection: [FileItem] = [], isDualPane: Bool = false, windowNumber: Int? = nil) {
        self.location = location
        self.providedLocation = providedLocation
        self.selection = selection
        self.isDualPane = isDualPane
        self.windowNumber = windowNumber
        self.controller = nil
    }

    init(pane: BrowserPaneController) {
        self.location = pane.location
        self.providedLocation = pane.providedLocation
        self.selection = pane.selectedItems
        self.isDualPane = pane.windowController?.isDualPane ?? false
        self.windowNumber = pane.windowController?.window?.windowNumber
        self.controller = pane.windowController
    }

    init(controller: BrowserWindowController) {
        let pane = controller.activePane
        self.location = pane.location
        self.providedLocation = pane.providedLocation
        self.selection = pane.selectedItems
        self.isDualPane = controller.isDualPane
        self.windowNumber = controller.window?.windowNumber
        self.controller = controller
    }

    public func navigate(to location: BrowserLocation) { controller?.navigate(to: location) }
    public func navigate(to location: ProvidedLocation) { controller?.navigate(to: location) }
    public func refresh() { controller?.refresh(nil) }

    @discardableResult
    public func runCommand(_ qualifiedID: String) -> Bool {
        guard let controller else { return false }
        return controller.registries.commands.run(qualifiedID, context: self)
    }
}

public struct CommandSpec: BrowserContribution {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var category: String?
    public var symbolName: String?
    public var showsInPalette: Bool
    public var isEnabled: (@MainActor (BrowserContext) -> Bool)?
    public var handler: @MainActor (BrowserContext) -> Void

    public init(id: String, title: String, subtitle: String? = nil, category: String? = nil, symbolName: String? = nil, showsInPalette: Bool = true,
                isEnabled: (@MainActor (BrowserContext) -> Bool)? = nil, handler: @escaping @MainActor (BrowserContext) -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.symbolName = symbolName
        self.showsInPalette = showsInPalette
        self.isEnabled = isEnabled
        self.handler = handler
    }
}

public struct CommandPaletteEntry: Hashable, Sendable {
    public var qualifiedID: String
    public var title: String
    public var detail: String
    public var chord: String?
    public var symbolName: String?
    public var isEnabled: Bool
    public var isBuiltIn: Bool
}

@MainActor
public final class CommandRegistry: BrowserRegistry<CommandSpec> {
    public static let shared = CommandRegistry()

    weak var keyBindings: KeyBindingRegistry?
    weak var panels: PanelRegistry?

    public init() { super.init(kind: .command) }

    override public func validate(_ item: CommandSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A command needs a title." }
        return nil
    }

    @discardableResult
    public func run(_ qualifiedID: String, context: BrowserContext) -> Bool {
        guard let spec = item(qualifiedID) else { return false }
        if let enabled = spec.isEnabled, !enabled(context) { return false }
        spec.handler(context)
        return true
    }

    public func isEnabled(_ qualifiedID: String, context: BrowserContext) -> Bool {
        guard let spec = item(qualifiedID) else { return false }
        return spec.isEnabled?(context) ?? true
    }

    public func paletteEntries(query: String, context: BrowserContext) -> [CommandPaletteEntry] {
        var candidates: [CommandPaletteEntry] = []
        for e in orderedEntries where e.item.showsInPalette {
            let detail = [e.item.category, e.owner == BrowserOwner.builtIn ? nil : e.owner, e.item.subtitle].compactMap { $0 }.joined(separator: " · ")
            candidates.append(CommandPaletteEntry(
                qualifiedID: e.qualifiedID, title: e.item.title, detail: detail,
                chord: keyBindings?.chord(forCommand: e.qualifiedID).map(\.description),
                symbolName: e.item.symbolName, isEnabled: e.item.isEnabled?(context) ?? true, isBuiltIn: e.owner == BrowserOwner.builtIn
            ))
        }
        if let panels {
            for e in panels.visibleEntries {
                candidates.append(CommandPaletteEntry(
                    qualifiedID: PanelCommand.id(for: e.qualifiedID), title: "Toggle \(e.item.title) Panel", detail: "Panels · \(e.owner)",
                    chord: nil, symbolName: e.item.symbolName, isEnabled: true, isBuiltIn: false
                ))
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        let scored: [(CommandPaletteEntry, Int)] = candidates.compactMap { c in
            guard let s = CommandRegistry.fuzzyScore(query: trimmed, in: c.title + " " + c.detail) else { return nil }
            return (c, s)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    nonisolated static func fuzzyScore(query: String, in text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        var qi = 0
        var score = 0
        var lastMatch = -2
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += 10
            if i == lastMatch + 1 { score += 8 }
            if i == 0 || t[i - 1] == " " || t[i - 1] == "-" || t[i - 1] == "." { score += 12 }
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if text.lowercased().hasPrefix(query.lowercased()) { score += 40 }
        return score - t.count / 8
    }
}

enum PanelCommand {
    static let prefix = "panel.toggle:"
    static func id(for panelID: String) -> String { prefix + panelID }
    static func panelID(from commandID: String) -> String? { commandID.hasPrefix(prefix) ? String(commandID.dropFirst(prefix.count)) : nil }
}

@MainActor
enum BuiltInCommands {
    static func register(into registry: CommandRegistry) {
        func hasSelection(_ c: BrowserContext) -> Bool { !c.selection.isEmpty }
        func send(_ sel: Selector) -> @MainActor (BrowserContext) -> Void { { $0.controller?.dispatch(sel) } }
        func viewModes(_ c: BrowserContext) -> Bool { c.controller?.activePane.supportsViewModes ?? true }
        let specs: [CommandSpec] = [
            CommandSpec(id: "go.back", title: "Back", category: "Go", symbolName: "chevron.left", isEnabled: { !($0.controller?.activePane.backStack.isEmpty ?? true) }, handler: send(#selector(BrowserWindowController.goBack(_:)))),
            CommandSpec(id: "go.forward", title: "Forward", category: "Go", symbolName: "chevron.right", isEnabled: { !($0.controller?.activePane.forwardStack.isEmpty ?? true) }, handler: send(#selector(BrowserWindowController.goForward(_:)))),
            CommandSpec(id: "go.up", title: "Enclosing Folder", category: "Go", symbolName: "arrow.up", isEnabled: { $0.controller?.activePane.canGoUp ?? false }, handler: send(#selector(BrowserWindowController.goUp(_:)))),
            CommandSpec(id: "go.home", title: "Go to Home", category: "Go", symbolName: "house", handler: send(#selector(BrowserWindowController.goHome(_:)))),
            CommandSpec(id: "go.computer", title: "Go to Computer", category: "Go", symbolName: "desktopcomputer", handler: send(#selector(BrowserWindowController.goComputer(_:)))),
            CommandSpec(id: "go.recents", title: "Go to Recents", category: "Go", symbolName: "clock", handler: send(#selector(BrowserWindowController.goRecents(_:)))),
            CommandSpec(id: "go.desktop", title: "Go to Desktop", category: "Go", symbolName: "menubar.dock.rectangle", handler: send(#selector(BrowserWindowController.goDesktop(_:)))),
            CommandSpec(id: "go.documents", title: "Go to Documents", category: "Go", symbolName: "doc", handler: send(#selector(BrowserWindowController.goDocuments(_:)))),
            CommandSpec(id: "go.downloads", title: "Go to Downloads", category: "Go", symbolName: "arrow.down.circle", handler: send(#selector(BrowserWindowController.goDownloads(_:)))),
            CommandSpec(id: "go.applications", title: "Go to Applications", category: "Go", symbolName: "square.grid.2x2", handler: send(#selector(BrowserWindowController.goApplications(_:)))),
            CommandSpec(id: "go.folder", title: "Go to Folder…", category: "Go", handler: send(#selector(BrowserWindowController.goToFolder(_:)))),
            CommandSpec(id: "view.list", title: "View as List", category: "View", symbolName: "list.bullet", isEnabled: viewModes, handler: send(#selector(BrowserWindowController.asList(_:)))),
            CommandSpec(id: "view.columns", title: "View as Columns", category: "View", symbolName: "rectangle.split.3x1", isEnabled: viewModes, handler: send(#selector(BrowserWindowController.asColumns(_:)))),
            CommandSpec(id: "view.icons", title: "View as Icons", category: "View", symbolName: "square.grid.2x2", isEnabled: viewModes, handler: send(#selector(BrowserWindowController.asIcons(_:)))),
            CommandSpec(id: "view.toggleDualPane", title: "Toggle Dual Pane", category: "View", symbolName: "rectangle.split.2x1", handler: send(#selector(BrowserWindowController.toggleDualPane(_:)))),
            CommandSpec(id: "view.toggleHidden", title: "Toggle Hidden Files", category: "View", symbolName: "eye", handler: send(#selector(BrowserWindowController.toggleHiddenFiles(_:)))),
            CommandSpec(id: "view.refresh", title: "Refresh", category: "View", symbolName: "arrow.clockwise", handler: send(#selector(BrowserWindowController.refresh(_:)))),
            CommandSpec(id: "view.increaseIcons", title: "Increase Icon Size", category: "View", handler: send(#selector(BrowserWindowController.increaseIconSize(_:)))),
            CommandSpec(id: "view.decreaseIcons", title: "Decrease Icon Size", category: "View", handler: send(#selector(BrowserWindowController.decreaseIconSize(_:)))),
            CommandSpec(id: "file.newTab", title: "New Tab", category: "File", symbolName: "plus.square.on.square", handler: send(#selector(BrowserWindowController.newTab(_:)))),
            CommandSpec(id: "file.newFolder", title: "New Folder", category: "File", symbolName: "folder.badge.plus", isEnabled: { $0.controller?.activePane.canCreateFolder ?? false }, handler: send(#selector(BrowserWindowController.newFolder(_:)))),
            CommandSpec(id: "file.newFile", title: "New File", category: "File", symbolName: "doc.badge.plus", isEnabled: { $0.controller?.activePane.canCreateFile ?? false }, handler: send(#selector(BrowserWindowController.newFile(_:)))),
            CommandSpec(id: "file.getInfo", title: "Get Info", category: "File", symbolName: "info.circle", handler: send(#selector(BrowserWindowController.getInfo(_:)))),
            CommandSpec(id: "file.copyPath", title: "Copy Path", category: "File", symbolName: "doc.on.doc", handler: send(#selector(BrowserWindowController.copyPath(_:)))),
            CommandSpec(id: "file.openInTerminal", title: "Open in Terminal", category: "File", symbolName: "terminal", handler: send(#selector(BrowserWindowController.openInTerminal(_:)))),
            CommandSpec(id: "file.open", title: "Open Selection", category: "File", isEnabled: hasSelection, handler: send(#selector(BrowserPaneController.openSelection(_:)))),
            CommandSpec(id: "file.rename", title: "Rename", category: "File", isEnabled: { $0.selection.count == 1 }, handler: send(#selector(BrowserPaneController.renameSelection(_:)))),
            CommandSpec(id: "file.duplicate", title: "Duplicate", category: "File", symbolName: "plus.square.on.square", isEnabled: hasSelection, handler: send(#selector(BrowserPaneController.duplicate(_:)))),
            CommandSpec(id: "file.trash", title: "Move to Trash", category: "File", symbolName: "trash", isEnabled: hasSelection, handler: send(#selector(BrowserPaneController.moveToTrash(_:)))),
            CommandSpec(id: "file.quickLook", title: "Quick Look", category: "File", symbolName: "eye", isEnabled: hasSelection, handler: send(#selector(BrowserPaneController.toggleQuickLook(_:)))),
            CommandSpec(id: "search.focus", title: "Search", category: "Go", symbolName: "magnifyingglass", handler: send(#selector(BrowserWindowController.focusSearch(_:)))),
        ]
        _ = try? registry.registerBatch(specs, owner: BrowserOwner.builtIn)
    }
}

@MainActor
final class CommandPaletteModel {
    private let registries: BrowserRegistries
    private let contextProvider: @MainActor () -> BrowserContext
    private(set) var entries: [CommandPaletteEntry] = []
    var query = "" { didSet { refresh() } }

    init(registries: BrowserRegistries, contextProvider: @escaping @MainActor () -> BrowserContext) {
        self.registries = registries
        self.contextProvider = contextProvider
        refresh()
    }

    func refresh() {
        entries = registries.commands.paletteEntries(query: query, context: contextProvider())
    }

    @discardableResult
    func run(_ entry: CommandPaletteEntry, controller: BrowserWindowController?) -> Bool {
        guard entry.isEnabled else { return false }
        if let panelID = PanelCommand.panelID(from: entry.qualifiedID) {
            controller?.togglePanel(panelID)
            return true
        }
        return registries.commands.run(entry.qualifiedID, context: contextProvider())
    }
}

@MainActor
final class CommandPaletteController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let panel: NSPanel
    let model: CommandPaletteModel
    let field = NSSearchField()
    let table = NSTableView()
    private weak var controller: BrowserWindowController?
    private static var current: CommandPaletteController?

    init(controller: BrowserWindowController) {
        self.controller = controller
        self.model = CommandPaletteModel(registries: controller.registries) { [weak controller] in
            controller.map { BrowserContext(controller: $0) } ?? BrowserContext(location: .computer)
        }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Spacing.paletteWidth, height: 360), styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel("Command palette")
        build()
    }

    private func build() {
        field.placeholderString = "Run a command"
        field.delegate = self
        field.setAccessibilityLabel("Command palette search")
        field.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Spacing.paletteRowHeight
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runClicked(_:))
        table.allowsEmptySelection = false
        table.style = .plain
        table.setAccessibilityLabel("Commands")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: Spacing.panelPadding),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Spacing.panelPadding),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Spacing.panelPadding),
            field.heightAnchor.constraint(equalToConstant: Spacing.controlHeight),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Spacing.xs),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        panel.initialFirstResponder = field
        table.reloadData()
        selectFirst()
    }

    static func show(for controller: BrowserWindowController) {
        current?.close()
        let c = CommandPaletteController(controller: controller)
        current = c
        c.present(over: controller.window)
    }

    func present(over window: NSWindow?) {
        if let window {
            let f = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 80))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func selectFirst() {
        guard !model.entries.isEmpty else { return }
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        model.query = field.stringValue
        table.reloadData()
        selectFirst()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !model.entries.isEmpty else { return }
        let next = min(max(0, table.selectedRow + delta), model.entries.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func runClicked(_ sender: Any?) { runSelected() }

    func runSelected() {
        let row = table.selectedRow
        guard model.entries.indices.contains(row) else { return }
        let entry = model.entries[row]
        guard entry.isEnabled else { NSSound.beep(); return }
        let controller = controller
        close()
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.model.run(entry, controller: controller) } }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.entries.indices.contains(row) else { return nil }
        let entry = model.entries[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = entry.isEnabled ? .labelColor : .disabledControlTextColor
        let detail = NSTextField(labelWithString: entry.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let chord = NSTextField(labelWithString: entry.chord ?? "")
        chord.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        chord.textColor = .secondaryLabelColor
        for v in [title, detail, chord] { v.translatesAutoresizingMaskIntoConstraints = false; v.lineBreakMode = .byTruncatingTail; cell.addSubview(v) }
        chord.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: -Spacing.relatedText / 2),
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Spacing.panelPadding),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chord.leadingAnchor, constant: -Spacing.xs),
            detail.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: Spacing.relatedText / 2),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: chord.leadingAnchor, constant: -Spacing.xs),
            chord.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.panelPadding),
            chord.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel([entry.title, entry.detail, entry.chord, entry.isEnabled ? nil : "unavailable"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }
}
