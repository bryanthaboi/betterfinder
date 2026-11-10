import AppKit
import Browser
import FSCore
import Foundation
import ModHost
import ModKit

@MainActor
final class OwnedBucket<Item: BrowserContribution> {
    struct Slot {
        var key: UUID
        var item: Item
    }

    let registry: BrowserRegistry<Item>
    private(set) var items: [String: [Slot]] = [:]
    private var dirty: Set<String> = []

    init(_ registry: BrowserRegistry<Item>) { self.registry = registry }

    var isDirty: Bool { !dirty.isEmpty }

    func add(_ item: Item, owner: String) throws -> UUID {
        if let problem = registry.validate(item, owner: owner) { throw BrowserRegistryError(problem) }
        var list = items[owner] ?? []
        if list.contains(where: { $0.item.id == item.id }) { throw ModRegistrationError.duplicate("\(owner)/\(item.id)") }
        let key = UUID()
        list.append(Slot(key: key, item: item))
        items[owner] = list
        dirty.insert(owner)
        return key
    }

    func remove(_ key: UUID, owner: String) {
        guard var list = items[owner], let i = list.firstIndex(where: { $0.key == key }) else { return }
        list.remove(at: i)
        items[owner] = list.isEmpty ? nil : list
        dirty.insert(owner)
    }

    func item(owner: String, id: String) -> Item? { items[owner]?.first { $0.item.id == id }?.item }

    func flush() {
        let owners = dirty
        dirty.removeAll()
        for owner in owners.sorted() {
            let list = items[owner] ?? []
            if list.isEmpty {
                registry.removeAll(owner: owner)
            } else if (try? registry.replaceAll(list.map(\.item), owner: owner)) == nil {
                registry.removeAll(owner: owner)
            }
        }
    }

    func removeOwner(_ owner: String) {
        items[owner] = nil
        dirty.remove(owner)
        registry.removeAll(owner: owner)
    }
}

@MainActor
final class ModStatusDriver: StatusBarSegmentDriver {
    weak var sink: BrowserModSink?
    let qualifiedID: String
    let fallback: String
    private weak var output: StatusBarSegmentOutput?

    init(sink: BrowserModSink?, qualifiedID: String, fallback: String) {
        self.sink = sink
        self.qualifiedID = qualifiedID
        self.fallback = fallback
    }

    func update(_ context: StatusBarContext, output: StatusBarSegmentOutput) {
        if self.output !== output {
            self.output = output
            sink?.attachStatusOutput(output, for: qualifiedID)
        }
        output.setHidden(false)
        output.set(text: sink?.statusText(qualifiedID) ?? fallback)
    }

    func stop() {}
}

@MainActor
public final class BrowserModSink: ModUIRegistrySink {
    public struct ToolbarState: Equatable {
        public var enabled: Bool
        public var title: String?
    }

    public static let replacedDefaultsKey = "appBridge.replacedBuiltins.v1"

    public let registries: BrowserRegistries
    public let environment: ModEnvironmentState
    public var onNotify: ((_ modId: String, _ message: String, _ level: String) -> Void)?
    public var navigator: ((ProvidedLocation) -> Void)?
    public var contextProvider: (() -> BrowserContext)?
    public var autoFlush = true

    let toolbar: OwnedBucket<ToolbarItemSpec>
    let sidebar: OwnedBucket<SidebarSectionSpec>
    let contextMenu: OwnedBucket<ContextMenuSpec>
    let columns: OwnedBucket<ColumnSpec>
    let statusBar: OwnedBucket<StatusBarSegmentSpec>
    let panels: OwnedBucket<PanelSpec>
    let previews: OwnedBucket<PreviewSpec>
    let views: OwnedBucket<BrowserViewSpec>
    let locations: OwnedBucket<LocationProviderSpec>
    let search: OwnedBucket<SearchProviderSpec>
    let commands: OwnedBucket<CommandSpec>
    let keyBindings: OwnedBucket<KeyBindingSpec>

