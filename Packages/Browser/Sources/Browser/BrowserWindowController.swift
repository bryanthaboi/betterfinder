import AppKit
import FSCore
import FileOps
import Theming

@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSSearchFieldDelegate, NSSharingServicePickerToolbarItemDelegate, NSUserInterfaceValidations, NSToolbarItemValidation, ThemedSurface {
    public var location: BrowserLocation { activePane.location }
    public var destination: BrowserDestination { activePane.destination }
    private(set) var panes: [BrowserPaneController] = []
    private(set) var activePane: BrowserPaneController
    public let registries: BrowserRegistries
    let sidebarController: SidebarViewController
    private let splitController = BrowserSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private(set) var secondSidebar: SidebarViewController?
    private var secondSidebarItem: NSSplitViewItem?
    private var syncingSidebars = false
    private var lastSidebarWidth: CGFloat = 0
    private let paneSplit = NSSplitViewController()
    private let contentSplit = NSSplitViewController()
    private var contentHost: ContentHostViewController?
    private(set) var panelHost: PanelHostController?
    private weak var navControl: NSSegmentedControl?
    private weak var viewControl: NSSegmentedControl?
    private weak var searchItem: NSSearchToolbarItem?
    private var contributedTargets: [String: ContributedToolbarTarget] = [:]
    private var knownContributedIdentifiers: Set<String> = []
    private var activeSearchProvider: String?
    private let backMenu = NSMenu()
    private let forwardMenu = NSMenu()
    private let actionMenu = NSMenu()

    var onClose: (() -> Void)?
    var onBecomeActive: (() -> Void)?
    var isDualPane: Bool { panes.count > 1 }
    public let isVisor: Bool
    weak var manager: BrowserWindowManager?
    var tabDropHighlight: TabDropHighlight?
    private(set) var visorPinButton: NSButton?

    private enum ToolbarID {
        static let nav = NSToolbarItem.Identifier("nav")
        static let up = NSToolbarItem.Identifier("up")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let action = NSToolbarItem.Identifier("action")
        static let share = NSToolbarItem.Identifier("share")
        static let operations = NSToolbarItem.Identifier("operations")
        static let search = NSToolbarItem.Identifier("search")
    }

    static let operationsItemAddedKey = "toolbarOperationsItemAdded"
    static var iCloudDriveURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    public convenience init(location: BrowserLocation) {
        self.init(location: location, registries: BrowserRegistries.shared)
    }

    public convenience init(location: BrowserLocation, registries: BrowserRegistries) {
        self.init(location: location, registries: registries, visor: false)
    }

    public init(location: BrowserLocation, registries: BrowserRegistries, visor: Bool) {
        self.registries = registries
        self.isVisor = visor
        if registries === BrowserRegistries.shared { RemoteIntegration.installIfNeeded(into: registries) }
        sidebarController = SidebarViewController(registries: registries)
        let pane = BrowserPaneController(location: location, registries: registries)
        activePane = pane
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 560, height: 320)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = visor ? VisorLayout.tabbingIdentifier : "BetterFinderBrowser"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setAccessibilityLabel("Browser")
        buildContent()
        addPane(pane)
        setActive(pane)
        window.setContentSize(NSSize(width: 1040, height: 640))
        if visor { installVisorChrome(on: window) } else { window.setFrameAutosaveName("BrowserWindow") }
        buildToolbar()
        ThemedWindowChrome.install(on: window)
        paneLocationChanged(pane)
        wire(sidebarController)
        window.autorecalculatesKeyViewLoop = true
        window.onFirstResponderChange = { [weak self] responder in self?.firstResponderChanged(responder) }
        splitController.onToggleSidebar = { [weak self] in self?.matchSecondSidebarCollapse() }
        NotificationCenter.default.addObserver(self, selector: #selector(splitDidResize(_:)), name: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        window.onKeyBinding = { [weak self] event in self?.handleKeyBinding(event) ?? false }
        window.onTabDoubleClick = { [weak self] point in self?.handleTabDoubleClick(at: point) ?? false }
        window.registerForDraggedTypes(DropSupport.types)
        registries.toolbar.addObserver(self) { [weak self] in self?.syncContributedToolbar() }
        registries.searchProviders.addObserver(self) { [weak self] in self?.rebuildSearchMenu() }
        backMenu.delegate = self
        forwardMenu.delegate = self
        actionMenu.delegate = self
        observeThemeChanges()
    }

    required init?(coder: NSCoder) { fatalError() }

    public func applyTheme(_ theme: Theme) {
        guard let window else { return }
        if !Theme.isSystemToken(theme.colors.windowBg) { window.backgroundColor = Theme.color(theme.colors.windowBg) } else { window.backgroundColor = .windowBackgroundColor }
    }

    private func installVisorChrome(on window: BrowserWindow) {
        window.allowsOffscreenFrame = true
        window.isMovable = false
        window.isRestorable = false
        window.styleMask.remove(.miniaturizable)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = VisorLayout.level(aboveDock: VisorSettings.aboveDock)
        window.collectionBehavior = VisorLayout.collectionBehavior(allSpaces: VisorSettings.allSpaces)
        window.setAccessibilityLabel("Visor")
        let button = NSButton(title: "", target: self, action: #selector(toggleVisorPin(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = button
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        visorPinButton = button
        syncVisorPin()
        NotificationCenter.default.addObserver(self, selector: #selector(syncVisorPin), name: .visorPinDidChange, object: nil)
    }

    @objc public func toggleVisorPin(_ sender: Any?) {
        (manager?.visor ?? .shared).togglePinned()
    }

    @objc private func syncVisorPin() {
        guard let button = visorPinButton else { return }
        let pinned = VisorSettings.pinned
        button.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        button.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        button.toolTip = pinned ? "Pinned: the visor stays open when you switch apps" : "Keep the visor open when you switch apps"
        button.setAccessibilityLabel("Keep visor open")
        button.setAccessibilityValue(pinned ? "on" : "off")
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard isVisor, let visor = manager?.visor else { return frameSize }
        return visor.constrainedSize(frameSize, for: sender)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        guard isVisor, let window else { return }
        manager?.visor?.userResized(window)
    }

    private func wire(_ sidebar: SidebarViewController) {
        sidebar.onSelect = { [weak self, weak sidebar] loc in
            guard let self, let sidebar else { return }
            let pane = self.boundPane(for: sidebar)
            if pane !== self.activePane { self.setActive(pane) }
            pane.navigate(to: loc)
            if NSApp.currentEvent?.type != .keyDown { pane.focusVisibleContent() }
        }
        sidebar.onSelectProvided = { [weak self, weak sidebar] p in
            guard let self, let sidebar else { return }
            let pane = self.boundPane(for: sidebar)
            if pane !== self.activePane { self.setActive(pane) }
            pane.navigate(to: p)
            if NSApp.currentEvent?.type != .keyDown { pane.focusVisibleContent() }
        }
        sidebar.onOpenInNewTab = { [weak self] loc in self?.openInNewTab(loc) }
        sidebar.onOpenProvidedInNewTab = { [weak self] p in self?.openInNewTab(provided: p) }
        sidebar.onCommand = { [weak self] id, key in
            guard let self else { return }
            let owner = key.components(separatedBy: "/").first ?? BrowserOwner.builtIn
            self.registries.commands.run(CommandRegistry.reference(id, owner: owner), context: BrowserContext(controller: self))
        }
    }

    func boundPane(for sidebar: SidebarViewController) -> BrowserPaneController {
        guard let second = secondSidebar, let first = panes.first, let last = panes.last else { return activePane }
        return sidebar === second ? last : first
    }

    private func sidebar(for pane: BrowserPaneController) -> SidebarViewController? {
        guard let second = secondSidebar else { return pane === activePane ? sidebarController : nil }
        return pane === panes.first ? sidebarController : second
    }

    private func highlightSidebar(for pane: BrowserPaneController) {
        guard let sidebar = sidebar(for: pane) else { return }
        let dest = pane.destination
        if let p = dest.providedLocation { sidebar.highlight(provided: p) } else { sidebar.highlight(pane.location) }
    }

    @objc private func defaultsChanged() { updateSecondSidebar() }

    private func updateSecondSidebar() {
        let wanted = isDualPane && BrowserDefaults.dualPaneSidebars
        if wanted, secondSidebar == nil {
            let second = SidebarViewController(registries: registries)
            wire(second)
            let item = NSSplitViewItem(viewController: TrailingSidebarHost(sidebar: second))
            item.minimumThickness = 160
            item.maximumThickness = 340
            item.canCollapse = true
            item.holdingPriority = sidebarItem?.holdingPriority ?? NSLayoutConstraint.Priority(260)
            secondSidebar = second
            secondSidebarItem = item
            splitController.addSplitViewItem(item)
            item.isCollapsed = sidebarItem?.isCollapsed ?? false
            let width = sidebarItem?.viewController.view.frame.width ?? 0
            if width > 0, !item.isCollapsed {
                lastSidebarWidth = width
                window?.contentView?.layoutSubtreeIfNeeded()
                setSecondSidebarWidth(width)
            }
            for p in panes { highlightSidebar(for: p) }
        } else if !wanted, let second = secondSidebar {
            if let item = secondSidebarItem { splitController.removeSplitViewItem(item) }
            second.teardown()
            secondSidebar = nil
            secondSidebarItem = nil
            highlightSidebar(for: activePane)
        }
    }

    private func setSecondSidebarWidth(_ width: CGFloat) {
        let split = splitController.splitView
        let divider = splitController.splitViewItems.count - 2
        guard divider >= 0 else { return }
        split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: divider)
    }

    private func matchSecondSidebarCollapse() {
        guard let first = sidebarItem, let second = secondSidebarItem else { return }
        second.animator().isCollapsed = first.isCollapsed
    }

    var sidebarWidths: (first: CGFloat, second: CGFloat?) {
        (sidebarItem?.viewController.view.frame.width ?? 0, secondSidebarItem.map { $0.viewController.view.frame.width })
    }

    @objc private func splitDidResize(_ note: Notification) {
        guard !syncingSidebars, let first = sidebarItem, let second = secondSidebarItem, !first.isCollapsed, !second.isCollapsed else { return }
        let firstWidth = first.viewController.view.frame.width
        let secondWidth = second.viewController.view.frame.width
        guard firstWidth > 0, secondWidth > 0 else { return }
        guard abs(firstWidth - secondWidth) > 0.5 else { lastSidebarWidth = firstWidth; return }
        syncingSidebars = true
        defer { syncingSidebars = false }
        if abs(firstWidth - lastSidebarWidth) > 0.5 {
            setSecondSidebarWidth(firstWidth)
            lastSidebarWidth = firstWidth
        } else {
            splitController.splitView.setPosition(secondWidth, ofDividerAt: 0)
            lastSidebarWidth = secondWidth
        }
    }

    private func buildContent() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        self.sidebarItem = sidebarItem
        paneSplit.splitView.isVertical = true
        paneSplit.splitView.dividerStyle = .thin
        contentSplit.splitView.isVertical = false
        contentSplit.splitView.dividerStyle = .thin
        contentSplit.addSplitViewItem(NSSplitViewItem(viewController: paneSplit))
        let host = ContentHostViewController(contentSplit: contentSplit)
        contentHost = host
        let contentItem = NSSplitViewItem(viewController: host)
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "BrowserSplit"
        window?.contentViewController = splitController
        panelHost = PanelHostController(registries: registries, splitController: splitController, contentSplit: contentSplit, host: host)
    }

    private func addPane(_ pane: BrowserPaneController) {
        pane.windowController = self
        pane.onLocationChange = { [weak self] p in self?.paneLocationChanged(p) }
        pane.onSelectionChange = { [weak self] p in self?.paneSelectionChanged(p) }
        pane.onActivate = { [weak self] p in self?.setActive(p) }
        panes.append(pane)
        let item = NSSplitViewItem(viewController: pane)
        item.minimumThickness = 280
        paneSplit.addSplitViewItem(item)
        for p in panes { p.isActive = p === activePane }
        updatePaneTitles()
    }

    private func updatePaneTitles() {
        let dual = panes.count > 1
        for (i, p) in panes.enumerated() {
            p.paneTitle = dual ? (i == 0 ? "Left pane" : "Right pane") : "Browser"
            p.updateAccessibility()
        }
    }

    private func firstResponderChanged(_ responder: NSResponder?) {
        guard isDualPane, let view = responder as? NSView else { return }
        if let pane = panes.first(where: { view.isDescendant(of: $0.view) }), pane !== activePane { setActive(pane) }
    }

    private func setActive(_ pane: BrowserPaneController) {
        let changed = activePane !== pane
        activePane = pane
        for p in panes { p.isActive = p === pane }
        if changed { paneLocationChanged(pane) }
    }

    private func paneLocationChanged(_ pane: BrowserPaneController) {
        highlightSidebar(for: pane)
        guard pane === activePane else { return }
        let dest = pane.destination
        window?.title = dest.displayName
        let hidesProxy = HomeLabel.hidesProxy(for: dest.url)
        window?.representedURL = hidesProxy ? nil : dest.url
        if let url = dest.url, !hidesProxy {
            window?.standardWindowButton(.documentIconButton)?.image = IconCache.shared.fileIcon(url, size: 16)
        }
        window?.tab.title = dest.displayName
        syncViewModeControl()
        refreshContributedToolbarItems()
        syncSearchField()
        updateNavControl()
        window?.toolbar?.validateVisibleItems()
    }

    private func paneSelectionChanged(_ pane: BrowserPaneController) {
        guard pane === activePane else { return }
        window?.toolbar?.validateVisibleItems()
        refreshContributedToolbarItems()
    }

    func otherPane(than pane: BrowserPaneController) -> BrowserPaneController? {
        panes.first { $0 !== pane }
    }

    func syncViewModeControl() {
        guard let viewControl else { return }
        let supported = activePane.supportsViewModes
        viewControl.isEnabled = supported
        viewControl.selectedSegment = supported || activePane.remoteController == nil ? activePane.viewMode.rawValue : BrowserViewMode.list.rawValue
    }

    var searchAnchorView: NSView? { searchItem?.searchField }

    func syncSearchField() {
        guard let field = searchItem?.searchField, field.currentEditor() == nil else { return }
        field.stringValue = activePane.searchText
    }

    private func updateNavControl() {
        navControl?.setEnabled(!activePane.backStack.isEmpty, forSegment: 0)
        navControl?.setEnabled(!activePane.forwardStack.isEmpty, forSegment: 1)
    }


    private func buildToolbar() {
        let shared = registries === BrowserRegistries.shared
        let toolbar = NSToolbar(identifier: shared ? "BrowserToolbar2" : "BrowserToolbar2.\(ObjectIdentifier(registries).hashValue)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = shared
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        ensureOperationsItem(in: toolbar)
    }

    func ensureOperationsItem(in toolbar: NSToolbar) {
        let store = BrowserDefaults.store
        guard !store.bool(forKey: Self.operationsItemAddedKey) else { return }
        store.set(true, forKey: Self.operationsItemAddedKey)
        let ids = toolbar.items.map(\.itemIdentifier)
        guard !ids.contains(ToolbarID.operations) else { return }
        let index = ids.firstIndex(of: ToolbarID.search) ?? ids.count
        toolbar.insertItem(withItemIdentifier: ToolbarID.operations, at: index)
    }

    private static let baseToolbarIdentifiers: [String] = [
        NSToolbarItem.Identifier.toggleSidebar.rawValue, NSToolbarItem.Identifier.sidebarTrackingSeparator.rawValue,
        "nav", "up", NSToolbarItem.Identifier.flexibleSpace.rawValue, "viewMode", "action", "share", "operations", "search",
    ]

    private func insertionIndex(for placement: ToolbarItemSpec.Placement, in ids: [String]) -> Int {
        let beforeSearch = ids.firstIndex(of: "search") ?? ids.count
        switch placement {
        case .beforeSearch: return beforeSearch
        case .end: return ids.count
        case .after(let id): return ids.firstIndex(of: id).map { $0 + 1 } ?? beforeSearch
        case .before(let id): return ids.firstIndex(of: id) ?? beforeSearch
        }
    }

    func defaultToolbarIdentifierStrings() -> [String] {
        var ids = Self.baseToolbarIdentifiers
        for e in registries.toolbar.visibleEntries {
            ids.insert(registries.toolbar.toolbarIdentifier(for: e), at: insertionIndex(for: e.item.placement, in: ids))
        }
        return ids
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultToolbarIdentifierStrings().map { NSToolbarItem.Identifier($0) }
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func contributedToolbarIdentifiers() -> [String] {
        registries.toolbar.visibleEntries.map { registries.toolbar.toolbarIdentifier(for: $0) }
    }

    func syncContributedToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let desired = contributedToolbarIdentifiers()
        let desiredSet = Set(desired)
        for (index, item) in toolbar.items.enumerated().reversed() {
            let id = item.itemIdentifier.rawValue
            if knownContributedIdentifiers.contains(id), !desiredSet.contains(id) {
                toolbar.removeItem(at: index)
                contributedTargets[id] = nil
            }
        }
        var current = toolbar.items.map { $0.itemIdentifier.rawValue }
        for e in registries.toolbar.visibleEntries {
            let id = registries.toolbar.toolbarIdentifier(for: e)
            guard !current.contains(id) else { continue }
            let index = insertionIndex(for: e.item.placement, in: current)
            let at = max(0, min(index, toolbar.items.count - 1))
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(id), at: at)
            current.insert(id, at: min(at, current.count))
            knownContributedIdentifiers.insert(id)
        }
        refreshContributedToolbarItems()
    }

    func refreshContributedToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        let context = BrowserContext(controller: self)
        for item in toolbar.items {
            guard let target = contributedTargets[item.itemIdentifier.rawValue] else { continue }
            target.apply(to: item, context: context)
        }
    }

    func contributedToolbarItem(_ identifier: String) -> NSToolbarItem? {
        window?.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier }
    }

    private func makeContributedItem(_ id: NSToolbarItem.Identifier, entry: BrowserRegistry<ToolbarItemSpec>.Entry) -> NSToolbarItem {
        let spec = entry.item
        let target = ContributedToolbarTarget(controller: self, qualifiedID: entry.qualifiedID)
        contributedTargets[id.rawValue] = target
        knownContributedIdentifiers.insert(id.rawValue)
        let item: NSToolbarItem
        switch spec.kind {
        case .button:
            item = NSToolbarItem(itemIdentifier: id)
            item.target = target
            item.action = #selector(ContributedToolbarTarget.invoke(_:))
            item.isBordered = true
        case .menu:
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            let menu = NSMenu(title: spec.title)
            menu.delegate = target
            menuItem.menu = menu
            menuItem.showsIndicator = true
            item = menuItem
        }
        item.label = spec.title
        item.paletteLabel = spec.paletteLabel ?? spec.title
        item.toolTip = spec.toolTip
        if let symbol = spec.symbolName { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: spec.accessibilityLabel ?? spec.title) }
        item.view?.setAccessibilityLabel(spec.accessibilityLabel ?? spec.title)
        target.apply(to: item, context: BrowserContext(controller: self))
        return item
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.nav:
            let seg = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!,
            ], trackingMode: .momentary, target: self, action: #selector(navSegment(_:)))
            seg.segmentStyle = .separated
            seg.setMenu(backMenu, forSegment: 0)
            seg.setMenu(forwardMenu, forSegment: 1)
            seg.setToolTip("Back (⌘[) — hold for history", forSegment: 0)
            seg.setToolTip("Forward (⌘]) — hold for history", forSegment: 1)
            seg.setAccessibilityLabel("Back and Forward")
            navControl = seg
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = seg
            item.label = "Back/Forward"
            item.isNavigational = true
            item.menuFormRepresentation = submenuItem("Back/Forward", [
                ("Back", #selector(goBack(_:))),
                ("Forward", #selector(goForward(_:))),
            ])
            updateNavControl()
            return item
        case ToolbarID.up:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Enclosing Folder")
            item.label = "Up"
            item.paletteLabel = "Enclosing Folder"
            item.toolTip = "Enclosing Folder (⌘↑)"
            item.target = self
            item.action = #selector(goUp(_:))
            item.isBordered = true
            item.isNavigational = true
            return item
        case ToolbarID.viewMode:
            let seg = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
                NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")!,
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
            ], trackingMode: .selectOne, target: self, action: #selector(viewModeSegment(_:)))
            seg.selectedSegment = activePane.viewMode.rawValue
            seg.setToolTip("as List (⌘1)", forSegment: 0)
            seg.setToolTip("as Columns (⌘2)", forSegment: 1)
            seg.setToolTip("as Icons (⌘3)", forSegment: 2)
            seg.setAccessibilityLabel("View mode")
            viewControl = seg
            syncViewModeControl()
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = seg
            item.label = "View"
            item.menuFormRepresentation = submenuItem("View", [
                ("as List", #selector(asList(_:))),
                ("as Columns", #selector(asColumns(_:))),
                ("as Icons", #selector(asIcons(_:))),
            ])
            return item
        case ToolbarID.action:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
            item.label = "Action"
            item.toolTip = "Actions for the selection"
            item.menu = actionMenu
            item.showsIndicator = true
            return item
        case ToolbarID.operations:
            let indicator = OperationsIndicatorView(queue: .shared)
            indicator.setAccessibilityLabel("File operations")
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = indicator
            item.label = "Operations"
            item.paletteLabel = "File Operations"
            item.toolTip = "File operations in progress"
            return item
        case ToolbarID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            item.label = "Share"
            item.toolTip = "Share the selection"
            return item
        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = false
            item.searchField.placeholderString = "Search"
            item.searchField.setAccessibilityLabel("Search")
            item.searchField.searchMenuTemplate = searchScopeMenu()
            item.label = "Search"
            item.toolTip = "Search this folder (⌘F)"
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        default:
            guard let entry = registries.toolbar.entry(forToolbarIdentifier: id.rawValue) else { return nil }
            return makeContributedItem(id, entry: entry)
        }
    }

    public func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        activePane.selectedURLs.map { $0 as NSURL }
    }

    private func searchScopeMenu() -> NSMenu {
        let m = NSMenu(title: "Search")
        let header = NSMenuItem(title: "Search In", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        for (i, t) in ["This Folder", "Home", "This Mac"].enumerated() {
            let item = NSMenuItem(title: t, action: #selector(searchScopeChosen(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.indentationLevel = 1
            item.state = activeSearchProvider == nil && BrowserDefaults.searchScope.rawValue == i ? .on : .off
            m.addItem(item)
        }
        let providers = registries.searchProviders.visibleEntries
        if !providers.isEmpty {
            m.addItem(.separator())
            for e in providers {
                let item = NSMenuItem(title: e.item.title, action: #selector(searchProviderChosen(_:)), keyEquivalent: "")
                item.representedObject = e.qualifiedID
                item.target = self
                item.indentationLevel = 1
                item.state = activeSearchProvider == e.qualifiedID ? .on : .off
                if let symbol = e.item.symbolName { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: e.item.title) }
                m.addItem(item)
            }
        }
        return m
    }

    func rebuildSearchMenu() {
        if let active = activeSearchProvider, registries.searchProviders.entry(active) == nil { activeSearchProvider = nil }
        searchItem?.searchField.searchMenuTemplate = searchScopeMenu()
    }

    @objc private func searchProviderChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        activeSearchProvider = id
        searchItem?.searchField.searchMenuTemplate = searchScopeMenu()
        if let q = searchItem?.searchField.stringValue, !q.isEmpty { activePane.searchWithProvider(id, query: q) }
    }

    @objc private func searchScopeChosen(_ sender: NSMenuItem) {
        guard let s = SearchScopeKind(rawValue: sender.tag) else { return }
        activeSearchProvider = nil
        searchItem?.searchField.searchMenuTemplate = searchScopeMenu()
        BrowserDefaults.searchScope = s
        if let q = searchItem?.searchField.stringValue, !q.isEmpty { activePane.search(q, scope: s) }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        if let id = activeSearchProvider { activePane.searchWithProvider(id, query: sender.stringValue) } else { activePane.search(sender.stringValue) }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchItem?.searchField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)) {
            if let id = activeSearchProvider { activePane.searchWithProvider(id, query: control.stringValue) } else { activePane.search(control.stringValue) }
            activePane.focusVisibleContent()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            control.stringValue = ""
            activePane.endSearch()
            activePane.focusVisibleContent()
            return true
        }
        return false
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === backMenu || menu === forwardMenu {
            menu.removeAllItems()
            let stack = menu === backMenu ? activePane.backStack : activePane.forwardStack
            for (i, loc) in stack.enumerated().reversed().prefix(25) {
                let item = NSMenuItem(title: loc.displayName, action: #selector(historyChosen(_:)), keyEquivalent: "")
                item.tag = i
                item.representedObject = menu === backMenu ? "back" : "forward"
                item.target = self
                if let url = loc.url {
                    item.image = IconCache.shared.fileIcon(url, size: 16)
                }
                menu.addItem(item)
            }
        } else if menu === actionMenu {
            menu.removeAllItems()
            for item in ContextMenuBuilder.menu(for: activePane).items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }
    }

    @objc private func historyChosen(_ sender: NSMenuItem) {
        if (sender.representedObject as? String) == "back" { activePane.jumpBack(to: sender.tag) } else { activePane.jumpForward(to: sender.tag) }
        updateNavControl()
    }

    @objc private func navSegment(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        seg.selectedSegment == 0 ? goBack(seg) : goForward(seg)
    }

    @objc private func viewModeSegment(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        if let m = BrowserViewMode(rawValue: seg.selectedSegment) { setViewMode(m) }
    }

    private func submenuItem(_ title: String, _ entries: [(String, Selector)]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for (t, action) in entries {
            let m = NSMenuItem(title: t, action: action, keyEquivalent: "")
            m.target = self
            menu.addItem(m)
        }
        item.submenu = menu
        return item
    }

    func setViewMode(_ mode: BrowserViewMode) {
        guard activePane.supportsViewModes else {
            syncViewModeControl()
            return
        }
        activePane.setViewMode(mode)
        syncViewModeControl()
    }


    public func navigate(to newLocation: BrowserLocation, select: [URL] = []) {
        activePane.navigate(to: newLocation, select: select)
    }

    public func navigate(to provided: ProvidedLocation) {
        activePane.navigate(to: provided)
    }

    public var providedLocation: ProvidedLocation? { activePane.providedLocation }

    @objc public func connectToServer(_ sender: Any?) {
        let integration = RemoteIntegration.shared
        integration.install(into: registries)
        ConnectToServerSheet.present(for: window, integration: integration) { [weak self] loc in
            self?.activePane.navigate(to: loc)
        }
    }

    func openInNewTab(provided: ProvidedLocation) {
        BrowserWindowManager.shared.openTab(at: provided, nextTo: self)
    }

    func dispatch(_ action: Selector) {
        if responds(to: action) { _ = perform(action, with: nil) } else if activePane.responds(to: action) { _ = activePane.perform(action, with: nil) }
    }

    public func togglePanel(_ qualifiedID: String) { panelHost?.toggle(qualifiedID) }
    public func setPanel(_ qualifiedID: String, open: Bool, animated: Bool = true) { panelHost?.setOpen(qualifiedID, open, animated: animated) }
    public func isPanelOpen(_ qualifiedID: String) -> Bool { panelHost?.isOpen(qualifiedID) ?? false }

    @objc public func showCommandPalette(_ sender: Any?) {
        CommandPaletteController.show(for: self)
    }

    func handleKeyBinding(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event), let entry = registries.keyBindings.binding(for: chord) else { return false }
        let ref = CommandRegistry.reference(entry.item.commandID, owner: entry.owner)
        return registries.commands.run(ref, context: BrowserContext(controller: self))
    }

    public func select(_ urls: [URL]) {
        activePane.expectSelection(urls)
        activePane.focusVisibleContent()
    }

    func openInNewTab(_ loc: BrowserLocation, select: [URL] = []) {
        BrowserWindowManager.shared.openTab(at: loc, select: select, nextTo: self)
    }

    @objc public func goUp(_ sender: Any?) { activePane.goUp(); updateNavControl() }

    @objc public func goUpInNewTab(_ sender: Any?) {
        if let parent = activePane.providedParent { openInNewTab(provided: parent); return }
        guard let t = activePane.upTarget else { return }
        openInNewTab(t.location, select: t.select.map { [$0] } ?? [])
    }

    @objc public func goBack(_ sender: Any?) { activePane.goBack(); updateNavControl() }
    @objc public func goForward(_ sender: Any?) { activePane.goForward(); updateNavControl() }
    @objc public func goHome(_ sender: Any?) { activePane.navigate(to: .folder(FileManager.default.homeDirectoryForCurrentUser)) }
    @objc public func goComputer(_ sender: Any?) { activePane.navigate(to: .computer) }
    @objc public func goRecents(_ sender: Any?) { activePane.navigate(to: .recents) }

    private func goStandard(_ d: FileManager.SearchPathDirectory) {
        if let u = FileManager.default.urls(for: d, in: .userDomainMask).first { activePane.navigate(to: .folder(u)) }
    }

    @objc public func goDesktop(_ sender: Any?) { goStandard(.desktopDirectory) }
    @objc public func goDocuments(_ sender: Any?) { goStandard(.documentDirectory) }
    @objc public func goDownloads(_ sender: Any?) { goStandard(.downloadsDirectory) }
    @objc public func goApplications(_ sender: Any?) { activePane.navigate(to: .folder(URL(fileURLWithPath: "/Applications"))) }

    @objc public func goICloud(_ sender: Any?) {
        let u = Self.iCloudDriveURL
        if FileManager.default.fileExists(atPath: u.path) {
            activePane.navigate(to: .folder(u))
        } else {
            activePane.showNotice("iCloud Drive isn’t available. Turn on iCloud Drive in System Settings to browse it here.")
        }
    }

    @objc public func refresh(_ sender: Any?) { activePane.refresh(sender) }

    @objc public func newTab(_ sender: Any?) {
        switch activePane.destination {
        case .local(let l): openInNewTab(l)
        case .provided(let p): openInNewTab(provided: p)
        }
    }

    public override func newWindowForTab(_ sender: Any?) { newTab(sender) }

    @objc public func newFolder(_ sender: Any?) { activePane.newFolder(sender) }
    @objc public func newFile(_ sender: Any?) { activePane.newFile(sender) }
    @objc public func newTextDocument(_ sender: Any?) { activePane.newTextDocument(sender) }
    @objc public func newMarkdownDocument(_ sender: Any?) { activePane.newMarkdownDocument(sender) }
    @objc public func newEmptyFile(_ sender: Any?) { activePane.newEmptyFile(sender) }

    @objc public func asList(_ sender: Any?) { setViewMode(.list) }
    @objc public func asColumns(_ sender: Any?) { setViewMode(.column) }
    @objc public func asIcons(_ sender: Any?) { setViewMode(.icon) }

    @objc public func focusPathBar(_ sender: Any?) { beginPathEditing() }
    @objc public func goToFolder(_ sender: Any?) { beginPathEditing() }

    private func beginPathEditing() {
        guard activePane.providedLocation == nil else {
            activePane.showNotice(activePane.remoteController != nil
                ? "Typing a path isn’t available on servers. Use Copy Path (⌥⌘C) to copy the server path."
                : "Typing a path isn’t available in “\(activePane.destination.displayName)”.")
            return
        }
        activePane.pathBar.beginEditing()
    }

    @objc public func focusSearch(_ sender: Any?) {
        guard let item = searchItem else { return }
        item.beginSearchInteraction()
        window?.makeFirstResponder(item.searchField)
    }

    @objc public func toggleHiddenFiles(_ sender: Any?) { activePane.toggleHiddenFiles(sender) }
    @objc public func getInfo(_ sender: Any?) { activePane.getInfo(sender) }
    @objc public func miniInfo(_ sender: Any?) { activePane.miniInfo(sender) }
    @objc public func copyPath(_ sender: Any?) { activePane.copyPath(sender) }
    @objc public func toggleFoldersFirst(_ sender: Any?) { activePane.toggleFoldersFirst(sender) }
    @objc public func openInTerminal(_ sender: Any?) { activePane.openInTerminal(sender) }
    @objc public func copyToOtherPane(_ sender: Any?) { activePane.copyToOtherPane(sender) }
    @objc public func moveToOtherPane(_ sender: Any?) { activePane.moveToOtherPane(sender) }

    @objc public func increaseIconSize(_ sender: Any?) { adjustIconSize(16) }
    @objc public func decreaseIconSize(_ sender: Any?) { adjustIconSize(-16) }

    private func adjustIconSize(_ delta: Double) {
        BrowserDefaults.iconSize += delta
        for p in panes { p.statusBar.iconSize = BrowserDefaults.iconSize }
        NotificationCenter.default.post(name: .browserViewOptionsDidChange, object: nil)
    }

    @objc public func toggleDualPane(_ sender: Any?) {
        if isDualPane {
            let keep = activePane
            for p in panes where p !== keep {
                if let item = paneSplit.splitViewItems.first(where: { $0.viewController === p }) { paneSplit.removeSplitViewItem(item) }
                p.close()
            }
            panes = [keep]
            setActive(keep)
            keep.isActive = true
            updatePaneTitles()
        } else {
            let second = BrowserPaneController(location: activePane.location, viewMode: activePane.viewMode, registries: registries)
            addPane(second)
            for p in panes { p.isActive = p === activePane }
        }
        updateSecondSidebar()
        refreshContributedToolbarItems()
        activePane.focusVisibleContent()
    }

    @objc public func switchPane(_ sender: Any?) {
        guard isDualPane, let other = otherPane(than: activePane) else { return }
        setActive(other)
        other.focusVisibleContent()
    }

    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if activePane.responds(to: action) { return activePane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(goUp(_:)), #selector(goUpInNewTab(_:)): return activePane.canGoUp
        case #selector(goBack(_:)): return !activePane.backStack.isEmpty
        case #selector(goForward(_:)): return !activePane.forwardStack.isEmpty
        case #selector(newFolder(_:)): return activePane.canCreateFolder
        case #selector(newFile(_:)), #selector(newTextDocument(_:)), #selector(newMarkdownDocument(_:)), #selector(newEmptyFile(_:)): return activePane.canCreateFile
        case #selector(openInTerminal(_:)): return activePane.terminalTarget != nil
        case #selector(switchPane(_:)): return isDualPane
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)): return isDualPane && activePane.canSendToOtherPane(move: item.action == #selector(moveToOtherPane(_:)))
        case #selector(focusPathBar(_:)), #selector(goToFolder(_:)): return activePane.providedLocation == nil
        case #selector(asList(_:)), #selector(asColumns(_:)), #selector(asIcons(_:)):
            let mode: BrowserViewMode = item.action == #selector(asList(_:)) ? .list : (item.action == #selector(asColumns(_:)) ? .column : .icon)
            (item as? NSMenuItem)?.state = activePane.supportsViewModes && activePane.viewMode == mode ? .on : .off
            return activePane.supportsViewModes
        case #selector(toggleDualPane(_:)):
            (item as? NSMenuItem)?.state = isDualPane ? .on : .off
            return true
        case #selector(toggleHiddenFiles(_:)):
            (item as? NSMenuItem)?.title = BrowserDefaults.showHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return true
        case #selector(toggleFoldersFirst(_:)):
            (item as? NSMenuItem)?.state = BrowserDefaults.sort.foldersFirst ? .on : .off
            return true
        default: return true
        }
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validateUserInterfaceItem(item)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        updateNavControl()
        onBecomeActive?()
    }

    public func windowDidBecomeMain(_ notification: Notification) {
        onBecomeActive?()
    }

    public func windowWillClose(_ notification: Notification) {
        (window as? BrowserWindow)?.onFirstResponderChange = nil
        (window as? BrowserWindow)?.onKeyBinding = nil
        registries.toolbar.removeObserver(self)
        registries.searchProviders.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView)
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .visorPinDidChange, object: nil)
        tabDropHighlight?.removeFromSuperview()
        tabDropHighlight = nil
        sidebarController.teardown()
        secondSidebar?.teardown()
        panelHost?.tearDown()
        for p in panes { p.close() }
        onClose?()
        MemoryRelief.schedule()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if FileOperationQueue.shared.undoManager == nil { FileOperationQueue.shared.undoManager = UndoManager() }
        return FileOperationQueue.shared.undoManager
    }
}


