import AppKit
import FSCore
import FileOps
import Quartz
import Remote
import Theming

@MainActor
final class BrowserPaneController: NSViewController, NSMenuItemValidation, ThemedSurface {
    private(set) var location: BrowserLocation
    private(set) var model: FolderModel
    let sizes = SizeCoordinator()
    private(set) var backStack: [BrowserDestination] = []
    private(set) var forwardStack: [BrowserDestination] = []
    let registries: BrowserRegistries
    let pathBar = PathBarView()
    let statusBar: StatusBarView
    private(set) var providedLocation: ProvidedLocation?
    private var aux: PaneAuxViewController?
    private var remote: RemoteBrowserViewController?
    var remoteController: RemoteBrowserViewController? { remote }
    private var customPreview: PreviewPanelController?
    private let contentContainer = NSView()
    private(set) var viewMode: BrowserViewMode
    private(set) var content: BrowserContentController
    private var pendingSelection: [URL] = []
    private var pendingRename: URL?
    private var searchOrigin: BrowserLocation?
    private var sizeRequestScheduled = false
    private var sortBySizeScheduled = false
    private var activeIndicator = NSView()
    private var announcesNavigation = false
    private(set) var lastNotice: String?
    static var announcer: @MainActor (String, NSView?) -> Void = { text, view in
        NSAccessibility.post(element: view?.window ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    static var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    weak var windowController: BrowserWindowController?
    var onLocationChange: ((BrowserPaneController) -> Void)?
    var onSelectionChange: ((BrowserPaneController) -> Void)?
    var onActivate: ((BrowserPaneController) -> Void)?

    var isActive = false {
        didSet {
            pathBar.isActive = isActive
            activeIndicator.isHidden = !isActive || !(windowController?.isDualPane ?? false)
            updateAccessibility()
        }
    }

    var paneTitle: String = "Browser" { didSet { updateAccessibility() } }

    func updateAccessibility() {
        guard isViewLoaded else { return }
        view.setAccessibilityLabel(paneTitle)
        let name = destination.displayName
        view.setAccessibilityValue(windowController?.isDualPane == true ? (isActive ? "Active, \(name)" : name) : name)
        content.updateAccessibility(location: location)
    }

    func close() {
        registries.browserViews.removeObserver(self)
        registries.locations.removeObserver(self)
        registries.searchProviders.removeObserver(self)
        aux?.stop()
        remote?.stop()
        customPreview?.close()
        content.teardown()
        sizes.reset()
        sizes.enabled = false
        statusBar.stop()
        detach(model)
        model.stop()
    }

    init(location: BrowserLocation, viewMode: BrowserViewMode = BrowserDefaults.viewMode, registries: BrowserRegistries? = nil) {
        let loc = location.normalized
        let registries = registries ?? .shared
        self.registries = registries
        self.statusBar = StatusBarView(registries: registries)
        self.location = loc
        self.model = FolderModel(location: loc)
        self.viewMode = viewMode
        self.content = Self.makeContent(viewMode)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeContent(_ mode: BrowserViewMode) -> BrowserContentController {
        switch mode {
        case .list: return ListViewController()
        case .column: return ColumnViewController()
        case .icon: return IconViewController()
        }
    }

    override func loadView() {
        let root = PaneRootView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.onMouseDown = { [weak self] in
            guard let self else { return }
            self.onActivate?(self)
        }
        view = root
        for v in [pathBar, contentContainer, statusBar, activeIndicator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        activeIndicator.wantsLayer = true
        activeIndicator.isHidden = true
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBarHeight,
            activeIndicator.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            activeIndicator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activeIndicator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activeIndicator.heightAnchor.constraint(equalToConstant: 2),
            contentContainer.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBarHeight,
        ])
        pathBar.onNavigate = { [weak self] loc, sel in self?.navigate(to: loc, select: sel) }
        pathBar.onScopeChange = { [weak self] scope in self?.changeSearchScope(scope) }
        pathBar.onEndEditing = { [weak self] in self?.focusVisibleContent() }
        statusBar.onIconSizeChange = { size in
            BrowserDefaults.iconSize = size
            NotificationCenter.default.post(name: .browserViewOptionsDidChange, object: nil)
        }
        statusBar.contextProvider = { [weak self] in
            guard let self else { return BrowserContext(location: .computer) }
            return BrowserContext(pane: self)
        }
        sizes.onUpdate = { [weak self] key in self?.sizeUpdated(key) }
        installContent(content)
        attach(model)
        content.locationDidChange()
        pathBar.update(location: location)
        model.start()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sortDidChange), name: .browserSortDidChange, object: nil)
        nc.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeWillEject(_:)), name: .browserVolumeWillEject, object: nil)
        nc.addObserver(self, selector: #selector(renameEnded), name: .browserRenameDidEnd, object: nil)
        nc.addObserver(self, selector: #selector(iconsInvalidated), name: .browserIconsDidInvalidate, object: nil)
        registries.browserViews.addObserver(self) { [weak self] in self?.refreshAux() }
        registries.locations.addObserver(self) { [weak self] in self?.refreshAux() }
        registries.searchProviders.addObserver(self) { [weak self] in self?.refreshAux() }
        lastShowHidden = BrowserDefaults.showHidden
        lastFoldersFirst = BrowserDefaults.sort.foldersFirst
        observeThemeChanges()
        updateStatus()
        updateAccessibility()
    }

    private lazy var pathBarHeight = pathBar.heightAnchor.constraint(equalToConstant: ThemeManager.shared.layout.pathBarHeight)
    private lazy var statusBarHeight = statusBar.heightAnchor.constraint(equalToConstant: ThemeManager.shared.layout.statusBarHeight)

    func applyTheme(_ theme: Theme) {
        let lay = theme.layout
        if pathBarHeight.constant != lay.pathBarHeight { pathBarHeight.constant = lay.pathBarHeight }
        if statusBarHeight.constant != lay.statusBarHeight { statusBarHeight.constant = lay.statusBarHeight }
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.listBackground.cgColor
        activeIndicator.layer?.backgroundColor = theme.accentColor.cgColor
        content.applyTheme(theme)
    }

    private var lastShowHidden = false
    private var lastFoldersFirst = false

    @objc private func defaultsChanged() {
        let hidden = BrowserDefaults.showHidden
        if hidden != lastShowHidden {
            lastShowHidden = hidden
            remote?.reload()
            pendingSelection = selectedURLs
            model.load()
        }
        let ff = BrowserDefaults.sort.foldersFirst
        if ff != lastFoldersFirst {
            lastFoldersFirst = ff
            remote?.applySharedSort()
            content.prepareForResort()
            model.updateSort(BrowserDefaults.sort)
        }
    }

    @objc private func sortDidChange() {
        remote?.applySharedSort()
        let spec = BrowserDefaults.sort
        guard spec != model.sorter.spec else { return }
        pendingSelection = selectedURLs
        content.prepareForResort()
        model.updateSort(spec)
        content.refreshDisplay()
    }

    func customSortValuesChanged(_ values: [String: ColumnValue]) {
        pendingSelection = selectedURLs
        model.updateCustomValues(values)
    }

    @objc private func volumeWillEject(_ note: Notification) {
        guard let vol = note.object as? URL, let scope = location.scopeURL else { return }
        if scope.pathKey == vol.pathKey || vol.isAncestor(of: scope) {
            navigate(to: .computer, select: [vol], record: false)
        }
    }

    private func installContent(_ c: BrowserContentController) {
        c.pane = self
        addChild(c)
        c.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(c.view)
        NSLayoutConstraint.activate([
            c.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            c.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            c.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            c.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        statusBar.showsIconSlider = viewMode == .icon
        statusBar.iconSize = BrowserDefaults.iconSize
    }

    var supportsViewModes: Bool { remote == nil && aux == nil }

    private func reconcileContentVisibility() {
        content.view.isHidden = remote != nil || aux != nil
    }

    func setViewMode(_ mode: BrowserViewMode) {
        BrowserDefaults.viewMode = mode
        guard mode != viewMode else { reconcileContentVisibility(); return }
        let sel = selectedURLs
        let hadFocus = isContentFocused
        let old = content
        old.teardown()
        old.pane = nil
        old.view.removeFromSuperview()
        old.removeFromParent()
        viewMode = mode
        let c = Self.makeContent(mode)
        content = c
        installContent(c)
        c.applyTheme(ThemeManager.shared.current)
        c.locationDidChange()
        c.modelDidChange(.reset)
        c.updateAccessibility(location: location)
        reconcileContentVisibility()
        if !sel.isEmpty { c.select(sel, scroll: true) }
        if supportsViewModes, hadFocus || view.window?.firstResponder == view.window { c.focus() }
        scheduleSizeRequest()
        updateStatus()
        onLocationChange?(self)
    }

    var isContentFocused: Bool {
        guard let fr = view.window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: content.view)
    }

    var visibleContentView: NSView {
        if let remote { return remote.table }
        if let aux { return aux.view }
        return content.view
    }

    @discardableResult
    func focusVisibleContent() -> Bool {
        guard isViewLoaded, let window = view.window else { return false }
        if let remote { return window.makeFirstResponder(remote.table) }
        if let aux {
            guard let target = PanelContentViewController.firstKeyView(in: aux.view) ?? Self.firstAcceptingResponder(in: aux.view) else { return false }
            return window.makeFirstResponder(target)
        }
        content.focus()
        guard let fr = window.firstResponder as? NSView else { return false }
        return fr === content.view || fr.isDescendant(of: content.view)
    }

    private static func firstAcceptingResponder(in view: NSView) -> NSView? {
        for sub in view.subviews where !sub.isHidden {
            if sub.acceptsFirstResponder { return sub }
            if let found = firstAcceptingResponder(in: sub) { return found }
        }
        return nil
    }


    var selectedItems: [FileItem] { content.selectedItems }
    var selectedURLs: [URL] { content.selectedURLs }

    var destination: BrowserDestination {
        providedLocation.map(BrowserDestination.provided) ?? .local(location)
    }

    func navigate(to newLocation: BrowserLocation, select: [URL] = [], record: Bool = true, reuse: FolderModel? = nil) {
        let target = newLocation.normalized
        guard target != location || providedLocation != nil else {
            if !select.isEmpty { content.select(select, scroll: true) }
            return
        }
        if record {
            pushHistory(destination)
            announcesNavigation = true
        }
        if target.isVirtual && !location.isVirtual && providedLocation == nil { searchOrigin = location }
        load(target, select: select, reuse: reuse)
    }

    func navigate(to provided: ProvidedLocation, record: Bool = true) {
        guard provided != providedLocation else {
            if let r = remote, r.showsDisconnected { r.reconnect() }
            return
        }
        if record {
            pushHistory(destination)
            announcesNavigation = true
        }
        enterProvided(provided)
    }

    func navigate(to destination: BrowserDestination, record: Bool = true) {
        switch destination {
        case .local(let l): navigate(to: l, record: record)
        case .provided(let p): navigate(to: p, record: record)
        }
    }

    private func pushHistory(_ entry: BrowserDestination) {
        backStack.append(entry)
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack.removeAll()
    }

    private func enterProvided(_ p: ProvidedLocation) {
        if RemoteIntegration.shared.isDisconnected(providerID: p.providerID) { RemoteIntegration.shared.reconnect(providerID: p.providerID) }
        providedLocation = p
        pendingSelection = []
        pendingRename = nil
        pathBar.showProvided(title: p.title, symbolName: p.symbolName, path: p.resourceID.map(RemoteBrowserViewController.serverPath(for:)))
        refreshAux()
        updateStatus()
        updateAccessibility()
        onLocationChange?(self)
    }

    private func resourceLocationProvider(for p: ProvidedLocation) -> ResourceLocationProvider? {
        guard p.kind == .container, p.resourceID != nil, registries.browserViews.entry(matching: .provided(p)) == nil else { return nil }
        return registries.locations.provider(for: p.providerID) as? ResourceLocationProvider
    }

    private func refreshRemote() -> Bool {
        guard let p = providedLocation, let lp = resourceLocationProvider(for: p) else {
            if let r = remote {
                r.stop()
                r.view.removeFromSuperview()
                r.removeFromParent()
                remote = nil
            }
            return false
        }
        if let r = remote, r.location == p, r.locationProvider.resourceProvider === lp.resourceProvider { return true }
        let hadFocus = view.window?.firstResponder === remote?.table || isContentFocused
        if let r = remote {
            r.stop()
            r.view.removeFromSuperview()
            r.removeFromParent()
        }
        aux?.stop()
        aux?.view.removeFromSuperview()
        aux?.removeFromParent()
        aux = nil
        sizes.reset()
        let vc = RemoteBrowserViewController(location: p, provider: lp)
        vc.pane = self
        vc.onNavigate = { [weak self] loc in self?.navigate(to: loc) }
        vc.onStateChange = { [weak self, weak vc] in
            guard let self else { return }
            self.updateStatus()
            if let vc, vc === self.remote, !vc.isLoading { self.announceNavigationIfNeeded(count: vc.items.count, error: vc.loadError) }
        }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        content.view.isHidden = true
        remote = vc
        vc.start()
        if hadFocus || isActive { vc.focus() }
        return true
    }

    func refreshAux() {
        defer { windowController?.syncViewModeControl() }
        if refreshRemote() { return }
        let dest = destination
        var wanted: BrowserDestination?
        if providedLocation != nil || registries.browserViews.entry(matching: dest) != nil { wanted = dest }
        let wantedSpec = wanted.flatMap { registries.browserViews.entry(matching: $0)?.qualifiedID }
        if let aux, let wanted, aux.destination == wanted, aux.specID == wantedSpec { return }
        aux?.stop()
        aux?.view.removeFromSuperview()
        aux?.removeFromParent()
        aux = nil
        content.view.isHidden = false
        guard let wanted else { return }
        let vc = PaneAuxViewController(destination: wanted, registries: registries)
        vc.onNavigate = { [weak self] d in self?.navigate(to: d) }
        vc.onOpenLocal = { [weak self] url in self?.openLocalResult(url) }
        vc.onStateChange = { [weak self, weak vc] in
            guard let self else { return }
            self.updateStatus()
            if let vc, vc === self.aux, !vc.isLoading { self.announceNavigationIfNeeded(count: vc.itemCount, error: nil) }
        }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        content.view.isHidden = true
        aux = vc
        vc.start()
    }

    var auxItemCount: Int { remote?.items.count ?? aux?.itemCount ?? 0 }
    var auxViewController: NSViewController? { aux }

    private func openLocalResult(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            navigate(to: .folder(url))
        } else {
            navigate(to: .folder(url.deletingLastPathComponent()), select: [url])
        }
    }

    private func load(_ newLocation: BrowserLocation, select: [URL], reuse: FolderModel?) {
        let hadProvided = providedLocation != nil
        providedLocation = nil
        if hadProvided { refreshAux() }
        let old = model
        detach(old)
        location = newLocation
        let m = reuse ?? FolderModel(location: newLocation, sort: BrowserDefaults.sort)
        model = m
        sizes.reset()
        deferredReset = false
        pendingSelection = select
        pendingRename = nil
        attach(m)
        content.locationDidChange()
        if reuse != nil {
            content.modelDidChange(.reset)
            applyPendingSelection()
        }
        m.start()
        if !content.usesModel(old) { old.stop() }
        pathBar.update(location: newLocation)
        refreshAux()
        if let url = newLocation.url { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        updateStatus()
        scheduleSizeRequest()
        updateAccessibility()
        onLocationChange?(self)
    }

    private func attach(_ m: FolderModel) {
        m.addObserver(self) { [weak self] change in self?.modelChanged(change) }
        m.onFSEvents = { [weak self] batch in self?.handleFSEvents(batch) }
        m.onRootGone = { [weak self] in self?.rootGone() }
        m.onLoadingChange = { [weak self] in
            guard let self else { return }
            self.updateStatus()
            if !self.model.isLoading {
                self.applyPendingSelection(final: true)
                self.harvestTags()
                if self.providedLocation == nil, self.aux == nil { self.announceNavigationIfNeeded(count: self.model.items.count, error: self.model.error) }
            }
        }
    }

    private func announceNavigationIfNeeded(count: Int, error: Error?) {
        guard announcesNavigation else { return }
        announcesNavigation = false
        guard isActive || windowController == nil else { return }
        Self.announcer(Self.navigationAnnouncement(destination.displayName, count: count, error: error), view)
    }

    static func navigationAnnouncement(_ name: String, count: Int, error: Error?) -> String {
        if let error { return "\(name), can’t be read: \(error.localizedDescription)" }
        switch count {
        case 0: return "\(name), empty"
        case 1: return "\(name), 1 item"
        default: return "\(name), \(count) items"
        }
    }

    func showNotice(_ message: String, relativeTo anchor: NSView? = nil) {
        lastNotice = message
        if let target = [anchor, pathBar].compactMap({ $0 }).first(where: { $0.window != nil }) {
            InlineWarning.show(message, relativeTo: target)
        } else {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func harvestTags() {
        guard !location.isVirtual else { return }
        let items = model.items
        DispatchQueue.global(qos: .utility).async {
            let tags = DirectoryStream.harvestTags(items)
            guard !tags.isEmpty else { return }
            onMain { BrowserDefaults.noteTags(tags.sorted()) }
        }
    }

    private func detach(_ m: FolderModel) {
        m.removeObserver(self)
        m.onFSEvents = nil
        m.onRootGone = nil
        m.onLoadingChange = nil
    }

    private var deferredReset = false

    @objc private func iconsInvalidated() {
        content.refreshDisplay()
        pathBar.update(location: location)
    }

    @objc private func renameEnded() {
        guard deferredReset else { return }
        deferredReset = false
        content.modelDidChange(.reset)
        applyPendingSelection()
        updateStatus()
    }

    private func modelChanged(_ change: FolderModel.Change) {
        if RenameSession.isEditing(in: content.view) {
            deferredReset = true
            updateStatus()
            return
        }
        content.modelDidChange(change)
        applyPendingSelection()
        updateStatus()
        scheduleSizeRequest()
    }

    func expectSelection(_ urls: [URL], rename: Bool = false) {
        pendingSelection = urls
        pendingRename = rename ? urls.first : nil
        applyPendingSelection()
    }

    private func applyPendingSelection(final: Bool = false) {
        guard !pendingSelection.isEmpty else { return }
        let keys = Set(model.items.map(\.url.pathKey))
        let allFound = pendingSelection.allSatisfy { keys.contains($0.pathKey) }
        guard allFound || final else { return }
        let sel = pendingSelection
        pendingSelection = []
        content.select(sel, scroll: true)
        if let r = pendingRename, keys.contains(r.pathKey) {
            pendingRename = nil
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.content.beginRename(r) } }
        }
    }

    private func handleFSEvents(_ batch: FolderModel.FSEventBatch) {
        let paths = batch.paths
        Task.detached(priority: .utility) {
            for p in paths { await SizeEngine.shared.invalidate(path: p) }
        }
        if let root = location.url?.pathKey {
            for p in paths { sizes.invalidateContaining(path: p, under: root) }
        }
        for p in paths { IconCache.shared.invalidate(URL(fileURLWithPath: p)) }
        if !batch.directories.isEmpty { content.childDirectoryEvents(batch.directories) }
        if batch.paths.contains(where: { p in selectedURLs.contains { $0.pathKey == p } }) { updateStatus() }
    }

    private func rootGone() {
        guard var url = location.url else { return }
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url = url.deletingLastPathComponent() }
        navigate(to: .folder(url), record: false)
    }

    private func restore(_ dest: BrowserDestination, select: [URL]) {
        switch dest {
        case .local(let l): load(l, select: select, reuse: nil)
        case .provided(let p): enterProvided(p)
        }
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        announcesNavigation = true
        let from = destination
        forwardStack.append(from)
        restore(prev, select: from.url.map { [$0] } ?? [])
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        announcesNavigation = true
        backStack.append(destination)
        restore(next, select: [])
    }

    func jumpBack(to index: Int) {
        guard index >= 0, index < backStack.count else { return }
        let target = backStack[index]
        announcesNavigation = true
        let from = destination
        forwardStack.append(from)
        forwardStack.append(contentsOf: backStack[(index + 1)...].reversed())
        backStack.removeSubrange(index...)
        restore(target, select: from.url.map { [$0] } ?? [])
    }

    func jumpForward(to index: Int) {
        guard index >= 0, index < forwardStack.count else { return }
        let target = forwardStack[index]
        announcesNavigation = true
        backStack.append(destination)
        backStack.append(contentsOf: forwardStack[(index + 1)...].reversed())
        forwardStack.removeSubrange(index...)
        restore(target, select: [])
    }

    var upTarget: (location: BrowserLocation, select: URL?)? {
        guard providedLocation == nil else { return nil }
        return location.parent(selected: location.isVirtual ? selectedURLs.first : nil)
    }

    var providedParent: ProvidedLocation? {
        guard let p = providedLocation else { return nil }
        return registries.locations.provider(for: p.providerID)?.parent(of: p)
    }

    var canGoUp: Bool {
        providedLocation != nil ? providedParent != nil : upTarget != nil
    }

    func goUp() {
        if providedLocation != nil {
            if let parent = providedParent { navigate(to: parent) }
            return
        }
        guard let t = upTarget else { return }
        navigate(to: t.location, select: t.select.map { [$0] } ?? [])
    }


    var searchText: String {
        if let p = providedLocation, p.kind == .search { return p.id }
        return location.searchQuery ?? ""
    }

    func search(_ query: String, scope: SearchScopeKind? = nil) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { endSearch(); return }
        let kind = scope ?? BrowserDefaults.searchScope
        if kind == .folder, let p = providedLocation, p.kind == .container {
            showNotice(remote != nil ? "Search isn’t available on this server. Choose Home or This Mac in the search menu to search your Mac." : "Search isn’t available in “\(p.title)”. Choose Home or This Mac in the search menu to search your Mac.",
                       relativeTo: windowController?.searchAnchorView)
            return
        }
        let base: URL
        switch kind {
        case .folder:
            if case .search(let s, _) = location, let o = searchOrigin?.url, s.pathKey == "/" || s.pathKey == FileManager.default.homeDirectoryForCurrentUser.pathKey {
                base = o
            } else {
                base = (location.isVirtual ? (searchOrigin?.url ?? location.scopeURL) : location.url) ?? FileManager.default.homeDirectoryForCurrentUser
            }
        case .home: base = FileManager.default.homeDirectoryForCurrentUser
        case .computer: base = URL(fileURLWithPath: "/")
        }
        let target = BrowserLocation.search(scope: base, query: q)
        if case .search = location {
            navigate(to: target, record: false)
        } else {
            navigate(to: target)
        }
    }

    func searchWithProvider(_ qualifiedID: String, query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { endProviderSearch(); return }
        let target = ProvidedLocation.search(providerID: qualifiedID, query: q)
        if providedLocation?.kind == .search {
            navigate(to: target, record: false)
        } else {
            navigate(to: target)
        }
    }

    func endProviderSearch() {
        guard providedLocation?.kind == .search else { return }
        if let prev = backStack.popLast() { restore(prev, select: []) } else { restore(.local(location), select: []) }
        windowController?.syncSearchField()
    }

    func changeSearchScope(_ scope: SearchScopeKind) {
        BrowserDefaults.searchScope = scope
        guard case .search(_, let q) = location else { return }
        search(q, scope: scope)
    }

    func endSearch() {
        guard case .search(let scope, _) = location else { return }
        let back = searchOrigin ?? .folder(scope)
        if let last = backStack.last, last == .local(back.normalized) {
            backStack.removeLast()
            load(back.normalized, select: [], reuse: nil)
        } else {
            navigate(to: back, record: false)
        }
        windowController?.syncSearchField()
    }


    func selectionDidChange() {
        updateStatus()
        if let c = customPreview, c.isVisible {
            if let item = customPreviewItem { c.present(item, location: location, selectionCount: 1) } else { c.close() }
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self {
            panel.reloadData()
        }
        scheduleSizeRequest()
        onSelectionChange?(self)
    }

    func updateStatus() {
        if let p = providedLocation, let r = remote {
            statusBar.update(context: StatusBarContext(location: location, providedLocation: p, selection: [], itemCount: r.items.count, isLoading: r.isLoading || r.isStagingPreview,
                                                       errorDescription: r.loadError?.localizedDescription, resourceSelection: r.selectedItems))
            return
        }
        if let p = providedLocation {
            statusBar.update(context: StatusBarContext(location: location, providedLocation: p, selection: [], itemCount: auxItemCount, isLoading: aux?.isLoading ?? false))
            return
        }
        statusBar.update(location: location, providedLocation: nil, model: model, selection: selectedItems, sizes: sizes)
    }

    func scheduleSizeRequest() {
        guard !sizeRequestScheduled else { return }
        sizeRequestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sizeRequestScheduled = false
                self.requestSizes()
            }
        }
    }

    private var sizesAllowed: Bool {
        guard BrowserDefaults.calculateFolderSizes, remote == nil else { return false }
        if let url = location.scopeURL, VolumeInfo.isNetworkVolume(url), !BrowserDefaults.networkFolderSizes { return false }
        return true
    }

    private func requestSizes() {
        sizes.enabled = sizesAllowed
        guard sizes.enabled else { return }
        let pinned = selectedItems.filter(\.isBrowsableFolder).map(\.url)
        sizes.request(visible: content.visibleFolderURLs(), pinned: pinned)
    }

    private func sizeUpdated(_ key: String) {
        content.sizeDidChange(key)
        let sel = selectedItems
        if sel.count == 1, sel[0].isBrowsableFolder, sel[0].url.pathKey == key { updateStatus() }
        if model.sorter.spec.key == .size, sizes.results[key]?.isComplete == true, !sortBySizeScheduled {
            sortBySizeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sortBySizeScheduled = false
                    self.pendingSelection = self.selectedURLs
                    self.model.updateSizes(self.sizes.completedAllocated)
                }
            }
        }
    }


    func handleKeyDown(_ event: NSEvent) -> Bool {
        if view.window?.firstResponder is NSText { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let windowsKeys = BrowserDefaults.returnOpens
        switch event.keyCode {
        case 49 where flags.isEmpty:
            toggleQuickLook(nil); return true
        case 36, 76:
            guard flags.isEmpty else {
                if flags == .command { openSelection(nil); return true }
                return false
            }
            if BrowserDefaults.returnOpens { openSelection(nil) } else { renameSelection(nil) }
            return true
        case 120 where flags.isEmpty:
            renameSelection(nil); return true
        case 125 where flags == .command:
            openSelection(nil); return true
        case 51 where flags == .command:
            moveToTrash(nil); return true
        case 51 where flags.isEmpty && windowsKeys:
            if let wc = windowController { wc.goUp(nil) } else { goUp() }
            return true
        case 117 where flags.isEmpty && windowsKeys:
            moveToTrash(nil); return true
        case 48 where flags.isEmpty:
            if windowController?.isDualPane == true { windowController?.switchPane(nil); return true }
            return false
        case 96 where flags.isEmpty:
            if windowsKeys { refresh(nil) } else { copyToOtherPane(nil) }
            return true
        case 96 where flags == .shift && windowsKeys:
            copyToOtherPane(nil); return true
        case 97 where flags.isEmpty:
            moveToOtherPane(nil); return true
        case 53 where flags.isEmpty:
            if providedLocation?.kind == .search { endProviderSearch(); return true }
            if case .search = location { endSearch(); return true }
            return false
        default:
            return false
        }
    }


    var destinationFolder: URL? { providedLocation == nil ? location.url : nil }

    var destinationResource: ResourceID? {
        if let r = remote { return r.capabilities.canWrite ? r.directory : nil }
        return destinationFolder.map(ResourceID.local)
    }

    var selectedResources: [ResourceID] {
        if let r = remote { return r.selectedItems.map(\.id) }
        if aux != nil { return [] }
        return selectedURLs.map(ResourceID.local)
    }

    var canCreateFolder: Bool {
        if let r = remote { return r.capabilities.contains(.makeDirectory) && !r.showsDisconnected }
        return destinationFolder != nil
    }

    var canCreateFile: Bool { remote == nil && destinationFolder != nil }

    func canSendToOtherPane(move: Bool) -> Bool {
        guard !selectedResources.isEmpty, windowController?.otherPane(than: self)?.destinationResource != nil else { return false }
        if move, let r = remote { return r.capabilities.canDelete }
        return true
    }

    var trashService: TrashService { FileOperationQueue.shared.trashService }

    static func isTrashLocation(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    var canPutBack: Bool {
        guard remote == nil, providedLocation == nil, Self.isTrashLocation(location.url) || selectedURLs.contains(where: { Self.isTrashLocation($0) }) else { return false }
        let urls = selectedURLs
        guard !urls.isEmpty, urls.count <= 500 else { return false }
        return urls.allSatisfy { trashService.journal.entry(forTrashedURL: $0) != nil }
    }

    var isShowingTrash: Bool { remote == nil && providedLocation == nil && Self.isTrashLocation(location.url) }

    static var putBackWork: @Sendable (TrashService, [URL]) -> PutBackReport = { service, urls in service.putBack(urls) }

    @objc func putBack(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let service = trashService
        let work = Self.putBackWork
        let queue = FileOperationQueue.shared
        queue.beginBackgroundMutation()
        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { work(service, urls) }.value
            queue.endBackgroundMutation()
            guard let self else { return }
            self.model.refresh()
            guard !report.failures.isEmpty else { return }
            let lines = report.failures.prefix(10).map { "“\($0.trashed.lastPathComponent)”: \($0.error.localizedDescription)" }
            let more = report.failures.count > 10 ? "\n…and \(report.failures.count - 10) more." : ""
            let message = report.failures.count == 1 ? "Couldn’t put back 1 item." : "Couldn’t put back \(report.failures.count) items."
            self.lastNotice = message + "\n" + lines.joined(separator: "\n") + more
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = lines.joined(separator: "\n") + more
            if let w = self.view.window, w.isVisible { alert.beginSheetModal(for: w, completionHandler: nil) } else {
                Self.announcer(message, self.view)
            }
        }
    }

    @objc func showRecentlyTrashed(_ sender: Any?) {
        RecentlyTrashedWindowController.shared.show()
    }

    @objc func openSelection(_ sender: Any?) {
        if let r = remote { r.openSelection(); return }
        let sel = selectedItems
        guard !sel.isEmpty else { return }
        if sel.count == 1, sel[0].isBrowsableFolder {
            navigate(to: .folder(sel[0].url))
            return
        }
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        for item in sel {
            if item.isBrowsableFolder {
                windowController?.openInNewTab(.folder(item.url))
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
        if optionHeld, sel.contains(where: { !$0.isBrowsableFolder }) { view.window?.performClose(nil) }
    }

    @objc func openInNewTab(_ sender: Any?) {
        for item in selectedItems where item.isBrowsableFolder { windowController?.openInNewTab(.folder(item.url)) }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        for item in selectedItems where item.isBrowsableFolder { BrowserWindowManager.shared.openWindow(at: .folder(item.url)) }
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let item = selectedItems.first, item.isPackage else { return }
        navigate(to: .folder(item.url))
    }

    @objc func moveToTrash(_ sender: Any?) {
        if let r = remote { r.moveToTrash(); return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOperationQueue.shared.enqueue(.trash(items: urls))
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOperationQueue.shared.enqueue(.duplicate(items: urls))
    }

    @objc func copy(_ sender: Any?) {
        if let r = remote { r.copySelection(cut: false); return }
        Clipboard.shared.copy(selectedURLs)
    }

    @objc func deleteImmediately(_ sender: Any?) {
        if let r = remote { r.deleteSelection() }
    }

    @objc func uploadFiles(_ sender: Any?) { remote?.uploadFiles() }
    @objc func downloadSelection(_ sender: Any?) { remote?.downloadSelection() }

    @objc func cut(_ sender: Any?) {
        if let r = remote { r.copySelection(cut: true); return }
        Clipboard.shared.cut(selectedURLs)
        content.refreshDisplay()
    }

    @objc func paste(_ sender: Any?) {
        if let r = remote { r.paste(forceMove: NSEvent.modifierFlags.contains(.option)); return }
        guard let dest = destinationFolder else { return }
        Clipboard.shared.paste(into: dest, forceMove: NSEvent.modifierFlags.contains(.option))
        content.refreshDisplay()
    }

    @objc func pasteAndMove(_ sender: Any?) {
        if let r = remote { r.paste(forceMove: true); return }
        guard let dest = destinationFolder else { return }
        Clipboard.shared.paste(into: dest, forceMove: true)
    }

    @objc func renameSelection(_ sender: Any?) {
        if let r = remote { r.beginRename(); return }
        guard selectedURLs.count == 1, let url = selectedURLs.first else { return }
        content.beginRename(url)
    }

    var customPreviewItem: FileItem? {
        let sel = selectedItems
        guard sel.count == 1, registries.previews.entry(matching: sel[0]) != nil else { return nil }
        return sel[0]
    }

    var customPreviewController: PreviewPanelController? { customPreview }

    @objc func toggleQuickLook(_ sender: Any?) {
        if let r = remote { r.toggleQuickLook(); return }
        if let item = customPreviewItem {
            let c = customPreview ?? PreviewPanelController(registries: registries)
            customPreview = c
            if c.isVisible { c.close() } else { c.present(item, location: location, selectionCount: 1) }
            return
        }
        if let c = customPreview, c.isVisible { c.close() }
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedURLs.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc func showInEnclosingFolder(_ sender: Any?) {
        let urls = selectedURLs
        guard let first = urls.first else { return }
        navigate(to: .folder(first.deletingLastPathComponent()), select: urls.filter { $0.deletingLastPathComponent().pathKey == first.deletingLastPathComponent().pathKey })
    }

    @objc func getInfo(_ sender: Any?) {
        let urls = selectedURLs.isEmpty ? (location.url.map { [$0] } ?? []) : selectedURLs
        InfoPanelController.show(urls)
    }

    @objc func copyPath(_ sender: Any?) {
        if let r = remote { r.copyPath(); return }
        let urls = selectedURLs.isEmpty ? (location.url.map { [$0] } ?? []) : selectedURLs
        FileCommands.copyPaths(urls)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let sel = selectedItems
        let target: URL?
        if sel.count == 1, sel[0].isBrowsableFolder { target = sel[0].url } else { target = location.url ?? sel.first?.url.deletingLastPathComponent() }
        if let target { FileCommands.openInTerminal(target) }
    }

    @objc func newFolder(_ sender: Any?) {
        if let r = remote { r.newFolder(); return }
        guard let dir = destinationFolder else { return }
        Task { [weak self] in
            do {
                let url = try await FileActions.createFolderAsync(in: dir)
                self?.expectSelection([url], rename: true)
                self?.model.refresh()
            } catch { self?.presentError(error) }
        }
    }

    @objc func newFolderWithSelection(_ sender: Any?) {
        guard let dir = destinationFolder, !selectedURLs.isEmpty else { return }
        let sources = selectedURLs
        Task { [weak self] in
            do {
                let url = try await FileActions.createFolderAsync(in: dir, name: "New Folder With Items")
                FileOperationQueue.shared.enqueue(.move(sources: sources, destination: url))
                self?.expectSelection([url], rename: true)
                self?.model.refresh()
            } catch { self?.presentError(error) }
        }
    }

    @objc func newFile(_ sender: Any?) {
        guard let dir = destinationFolder else { return }
        let template = (sender as? NSMenuItem)?.representedObject as? FileTemplate ?? FileTemplate.all[0]
        Task { [weak self] in
            do {
                let url = try await FileActions.createFileAsync(in: dir, name: template.fileName, contents: template.contents)
                self?.expectSelection([url], rename: true)
                self?.model.refresh()
            } catch { self?.presentError(error) }
        }
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        BrowserDefaults.showHidden.toggle()
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let urls = selectedURLs
        Task { [weak self] in
            do { try await FileCommands.toggleTag(tag, on: urls) } catch { self?.presentError(error) }
            self?.model.refresh()
        }
    }

    @objc func copyToOtherPane(_ sender: Any?) {
        guard let dest = windowController?.otherPane(than: self)?.destinationResource, !selectedResources.isEmpty else { NSSound.beep(); return }
        RemoteTransfers.enqueue(selectedResources, into: dest, move: false)
    }

    @objc func moveToOtherPane(_ sender: Any?) {
        guard let dest = windowController?.otherPane(than: self)?.destinationResource, !selectedResources.isEmpty else { NSSound.beep(); return }
        RemoteTransfers.enqueue(selectedResources, into: dest, move: true)
    }

    @objc func sortByMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        var spec = BrowserDefaults.sort
        if spec.key == key { spec.ascending.toggle() } else { spec.key = key; spec.ascending = key == .name || key == .kind || key == .tags || key == .location }
        spec.customColumn = nil
        BrowserDefaults.sort = spec
        NotificationCenter.default.post(name: .browserSortDidChange, object: nil)
    }

    @objc func toggleFoldersFirst(_ sender: Any?) {
        var spec = BrowserDefaults.sort
        spec.foldersFirst.toggle()
        BrowserDefaults.sort = spec
        NotificationCenter.default.post(name: .browserSortDidChange, object: nil)
    }

    @objc func viewModeMenu(_ sender: NSMenuItem) {
        if let m = BrowserViewMode(rawValue: sender.tag) { windowController?.setViewMode(m) }
    }

    @objc func revealInSidebarFavorites(_ sender: Any?) {
        let folders = selectedItems.filter(\.isBrowsableFolder).map(\.url)
        let targets = folders.isEmpty ? (location.url.map { [$0] } ?? []) : folders
        SidebarStore.addFavorites(targets, at: nil)
    }

    @objc func refresh(_ sender: Any?) {
        if let r = remote {
            if r.showsDisconnected { r.reconnect() } else { r.reload() }
            return
        }
        IconCache.shared.invalidate(location.url ?? URL(fileURLWithPath: "/"))
        pendingSelection = selectedURLs
        model.load()
    }

    func validateRemoteMenuItem(_ menuItem: NSMenuItem, _ r: RemoteBrowserViewController) -> Bool {
        let sel = r.selectedItems
        let caps = r.capabilities
        let editingText = view.window?.firstResponder is NSText
        switch menuItem.action {
        case #selector(openSelection(_:)), #selector(copy(_:)), #selector(copyToOtherPane(_:)), #selector(downloadSelection(_:)):
            if menuItem.action == #selector(copyToOtherPane(_:)) { return !sel.isEmpty && windowController?.otherPane(than: self)?.destinationResource != nil }
            return !sel.isEmpty && !editingText
        case #selector(toggleQuickLook(_:)):
            return sel.contains { !$0.isDirectory }
        case #selector(moveToTrash(_:)):
            return !sel.isEmpty && caps.canTrash && !editingText
        case #selector(deleteImmediately(_:)):
            return !sel.isEmpty && caps.canDelete
        case #selector(cut(_:)), #selector(moveToOtherPane(_:)):
            if menuItem.action == #selector(moveToOtherPane(_:)) { return !sel.isEmpty && caps.canDelete && windowController?.otherPane(than: self)?.destinationResource != nil }
            return !sel.isEmpty && caps.canDelete && !editingText
        case #selector(renameSelection(_:)):
            return sel.count == 1 && caps.canRename
        case #selector(paste(_:)), #selector(pasteAndMove(_:)):
            return r.canPaste && !editingText
        case #selector(newFolder(_:)):
            return canCreateFolder
        case #selector(uploadFiles(_:)):
            return caps.canWrite
        case #selector(newFile(_:)), #selector(newFolderWithSelection(_:)), #selector(duplicate(_:)), #selector(getInfo(_:)), #selector(openInTerminal(_:)),
             #selector(showInEnclosingFolder(_:)), #selector(toggleTag(_:)), #selector(showPackageContents(_:)), #selector(openInNewTab(_:)),
             #selector(openInNewWindow(_:)), #selector(revealInSidebarFavorites(_:)), #selector(putBack(_:)):
            return false
        case #selector(copyPath(_:)), #selector(refresh(_:)), #selector(showRecentlyTrashed(_:)):
            return true
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let r = remote { return validateRemoteMenuItem(menuItem, r) }
        if providedLocation != nil {
            switch menuItem.action {
            case #selector(newFolder(_:)), #selector(newFile(_:)), #selector(paste(_:)), #selector(pasteAndMove(_:)), #selector(newFolderWithSelection(_:)), #selector(putBack(_:)): return false
            default: break
            }
        }
        let hasSel = !selectedURLs.isEmpty
        let editingText = view.window?.firstResponder is NSText
        switch menuItem.action {
        case #selector(moveToTrash(_:)) where editingText, #selector(duplicate(_:)) where editingText,
             #selector(copy(_:)) where editingText, #selector(cut(_:)) where editingText, #selector(paste(_:)) where editingText:
            return false
        case #selector(moveToTrash(_:)), #selector(duplicate(_:)), #selector(copy(_:)), #selector(cut(_:)),
             #selector(openSelection(_:)), #selector(toggleQuickLook(_:)):
            return hasSel
        case #selector(renameSelection(_:)):
            return selectedURLs.count == 1
        case #selector(showInEnclosingFolder(_:)):
            return hasSel && location.isVirtual
        case #selector(paste(_:)), #selector(pasteAndMove(_:)):
            return destinationFolder != nil && (Clipboard.shared.hasFiles || Clipboard.shared.hasResources)
        case #selector(newFolder(_:)), #selector(newFile(_:)):
            return destinationFolder != nil
        case #selector(newFolderWithSelection(_:)):
            return destinationFolder != nil && hasSel
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return canSendToOtherPane(move: menuItem.action == #selector(moveToOtherPane(_:)))
        case #selector(putBack(_:)):
            return canPutBack
        case #selector(toggleHiddenFiles(_:)):
            menuItem.title = BrowserDefaults.showHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return true
        case #selector(toggleFoldersFirst(_:)):
            menuItem.state = BrowserDefaults.sort.foldersFirst ? .on : .off
            return true
        case #selector(sortByMenu(_:)):
            let spec = BrowserDefaults.sort
            menuItem.state = (menuItem.representedObject as? String) == spec.key.rawValue ? .on : .off
            return true
        case #selector(viewModeMenu(_:)):
            menuItem.state = menuItem.tag == viewMode.rawValue ? .on : .off
            return true
        case #selector(toggleTag(_:)):
            guard hasSel, let tag = menuItem.representedObject as? String else { return false }
            let all = selectedItems.allSatisfy { $0.tagNames.contains(tag) }
            menuItem.state = all ? .on : .off
            return true
        case #selector(showPackageContents(_:)):
            return selectedItems.count == 1 && selectedItems[0].isPackage
        case #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)):
            return selectedItems.contains(where: \.isBrowsableFolder)
        default:
            return true
        }
    }


    private var previewURLs: [URL] = []

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension BrowserPaneController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs = remote?.stagedPreviewURLs ?? selectedURLs
            return previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard index >= 0, index < previewURLs.count else { return nil }
            return previewURLs[index] as NSURL
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown, let target = remote?.table ?? content.keyView else { return false }
            switch event.keyCode {
            case 123, 124, 125, 126:
                target.keyDown(with: event)
                return true
            default:
                return false
            }
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated {
            guard !Self.reduceMotion(), let url = item?.previewItemURL else { return .zero }
            if let r = remote { return r.previewSourceRect(for: url) ?? .zero }
            return content.previewSourceRect(for: url) ?? .zero
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated {
            guard !Self.reduceMotion(), let url = item?.previewItemURL else { return nil }
            if remote != nil { return NSWorkspace.shared.icon(forFile: url.path) }
            return content.previewImage(for: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

final class PaneRootView: NSView {
    var onMouseDown: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .rightMouseDown {
            onMouseDown?()
        }
        return hit
    }
}