    private var flushScheduled = false
    private var toolbarStates: [String: ToolbarState] = [:]
    private var disabledCommands: Set<String> = []
    private var statusTexts: [String: String] = [:]
    private var statusOutputs: [String: NSHashTable<StatusBarSegmentOutput>] = [:]
    private var panelCommands: [String: [String: String]] = [:]
    private var panelFieldIDs: [String: [String: String]] = [:]
    private var panelNodes: [String: Browser.ModUINode] = [:]
    private var panelFieldValues: [String: [String: String]] = [:]
    private var panelReports: [String: String] = [:]
    private var commandRunners: [String: ModCommandRunning] = [:]
    private var locationOwners: [String: String] = [:]
    private var replaced: [String: Int] = [:]

    public init(registries: BrowserRegistries = .shared, environment: ModEnvironmentState = ModEnvironmentState()) {
        self.registries = registries
        self.environment = environment
        toolbar = OwnedBucket(registries.toolbar)
        sidebar = OwnedBucket(registries.sidebar)
        contextMenu = OwnedBucket(registries.contextMenu)
        columns = OwnedBucket(registries.columns)
        statusBar = OwnedBucket(registries.statusBar)
        panels = OwnedBucket(registries.panels)
        previews = OwnedBucket(registries.previews)
        views = OwnedBucket(registries.browserViews)
        locations = OwnedBucket(registries.locations)
        search = OwnedBucket(registries.searchProviders)
        commands = OwnedBucket(registries.commands)
        keyBindings = OwnedBucket(registries.keyBindings)
    }

    public static func locationProviderID(_ id: ModContributionID) -> String { "\(id.modId).\(id.localId)" }