@MainActor
final class ContributedToolbarTarget: NSObject, NSMenuDelegate, NSToolbarItemValidation {
    private weak var controller: BrowserWindowController?
    let qualifiedID: String

    init(controller: BrowserWindowController, qualifiedID: String) {
        self.controller = controller
        self.qualifiedID = qualifiedID
    }

    private var entry: BrowserRegistry<ToolbarItemSpec>.Entry? { controller?.registries.toolbar.entry(qualifiedID) }

    @objc func invoke(_ sender: Any?) {
        guard let controller, let entry else { return }
        let context = BrowserContext(controller: controller)
        if let action = entry.item.action {
            action(context)
        } else if let ref = entry.item.commandID {
            controller.registries.commands.run(CommandRegistry.reference(ref, owner: entry.owner), context: context)
        }
    }

    func apply(to item: NSToolbarItem, context: BrowserContext) {
        guard let entry else { return }
        let spec = entry.item
        let look = spec.appearance?(context)
        let title = look?.title ?? spec.title
        item.label = title
        item.toolTip = look?.toolTip ?? spec.toolTip
        if let symbol = look?.symbolName ?? spec.symbolName {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: look?.accessibilityLabel ?? spec.accessibilityLabel ?? title)
        }
        item.view?.setAccessibilityLabel(look?.accessibilityLabel ?? spec.accessibilityLabel ?? title)
        var enabled = look?.isEnabled ?? true
        if spec.action == nil, let ref = spec.commandID, let controller {
            enabled = enabled && controller.registries.commands.isEnabled(CommandRegistry.reference(ref, owner: entry.owner), context: context)
        }
        item.isEnabled = enabled
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let controller, let entry else { return false }
        let context = BrowserContext(controller: controller)
        let look = entry.item.appearance?(context)
        var enabled = look?.isEnabled ?? true
        if entry.item.action == nil, let ref = entry.item.commandID {
            enabled = enabled && controller.registries.commands.isEnabled(CommandRegistry.reference(ref, owner: entry.owner), context: context)
        }
        return enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller, let entry, case .menu(let builder) = entry.item.kind else { return }
        menu.removeAllItems()
        let context = BrowserContext(controller: controller)
        for item in ContributionMenus.items(from: builder(context), owner: entry.owner, context: context, registries: controller.registries) { menu.addItem(item) }
    }
}
