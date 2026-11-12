import AppKit
import FSCore
import FileOps
import Quartz
import Theming

final class FileNode: @unchecked Sendable {
    var item: FileItem
    var children: [FileNode]?
    weak var parent: FileNode?
    var isLoading = false
    var token: CancelToken?
    init(item: FileItem, parent: FileNode? = nil) { self.item = item; self.parent = parent }
    var key: String { item.url.pathKey }
}

@MainActor
final class ListViewController: BrowserContentController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = BrowserOutlineView()
    private let scroll = NSScrollView()
    private var roots: [FileNode] = []
    private var nodeByKey: [String: FileNode] = [:]
    private var expandedKeys: Set<String> = []
    private var rootKey: String?
    private var suppressExpansionTracking = false
    private var syncingSort = false
    private var persistScheduled = false
    let spring = SpringLoader()
    private let headerMenu = NSMenu()
    let columnStore = ColumnValueStore()
    private var columnRequestScheduled = false
    private var sortPushScheduled = false
    private var registries: BrowserRegistries { pane?.registries ?? .shared }

    enum Col {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let heat = NSUserInterfaceItemIdentifier("heat")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let added = NSUserInterfaceItemIdentifier("added")
        static let created = NSUserInterfaceItemIdentifier("created")
        static let tags = NSUserInterfaceItemIdentifier("tags")
        static let dimensions = NSUserInterfaceItemIdentifier("dimensions")
        static let location = NSUserInterfaceItemIdentifier("location")
        static let optional: [NSUserInterfaceItemIdentifier] = [modified, size, heat, kind, added, created, tags, dimensions]
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = outline
        view = scroll

        let header = NSTableHeaderView()
        outline.headerView = header
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.allowsTypeSelect = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.style = .fullWidth
        outline.rowHeight = Self.fittedRowHeight(ThemeManager.shared.current)
        outline.autosaveExpandedItems = false
        outline.indentationPerLevel = Spacing.outlineIndent
        outline.intercellSpacing = .zero

        addColumn(Col.name, "Name", width: 320, sortKey: .name)
        addColumn(Col.modified, "Date Modified", width: 170, sortKey: .modified)
        addColumn(Col.size, "Size", width: 90, sortKey: .size)
        addColumn(Col.heat, "Heat", width: 84, sortKey: .size)
        addColumn(Col.kind, "Kind", width: 140, sortKey: .kind)
        addColumn(Col.added, "Date Added", width: 170, sortKey: .added)
        addColumn(Col.created, "Date Created", width: 170, sortKey: .created)
        addColumn(Col.tags, "Tags", width: 120, sortKey: .tags)
        addColumn(Col.dimensions, "Dimensions", width: 110, sortKey: .dimensions)
        addColumn(Col.location, "Location", width: 220, sortKey: .location)
        outline.outlineTableColumn = outline.tableColumns.first
        outline.autosaveName = "BetterFinderListColumns"
        outline.autosaveTableColumns = true
        placeHeatColumnOnce()
        syncContributedColumns()
        applyColumnVisibility()
        columnStore.onUpdate = { [weak self] qid, keys in self?.columnValuesUpdated(qid, keys) }
        registries.columns.addObserver(self) { [weak self] in self?.syncContributedColumns() }

        headerMenu.delegate = self
        header.menu = headerMenu

        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.listController = self
        outline.registerForDraggedTypes(DropSupport.types)
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask([.move, .copy, .link, .generic], forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.setAccessibilityLabel("Files")

        ThemeHooks.install(scroll: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        DimensionsCache.shared.addListener(self) { [weak self] key in self?.reloadRow(key, column: Col.dimensions) }
        syncSortIndicator()
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, sortKey: SortKey) {
        let c = NSTableColumn(identifier: id)
        c.title = title
        c.width = width
        c.minWidth = id == Col.name ? 120 : 50
        c.sortDescriptorPrototype = id == Col.heat ? NSSortDescriptor(key: Col.heat.rawValue, ascending: false) : NSSortDescriptor(key: sortKey.rawValue, ascending: true)
        c.resizingMask = [.userResizingMask]
        if id == Col.size { c.headerCell.alignment = .right }
        outline.addTableColumn(c)
    }

    private func placeHeatColumnOnce() {
        guard !BrowserDefaults.store.bool(forKey: BrowserDefaults.Key.heatColumnPlaced) else { return }
        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.heatColumnPlaced)
        let size = outline.column(withIdentifier: Col.size)
        let heat = outline.column(withIdentifier: Col.heat)
        guard size >= 0, heat >= 0, heat != size + 1 else { return }
        outline.moveColumn(heat, toColumn: heat > size ? size + 1 : size)
    }

    private func applyColumnVisibility() {
        let visible = BrowserDefaults.visibleColumns
        for c in outline.tableColumns {
            if c.identifier == Col.name { c.isHidden = false; continue }
            if c.identifier == Col.location { c.isHidden = !(pane?.location.isVirtual ?? false); continue }
            if let qid = ColumnRegistry.qualifiedID(fromTableIdentifier: c.identifier.rawValue) { c.isHidden = registries.columns.isHidden(qid); continue }
            c.isHidden = !visible.contains(c.identifier.rawValue)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for id in Col.optional {
            guard let col = outline.tableColumn(withIdentifier: id) else { continue }
            let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            item.state = col.isHidden ? .off : .on
            menu.addItem(item)
        }
        let contributed = registries.columns.orderedEntries
        if !contributed.isEmpty {
            menu.addItem(.separator())
            for e in contributed {
                let item = NSMenuItem(title: e.item.title, action: #selector(toggleContributedColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = e.qualifiedID
                item.state = registries.columns.isHidden(e.qualifiedID) ? .off : .on
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let ff = NSMenuItem(title: "Keep Folders on Top", action: #selector(BrowserPaneController.toggleFoldersFirst(_:)), keyEquivalent: "")
        ff.target = pane
        menu.addItem(ff)
        let reset = NSMenuItem(title: "Reset Columns", action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        var visible = BrowserDefaults.visibleColumns
        if visible.contains(raw) { visible.remove(raw) } else { visible.insert(raw) }
        BrowserDefaults.visibleColumns = visible
        NotificationCenter.default.post(name: .browserViewOptionsDidChange, object: nil)
        applyColumnVisibility()
        reloadVisible()
    }

    @objc private func toggleContributedColumn(_ sender: NSMenuItem) {
        guard let qid = sender.representedObject as? String else { return }
        registries.columns.setHidden(qid, !registries.columns.isHidden(qid))
    }

    func syncContributedColumns() {
        let entries = registries.columns.orderedEntries
        let desired = Set(entries.map { ColumnRegistry.tableIdentifier(for: $0.qualifiedID) })
        for c in outline.tableColumns where c.identifier.rawValue.hasPrefix("x:") && !desired.contains(c.identifier.rawValue) {
            if let qid = ColumnRegistry.qualifiedID(fromTableIdentifier: c.identifier.rawValue) { columnStore.forget(column: qid) }
            outline.removeTableColumn(c)
        }
        for e in entries {
            let id = NSUserInterfaceItemIdentifier(ColumnRegistry.tableIdentifier(for: e.qualifiedID))
            let spec = e.item
            if let existing = outline.tableColumn(withIdentifier: id) {
                existing.title = spec.title
                existing.minWidth = CGFloat(spec.minWidth)
                existing.sortDescriptorPrototype = spec.isSortable ? NSSortDescriptor(key: id.rawValue, ascending: true) : nil
                existing.headerCell.alignment = spec.alignment == .trailing ? .right : .natural
                continue
            }
            let c = NSTableColumn(identifier: id)
            c.title = spec.title
            c.width = CGFloat(spec.width)
            c.minWidth = CGFloat(spec.minWidth)
            c.resizingMask = [.userResizingMask]
            if spec.isSortable { c.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true) }
            if spec.alignment == .trailing { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
        }
        applyColumnVisibility()
        let spec = BrowserDefaults.sort
        if spec.key == .custom, spec.customColumn.map({ registries.columns.entry($0) == nil }) ?? true {
            var fallback = spec
            fallback.key = .name
            fallback.ascending = true
            fallback.customColumn = nil
            BrowserDefaults.sort = fallback
            NotificationCenter.default.post(name: .browserSortDidChange, object: nil)
        }
        syncSortIndicator()
        reloadVisible()
        scheduleColumnRequest()
    }

    func scheduleColumnRequest() {
        guard !columnRequestScheduled else { return }
        columnRequestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.columnRequestScheduled = false
                self.requestContributedColumns()
            }
        }
    }

    private func visibleItems() -> [FileItem] {
        let range = outline.rows(in: scroll.contentView.bounds)
        guard range.length > 0 else { return [] }
        var out: [FileItem] = []
        for row in range.location..<(range.location + range.length) {
            if let n = outline.item(atRow: row) as? FileNode { out.append(n.item) }
        }
        return out
    }

    func requestContributedColumns() {
        let entries = registries.columns.orderedEntries
        guard !entries.isEmpty else { return }
        columnStore.location = pane?.location ?? .computer
        let visible = visibleItems()
        let sort = BrowserDefaults.sort
        for e in entries {
            let id = ColumnRegistry.tableIdentifier(for: e.qualifiedID)
            let isSortColumn = sort.key == .custom && sort.customColumn == e.qualifiedID
            let shown = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)).map { !$0.isHidden } ?? false
            guard shown || isSortColumn else {
                columnStore.cancel(column: e.qualifiedID, keeping: [])
                continue
            }
            let items = isSortColumn ? (pane?.model.items ?? visible) : visible
            guard !items.isEmpty else { continue }
            columnStore.request(.init(qualifiedID: e.qualifiedID, provider: e.item.provider, specRevision: e.item.revision, timeout: e.item.timeout), items: items)
        }
    }

    private func columnValuesUpdated(_ qid: String, _ keys: [String]) {
        let id = NSUserInterfaceItemIdentifier(ColumnRegistry.tableIdentifier(for: qid))
        for key in keys { reloadRow(key, column: id) }
        let sort = BrowserDefaults.sort
        if sort.key == .custom, sort.customColumn == qid { schedulePushSortValues() }
    }

    private func schedulePushSortValues() {
        guard !sortPushScheduled else { return }
        sortPushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sortPushScheduled = false
                let sort = BrowserDefaults.sort
                guard sort.key == .custom, let qid = sort.customColumn else { return }
                self.pane?.customSortValuesChanged(self.columnStore.snapshot(column: qid))
            }
        }
    }

    @objc private func resetColumns(_ sender: Any?) {
        BrowserDefaults.visibleColumns = Set(BrowserDefaults.defaultColumns)
        let order: [NSUserInterfaceItemIdentifier] = [Col.name, Col.modified, Col.size, Col.heat, Col.kind, Col.added, Col.created, Col.tags, Col.dimensions, Col.location]
        for (i, id) in order.enumerated() {
            let cur = outline.column(withIdentifier: id)
            if cur >= 0 && cur != i { outline.moveColumn(cur, toColumn: i) }
        }
        applyColumnVisibility()
        reloadVisible()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(optionsChanged), name: .browserViewOptionsDidChange, object: nil)
    }

    @objc private func optionsChanged() {
        applyColumnVisibility()
    }

    override var keyView: NSView? { outline }

    override func applyTheme(_ theme: Theme) {
        let lay = theme.layout
        outline.rowHeight = Self.fittedRowHeight(theme)
        outline.indentationPerLevel = lay.isAuthenticCompact ? Spacing.s : Spacing.outlineIndent
        outline.backgroundColor = theme.listBackground
        outline.usesAlternatingRowBackgroundColors = theme.usesSystemListColors && !theme.colors.rowAlt.isEmpty
        scroll.backgroundColor = theme.listBackground
        ThemeHooks.apply(theme, table: outline, headerHeight: Spacing.listHeaderHeight)
        outline.headerView?.menu = headerMenu
        outline.reloadData()
        restoreExpansion()
    }


    override func usesModel(_ model: FolderModel) -> Bool { false }

    override func teardown() {
        spring.cancel()
        for n in nodeByKey.values { n.token?.cancel() }
        columnStore.cancelAll()
        registries.columns.removeObserver(self)
        DimensionsCache.shared.removeListener(self)
        outline.dataSource = nil
        outline.delegate = nil
    }

    override func locationDidChange() {
        for n in nodeByKey.values { n.token?.cancel() }
        roots = []
        nodeByKey = [:]
        rootKey = pane?.location.url?.pathKey
        expandedKeys = rootKey.map(ExpansionMemory.expanded(in:)) ?? []
        applyColumnVisibility()
        syncSortIndicator()
        suppressExpansionTracking = true
        outline.reloadData()
        suppressExpansionTracking = false
        outline.scroll(.zero)
        columnStore.reset()
        scheduleColumnRequest()
    }

    override func modelDidChange(_ change: FolderModel.Change) {
        guard let model = pane?.model else { return }
        switch change {
        case .reset:
            let selected = Set(selectedURLs.map(\.pathKey))
            let anchor = scrollAnchor()
            roots = model.items.map { reuseNode(for: $0, parent: nil) }
            pruneIndex()
            suppressExpansionTracking = true
            outline.reloadData()
            restoreExpansion()
            suppressExpansionTracking = false
            restoreSelection(selected)
            if resortPending {
                resortPending = false
                let first = outline.selectedRowIndexes.first
                if let first { outline.scrollRowToVisible(first) } else { scrollToTop() }
            } else {
                restoreScroll(anchor)
            }
            scheduleColumnRequest()
        case .reorder:
            let selected = Set(selectedURLs.map(\.pathKey))
            let origin = scroll.contentView.bounds.origin
            roots = model.items.map { reuseNode(for: $0, parent: nil) }
            pruneIndex()
            suppressExpansionTracking = true
            outline.reloadData()
            restoreExpansion()
            suppressExpansionTracking = false
            restoreSelection(selected)
            if resortPending {
                resortPending = false
                if let first = outline.selectedRowIndexes.first { outline.scrollRowToVisible(first) } else { scrollToTop() }
            } else {
                let clip = scroll.contentView
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                scroll.reflectScrolledClipView(clip)
            }
            scheduleColumnRequest()
        case .diff(let d):
            let newRoots = splice(d, items: model.items)
            roots = newRoots
            suppressExpansionTracking = true
            outline.beginUpdates()
            if !d.removed.isEmpty { outline.removeItems(at: d.removed, inParent: nil, withAnimation: []) }
            if !d.inserted.isEmpty { outline.insertItems(at: d.inserted, inParent: nil, withAnimation: []) }
            outline.endUpdates()
            for i in d.updated where i < newRoots.count { outline.reloadItem(newRoots[i], reloadChildren: false) }
            for i in d.inserted where i < newRoots.count && expandedKeys.contains(newRoots[i].key) { outline.expandItem(newRoots[i]) }
            suppressExpansionTracking = false
            scheduleColumnRequest()
        }
    }

    private func splice(_ d: ListDiff, items: [FileItem]) -> [FileNode] {
        var out = roots
        for i in d.removed.reversed() {
            guard i < out.count else { return rebuildRoots(items) }
            forget(out.remove(at: i))
        }
        for i in d.inserted {
            guard i <= out.count, i < items.count else { return rebuildRoots(items) }
            out.insert(reuseNode(for: items[i], parent: nil), at: i)
        }
        guard out.count == items.count else { return rebuildRoots(items) }
        for i in d.updated where i < out.count { out[i].item = items[i] }
        return out
    }

    private func rebuildRoots(_ items: [FileItem]) -> [FileNode] {
        let out = items.map { reuseNode(for: $0, parent: nil) }
        roots = out
        pruneIndex()
        return out
    }

    private func forget(_ node: FileNode) {
        node.token?.cancel()
        nodeByKey[node.key] = nil
        for c in node.children ?? [] { forget(c) }
    }

    private func reuseNode(for item: FileItem, parent: FileNode?) -> FileNode {
        let key = item.url.pathKey
        if let n = nodeByKey[key] {
            n.item = item
            n.parent = parent
            return n
        }
        let n = FileNode(item: item, parent: parent)
        nodeByKey[key] = n
        return n
    }

    private func pruneIndex() {
        var live: [String: FileNode] = [:]
        func walk(_ nodes: [FileNode]) {
            for n in nodes {
                live[n.key] = n
                if let c = n.children { walk(c) }
            }
        }
        walk(roots)
        for (k, n) in nodeByKey where live[k] == nil { n.token?.cancel() }
        nodeByKey = live
    }

    private func restoreExpansion() {
        guard !expandedKeys.isEmpty else { return }
        var row = 0
        while row < outline.numberOfRows {
            if let n = outline.item(atRow: row) as? FileNode, n.item.isBrowsableFolder, expandedKeys.contains(n.key), !outline.isItemExpanded(n) {
                outline.expandItem(n)
            }
            row += 1
        }
    }

    private func scrollAnchor() -> (String, CGFloat)? {
        let visible = scroll.contentView.bounds
        let range = outline.rows(in: visible)
        guard range.length > 0, let n = outline.item(atRow: range.location) as? FileNode else { return nil }
        return (n.key, visible.minY - outline.rect(ofRow: range.location).minY)
    }

    private var resortPending = false

    override func prepareForResort() {
        resortPending = true
    }

    private func scrollToTop() {
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: -.greatestFiniteMagnitude, width: clip.bounds.width, height: clip.bounds.height)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func restoreScroll(_ anchor: (String, CGFloat)?) {
        guard let (key, offset) = anchor, let n = nodeByKey[key] else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        let clip = scroll.contentView
        let y = outline.rect(ofRow: row).minY + offset
        clip.scroll(to: clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: y, width: clip.bounds.width, height: clip.bounds.height)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func restoreSelection(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        var idx = IndexSet()
        for k in keys { if let n = nodeByKey[k] { let r = outline.row(forItem: n); if r >= 0 { idx.insert(r) } } }
        outline.selectRowIndexes(idx, byExtendingSelection: false)
    }


    private func loadChildren(_ node: FileNode) {
        guard !node.isLoading, let sorter = pane?.model.sorter else { return }
        node.isLoading = true
        let token = CancelToken()
        node.token = token
        let url = node.item.url
        let showHidden = BrowserDefaults.showHidden
        DirectoryStream.queue.async { [weak self] in
            let r = try? DirectoryStream.list(url, showHidden: showHidden)
            let sorted = sorter.sorted(r?.visible ?? [])
            onMain {
                guard let self, !token.isCancelled else { return }
                node.isLoading = false
                self.applyChildren(sorted, to: node)
            }
        }
    }

    private func applyChildren(_ items: [FileItem], to node: FileNode) {
        let previous = node.children
        let newChildren = items.map { reuseNode(for: $0, parent: node) }
        node.children = newChildren
        suppressExpansionTracking = true
        defer { suppressExpansionTracking = false }
        if let previous, outline.isItemExpanded(node), let d = ListDiff.compute(old: previous.map(\.item), new: items), d.size < 1000 {
            outline.beginUpdates()
            if !d.removed.isEmpty { outline.removeItems(at: d.removed, inParent: node, withAnimation: []) }
            if !d.inserted.isEmpty { outline.insertItems(at: d.inserted, inParent: node, withAnimation: []) }
            outline.endUpdates()
            for i in d.updated where i < newChildren.count { outline.reloadItem(newChildren[i], reloadChildren: false) }
        } else {
            let wasExpanded = outline.isItemExpanded(node)
            outline.reloadItem(node, reloadChildren: true)
            if wasExpanded && !outline.isItemExpanded(node) { outline.expandItem(node) }
        }
        pruneIndex()
        for c in newChildren where c.item.isBrowsableFolder && expandedKeys.contains(c.key) && !outline.isItemExpanded(c) {
            outline.expandItem(c)
        }
        pane?.scheduleSizeRequest()
    }

    override func childDirectoryEvents(_ dirs: Set<String>) {
        for d in dirs {
            if let n = nodeByKey[d], n.children != nil, !n.isLoading { loadChildren(n) }
        }
    }


    override var selectedItems: [FileItem] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.item }
    }

    override func select(_ urls: [URL], scroll doScroll: Bool) {
        var idx = IndexSet()
        for u in urls {
            if let n = nodeByKey[u.pathKey] {
                let r = outline.row(forItem: n)
                if r >= 0 { idx.insert(r) }
            }
        }
        outline.selectRowIndexes(idx, byExtendingSelection: false)
        if doScroll, let first = idx.first { outline.scrollRowToVisible(first) }
    }

    override func focus() { view.window?.makeFirstResponder(outline) }

    override func visibleFolderURLs() -> [URL] {
        let range = outline.rows(in: scroll.contentView.bounds)
        guard range.length > 0 else { return [] }
        var out: [URL] = []
        for row in range.location..<(range.location + range.length) {
            if let n = outline.item(atRow: row) as? FileNode, n.item.isBrowsableFolder { out.append(n.item.url) }
        }
        return out
    }

    @objc private func scrolled() {
        pane?.scheduleSizeRequest()
        scheduleColumnRequest()
    }

    override func sizeDidChange(_ key: String) {
        reloadRow(key, column: Col.size)
        reloadRow(key, column: Col.heat)
        guard let pane, pane.sizes.results[key]?.isSettled == true, !registries.columns.orderedEntries.isEmpty else { return }
        columnStore.invalidate(pathKeys: [key])
        scheduleColumnRefresh()
    }

    private var columnRefreshScheduled = false

    private func scheduleColumnRefresh() {
        guard !columnRefreshScheduled else { return }
        columnRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.columnRefreshScheduled = false
                self.requestContributedColumns()
            }
        }
    }

    private func reloadRow(_ key: String, column: NSUserInterfaceItemIdentifier) {
        guard let n = nodeByKey[key] else { return }
        let row = outline.row(forItem: n)
        let col = outline.column(withIdentifier: column)
        guard row >= 0, col >= 0, !outline.tableColumns[col].isHidden else { return }
        outline.reloadData(forRowIndexes: [row], columnIndexes: [col])
    }

    private func reloadVisible() {
        let range = outline.rows(in: scroll.contentView.bounds)
        guard range.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<(range.location + range.length)), columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
    }

    override func refreshDisplay() {
        syncSortIndicator()
        reloadVisible()
        scheduleColumnRequest()
        let sort = BrowserDefaults.sort
        if sort.key == .custom, let qid = sort.customColumn {
            pane?.customSortValuesChanged(columnStore.snapshot(column: qid))
        }
    }

    private func syncSortIndicator() {
        let spec = BrowserDefaults.sort
        var key = spec.key == .custom ? ColumnRegistry.tableIdentifier(for: spec.customColumn ?? "") : spec.key.rawValue
        if spec.key == .size, outline.tableColumn(withIdentifier: Col.size)?.isHidden == true, outline.tableColumn(withIdentifier: Col.heat)?.isHidden == false {
            key = Col.heat.rawValue
        }
        syncingSort = true
        outline.sortDescriptors = [NSSortDescriptor(key: key, ascending: spec.ascending)]
        syncingSort = false
    }

    override func beginRename(_ url: URL) {
        guard let n = nodeByKey[url.pathKey] else { return }
        let row = outline.row(forItem: n)
        let col = outline.column(withIdentifier: Col.name)
        guard row >= 0, col >= 0 else { return }
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes([row], byExtendingSelection: false)
        guard let cell = outline.view(atColumn: col, row: row, makeIfNecessary: true) as? FileCellView, let tf = cell.textField else { return }
        RenameSession.begin(url: url, field: tf) { [weak self] renamed in
            guard let self else { return }
            if let renamed {
                self.pane?.expectSelection([renamed])
                self.pane?.model.refresh()
                if let parent = n.parent { self.loadChildren(parent) }
            } else {
                self.reloadRow(n.key, column: Col.name)
            }
            self.focus()
        }
    }

    override func previewSourceRect(for url: URL) -> NSRect? {
        guard let n = nodeByKey[url.pathKey], let window = outline.window else { return nil }
        let row = outline.row(forItem: n)
        let col = outline.column(withIdentifier: Col.name)
        guard row >= 0, col >= 0, outline.rows(in: scroll.contentView.bounds).contains(row),
              let cell = outline.view(atColumn: col, row: row, makeIfNecessary: false) as? FileCellView, let iv = cell.imageView else { return nil }
        return window.convertToScreen(iv.convert(iv.bounds, to: nil))
    }

    override func previewImage(for url: URL) -> NSImage? {
        guard let n = nodeByKey[url.pathKey] else { return nil }
        return IconCache.shared.icon(for: n.item)
    }


    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        guard let c = node.children else {
            loadChildren(node)
            return 0
        }
        return c.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? FileNode else { return false }
        return n.item.isBrowsableFolder && pane?.location.isVirtual == false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !syncingSort, let d = outlineView.sortDescriptors.first, let raw = d.key else { return }
        var spec = BrowserDefaults.sort
        var ascending = d.ascending
        if let qid = ColumnRegistry.qualifiedID(fromTableIdentifier: raw) {
            spec.key = .custom
            spec.customColumn = qid
        } else if raw == Col.heat.rawValue {
            ascending = spec.key == .size ? !spec.ascending : false
            spec.key = .size
            spec.customColumn = nil
        } else if let key = SortKey(rawValue: raw) {
            spec.key = key
            spec.customColumn = nil
        } else {
            return
        }
        spec.ascending = ascending
        BrowserDefaults.sort = spec
        NotificationCenter.default.post(name: .browserSortDidChange, object: nil)
    }

    func heatValue(for item: FileItem) -> (bytes: Int64?, settled: Bool) {
        if pane?.location == .computer, let volume = VolumeInfo.details(for: item.url) { return (volume.usedBytes, true) }
        guard item.isBrowsableFolder else { return (item.logicalSize, true) }
        guard let result = pane?.sizes.result(for: item.url) else { return (nil, true) }
        return (result.allocatedBytes, result.isSettled)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier == Col.name else { return nil }
        return (item as? FileNode)?.item.name
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.item.url as NSURL?
    }

    private func dropDestination(_ item: Any?, index: Int) -> (URL, FileNode?)? {
        if let n = item as? FileNode {
            if n.item.isBrowsableFolder { return (n.item.url, n) }
            if let p = n.parent { return (p.item.url, p) }
        }
        if let u = pane?.destinationFolder { return (u, nil) }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let (dest, node) = dropDestination(item, index: index) else { spring.cancel(); return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let op = DropSupport.operation(for: info, destination: dest)
        if let node, !op.isEmpty, index == NSOutlineViewDropOnItemIndex, item as? FileNode === node {
            spring.hover(dest) { [weak self] in self?.pane?.navigate(to: .folder(dest)) }
        } else {
            spring.cancel()
        }
        return op
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        spring.cancel()
        guard let (dest, _) = dropDestination(item, index: index) else { return false }
        return DropSupport.perform(info, destination: dest)
    }


    private func displayName(_ item: FileItem) -> String {
        if item.isPackage || item.contentType?.conforms(to: .applicationBundle) == true {
            return FileManager.default.displayName(atPath: item.url.path)
        }
        return HomeLabel.name(item.name, for: item.url)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode, let col = tableColumn else { return nil }
        let theme = ThemeManager.shared.current
        let id = col.identifier
        if id == Col.heat {
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? HeatCellView) ?? HeatCellView(identifier: id)
            let value = heatValue(for: node.item)
            cell.show(bytes: value.bytes, settled: value.settled, trackColor: theme.secondaryTextColor)
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FileCellView) ?? FileCellView(identifier: id, showsIcon: id == Col.name)
        let leading = id == Col.name ? Spacing.xxs : nil
        if cell.leadingInset != leading { cell.leadingInset = leading }
        let tf = cell.textField!
        if tf.font != theme.listFont { tf.font = theme.listFont; cell.needsLayout = true }
        let contributedQID = ColumnRegistry.qualifiedID(fromTableIdentifier: id.rawValue)
        let contributedSpec = contributedQID.flatMap { registries.columns.item($0) }
        tf.alignment = (id == Col.size || contributedSpec?.alignment == .trailing) ? .right : .natural
        cell.attributedText = nil
        tf.setAccessibilityValue(nil)
        cell.normalTextColor = id == Col.name ? theme.textColor : theme.secondaryTextColor
        let it = node.item
        switch id {
        case Col.name:
            let shown = displayName(it)
            tf.stringValue = shown
            tf.isEditable = false
            let dim: CGFloat = Clipboard.shared.isCut(it.url) ? 0.4 : (it.isHidden ? 0.5 : 1)
            cell.setIcon(for: it, dimmed: dim)
            tf.alphaValue = Clipboard.shared.isCut(it.url) ? 0.55 : 1
            if HomeLabel.isRedacted(it.url) {
                let font = theme.listFont
                let hidden = it.name
                cell.attributedText = { color in RedactedText.attributed(hidden, font: font, color: color) }
            }
            cell.setAccessibilityLabel(Self.accessibilityLabel(for: it, name: HomeLabel.accessibilityName(shown, for: it.url), cut: Clipboard.shared.isCut(it.url)))
            let row = outlineView.row(forItem: node)
            if row >= 0 { (outlineView.rowView(atRow: row, makeIfNecessary: false) as? ThemedRowView)?.labelColor = TagColors.labelColor(for: it.url) }
        case Col.modified:
            tf.stringValue = it.dateModified.map { Self.dateFormatter.string(from: $0) } ?? "--"
        case Col.added:
            tf.stringValue = it.dateAdded.map { Self.dateFormatter.string(from: $0) } ?? "--"
        case Col.created:
            tf.stringValue = it.dateCreated.map { Self.dateFormatter.string(from: $0) } ?? "--"
        case Col.size:
            if pane?.location == .computer, let volume = VolumeInfo.details(for: it.url) {
                tf.stringValue = volume.spaceText
                tf.toolTip = volume.usedBytes.map { "\(SizeFormatter.string($0)) used" }
            } else if it.isBrowsableFolder {
                if let r = pane?.sizes.result(for: it.url) {
                    tf.stringValue = r.isSettled ? SizeFormatter.string(r.allocatedBytes) : "\(SizeFormatter.string(r.allocatedBytes))…"
                    tf.toolTip = "\(SizeFormatter.exact(r.logicalBytes)) logical · \(r.itemCount.formatted()) items\(r.isUnreadable ? " · some folders couldn’t be read" : "")"
                } else {
                    tf.stringValue = "--"
                    tf.toolTip = nil
                }
            } else {
                tf.stringValue = it.logicalSize.map(SizeFormatter.string) ?? "--"
                tf.toolTip = it.allocatedSize.map { "\(SizeFormatter.string($0)) on disk" }
            }
        case Col.kind:
            if pane?.location == .computer, let volume = VolumeInfo.details(for: it.url) {
                tf.stringValue = volume.kindText
            } else {
                tf.stringValue = it.kindDescription
            }
        case Col.tags:
            let tags = it.tagNames
            if tags.isEmpty { tf.stringValue = "" } else {
                let font = theme.listFont
                cell.attributedText = { color in TagColors.attributed(tags, font: font, textColor: color) }
            }
        case Col.dimensions:
            if let d = DimensionsCache.shared.dimensions(for: it) {
                tf.stringValue = "\(Int(d.width)) × \(Int(d.height))"
            } else {
                tf.stringValue = DimensionsCache.shared.isPending(it) ? "…" : "--"
            }
        case Col.location:
            tf.stringValue = it.url.deletingLastPathComponent().abbreviatedPath
            tf.toolTip = it.url.deletingLastPathComponent().displayPath
        default:
            if let qid = contributedQID {
                if let v = columnStore.cachedValue(column: qid, for: it) {
                    tf.stringValue = v.displayText
                    tf.setAccessibilityValue(v.accessibilityDescription ?? v.displayText)
                } else {
                    tf.stringValue = columnStore.isPending(column: qid, for: it) ? "…" : ""
                    scheduleColumnRequest()
                }
            }
        }
        cell.refreshTextColor()
        return cell
    }

    static func fittedRowHeight(_ theme: Theme) -> CGFloat {
        let lay = theme.layout
        return ThemeLayout.fittedHeight(max(16, lay.rowHeight), font: theme.listFont, verticalPadding: 0)
    }

    static func accessibilityLabel(for it: FileItem, name: String, cut: Bool = false) -> String {
        var parts = [name, it.kindDescription]
        if it.isHidden { parts.append("hidden") }
        if cut { parts.append("cut") }
        return parts.joined(separator: ", ")
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let themed = rowView as? ThemedRowView else { return }
        themed.rowIndex = row
        themed.labelColor = (outlineView.item(atRow: row) as? FileNode).flatMap { TagColors.labelColor(for: $0.item.url) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        notifySelection()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        if node.children == nil { loadChildren(node) }
        guard !suppressExpansionTracking else { return }
        expandedKeys.insert(node.key)
        persistExpansion()
        pane?.scheduleSizeRequest()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppressExpansionTracking, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedKeys.remove(node.key)
        persistExpansion()
    }

    private func persistExpansion() {
        guard let rootKey, !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistScheduled = false
                ExpansionMemory.set(self.expandedKeys, in: rootKey)
            }
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0 else { return }
        pane?.openSelection(sender)
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: point)
        if row >= 0 {
            if !outline.selectedRowIndexes.contains(row) { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outline.deselectAll(nil)
        }
        guard let pane else { return nil }
        let menu = ContextMenuBuilder.menu(for: pane)
        let column = outline.column(at: point)
        if row >= 0, column >= 0, outline.tableColumns[column].identifier == Col.kind, let item = (outline.item(atRow: row) as? FileNode)?.item {
            let kind = item.kindDescription
            if !kind.isEmpty, pane.itemFilter?.rule != .kind(kind) {
                let entry = NSMenuItem(title: "Filter by “\(kind)”", action: #selector(BrowserPaneController.filterByKind(_:)), keyEquivalent: "")
                entry.target = pane
                entry.representedObject = kind
                menu.insertItem(entry, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
        }
        return menu
    }
}

@MainActor
final class BrowserOutlineView: NSOutlineView {
    weak var listController: ListViewController?

    override func keyDown(with event: NSEvent) {
        if let pane = listController?.pane, pane.handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        listController?.contextMenu(for: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        listController?.spring.cancel()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        listController?.spring.cancel()
        super.draggingEnded(sender)
    }
}
