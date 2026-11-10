import AppKit
import FSCore
import Theming

@MainActor
enum SidebarStore {
    static let recentsToken = "@recents"

    static var defaultFavorites: [String] {
        let fm = FileManager.default
        if DemoEnvironment.isEnabled {
            return [recentsToken, DemoEnvironment.home.path] + ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Projects"].map { DemoEnvironment.home.appendingPathComponent($0).path }
        }
        var out = [recentsToken, fm.homeDirectoryForCurrentUser.path]
        for d in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { out.append(u.path) }
        }
        out.append("/Applications")
        return out
    }

    static var favorites: [String] {
        get { DemoEnvironment.isEnabled ? defaultFavorites : BrowserDefaults.favorites ?? defaultFavorites }
        set {
            BrowserDefaults.favorites = newValue
            NotificationCenter.default.post(name: .browserFavoritesDidChange, object: nil)
        }
    }

    static func addFavorites(_ urls: [URL], at index: Int?) {
        var favs = favorites
        let paths = urls.map(\.pathKey).filter { !favs.contains($0) }
        guard !paths.isEmpty else { return }
        let i = min(max(0, index ?? favs.count), favs.count)
        favs.insert(contentsOf: paths, at: i)
        favorites = favs
    }

    static func remove(_ token: String) {
        favorites = favorites.filter { $0 != token }
    }

    static func move(_ token: String, to index: Int) {
        var favs = favorites
        guard let from = favs.firstIndex(of: token) else { return }
        favs.remove(at: from)
        let dest = from < index ? index - 1 : index
        favs.insert(token, at: min(max(0, dest), favs.count))
        favorites = favs
    }
}

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, ThemedSurface {
    enum Kind: Hashable {
        case favorite(String)
        case cloud
        case computer
        case volume(URL, ejectable: Bool)
        case tag(String)
        case contributed(String)
        case remote(UUID)
    }

    final class Section: NSObject {
        let title: String
        var entries: [Entry]
        init(title: String, entries: [Entry]) { self.title = title; self.entries = entries }
    }
    struct Entry: Hashable {
        let title: String
        let location: BrowserLocation
        let symbol: String?
        let kind: Kind
        var tagColor: NSColor?
        var action: SidebarEntryAction?
        var toolTip: String?
        var redacted: String? = nil
    }

    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private var sections: [Section] = []
    private var boxes: [Entry: EntryBox] = [:]
    private var current: BrowserLocation?
    var onSelect: ((BrowserLocation) -> Void)?
    var onSelectProvided: ((ProvidedLocation) -> Void)?
    var onCommand: ((String, String) -> Void)?
    var onOpenInNewTab: ((BrowserLocation) -> Void)?
    var onOpenProvidedInNewTab: ((ProvidedLocation) -> Void)?
    private var registries: BrowserRegistries
    private var currentProvided: ProvidedLocation?

    init(registries: BrowserRegistries? = nil) {
        self.registries = registries ?? .shared
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func teardown() {
        registries.sidebar.removeObserver(self)
    }
    private var suppressSelect = false
    static let favoriteType = NSPasteboard.PasteboardType("com.betterfinder.sidebar-favorite")

    override func loadView() {
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        ThemeHooks.install(scroll: scroll)
        view = scroll
        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.rowHeight = Self.rowHeight(for: ThemeManager.shared.current)
        outline.intercellSpacing = .zero
        outline.dataSource = self
        outline.delegate = self
        outline.controller = self
        outline.setAccessibilityLabel("Sidebar")
        outline.registerForDraggedTypes([Self.favoriteType] + DropSupport.types)
        outline.setDraggingSourceOperationMask([.move, .copy, .link, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        rebuild()
        registries.sidebar.addObserver(self) { [weak self] in self?.rebuild() }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(volumesChanged), name: n, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .browserFavoritesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .remoteLocationsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .remoteConnectionStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        observeThemeChanges()
    }

    private var lastKnownTags: [String] = []
    private var lastHomeDisplay = HomeLabel.display

    @objc private func defaultsChanged() {
        let tags = BrowserDefaults.knownTags
        let home = HomeLabel.display
        if tags != lastKnownTags || home != lastHomeDisplay {
            lastKnownTags = tags
            lastHomeDisplay = home
            rebuild()
        }
    }

    func applyTheme(_ theme: Theme) {
        let bg = theme.colors.sidebarBg.lowercased()
        if bg == "system:clear" {
            outline.backgroundColor = .clear
            scroll.drawsBackground = false
        } else {
            outline.backgroundColor = Theme.color(theme.colors.sidebarBg)
            scroll.drawsBackground = true
            scroll.backgroundColor = Theme.color(theme.colors.sidebarBg)
        }
        outline.style = Self.usesCustomSelection(theme) || ThemeAccessibility.increaseContrast ? .plain : .sourceList
        outline.rowHeight = Self.rowHeight(for: theme)
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
        if let current { highlight(current) }
    }

    @objc private func volumesChanged() { rebuild() }

    private func favoriteEntry(_ token: String) -> Entry? {
        if token == SidebarStore.recentsToken {
            return Entry(title: "Recents", location: .recents, symbol: "clock", kind: .favorite(token))
        }
        let url = URL(fileURLWithPath: token, isDirectory: true)
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.pathKey
        func dir(_ d: FileManager.SearchPathDirectory) -> String? { fm.urls(for: d, in: .userDomainMask).first?.pathKey }
        let symbol: String
        switch token {
        case home: symbol = "house"
        case dir(.desktopDirectory): symbol = "menubar.dock.rectangle"
        case dir(.documentDirectory): symbol = "doc"
        case dir(.downloadsDirectory): symbol = "arrow.down.circle"
        case "/Applications": symbol = "square.grid.2x2"
        case dir(.moviesDirectory): symbol = "film"
        case dir(.musicDirectory): symbol = "music.note"
        case dir(.picturesDirectory): symbol = "photo"
        default: symbol = "folder"
        }
        if HomeLabel.isRedacted(url) {
            return Entry(title: HomeNameDisplay.redactedAccessibilityName, location: .folder(url), symbol: symbol, kind: .favorite(token), redacted: fm.displayName(atPath: token))
        }
        return Entry(title: HomeLabel.name(fm.displayName(atPath: token), for: url), location: .folder(url), symbol: symbol, kind: .favorite(token))
    }

    private func rebuild() {
        let fm = FileManager.default
        let favorites = SidebarStore.favorites.compactMap(favoriteEntry)
        let icloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var cloud: [Entry] = []
        if fm.fileExists(atPath: icloud.path) {
            cloud.append(Entry(title: "iCloud Drive", location: .folder(icloud), symbol: "icloud", kind: .cloud))
        }
        var locations: [Entry] = [Entry(title: BrowserLocation.computer.displayName, location: .computer, symbol: "desktopcomputer", kind: .computer)]
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let vols = DemoEnvironment.volumes
        for v in vols {
            let values = try? v.resourceValues(forKeys: Set(keys))
            let isNetwork = values?.volumeIsLocal == false
            let symbol = isNetwork ? "network" : ((values?.volumeIsRemovable == true || values?.volumeIsInternal == false) ? "externaldrive" : "internaldrive")
            let ejectable = values?.volumeIsRootFileSystem != true && (values?.volumeIsEjectable == true || values?.volumeIsRemovable == true || isNetwork || values?.volumeIsInternal == false)
            locations.append(Entry(title: values?.volumeLocalizedName ?? v.lastPathComponent, location: .folder(v), symbol: symbol, kind: .volume(v, ejectable: ejectable)))
        }
        var tagNames = TagColors.systemTags
        for t in BrowserDefaults.knownTags where !tagNames.contains(t) { tagNames.append(t) }
        let tags = tagNames.map { Entry(title: $0, location: .tag($0), symbol: nil, kind: .tag($0), tagColor: TagColors.color(for: $0)) }
        sections = [Section(title: "Favorites", entries: favorites)]
        if !cloud.isEmpty { sections.append(Section(title: "iCloud", entries: cloud)) }
        locations += remoteEntries()
        sections.append(Section(title: "Locations", entries: locations))
        if !tags.isEmpty { sections.append(Section(title: "Tags", entries: tags)) }
        insertContributedSections()
        boxes = [:]
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
        if let current { highlight(current) }
    }

    private func remoteEntries() -> [Entry] {
        let integration = RemoteIntegration.shared
        guard integration.isInstalled(in: registries) else { return [] }
        return integration.servers.compactMap { server in
            guard let root = integration.rootLocation(for: server) else { return nil }
            var tip = "\(server.kindDescription) — \(server.address)"
            if case .failed(let m) = integration.manager.state(of: server) { tip += "\n\(m)" }
            return Entry(title: server.name, location: .computer, symbol: server.symbolName, kind: .remote(server.id), action: .navigateProvided(root), toolTip: tip)
        }
    }

    private func remoteRoot(_ b: EntryBox) -> ResourceID? {
        guard case .remote = b.entry.kind, case .navigateProvided(let p)? = b.entry.action else { return nil }
        return p.resourceID
    }

    private func insertContributedSections() {
        for e in registries.sidebar.visibleEntries {
            let spec = e.item
            let entries: [Entry] = spec.resolvedEntries.map { entry in
                let location: BrowserLocation
                if case .navigate(let l) = entry.action { location = l } else { location = .computer }
                return Entry(title: entry.title, location: location, symbol: entry.symbolName ?? "folder", kind: .contributed("\(e.qualifiedID)/\(entry.id)"), action: entry.action, toolTip: entry.toolTip)
            }
            let section = Section(title: spec.title, entries: entries)
            switch spec.placement {
            case .afterBuiltIns: sections.append(section)
            case .beforeBuiltIns: sections.insert(section, at: 0)
            case .after(let title): sections.insert(section, at: (sections.firstIndex { $0.title == title }.map { $0 + 1 }) ?? sections.count)
            case .before(let title): sections.insert(section, at: sections.firstIndex { $0.title == title } ?? sections.count)
            }
        }
    }

    var sectionTitles: [String] { sections.map(\.title) }

    func entryTitles(inSection title: String) -> [String] { section(title)?.entries.map(\.title) ?? [] }

    func highlight(provided: ProvidedLocation) {
        currentProvided = provided
        suppressSelect = true
        defer { suppressSelect = false }
        for row in 0..<outline.numberOfRows {
            if let e = outline.item(atRow: row) as? EntryBox, case .navigateProvided(let p)? = e.entry.action, p == provided {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    func highlight(_ location: BrowserLocation) {
        current = location
        currentProvided = nil
        suppressSelect = true
        defer { suppressSelect = false }
        for row in 0..<outline.numberOfRows {
            if let e = outline.item(atRow: row) as? EntryBox, e.entry.location.isSame(as: location) {
                switch e.entry.action {
                case .navigateProvided?, .command?: continue
                default: break
                }
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    private func box(_ e: Entry) -> EntryBox {
        if let b = boxes[e] { return b }
        let b = EntryBox(e); boxes[e] = b; return b
    }

    private func section(_ title: String) -> Section? { sections.first { $0.title == title } }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        if let sec = item as? Section { return sec.entries.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return box((item as! Section).entries[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is EntryBox }

    static func headingHeight(first: Bool, font: NSFont) -> CGFloat {
        let text = ceil(font.ascender - font.descender + font.leading)
        return (first ? Spacing.sidebarTopInset : Spacing.sidebarHeadingAbove) + text + Spacing.sidebarHeadingBelow
    }

    static let headingFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static func rowHeight(for theme: Theme) -> CGFloat {
        ThemeLayout.fittedHeight(theme.layout.sidebarRowHeight, font: theme.sidebarFont, verticalPadding: ThemeLayout.sidebarTextPadding)
    }

    static func usesCustomSelection(_ theme: Theme) -> Bool {
        !Theme.isSystemToken(theme.colors.sidebarSelection)
    }

    static func headingColor(for theme: Theme) -> NSColor {
        let base = Theme.color(theme.colors.sidebarText)
        let bgToken = theme.colors.sidebarBg.lowercased() == "system:clear" ? "system:windowBackground" : theme.colors.sidebarBg
        guard let bg = Theme.color(bgToken).usingColorSpace(.sRGB), let fg = base.usingColorSpace(.sRGB) else { return base }
        return NSColor.contrastRatio(composite(fg, alpha: 0.6 * fg.alphaComponent, over: bg), bg) >= 4.5 ? base.withAlphaComponent(0.6) : base
    }

    static func composite(_ fg: NSColor, alpha a: CGFloat, over bg: NSColor) -> NSColor {
        NSColor(srgbRed: fg.redComponent * a + bg.redComponent * (1 - a), green: fg.greenComponent * a + bg.greenComponent * (1 - a), blue: fg.blueComponent * a + bg.blueComponent * (1 - a), alpha: 1)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let sec = item as? Section { return Self.headingHeight(first: sec === sections.first, font: Self.headingFont) }
        return Self.rowHeight(for: ThemeManager.shared.current)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is EntryBox else { return nil }
        let row = SidebarRowView()
        row.theme = ThemeManager.shared.current
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let theme = ThemeManager.shared.current
        if let sec = item as? Section {
            let cell = NSTableCellView()
            let tf = NSTextField(labelWithString: sec.title)
            tf.font = Self.headingFont
            tf.textColor = Self.headingColor(for: theme)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            cell.setAccessibilityLabel(sec.title)
            cell.setAccessibilityRoleDescription("section")
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarCellView.contentLeading),
                tf.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -Spacing.sidebarHeadingBelow),
            ])
            return cell
        }
        guard let b = item as? EntryBox else { return nil }
        let cell = SidebarCellView()
        cell.textField?.font = theme.sidebarFont
        if let hidden = b.entry.redacted {
            cell.textField?.attributedStringValue = RedactedText.attributed(hidden, font: theme.sidebarFont, color: Theme.color(theme.colors.sidebarText))
        } else {
            cell.textField?.stringValue = b.entry.title
        }
        cell.iconTextGap = theme.layout.isAuthenticCompact ? Spacing.xxs : Spacing.iconText
        cell.normalTextColor = Theme.color(theme.colors.sidebarText)
        cell.selectedTextColor = Theme.color(theme.colors.sidebarSelectionText)
        if let s = b.entry.symbol {
            cell.imageView?.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            cell.normalIconColor = Theme.color(theme.colors.sidebarIcon)
        } else {
            cell.imageView?.image = TagColors.dot(b.entry.tagColor, size: 12)
            cell.normalIconColor = nil
        }
        if case .volume(let url, let ejectable) = b.entry.kind, ejectable {
            cell.setEjectVisible(true)
            cell.onEject = { [weak self] in self?.eject(url) }
            cell.ejectButton.setAccessibilityLabel("Eject \(b.entry.title)")
        } else {
            cell.setEjectVisible(false)
            cell.onEject = nil
        }
        cell.updateColors()
        cell.setAccessibilityLabel(b.entry.title)
        cell.toolTip = b.entry.toolTip
        return cell
    }

    private func eject(_ url: URL) {
        VolumeEjector.eject(url, window: view.window)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelect, let b = outline.item(atRow: outline.selectedRow) as? EntryBox else { return }
        let loc = b.entry.location
        switch b.entry.action {
        case .navigateProvided(let p)?:
            onSelectProvided?(p)
            return
        case .command(let id)?:
            if case .contributed(let key) = b.entry.kind { onCommand?(id, key) }
            if let currentProvided { highlight(provided: currentProvided) } else if let current { highlight(current) }
            return
        default: break
        }
        if let url = loc.url, !FileManager.default.fileExists(atPath: url.path) {
            NSSound.beep()
            if let current { highlight(current) }
            return
        }
        onSelect?(loc)
    }


    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let b = item as? EntryBox else { return nil }
        let pb = NSPasteboardItem()
        if case .favorite(let token) = b.entry.kind { pb.setString(token, forType: Self.favoriteType) }
        if let url = b.entry.location.url { pb.setString(url.absoluteString, forType: .fileURL) }
        return pb.types.isEmpty ? nil : pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard
        let favCount = section("Favorites")?.entries.count ?? 0
        if pb.availableType(from: [Self.favoriteType]) != nil {
            if let sec = item as? Section, sec.title == "Favorites", index >= 0 { return .move }
            if let b = item as? EntryBox, case .favorite = b.entry.kind, let sec = section("Favorites"), let i = sec.entries.firstIndex(of: b.entry) {
                outlineView.setDropItem(sec, dropChildIndex: i)
                return .move
            }
            return []
        }
        if let sec = item as? Section, sec.title == "Favorites" {
            let urls = DropSupport.fileURLs(info)
            let folders = urls.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            guard !folders.isEmpty else { return [] }
            if index < 0 { outlineView.setDropItem(sec, dropChildIndex: favCount) }
            return .link
        }
        guard let b = item as? EntryBox, index == NSOutlineViewDropOnItemIndex else { return [] }
        if case .tag = b.entry.kind { return DropSupport.fileURLs(info).isEmpty ? [] : .copy }
        if remoteRoot(b) != nil {
            return (Clipboard.resources(from: pb).isEmpty && DropSupport.fileURLs(info).isEmpty) ? [] : .copy
        }
        guard let dest = b.entry.location.url else { return [] }
        return DropSupport.operation(for: info, destination: dest)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard
        if let token = pb.string(forType: Self.favoriteType) {
            SidebarStore.move(token, to: max(0, index))
            return true
        }
        if let sec = item as? Section, sec.title == "Favorites" {
            let folders = DropSupport.fileURLs(info).filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            SidebarStore.addFavorites(folders, at: index)
            return true
        }
        guard let b = item as? EntryBox else { return false }
        if let root = remoteRoot(b) {
            var sources = Clipboard.resources(from: pb)
            if sources.isEmpty { sources = DropSupport.fileURLs(info).map(ResourceID.local) }
            guard !sources.isEmpty else { return false }
            RemoteTransfers.enqueue(sources, into: root, move: false)
            return true
        }
        if case .tag(let t) = b.entry.kind {
            let urls = DropSupport.fileURLs(info)
            guard !urls.isEmpty else { return false }
            Task { [weak self] in
                for u in urls {
                    do { try await FileCommands.addTag(t, to: u) } catch { self?.presentError(error); break }
                }
            }
            return true
        }
        guard let dest = b.entry.location.url else { return false }
        return DropSupport.perform(info, destination: dest)
    }


    func contextMenu(for event: NSEvent) -> NSMenu? {
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        guard row >= 0, let b = outline.item(atRow: row) as? EntryBox else { return nil }
        let menu = NSMenu()
        if case .command? = b.entry.action { return nil }
        let open = NSMenuItem(title: "Open in New Tab", action: #selector(menuOpenInTab(_:)), keyEquivalent: "")
        open.representedObject = b
        open.target = self
        menu.addItem(open)
        if let url = b.entry.location.url {
            let info = NSMenuItem(title: "Get Info", action: #selector(menuGetInfo(_:)), keyEquivalent: "")
            info.representedObject = url
            info.target = self
            menu.addItem(info)
        }
        switch b.entry.kind {
        case .favorite(let token):
            menu.addItem(.separator())
            let rm = NSMenuItem(title: "Remove from Sidebar", action: #selector(menuRemove(_:)), keyEquivalent: "")
            rm.representedObject = token
            rm.target = self
            menu.addItem(rm)
        case .remote(let id):
            menu.addItem(.separator())
            for (title, action) in [("Disconnect", #selector(menuDisconnectRemote(_:))), ("Remove Server…", #selector(menuRemoveRemote(_:)))] {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.representedObject = id
                i.target = self
                menu.addItem(i)
            }
            let c = NSMenuItem(title: RemoteMenu.title, action: #selector(BrowserWindowController.connectToServer(_:)), keyEquivalent: "")
            menu.addItem(c)
        case .volume(let url, let ejectable) where ejectable:
            menu.addItem(.separator())
            let ej = NSMenuItem(title: "Eject “\(b.entry.title)”", action: #selector(menuEject(_:)), keyEquivalent: "")
            ej.representedObject = url
            ej.target = self
            menu.addItem(ej)
        default: break
        }
        if SidebarStore.favorites != SidebarStore.defaultFavorites {
            menu.addItem(.separator())
            let reset = NSMenuItem(title: "Restore Default Favorites", action: #selector(menuResetFavorites(_:)), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
        return menu
    }

    @objc private func menuOpenInTab(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? EntryBox else { return }
        if case .navigateProvided(let p)? = b.entry.action { onOpenProvidedInNewTab?(p) } else { onOpenInNewTab?(b.entry.location) }
    }

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { InfoPanelController.show([u]) }
    }

    @objc private func menuRemove(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? String { SidebarStore.remove(t) }
    }

    @objc private func menuDisconnectRemote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let server = RemoteIntegration.shared.manager.server(id: id) else { return }
        RemoteIntegration.shared.disconnect(server)
    }

    @objc private func menuRemoveRemote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let server = RemoteIntegration.shared.manager.server(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(server.name)” from the sidebar?"
        alert.informativeText = "Its saved credentials are deleted from your Keychain. Files on the server aren’t affected."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let run = { RemoteIntegration.shared.remove(server) }
        if let w = view.window { alert.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { run() } } } else if alert.runModal() == .alertFirstButtonReturn { run() }
    }

    @objc private func menuEject(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { eject(u) }
    }

    @objc private func menuResetFavorites(_ sender: Any?) {
        BrowserDefaults.favorites = nil
        NotificationCenter.default.post(name: .browserFavoritesDidChange, object: nil)
    }
}

final class EntryBox: NSObject {
    let entry: SidebarViewController.Entry
    init(_ e: SidebarViewController.Entry) { entry = e }
}

@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarViewController?
    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu(for: event) }
}

@MainActor
final class SidebarRowView: NSTableRowView {
    var theme: Theme = ThemeManager.shared.current { didSet { needsDisplay = true } }

    var usesCustomSelection: Bool { SidebarViewController.usesCustomSelection(theme) || ThemeAccessibility.increaseContrast }

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { refreshCells() } }
    }

    override var isEmphasized: Bool {
        didSet { if oldValue != isEmphasized { refreshCells() } }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SidebarCellView)?.updateColors()
    }

    private func refreshCells() {
        for case let cell as SidebarCellView in subviews { cell.updateColors() }
    }

    func selectionRect() -> NSRect {
        ListRenderer.sidebarSelectionRect(for: bounds, compact: theme.layout.isAuthenticCompact)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard usesCustomSelection else {
            super.drawSelection(in: dirtyRect)
            return
        }
        let compact = theme.layout.isAuthenticCompact
        ListRenderer.drawSidebarSelection(in: bounds, theme: theme, compact: compact, cornerRadius: compact ? 0 : CGFloat(theme.metrics.cornerRadius))
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        usesCustomSelection ? .normal : super.interiorBackgroundStyle
    }
}

final class SidebarCellView: NSTableCellView {
    let ejectButton = NSButton()
    var onEject: (() -> Void)?
    static let contentLeading: CGFloat = 0
    static let iconSize: CGFloat = 16
    var normalTextColor: NSColor = .labelColor
    var selectedTextColor: NSColor = .alternateSelectedControlTextColor
    var normalIconColor: NSColor?
    private var iconGap: NSLayoutConstraint!
    private var textToEject: NSLayoutConstraint!
    private var textToEdge: NSLayoutConstraint!

    var iconTextGap: CGFloat {
        get { iconGap.constant }
        set { iconGap.constant = newValue }
    }

    var isEjectVisible: Bool { !ejectButton.isHidden }

    init() {
        super.init(frame: .zero)
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setAccessibilityElement(false)
        iv.imageScaling = .scaleProportionallyDown
        iv.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        ejectButton.isBordered = false
        ejectButton.imagePosition = .imageOnly
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.target = self
        ejectButton.action = #selector(ejectClicked(_:))
        ejectButton.isHidden = true
        ejectButton.toolTip = "Eject"
        addSubview(iv)
        addSubview(tf)
        addSubview(ejectButton)
        imageView = iv
        textField = tf
        iconGap = tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: Spacing.iconText)
        textToEject = tf.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -Spacing.xxs)
        textToEdge = tf.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentLeading),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iv.heightAnchor.constraint(equalToConstant: Self.iconSize),
            iconGap,
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
            textToEdge,
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: Spacing.hitTarget),
            ejectButton.heightAnchor.constraint(equalToConstant: Spacing.hitTarget).withPriority(.defaultHigh),
            ejectButton.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setEjectVisible(_ visible: Bool) {
        ejectButton.isHidden = !visible
        textToEdge.isActive = !visible
        textToEject.isActive = visible
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    var isShowingSelection: Bool {
        if let row = superview as? SidebarRowView, row.usesCustomSelection { return row.isSelected }
        return backgroundStyle == .emphasized
    }

    func updateColors() {
        let selected = isShowingSelection
        let text = selected ? selectedTextColor : normalTextColor
        textField?.textColor = text
        if let icon = normalIconColor { imageView?.contentTintColor = selected ? selectedTextColor : icon } else { imageView?.contentTintColor = nil }
        ejectButton.contentTintColor = text.withAlphaComponent(0.7)
    }

    @objc private func ejectClicked(_ sender: Any?) { onEject?() }
}