    public static func builtinCandidates(_ raw: String) -> [String] {
        let rest = raw.hasPrefix("builtin.") ? String(raw.dropFirst(8)) : raw
        let words = rest.split(whereSeparator: { $0 == "-" || $0 == "." }).map(String.init)
        guard let first = words.first else { return [] }
        let camel = first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        var out = [rest, camel]
        if words.count > 1 {
            let tail = words[1] + words.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            out.append("\(first).\(tail)")
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public func browserCommandID(_ ref: ModCommandReference) -> String {
        guard ref.isBuiltIn else { return ref.qualified }
        let candidates = Self.builtinCandidates(ref.raw).map { BrowserRegistry<CommandSpec>.qualify($0, owner: BrowserOwner.builtIn) }
        return candidates.first { registries.commands.entry($0) != nil } ?? candidates.last ?? ref.raw
    }

    func builtinEntryID<Item>(_ raw: String, in registry: BrowserRegistry<Item>) -> String? {
        Self.builtinCandidates(raw).map { BrowserRegistry<Item>.qualify($0, owner: BrowserOwner.builtIn) }.first { registry.entry($0) != nil }
    }

    func scheduleFlush() {
        guard autoFlush, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }

    public func flush() {
        flushScheduled = false
        commands.flush()
        keyBindings.flush()
        locations.flush()
        search.flush()
        columns.flush()
        previews.flush()
        views.flush()
        panels.flush()
        statusBar.flush()
        contextMenu.flush()
        sidebar.flush()
        toolbar.flush()
        let liveStatus = Set(statusBar.items.flatMap { owner, slots in slots.map { "\(owner)/\($0.item.id)" } })
        statusOutputs = statusOutputs.filter { liveStatus.contains($0.key) }
        statusTexts = statusTexts.filter { liveStatus.contains($0.key) }
        let livePanels = Set(panels.items.flatMap { owner, slots in slots.map { "\(owner)/\($0.item.id)" } })
        panelCommands = panelCommands.filter { livePanels.contains($0.key) }
        for (qid, node) in panelNodes where livePanels.contains(qid) && registries.panels.contentOverrides[qid] == nil {
            registries.panels.updateContent(node, for: qid)
        }
        panelFieldIDs = panelFieldIDs.filter { livePanels.contains($0.key) }
        panelFieldValues = panelFieldValues.filter { livePanels.contains($0.key) }
        validateToolbars()
    }

    public func removeAll(owner: String) {
        commands.removeOwner(owner)
        keyBindings.removeOwner(owner)
        locations.removeOwner(owner)
        search.removeOwner(owner)
        columns.removeOwner(owner)
        previews.removeOwner(owner)
        views.removeOwner(owner)
        panels.removeOwner(owner)
        statusBar.removeOwner(owner)
        contextMenu.removeOwner(owner)
        sidebar.removeOwner(owner)
        toolbar.removeOwner(owner)
        registries.removeAll(owner: owner)
    }

    public var hasPendingChanges: Bool {
        toolbar.isDirty || sidebar.isDirty || contextMenu.isDirty || columns.isDirty || statusBar.isDirty || panels.isDirty
            || previews.isDirty || views.isDirty || locations.isDirty || search.isDirty || commands.isDirty || keyBindings.isDirty
    }

    private func token<Item>(_ bucket: OwnedBucket<Item>, _ key: UUID, owner: String, cleanup: (@MainActor () -> Void)? = nil) -> ModRegistrationToken {
        ModRegistrationToken { [weak self, weak bucket] in
            let work: @MainActor () -> Void = {
                bucket?.remove(key, owner: owner)
                cleanup?()
                self?.scheduleFlush()
            }
            if Thread.isMainThread { MainActor.assumeIsolated { work() } } else { DispatchQueue.main.async { MainActor.assumeIsolated { work() } } }
        }
    }

    private func register<Item>(_ item: Item, in bucket: OwnedBucket<Item>, owner: String, replaces: String? = nil, cleanup: (@MainActor () -> Void)? = nil) throws -> ModRegistrationToken {
        let key = try bucket.add(item, owner: owner)
        let release = replaces.flatMap { hideReplaced($0, in: bucket.registry) }
        scheduleFlush()
        return token(bucket, key, owner: owner) {
            release?()
            cleanup?()
        }
    }

    private func hideReplaced<Item>(_ raw: String, in registry: BrowserRegistry<Item>) -> (@MainActor () -> Void)? {
        guard let qid = builtinEntryID(raw, in: registry) else { return nil }
        let key = "\(registry.kind.rawValue)|\(qid)"
        if replaced[key, default: 0] == 0 {
            var persisted = UserDefaults.standard.dictionary(forKey: Self.replacedDefaultsKey) as? [String: Bool] ?? [:]
            if persisted[key] == nil { persisted[key] = registry.isHidden(qid) }
            UserDefaults.standard.set(persisted, forKey: Self.replacedDefaultsKey)
            if !registry.isHidden(qid) { registry.setHidden(qid, true) }
        }
        replaced[key, default: 0] += 1
        return { [weak self, weak registry] in
            guard let self, let registry else { return }
            self.replaced[key, default: 1] -= 1
            guard self.replaced[key] == 0 else { return }
            self.replaced[key] = nil
            var persisted = UserDefaults.standard.dictionary(forKey: Self.replacedDefaultsKey) as? [String: Bool] ?? [:]
            let wasHidden = persisted.removeValue(forKey: key) ?? false
            UserDefaults.standard.set(persisted, forKey: Self.replacedDefaultsKey)
            if !wasHidden { registry.setHidden(qid, false) }
        }
    }

    public func restoreReplacedBuiltins() {
        let persisted = UserDefaults.standard.dictionary(forKey: Self.replacedDefaultsKey) as? [String: Bool] ?? [:]
        for (key, wasHidden) in persisted where !wasHidden {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = BrowserRegistryKind(rawValue: parts[0]) else { continue }
            setHidden(parts[1], false, kind: kind)
        }
        UserDefaults.standard.removeObject(forKey: Self.replacedDefaultsKey)
    }

    private func setHidden(_ qid: String, _ hidden: Bool, kind: BrowserRegistryKind) {
        switch kind {
        case .toolbar: registries.toolbar.setHidden(qid, hidden)
        case .sidebar: registries.sidebar.setHidden(qid, hidden)
        case .contextMenu: registries.contextMenu.setHidden(qid, hidden)
        case .column: registries.columns.setHidden(qid, hidden)
        case .statusBar: registries.statusBar.setHidden(qid, hidden)
        case .panel: registries.panels.setHidden(qid, hidden)
        case .preview: registries.previews.setHidden(qid, hidden)
        case .browserView: registries.browserViews.setHidden(qid, hidden)
        case .command: registries.commands.setHidden(qid, hidden)
        case .keyBinding: registries.keyBindings.setHidden(qid, hidden)
        case .location: registries.locations.setHidden(qid, hidden)
        case .search: registries.searchProviders.setHidden(qid, hidden)
        }
    }

    func currentContext() -> BrowserContext {
        if let c = contextProvider?() { return c }
        return BrowserContext(location: .computer)
    }

    func run(_ commandID: String) {
        _ = registries.commands.run(commandID, context: currentContext())
    }

    func panelArgs(_ panel: String, extra: [String: JSONValue]) -> JSONValue? {
        var fields = [String: JSONValue]()
        for (nodeID, fieldID) in panelFieldIDs[panel] ?? [:] { fields[fieldID] = .string(panelFieldValues[panel]?[nodeID] ?? "") }
        var o = extra
        if !fields.isEmpty { o["fields"] = .object(fields) }
        return o.isEmpty ? nil : .object(o)
    }

    func runPanelCommand(_ commandID: String, panel: String, args: JSONValue?) {
        guard let runner = commandRunners[commandID], !disabledCommands.contains(commandID) else { run(commandID); return }
        let owner = ModContributionID(qualified: commandID)?.modId ?? panel
        let urls = currentContext().selectedURLs
        Task { [weak self] in
            do {
                let outcome = try await runner.run(selection: urls, args: args)
                if let m = outcome.message, !m.isEmpty { self?.onNotify?(owner, m, "info") }
            } catch {
                self?.onNotify?(owner, error.localizedDescription, "error")
            }
        }
    }

    func validateToolbars() {
        for w in NSApp?.windows ?? [] { w.toolbar?.validateVisibleItems() }
    }

    func statusText(_ qid: String) -> String? { statusTexts[qid] }

    func attachStatusOutput(_ output: StatusBarSegmentOutput, for qid: String) {
        let table = statusOutputs[qid] ?? NSHashTable<StatusBarSegmentOutput>.weakObjects()
        table.add(output)
        statusOutputs[qid] = table
    }

    public func toolbarState(_ qid: String) -> ToolbarState? { toolbarStates[qid] }
    public func isCommandDisabled(_ qid: String) -> Bool { disabledCommands.contains(qid) }
    public func locationOwner(_ providerID: String) -> String? { locationOwners[providerID] }

    static func symbol(_ name: String?, fallback: String) -> String {
        guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return fallback }
        return name
    }

    static func knownFolderURL(_ f: KnownFolder) -> URL {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL { fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser }
        switch f {
        case .home: return fm.homeDirectoryForCurrentUser
        case .desktop: return dir(.desktopDirectory)
        case .documents: return dir(.documentDirectory)
        case .downloads: return dir(.downloadsDirectory)
        case .applications: return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .pictures: return dir(.picturesDirectory)
        case .movies: return dir(.moviesDirectory)
        case .music: return dir(.musicDirectory)
        }
    }

    public func registerToolbarItem(_ item: ModToolbarContribution, owner: String) throws -> ModRegistrationToken {
        let qid = item.id.qualified
        let command = browserCommandID(item.command)
        let symbol = Self.symbol(item.symbolName, fallback: "puzzlepiece.extension")
        let title = item.title
        let spec = ToolbarItemSpec(
            id: item.id.localId, title: title, paletteLabel: title, toolTip: title, symbolName: symbol, accessibilityLabel: title,
            commandID: command,
            appearance: { [weak self] _ in
                let state = self?.toolbarStates[qid]
                let enabled = (state?.enabled ?? true) && !(self?.disabledCommands.contains(command) ?? false)
                return ToolbarItemAppearance(title: state?.title ?? title, symbolName: symbol, toolTip: state?.title ?? title, accessibilityLabel: state?.title ?? title, isEnabled: enabled)
            }
        )
        return try register(spec, in: toolbar, owner: owner, replaces: item.replaces) { [weak self] in self?.toolbarStates[qid] = nil }
    }

    public func registerSidebarSection(_ section: ModSidebarContribution, owner: String) throws -> ModRegistrationToken {
        let entries = section.items.compactMap { i -> SidebarEntrySpec? in
            let action: SidebarEntryAction
            if let folder = i.knownFolder {
                action = .navigate(.folder(Self.knownFolderURL(folder)))
            } else if let loc = i.location {
                action = .navigateProvided(ProvidedLocation(providerID: Self.locationProviderID(loc), id: "", title: i.title, symbolName: i.symbolName))
            } else {
                return nil
            }
            return SidebarEntrySpec(id: i.id, title: i.title, symbolName: Self.symbol(i.symbolName, fallback: "folder"), toolTip: i.title, action: action)
        }
        let spec = SidebarSectionSpec(id: section.id.localId, title: section.title, entries: entries)
        return try register(spec, in: sidebar, owner: owner, replaces: section.replaces)
    }

    public func registerContextMenuItem(_ item: ModContextMenuContribution, owner: String) throws -> ModRegistrationToken {
        let isItems = item.target == .items
        let entry = BrowserMenuEntry(id: item.id.localId, title: item.title, commandID: browserCommandID(item.command))
        let spec = ContextMenuSpec(id: item.id.localId, targets: isItems ? [.selection] : [.background], minSelection: isItems ? 1 : 0, entries: [entry])
        return try register(spec, in: contextMenu, owner: owner, replaces: item.replaces)
    }

    public func registerColumn(_ column: ModColumnContribution, provider: ModColumnValuesProviding, owner: String) throws -> ModRegistrationToken {
        let numeric = column.valueType == .number || column.valueType == .bytes
        let spec = ColumnSpec(
            id: column.id.localId, title: column.title, width: Double(column.width ?? 120), alignment: numeric ? .trailing : .leading,
            isSortable: column.sortable, revision: UUID().uuidString, timeout: 10,
            provider: ModColumnAdapter(provider: provider, valueType: column.valueType)
        )
        return try register(spec, in: columns, owner: owner, replaces: column.replaces)
    }

    public func registerStatusBarItem(_ item: ModStatusBarContribution, owner: String) throws -> ModRegistrationToken {
        let qid = item.id.qualified
        let title = item.title
        let command = item.command.map(browserCommandID)
        let panel = item.panel?.qualified
        var action: (@MainActor (BrowserContext) -> Void)?
        if command != nil || panel != nil {
            action = { [weak self] (ctx: BrowserContext) in
                if let panel { ctx.togglePanel(panel) }
                if let command { _ = self?.registries.commands.run(command, context: ctx) }
            }
        }
        let spec = StatusBarSegmentSpec(
            id: item.id.localId, alignment: item.alignment == .leading ? .leading : .trailing, accessibilityLabel: title,
            makeDriver: { [weak self] in ModStatusDriver(sink: self, qualifiedID: qid, fallback: title) },
            action: action
        )
        return try register(spec, in: statusBar, owner: owner, replaces: item.replaces) { [weak self] in
            self?.statusTexts[qid] = nil
            self?.statusOutputs[qid] = nil
        }
    }

    public func registerPanel(_ panel: ModPanelContribution, owner: String) throws -> ModRegistrationToken {
        let qid = panel.id.qualified
        let edge: Browser.PanelEdge
        switch panel.edge {
        case .left: edge = .left
        case .right: edge = .right
        case .bottom: edge = .bottom
        }
        let placeholder = Browser.ModUINode.label(id: "placeholder", panel.title, style: .secondary)
        let spec = PanelSpec(
            id: panel.id.localId, title: panel.title, symbolName: Self.symbol(panel.symbolName, fallback: "sidebar.right"), edge: edge,
            presentation: panel.presentation == .slideOut ? .slideOut : .docked, content: .ui(placeholder), accessibilityLabel: panel.title,
            onEvent: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch event.kind {
                    case .press:
                        if let command = self.panelCommands[qid]?[event.nodeID] { self.runPanelCommand(command, panel: qid, args: self.panelArgs(qid, extra: [:])) }
                    case .activated(let row):
                        if let command = self.panelCommands[qid]?[event.nodeID] { self.runPanelCommand(command, panel: qid, args: self.panelArgs(qid, extra: ["value": .string(row)])) }
                    case .selected(let choice):
                        guard let fieldID = self.panelFieldIDs[qid]?[event.nodeID] else { break }
                        self.panelFieldValues[qid, default: [:]][event.nodeID] = choice
                        if let command = self.panelCommands[qid]?[event.nodeID] {
                            self.runPanelCommand(command, panel: qid, args: self.panelArgs(qid, extra: ["id": .string(fieldID), "value": .string(choice)]))
                        }
                    case .textChanged(let text):
                        if self.panelFieldIDs[qid]?[event.nodeID] != nil { self.panelFieldValues[qid, default: [:]][event.nodeID] = String(text.prefix(4096)) }
                    case .textCommitted(let text):
                        guard let fieldID = self.panelFieldIDs[qid]?[event.nodeID] else { break }
                        let value = String(text.prefix(4096))
                        self.panelFieldValues[qid, default: [:]][event.nodeID] = value
                        if let command = self.panelCommands[qid]?[event.nodeID] {
                            self.runPanelCommand(command, panel: qid, args: self.panelArgs(qid, extra: ["id": .string(fieldID), "value": .string(value)]))
                        }
                    default: break
                    }
                }
            }
        )
        return try register(spec, in: panels, owner: owner) { [weak self] in
            self?.panelNodes[qid] = nil
            self?.panelCommands[qid] = nil
            self?.panelFieldIDs[qid] = nil
            self?.panelFieldValues[qid] = nil
            self?.panelReports[qid] = nil
        }
    }

    public func registerPreview(_ preview: ModPreviewContribution, provider: ModPreviewProviding, owner: String) throws -> ModRegistrationToken {
        let spec = PreviewSpec(
            id: preview.id.localId, title: preview.title, extensions: preview.extensions, priority: 10, timeout: 5,
            provider: ModPreviewAdapter(provider: provider, environment: environment, resolve: { [weak self] ref in
                MainActor.assumeIsolated { self?.browserCommandID(ref) ?? ref.qualified }
            })
        )
        return try register(spec, in: previews, owner: owner, replaces: preview.replaces)
    }

    public func registerView(_ view: ModViewContribution, owner: String) throws -> ModRegistrationToken {
        let registries = registries
        let layout = view.layout
        let spec = BrowserViewSpec(
            id: view.id.localId, title: view.title, priority: 5,
            matches: { [weak self] dest in
                guard let pid = dest.providedLocation?.providerID else { return false }
                return self?.locationOwners[pid] == owner
            },
            build: { ctx in ModLocationView.build(ctx, registries: registries, layout: layout) }
        )
        return try register(spec, in: views, owner: owner, replaces: view.replaces)
    }

    public func registerLocation(_ location: ModLocationContribution, provider: ModLocationProviding, owner: String) throws -> ModRegistrationToken {
        let pid = Self.locationProviderID(location.id)
        let symbol = Self.symbol(location.symbolName, fallback: "folder")
        let root = ProvidedLocation(providerID: pid, id: "", title: location.title, symbolName: symbol)
        let spec = LocationProviderSpec(
            id: pid, title: location.title, symbolName: symbol,
            provider: ModLocationAdapter(providerID: pid, root: root, provider: provider, readOnly: location.readOnly), root: root
        )
        locationOwners[pid] = owner
        do {
            return try register(spec, in: locations, owner: owner) { [weak self] in self?.locationOwners[pid] = nil }
        } catch {
            locationOwners[pid] = nil
            throw error
        }
    }

    public func registerSearchProvider(_ provider: ModSearchProviderContribution, search: ModSearchProviding, owner: String) throws -> ModRegistrationToken {
        let spec = SearchProviderSpec(id: provider.id.localId, title: provider.title, symbolName: Self.symbol(provider.symbolName, fallback: "magnifyingglass"), provider: ModSearchAdapter(provider: search))
        return try register(spec, in: self.search, owner: owner)
    }

    public func registerCommand(_ command: ModCommandContribution, runner: ModCommandRunning, owner: String) throws -> ModRegistrationToken {
        let qid = command.id.qualified
        let spec = CommandSpec(
            id: command.id.localId, title: command.title, subtitle: nil, category: command.category, symbolName: command.symbolName.map { Self.symbol($0, fallback: "puzzlepiece.extension") },
            isEnabled: { [weak self] _ in !(self?.disabledCommands.contains(qid) ?? false) },
            handler: { [weak self] ctx in
                let urls = ctx.selectedURLs
                Task { [weak self] in
                    do {
                        let outcome = try await runner.run(selection: urls, args: nil)
                        if let m = outcome.message, !m.isEmpty { self?.onNotify?(owner, m, "info") }
                    } catch {
                        self?.onNotify?(owner, error.localizedDescription, "error")
                    }
                }
            }
        )
        commandRunners[qid] = runner
        return try register(spec, in: commands, owner: owner) { [weak self] in
            self?.disabledCommands.remove(qid)
            self?.commandRunners[qid] = nil
        }
    }

    public func registerKeybinding(_ binding: ModKeybindingContribution, owner: String) throws -> ModRegistrationToken {
        guard let chord = KeyChord.parse(binding.chord) else { throw BrowserRegistryError("“\(binding.chord)” is not a valid key chord.") }
        let spec = KeyBindingSpec(id: binding.id.localId, chord: chord, commandID: browserCommandID(binding.command), title: nil)
        return try register(spec, in: keyBindings, owner: owner)
    }

    public func apply(_ update: ModUIUpdate) {
        switch update {
        case .panelContent(let panel, let node):
            let converted = ModUIConversion.convert(node, commandResolver: browserCommandID)
            let title = panels.item(owner: panel.modId, id: panel.localId)?.title ?? panel.localId
            let issues = converted.issues
            let report = issues.isEmpty ? converted.warnings.prefix(3).joined(separator: "; ") : issues.prefix(3).joined(separator: "; ")
            if report.isEmpty {
                panelReports[panel.qualified] = nil
            } else if panelReports[panel.qualified] != report {
                panelReports[panel.qualified] = report
                if issues.isEmpty {
                    onNotify?(panel.modId, "Panel “\(title)”: \(report)", "warning")
                } else {
                    onNotify?(panel.modId, "Panel “\(title)” wasn’t updated: \(report)", "error")
                }
            }
            guard issues.isEmpty else { return }
            panelCommands[panel.qualified] = converted.commands
            panelFieldIDs[panel.qualified] = converted.fields
            panelFieldValues[panel.qualified] = converted.fieldValues
            panelNodes[panel.qualified] = converted.node
            registries.panels.updateContent(converted.node, for: panel.qualified)
        case .statusText(let item, let text):
            statusTexts[item.qualified] = text
            for output in statusOutputs[item.qualified]?.allObjects ?? [] { output.set(text: text) }
        case .toolbarItemState(let item, let enabled, let title):
            toolbarStates[item.qualified] = ToolbarState(enabled: enabled, title: title)
            validateToolbars()
        case .commandEnabled(let command, let enabled):
            if enabled { disabledCommands.remove(command.qualified) } else { disabledCommands.insert(command.qualified) }
            validateToolbars()
        case .notify(let modId, let message, let level):
            onNotify?(modId, message, level)
        case .openLocation(let location, let path):
            let pid = Self.locationProviderID(location)
            guard let spec = registries.locations.spec(for: pid) else { return }
            let title = path.isEmpty ? spec.title : (path as NSString).lastPathComponent
            let target = ProvidedLocation(providerID: pid, id: path, title: title, symbolName: spec.symbolName)
            if let navigator { navigator(target) } else { Self.navigate(target) }
        case .refreshLocation(let location):
            let pid = Self.locationProviderID(location)
            for wc in Self.browserWindows where wc.providedLocation?.providerID == pid { wc.refresh(nil) }
        case .refreshPreview, .invalidatePreviews:
            registries.previews.notify()
        }
    }

    static var browserWindows: [BrowserWindowController] {
        (NSApp?.windows ?? []).compactMap { $0.windowController as? BrowserWindowController }
    }

    static func navigate(_ target: ProvidedLocation) {
        if let wc = NSApp?.keyWindow?.windowController as? BrowserWindowController ?? browserWindows.first {
            wc.navigate(to: target)
        } else {
            BrowserWindowManager.shared.openWindow(at: target)
        }
    }
}
