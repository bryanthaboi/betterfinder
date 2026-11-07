import AppKit
import Combine
import FileOps
import FSCore
import Quartz
import Remote
import Theming
import UniformTypeIdentifiers

@MainActor
final class RemoteBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, ThemedSurface {
    enum Col {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    let location: ProvidedLocation
    let directory: ResourceID
    let locationProvider: ResourceLocationProvider
    var provider: ResourceProvider { locationProvider.resourceProvider }
    let table = RemoteTableView()
    private let scroll = NSScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private(set) var items: [ResourceItem] = []
    private(set) var isLoading = false
    private(set) var loadError: Error?
    private(set) var stagedPreviewURLs: [URL] = []
    private(set) var isStagingPreview = false
    private(set) var showsDisconnected = false
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var watchToken: ResourceWatchToken?
    private var generation = 0
    private var pendingSelectionNames: [String] = []
    private(set) var renamingID: ResourceID?
    private(set) var renameFailureMessage: String?
    private var applyingSharedSort = false
    weak var pane: BrowserPaneController?
    var onNavigate: ((ProvidedLocation) -> Void)?
    var onStateChange: (() -> Void)?

    init(location: ProvidedLocation, provider: ResourceLocationProvider) {
        self.location = location
        self.directory = location.resourceID ?? provider.resourceProvider.root
        self.locationProvider = provider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var capabilities: ResourceCapabilities { provider.capabilities }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(location.title)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.remote = self
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(doubleClicked(_:))
        table.target = self
        table.setAccessibilityLabel("Items in \(location.title)")
        for (id, title, width, key) in [(Col.name, "Name", 320.0, "name"), (Col.modified, "Date Modified", 170.0, "modified"), (Col.size, "Size", 90.0, "size"), (Col.kind, "Kind", 140.0, "kind")] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 60
            c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key != "modified" && key != "size")
            if id == Col.size { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [Self.sharedSortDescriptor() ?? NSSortDescriptor(key: "name", ascending: true)]
        table.registerForDraggedTypes([.fileURL, Clipboard.resourceType])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectClicked(_:))
        reconnectButton.bezelStyle = .rounded
        reconnectButton.isHidden = true
        reconnectButton.setAccessibilityLabel("Reconnect to \(location.title)")
        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(messageLabel)
        root.addSubview(spinner)
        root.addSubview(reconnectButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            reconnectButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            reconnectButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: Spacing.s),
        ])
        view = root
        ThemeHooks.install(scroll: scroll)
        applyTheme(ThemeManager.shared.current)
        observeThemeChanges()
        NotificationCenter.default.addObserver(self, selector: #selector(resourcesChanged(_:)), name: .remoteResourcesDidChange, object: nil)
    }

    func applyTheme(_ theme: Theme) {
        ThemeHooks.apply(theme, table: table)
        table.backgroundColor = theme.listBackground
        table.rowHeight = max(18, ThemeManager.shared.layout.rowHeight)
        table.reloadData()
    }

    var isDisconnected: Bool { RemoteIntegration.shared.isDisconnected(providerID: directory.providerID) }

    func start() {
        _ = view
        NotificationCenter.default.addObserver(self, selector: #selector(connectionStateChanged(_:)), name: .remoteConnectionStateDidChange, object: nil)
        if isDisconnected {
            showDisconnected()
            return
        }
        beginListing()
    }

    private func beginListing() {
        showsDisconnected = false
        reconnectButton.isHidden = true
        reload()
        watchToken?.cancel()
        watchToken = provider.watch(directory) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } }
        }
    }

    func reconnect() {
        RemoteIntegration.shared.reconnect(providerID: directory.providerID)
        beginListing()
    }

    @objc private func reconnectClicked(_ sender: Any?) {
        reconnect()
        focus()
    }

    @objc private func connectionStateChanged(_ note: Notification) {
        let disconnected = isDisconnected
        if showsDisconnected, !disconnected { beginListing() } else if !showsDisconnected, disconnected { showDisconnected() }
    }

    private func showDisconnected() {
        loadTask?.cancel()
        previewTask?.cancel()
        previewGeneration += 1
        watchToken?.cancel()
        watchToken = nil
        generation += 1
        clearPreviewStaging()
        showsDisconnected = true
        isLoading = false
        isStagingPreview = false
        items = []
        table.reloadData()
        spinner.stopAnimation(nil)
        loadError = RemoteDisconnectedError(title: location.title)
        messageLabel.stringValue = "Disconnected from “\(location.title)”."
        messageLabel.isHidden = false
        reconnectButton.isHidden = false
        onStateChange?()
    }

    func stop() {
        loadTask?.cancel()
        previewTask?.cancel()
        previewGeneration += 1
        watchToken?.cancel()
        watchToken = nil
        generation += 1
        clearPreviewStaging()
        NotificationCenter.default.removeObserver(self)
    }

    func focus() { view.window?.makeFirstResponder(table) }

    @objc private func resourcesChanged(_ note: Notification) {
        let ids = note.userInfo?["providerIDs"] as? [String] ?? []
        if ids.isEmpty || ids.contains(directory.providerID) { reload() }
    }

    func reload() {
        guard !showsDisconnected else { return }
        loadTask?.cancel()
        generation += 1
        let gen = generation
        let keepNames = pendingSelectionNames.isEmpty ? selectedItems.map(\.name) : pendingSelectionNames
        isLoading = true
        loadError = nil
        spinner.startAnimation(nil)
        messageLabel.isHidden = true
        onStateChange?()
        let provider = self.provider
        let dir = directory
        let showHidden = BrowserDefaults.showHidden
        loadTask = Task { [weak self] in
            var collected: [ResourceItem] = []
            do {
                for try await page in provider.list(dir, options: ResourceListOptions(showHidden: showHidden, pageSize: 500)) {
                    guard let self, self.generation == gen else { return }
                    collected += page
                    self.apply(collected, select: keepNames)
                }
                try Task.checkCancellation()
                guard let self, self.generation == gen else { return }
                self.isLoading = false
                self.apply(collected, select: keepNames)
                self.pendingSelectionNames = []
                self.finishLoading(nil)
            } catch {
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.isLoading = false
                self.finishLoading(error)
            }
        }
    }

    private func finishLoading(_ error: Error?) {
        spinner.stopAnimation(nil)
        loadError = error
        if let error {
            messageLabel.stringValue = error.localizedDescription
            messageLabel.isHidden = false
        } else {
            messageLabel.stringValue = "This folder is empty."
            messageLabel.isHidden = !items.isEmpty
        }
        onStateChange?()
    }

    private func apply(_ list: [ResourceItem], select names: [String]) {
        items = sorted(list)
        table.reloadData()
        if !names.isEmpty {
            let set = Set(names)
            let rows = IndexSet(items.indices.filter { set.contains(items[$0].name) })
            if !rows.isEmpty {
                table.selectRowIndexes(rows, byExtendingSelection: false)
                if let first = rows.first { table.scrollRowToVisible(first) }
            }
        }
        onStateChange?()
    }

    private func sorted(_ list: [ResourceItem]) -> [ResourceItem] {
        let d = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let foldersFirst = BrowserDefaults.sort.foldersFirst
        return list.sorted { a, b in
            if foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            let r: ComparisonResult
            switch d.key {
            case "size": r = (a.size ?? -1) == (b.size ?? -1) ? .orderedSame : ((a.size ?? -1) < (b.size ?? -1) ? .orderedAscending : .orderedDescending)
            case "modified": r = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case "kind": r = a.kindDescription.localizedStandardCompare(b.kindDescription)
            default: r = .orderedSame
            }
            if r == .orderedSame { return a.name.localizedStandardCompare(b.name) == (d.ascending || d.key != "name" ? .orderedAscending : .orderedDescending) }
            return d.ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }

    var selectedItems: [ResourceItem] {
        table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    func select(names: [String]) {
        pendingSelectionNames = names
        apply(items, select: names)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let names = selectedItems.map(\.name)
        apply(items, select: names)
        guard !applyingSharedSort, let d = tableView.sortDescriptors.first, let key = d.key.flatMap(Self.sortKey(forRemoteKey:)) else { return }
        var spec = BrowserDefaults.sort
        guard spec.key != key || spec.ascending != d.ascending || spec.customColumn != nil else { return }
        spec.key = key
        spec.ascending = d.ascending
        spec.customColumn = nil
        BrowserDefaults.sort = spec
        NotificationCenter.default.post(name: .browserSortDidChange, object: nil)
    }

    static func remoteSortKey(for key: SortKey) -> String? {
        switch key {
        case .name: return "name"
        case .modified: return "modified"
        case .size: return "size"
        case .kind: return "kind"
        default: return nil
        }
    }

    static func sortKey(forRemoteKey key: String) -> SortKey? {
        switch key {
        case "name": return .name
        case "modified": return .modified
        case "size": return .size
        case "kind": return .kind
        default: return nil
        }
    }

    static func sharedSortDescriptor() -> NSSortDescriptor? {
        let spec = BrowserDefaults.sort
        return remoteSortKey(for: spec.key).map { NSSortDescriptor(key: $0, ascending: spec.ascending) }
    }

    func applySharedSort() {
        let names = selectedItems.map(\.name)
        if let d = Self.sharedSortDescriptor(), let current = table.sortDescriptors.first, current.key != d.key || current.ascending != d.ascending {
            applyingSharedSort = true
            table.sortDescriptors = [d]
            applyingSharedSort = false
        }
        apply(items, select: names)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onStateChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible { stagePreview(show: false) }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    func icon(for item: ResourceItem) -> NSImage {
        if item.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: item.contentType ?? .data)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, items.indices.contains(row) else { return nil }
        let item = items[row]
        let theme = ThemeManager.shared.current
        let cell = (tableView.makeView(withIdentifier: col.identifier, owner: self) as? NSTableCellView) ?? makeCell(col.identifier)
        cell.textField?.font = theme.listFont
        cell.textField?.textColor = col.identifier == Col.name ? theme.textColor : theme.secondaryTextColor
        switch col.identifier {
        case Col.name:
            cell.textField?.stringValue = item.name
            cell.imageView?.image = icon(for: item)
            cell.textField?.isEditable = false
            cell.setAccessibilityLabel(item.name)
        case Col.modified:
            cell.textField?.stringValue = item.modified.map { Self.dateFormatter.string(from: $0) } ?? "--"
        case Col.size:
            cell.textField?.stringValue = item.isDirectory ? "--" : (item.size.map(SizeFormatter.string) ?? "--")
        default:
            cell.textField?.stringValue = item.kindDescription
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.delegate = self
        cell.addSubview(tf)
        cell.textField = tf
        if id == Col.name {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            if id == Col.size { tf.alignment = .right }
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard items.indices.contains(row) else { return nil }
        let pb = NSPasteboardItem()
        let id = items[row].id
        if let data = try? JSONEncoder().encode([id]) { pb.setData(data, forType: Clipboard.resourceType) }
        pb.setString(items[row].name, forType: .string)
        return pb
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard capabilities.canWrite else { return [] }
        if op == .on, items.indices.contains(row), !items[row].isDirectory { tableView.setDropRow(-1, dropOperation: .on) }
        let resources = Clipboard.resources(from: info.draggingPasteboard)
        if !resources.isEmpty {
            let target = dropTarget(row: row, op: op)
            if resources.contains(where: { $0 == target || target.isDescendant(of: $0) || $0.lexicalParent == target }) { return [] }
            return resources.allSatisfy { $0.providerID == target.providerID } ? .move : .copy
        }
        return DropSupport.fileURLs(info).isEmpty ? [] : .copy
    }

    private func dropTarget(row: Int, op: NSTableView.DropOperation) -> ResourceID {
        if op == .on, items.indices.contains(row), items[row].isDirectory { return items[row].id }
        return directory
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let target = dropTarget(row: row, op: op)
        let resources = Clipboard.resources(from: info.draggingPasteboard)
        if !resources.isEmpty {
            let move = resources.allSatisfy { $0.providerID == target.providerID } && info.draggingSourceOperationMask.contains(.move)
            RemoteTransfers.enqueue(resources, into: target, move: move)
            return true
        }
        let urls = DropSupport.fileURLs(info)
        guard !urls.isEmpty else { return false }
        RemoteTransfers.enqueue(urls.map(ResourceID.local), into: target, move: false)
        return true
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        openSelection()
    }

    func openSelection() {
        let sel = selectedItems
        guard !sel.isEmpty else { return }
        if sel.count == 1, sel[0].isDirectory {
            onNavigate?(locationProvider.location(for: sel[0].id))
            return
        }
        let files = sel.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        confirmOpenCopy(files) { [weak self] in self?.downloadAndOpenCopies(files) }
    }

    var openSelectionTitle: String {
        let sel = selectedItems
        if sel.isEmpty || (sel.count == 1 && sel[0].isDirectory) || !sel.contains(where: { !$0.isDirectory }) { return "Open" }
        return sel.count == 1 ? "Download and Open Copy…" : "Download and Open Copies…"
    }

    private func confirmOpenCopy(_ files: [ResourceItem], then proceed: @escaping () -> Void) {
        if BrowserDefaults.store.bool(forKey: RemoteOpenCopies.confirmedKey) { proceed(); return }
        let alert = NSAlert()
        alert.messageText = files.count == 1 ? "Download and open a copy of “\(files[0].name)”?" : "Download and open copies of \(files.count) files?"
        alert.informativeText = RemoteOpenCopies.notice(serverTitle: serverTitle)
        alert.addButton(withTitle: "Download and Open")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { BrowserDefaults.store.set(true, forKey: RemoteOpenCopies.confirmedKey) }
            proceed()
        }
        if let w = view.window { alert.beginSheetModal(for: w, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private var serverTitle: String {
        RemoteIntegration.shared.manager.server(providerID: directory.providerID)?.name ?? locationProvider.rootTitle
    }

    private func downloadAndOpenCopies(_ files: [ResourceItem]) {
        let provider = self.provider
        RemoteMutationTracker.shared.run { [weak self] in
            var failure: Error?
            for file in files {
                do {
                    for u in try await RemoteOpenCopies.download([file], provider: provider) { RemoteOpenCopies.opener(u) }
                } catch {
                    if Task.isCancelled { return }
                    if failure == nil { failure = error }
                }
            }
            if let failure { self?.present(failure) }
        }
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        stagePreview(show: true)
    }

    func stagePreview(show: Bool) {
        let files = selectedItems.filter { !$0.isDirectory }
        previewTask?.cancel()
        previewGeneration += 1
        let gen = previewGeneration
        guard !files.isEmpty else {
            clearPreviewStaging()
            if isStagingPreview {
                isStagingPreview = false
                onStateChange?()
            }
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.reloadData() }
            return
        }
        isStagingPreview = true
        onStateChange?()
        let provider = self.provider
        previewTask = Task { [weak self] in
            do {
                let urls = try await RemoteStaging.stage(files, provider: provider, purpose: "QuickLook", limit: RemoteStaging.previewLimit)
                guard let self, self.previewGeneration == gen, !Task.isCancelled else {
                    RemoteStaging.discard(urls)
                    return
                }
                self.isStagingPreview = false
                RemoteStaging.discard(self.stagedPreviewURLs)
                self.stagedPreviewURLs = urls
                self.onStateChange?()
                if show {
                    QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
                }
                if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.reloadData() }
            } catch {
                guard let self, self.previewGeneration == gen else { return }
                self.isStagingPreview = false
                self.onStateChange?()
                if !Task.isCancelled, !(error is CancellationError) { self.present(error) }
            }
        }
    }

    private func clearPreviewStaging() {
        RemoteStaging.discard(stagedPreviewURLs)
        stagedPreviewURLs = []
    }

    func copySelection(cut: Bool) {
        let ids = selectedItems.map(\.id)
        guard !ids.isEmpty else { return }
        if cut { Clipboard.shared.cut(resources: ids) } else { Clipboard.shared.copy(resources: ids) }
    }

    func paste(forceMove: Bool) {
        Clipboard.shared.paste(intoResource: directory, forceMove: forceMove)
    }

    var canPaste: Bool { capabilities.canWrite && (Clipboard.shared.hasFiles || Clipboard.shared.hasResources) }

    func deleteSelection(confirm: Bool = true) {
        let sel = selectedItems
        guard !sel.isEmpty, capabilities.canDelete else { NSSound.beep(); return }
        let run = { [weak self] in
            guard let self else { return }
            RemoteMutationTracker.shared.run {
                do {
                    try await ResourceActions.delete(sel.map(\.id), provider: self.provider)
                    self.reload()
                } catch {
                    self.present(error)
                    self.reload()
                }
            }
        }
        guard confirm else { run(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = sel.count == 1 ? "Delete “\(sel[0].name)” immediately?" : "Delete \(sel.count) items immediately?"
        alert.informativeText = (ResourceActions.trashUnavailableReason(provider: provider) ?? "") + " This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let w = view.window {
            alert.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { run() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            run()
        }
    }

    func moveToTrash() {
        if capabilities.canTrash {
            let ids = selectedItems.map(\.id)
            let provider = self.provider
            RemoteMutationTracker.shared.run { [weak self] in
                do { try await ResourceActions.trash(ids, provider: provider) } catch { self?.present(error) }
                self?.reload()
            }
        } else {
            NSSound.beep()
        }
    }

    func newFolder() {
        guard capabilities.contains(.makeDirectory) else { NSSound.beep(); return }
        let dir = directory
        let provider = self.provider
        RemoteMutationTracker.shared.run { [weak self] in
            do {
                let made = try await ResourceActions.makeDirectory(in: dir, provider: provider)
                guard let self else { return }
                self.pendingSelectionNames = [made.name]
                self.reload()
                self.renameAfterLoad = made.name
            } catch { self?.present(error) }
        }
    }

    private var renameAfterLoad: String? {
        didSet { scheduleRenameAfterLoad() }
    }

    private func scheduleRenameAfterLoad() {
        guard let name = renameAfterLoad else { return }
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                if !self.isLoading, self.items.contains(where: { $0.name == name }) {
                    self.renameAfterLoad = nil
                    self.select(names: [name])
                    self.beginRename()
                    return
                }
            }
        }
    }

    func beginRename() {
        guard capabilities.canRename, selectedItems.count == 1, let row = table.selectedRowIndexes.first, items.indices.contains(row),
              let tf = nameField(row: row) else { NSSound.beep(); return }
        renameFailureMessage = nil
        startEditing(tf, id: items[row].id, text: nil, isDirectory: items[row].isDirectory)
    }

    private func nameField(row: Int) -> NSTextField? {
        guard let col = table.tableColumns.firstIndex(where: { $0.identifier == Col.name }) else { return nil }
        return (table.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
    }

    private func startEditing(_ tf: NSTextField, id: ResourceID, text: String?, isDirectory: Bool) {
        renamingID = id
        tf.isEditable = true
        tf.delegate = self
        if let text { tf.stringValue = text }
        view.window?.makeFirstResponder(tf)
        guard let editor = tf.currentEditor() else { return }
        let name = tf.stringValue as NSString
        if text != nil {
            editor.selectedRange = NSRange(location: name.length, length: 0)
            return
        }
        let ext = name.pathExtension
        editor.selectedRange = NSRange(location: 0, length: ext.isEmpty || isDirectory ? name.length : name.length - ext.count - 1)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard renamingID != nil else { return }
        InlineWarning.dismiss()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, let id = renamingID else { return }
        renamingID = nil
        tf.isEditable = false
        let newName = tf.stringValue
        guard newName != id.name, !newName.isEmpty else {
            tf.stringValue = id.name
            renameFailureMessage = nil
            InlineWarning.dismiss()
            return
        }
        let provider = self.provider
        RemoteMutationTracker.shared.run { [weak self] in
            do {
                let renamed = try await ResourceActions.rename(id, to: newName, provider: provider)
                guard let self else { return }
                self.renameFailureMessage = nil
                InlineWarning.dismiss()
                self.pendingSelectionNames = [renamed.name]
                self.reload()
            } catch {
                self?.renameFailed(id, typed: newName, error: error)
            }
        }
        view.window?.makeFirstResponder(table)
    }

    private func renameFailed(_ id: ResourceID, typed: String, error: Error) {
        guard !(error is CancellationError), (error as? ResourceError) != .cancelled else { return }
        guard renamingID == nil, let row = items.firstIndex(where: { $0.id == id }), let tf = nameField(row: row) else {
            present(error)
            return
        }
        NSSound.beep()
        let message = error.localizedDescription
        renameFailureMessage = message
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        startEditing(tf, id: id, text: typed, isDirectory: items[row].isDirectory)
        InlineWarning.show(message, relativeTo: tf)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let id = renamingID {
            renamingID = nil
            renameFailureMessage = nil
            InlineWarning.dismiss()
            (control as? NSTextField)?.abortEditing()
            (control as? NSTextField)?.stringValue = id.name
            (control as? NSTextField)?.isEditable = false
            view.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func uploadFiles() {
        guard capabilities.canWrite else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        let dir = directory
        let done: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, !panel.urls.isEmpty else { return }
            RemoteTransfers.enqueue(panel.urls.map(ResourceID.local), into: dir, move: false)
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    func downloadSelection() {
        let ids = selectedItems.map(\.id)
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let done: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let dest = panel.url else { return }
            RemoteTransfers.enqueue(ids, into: .local(dest), move: false)
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    static func serverPath(for id: ResourceID) -> String {
        switch RemoteIntegration.shared.manager.server(providerID: id.providerID)?.kind {
        case .s3(let c)?:
            let key = (c.prefix.isEmpty ? "" : c.prefix + "/") + id.path.dropFirst()
            return "s3://\(c.bucket)/\(key)"
        case .sftp(let c)?:
            return "sftp://\(c.username)@\(c.destinationHost)\(c.port == 22 ? "" : ":\(c.port)")\(id.path)"
        case nil:
            return id.path
        }
    }

    func copyPath() {
        let ids = selectedItems.isEmpty ? [directory] : selectedItems.map(\.id)
        let lines = ids.map(Self.serverPath(for:))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func present(_ error: Error) {
        guard !(error is CancellationError), (error as? ResourceError) != .cancelled else { return }
        if let w = view.window { NSAlert(error: error).beginSheetModal(for: w) } else { NSAlert(error: error).runModal() }
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        if row >= 0, !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let menu = NSMenu()
        let hasSel = !selectedItems.isEmpty
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            menu.addItem(i)
        }
        if hasSel {
            add(openSelectionTitle, #selector(menuOpen(_:)))
            add("Quick Look", #selector(menuQuickLook(_:)), enabled: selectedItems.contains { !$0.isDirectory })
            menu.addItem(.separator())
            add("Download…", #selector(menuDownload(_:)))
            add("Copy", #selector(menuCopy(_:)))
            add("Rename", #selector(menuRename(_:)), enabled: capabilities.canRename && selectedItems.count == 1)
            add("Copy Path", #selector(menuCopyPath(_:)))
            menu.addItem(.separator())
            if capabilities.canTrash { add("Move to Trash", #selector(menuTrash(_:))) }
            add("Delete Immediately…", #selector(menuDelete(_:)), enabled: capabilities.canDelete)
        } else {
            add("New Folder", #selector(menuNewFolder(_:)), enabled: capabilities.contains(.makeDirectory))
            add("Upload Files…", #selector(menuUpload(_:)), enabled: capabilities.canWrite)
            add("Paste", #selector(menuPaste(_:)), enabled: canPaste)
            add("Copy Path", #selector(menuCopyPath(_:)))
            menu.addItem(.separator())
            add(showsDisconnected ? "Reconnect" : "Refresh", #selector(menuRefresh(_:)))
        }
        return menu
    }

    @objc private func menuOpen(_ s: Any?) { openSelection() }
    @objc private func menuQuickLook(_ s: Any?) { toggleQuickLook() }
    @objc private func menuDownload(_ s: Any?) { downloadSelection() }
    @objc private func menuCopy(_ s: Any?) { copySelection(cut: false) }
    @objc private func menuRename(_ s: Any?) { beginRename() }
    @objc private func menuCopyPath(_ s: Any?) { copyPath() }
    @objc private func menuTrash(_ s: Any?) { moveToTrash() }
    @objc private func menuDelete(_ s: Any?) { deleteSelection() }
    @objc private func menuNewFolder(_ s: Any?) { newFolder() }
    @objc private func menuUpload(_ s: Any?) { uploadFiles() }
    @objc private func menuPaste(_ s: Any?) { paste(forceMove: false) }
    @objc private func menuRefresh(_ s: Any?) { showsDisconnected ? reconnect() : reload() }

    func previewSourceRect(for url: URL) -> NSRect? {
        guard let i = stagedPreviewURLs.firstIndex(of: url) else { return nil }
        let files = selectedItems.filter { !$0.isDirectory }
        guard i < files.count, let row = items.firstIndex(where: { $0.id == files[i].id }), let window = view.window else { return nil }
        let r = table.convert(table.rect(ofRow: row), to: nil)
        return window.convertToScreen(NSRect(x: r.minX + 4, y: r.minY, width: 16, height: r.height))
    }
}

@MainActor
final class RemoteTableView: NSTableView {
    weak var remote: RemoteBrowserViewController?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 51, flags == [.command, .option] { remote?.deleteSelection(); return }
        if let pane = remote?.pane, pane.handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { remote?.contextMenu(for: event) }
}

struct RemoteDisconnectedError: LocalizedError, Equatable {
    let title: String
    var errorDescription: String? { "Disconnected from “\(title)”. Choose Reconnect to browse it again." }
}

enum RemoteOpenCopies {
    static let confirmedKey = "remoteOpenCopyConfirmed"
    static var directoryOverride: URL?
    @MainActor static var opener: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    static func notice(serverTitle: String) -> String {
        "betterfinder downloads a copy to your Downloads folder and opens it there. Changes you make to the copy aren’t uploaded to “\(serverTitle)”."
    }

    static func download(_ items: [ResourceItem], provider: ResourceProvider, into dir: URL = directory) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let (staging, base) = try makeStaging(for: dir)
        defer {
            try? fm.removeItem(at: staging)
            if let base { rmdir(base.path) }
        }
        var out: [URL] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let name = fileName(for: item)
            let slot = staging.appendingPathComponent(String(index), isDirectory: true)
            try fm.createDirectory(at: slot, withIntermediateDirectories: false)
            let temp = slot.appendingPathComponent(name)
            _ = try await provider.download(item.id, to: temp, progress: { _ in })
            try Task.checkCancellation()
            out.append(try publish(temp, as: name, in: dir))
        }
        return out
    }

    static func fileName(for item: ResourceItem) -> String {
        let name = item.name
        return name.isEmpty || name == "." || name == ".." || name.contains("/") ? "item" : name
    }

    static func candidateName(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
    }

    private static func makeStaging(for dir: URL) throws -> (URL, URL?) {
        let fm = FileManager.default
        let id = "betterfinder-open-\(UUID().uuidString)"
        if let base = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true) {
            let staging = base.appendingPathComponent(id, isDirectory: true)
            if (try? fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil {
                return (staging, base)
            }
            rmdir(base.path)
        }
        let staging = fm.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (staging, nil)
    }

    static func publish(_ file: URL, as name: String, in dir: URL, maxAttempts: Int = 10_000) throws -> URL {
        for attempt in 1...maxAttempts {
            let target = dir.appendingPathComponent(candidateName(name, attempt: attempt))
            if renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let code = errno
            switch code {
            case EEXIST:
                continue
            case EXDEV, ENOTSUP, EINVAL:
                if try copyExclusively(file, to: target) { return target }
            default:
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dir.appendingPathComponent(name).path])
    }

    static func copyExclusively(_ file: URL, to target: URL) throws -> Bool {
        let src = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard src >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(src) }
        let dst = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if dst < 0 {
            let code = errno
            if code == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        if fcopyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 {
            let code = errno
            close(dst)
            unlink(target.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        close(dst)
        return true
    }
}

enum RemoteStaging {
    static let previewLimit: Int64 = 512 << 20

    static var root: URL { StagingArea.root.appendingPathComponent("Previews", isDirectory: true) }

    static func stage(_ items: [ResourceItem], provider: ResourceProvider?, purpose: String, limit: Int64? = nil) async throws -> [URL] {
        guard let provider else { throw ResourceError.providerUnavailable("remote") }
        if let limit, let big = items.first(where: { ($0.size ?? 0) > limit }) {
            throw ResourceError.unsupported("Previewing “\(big.name)” (\(SizeFormatter.string(big.size ?? 0)))")
        }
        let dir = root.appendingPathComponent(purpose, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var out: [URL] = []
        do {
            for item in items {
                try Task.checkCancellation()
                let sub = dir.appendingPathComponent(String(out.count), isDirectory: true)
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                let dest = sub.appendingPathComponent(item.name.isEmpty ? "item" : item.name)
                _ = try await provider.download(item.id, to: dest, progress: { _ in })
                out.append(dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return out
    }

    static func discard(_ urls: [URL]) {
        let dirs = Set(urls.map { $0.deletingLastPathComponent().deletingLastPathComponent() })
        for d in dirs where d.path.hasPrefix(root.path) { try? FileManager.default.removeItem(at: d) }
    }

    static func purge(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        for purpose in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for d in (try? fm.contentsOfDirectory(at: purpose, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(m) > age { try? fm.removeItem(at: d) }
            }
        }
    }
}

@MainActor
enum RemoteTransfers {
    private static var observers: [UUID: AnyCancellable] = [:]

    @discardableResult
    static func enqueue(_ sources: [ResourceID], into destination: ResourceID, move: Bool, queue explicitQueue: FileOperationQueue? = nil) -> FileOperation? {
        let queue = explicitQueue ?? .shared
        guard !sources.isEmpty else { return nil }
        let request = ResourceTransferRequest(mode: move ? .move : .copy, sources: sources, into: destination)
        let op: FileOperation
        if request.involvesRemote {
            op = queue.enqueueTransfer(request)
        } else {
            let urls = sources.compactMap(\.fileURL)
            guard let d = destination.fileURL else { return nil }
            op = queue.enqueue(move ? .move(sources: urls, destination: d) : .copy(sources: urls, destination: d))
        }
        track(op, providers: Set(sources.map(\.providerID) + [destination.providerID]))
        return op
    }

    static func track(_ op: FileOperation, providers: Set<String>) {
        let key = UUID()
        observers[key] = op.$state.sink { state in
            switch state {
            case .finished, .failed, .cancelled:
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .remoteResourcesDidChange, object: nil, userInfo: ["providerIDs": Array(providers)])
                    observers[key] = nil
                }
            default: break
            }
        }
    }
}
