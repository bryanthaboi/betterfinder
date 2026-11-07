import AppKit
import FSCore
import Quartz
import Theming

@MainActor
final class ColumnViewController: BrowserContentController, NSTableViewDataSource, NSTableViewDelegate {
    @MainActor
    final class Column {
        let url: URL?
        let model: FolderModel
        let container = NSView()
        let scroll = NSScrollView()
        let table = ColumnTableView()
        var items: [FileItem] = []
        var focusFirstWhenLoaded = false
        init(url: URL?, model: FolderModel) { self.url = url; self.model = model }
    }

    private var columns: [Column] = []
    private let hscroll = ColumnScrollView()
    private let stack = NSStackView()
    private let preview = PreviewColumnView()
    private var suppressSelection = 0
    private var focusedIndex = 0
    let spring = SpringLoader()
    static let columnWidth: CGFloat = Spacing.columnWidth

    override func loadView() {
        hscroll.hasHorizontalScroller = true
        hscroll.hasVerticalScroller = false
        hscroll.autohidesScrollers = true
        hscroll.borderType = .noBorder
        hscroll.horizontalScrollElasticity = .allowed
        ThemeHooks.install(scroll: hscroll)
        hscroll.verticalScrollElasticity = .none
        let clip = FlippedClipView()
        hscroll.contentView = clip
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .top
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        hscroll.documentView = stack
        let documentHeight = stack.heightAnchor.constraint(equalTo: hscroll.heightAnchor)
        hscroll.documentHeight = documentHeight
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            documentHeight,
        ])
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view = hscroll
    }

    override func updateAccessibility(location: BrowserLocation) {}

    override var keyView: NSView? { columns.indices.contains(focusedIndex) ? columns[focusedIndex].table : columns.last?.table }

    override func applyTheme(_ theme: Theme) {
        hscroll.backgroundColor = theme.listBackground
        for c in columns { style(c, theme) }
        preview.applyTheme(theme)
    }

    private func style(_ c: Column, _ theme: Theme) {
        c.table.backgroundColor = theme.listBackground
        let lay = theme.layout
        c.table.rowHeight = ListViewController.fittedRowHeight(theme)
        c.table.intercellSpacing = .zero
        let padV = lay.isAuthenticCompact ? Spacing.xxs : Spacing.xs
        c.scroll.automaticallyAdjustsContentInsets = false
        c.scroll.contentInsets = NSEdgeInsets(top: padV, left: 0, bottom: padV, right: 0)
        ThemeHooks.apply(theme, table: c.table)
        c.scroll.backgroundColor = theme.listBackground
        c.container.wantsLayer = true
        c.container.layer?.borderColor = theme.borderColor.cgColor
        c.table.reloadData()
    }

    override func usesModel(_ model: FolderModel) -> Bool {
        columns.contains { $0.model === model }
    }

    override func teardown() {
        spring.cancel()
        let paneModel = pane?.model
        for c in columns {
            c.model.removeObserver(self)
            c.focusFirstWhenLoaded = false
            c.table.dataSource = nil
            c.table.delegate = nil
            if c.model !== paneModel { c.model.stop() }
        }
        columns.removeAll()
    }


    private func makeColumn(url: URL?, model: FolderModel) -> Column {
        let c = Column(url: url, model: model)
        c.items = model.items
        let col = NSTableColumn(identifier: .init("col"))
        col.resizingMask = .autoresizingMask
        c.table.addTableColumn(col)
        c.table.headerView = nil
        c.table.style = .fullWidth
        c.table.allowsMultipleSelection = true
        c.table.allowsTypeSelect = true
        c.table.dataSource = self
        c.table.delegate = self
        c.table.target = self
        c.table.doubleAction = #selector(doubleClicked(_:))
        c.table.columnController = self
        c.table.registerForDraggedTypes(DropSupport.types)
        c.table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        c.table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        c.table.setAccessibilityLabel("Files in \(url.map { FileManager.default.displayName(atPath: $0.path) } ?? (pane?.location.displayName ?? "folder"))")
        c.scroll.documentView = c.table
        c.scroll.hasVerticalScroller = true
        c.scroll.autohidesScrollers = true
        c.scroll.borderType = .noBorder
        c.scroll.translatesAutoresizingMaskIntoConstraints = false
        ThemeHooks.install(scroll: c.scroll)
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        c.container.addSubview(c.scroll)
        c.container.addSubview(sep)
        c.container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            c.container.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            c.scroll.topAnchor.constraint(equalTo: c.container.topAnchor),
            c.scroll.bottomAnchor.constraint(equalTo: c.container.bottomAnchor),
            c.scroll.leadingAnchor.constraint(equalTo: c.container.leadingAnchor),
            c.scroll.trailingAnchor.constraint(equalTo: sep.leadingAnchor),
            sep.topAnchor.constraint(equalTo: c.container.topAnchor),
            sep.bottomAnchor.constraint(equalTo: c.container.bottomAnchor),
            sep.trailingAnchor.constraint(equalTo: c.container.trailingAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
        ])
        model.addObserver(self) { [weak self, weak c] change in
            guard let self, let c else { return }
            self.columnModelChanged(c, change)
        }
        style(c, ThemeManager.shared.current)
        return c
    }

    private func appendColumn(_ c: Column) {
        columns.append(c)
        c.items = c.model.items
        c.table.reloadData()
        hidePreview()
        stack.addArrangedSubview(c.container)
        c.container.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        scrollToEnd()
    }

    private func truncate(after index: Int) {
        guard index + 1 < columns.count else { hidePreview(); return }
        let removed = columns[(index + 1)...]
        for c in removed {
            c.container.removeFromSuperview()
            c.model.removeObserver(self)
            if c.model !== pane?.model { c.model.stop() }
        }
        columns.removeSubrange((index + 1)...)
        hidePreview()
        if focusedIndex >= columns.count { focusedIndex = max(0, columns.count - 1) }
    }

    private func removeAll() {
        truncate(after: -1)
    }

    private func scrollToEnd() {
        view.layoutSubtreeIfNeeded()
        let w = stack.fittingSize.width
        let clipW = hscroll.contentView.bounds.width
        let x = max(0, w - clipW)
        hscroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        hscroll.reflectScrolledClipView(hscroll.contentView)
    }

    override func locationDidChange() {
        guard let pane else { return }
        let loc = pane.location
        let model = pane.model
        if let idx = columns.firstIndex(where: { $0.model === model }) {
            focusedIndex = idx
            syncParentSelections()
            return
        }
        if let url = loc.url {
            if let idx = columns.firstIndex(where: { $0.url?.pathKey == url.pathKey }) {
                truncate(after: idx - 1)
                appendColumn(makeColumn(url: url, model: model))
                focusedIndex = columns.count - 1
                syncParentSelections()
                return
            }
            let parentKey = url.deletingLastPathComponent().pathKey
            if let idx = columns.lastIndex(where: { $0.url?.pathKey == parentKey }) {
                truncate(after: idx)
                appendColumn(makeColumn(url: url, model: model))
                syncParentSelections()
                return
            }
        }
        removeAll()
        appendColumn(makeColumn(url: loc.url, model: model))
        focusedIndex = 0
    }

    private func syncParentSelections() {
        suppressSelection += 1
        defer { suppressSelection -= 1 }
        for i in 1..<max(1, columns.count) {
            guard let childURL = columns[i].url else { continue }
            let parent = columns[i - 1]
            if let row = parent.items.firstIndex(where: { $0.url.pathKey == childURL.pathKey }) {
                if parent.table.selectedRowIndexes != [row] { parent.table.selectRowIndexes([row], byExtendingSelection: false) }
                parent.table.scrollRowToVisible(row)
            }
        }
    }

    private func columnModelChanged(_ c: Column, _ change: FolderModel.Change) {
        let selectedKeys = Set(c.table.selectedRowIndexes.compactMap { c.items.indices.contains($0) ? c.items[$0].url.pathKey : nil })
        let newItems = c.model.items
        suppressSelection += 1
        switch change {
        case .reset:
            c.items = newItems
            c.table.reloadData()
            var idx = IndexSet()
            for (i, it) in newItems.enumerated() where selectedKeys.contains(it.url.pathKey) { idx.insert(i) }
            c.table.selectRowIndexes(idx, byExtendingSelection: false)
        case .diff(let d):
            c.items = newItems
            c.table.beginUpdates()
            if !d.removed.isEmpty { c.table.removeRows(at: d.removed, withAnimation: []) }
            if !d.inserted.isEmpty { c.table.insertRows(at: d.inserted, withAnimation: []) }
            c.table.endUpdates()
            if !d.updated.isEmpty { c.table.reloadData(forRowIndexes: d.updated, columnIndexes: [0]) }
        }
        suppressSelection -= 1
        if let i = columns.firstIndex(where: { $0 === c }), i + 1 < columns.count { syncParentSelections() }
        if c.focusFirstWhenLoaded, !c.items.isEmpty {
            c.focusFirstWhenLoaded = false
            view.window?.makeFirstResponder(c.table)
            c.table.selectRowIndexes([0], byExtendingSelection: false)
        }
        if c.model === pane?.model { notifySelection() }
    }

    private var paneColumn: Column? {
        columns.first { $0.model === pane?.model }
    }


    override var selectedItems: [FileItem] {
        guard let c = paneColumn else { return [] }
        return c.table.selectedRowIndexes.compactMap { c.items.indices.contains($0) ? c.items[$0] : nil }
    }

    override func select(_ urls: [URL], scroll: Bool) {
        guard let c = paneColumn else { return }
        let keys = Set(urls.map(\.pathKey))
        var idx = IndexSet()
        for (i, it) in c.items.enumerated() where keys.contains(it.url.pathKey) { idx.insert(i) }
        suppressSelection += 1
        c.table.selectRowIndexes(idx, byExtendingSelection: false)
        suppressSelection -= 1
        if scroll, let f = idx.first { c.table.scrollRowToVisible(f) }
        updatePreview()
        notifySelection()
    }

    override func focus() {
        if let c = paneColumn ?? columns.last { view.window?.makeFirstResponder(c.table) }
    }

    override func refreshDisplay() {
        for c in columns { c.table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<c.table.numberOfRows), columnIndexes: [0]) }
    }

    override func beginRename(_ url: URL) {
        for c in columns {
            guard let row = c.items.firstIndex(where: { $0.url.pathKey == url.pathKey }) else { continue }
            c.table.scrollRowToVisible(row)
            guard let cell = c.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView, let tf = cell.textField else { return }
            RenameSession.begin(url: url, field: tf) { [weak self, weak c] renamed in
                if let renamed { self?.pane?.expectSelection([renamed]); c?.model.refresh() } else {
                    c?.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
                }
                if let c { self?.view.window?.makeFirstResponder(c.table) }
            }
            return
        }
    }

    override func previewSourceRect(for url: URL) -> NSRect? {
        guard let window = view.window else { return nil }
        if preview.superview != nil, preview.url?.pathKey == url.pathKey, let r = preview.iconRectInWindow() {
            return window.convertToScreen(r)
        }
        for c in columns {
            guard let row = c.items.firstIndex(where: { $0.url.pathKey == url.pathKey }),
                  let cell = c.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView, let iv = cell.imageView else { continue }
            return window.convertToScreen(iv.convert(iv.bounds, to: nil))
        }
        return nil
    }

    override func previewImage(for url: URL) -> NSImage? {
        for c in columns { if let it = c.items.first(where: { $0.url.pathKey == url.pathKey }) { return IconCache.shared.icon(for: it) } }
        return nil
    }

    override func sizeDidChange(_ key: String) {
        if preview.url?.pathKey == key { updatePreview() }
    }


    private func hidePreview() {
        if preview.superview != nil { preview.removeFromSuperview() }
        preview.show(nil, sizes: nil)
    }

    private func updatePreview() {
        let sel = selectedItems
        guard sel.count == 1, !sel[0].isBrowsableFolder, let c = paneColumn, c === columns.last else { hidePreview(); return }
        if preview.superview == nil {
            stack.addArrangedSubview(preview)
            preview.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        preview.show(sel[0], sizes: pane?.sizes)
        scrollToEnd()
    }


    private func column(for tableView: NSTableView) -> Int? {
        columns.firstIndex { $0.table === tableView }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard suppressSelection == 0, let table = notification.object as? NSTableView, let k = column(for: table) else { return }
        focusedIndex = k
        userSelected(in: k)
    }

    private func userSelected(in k: Int) {
        guard let pane else { return }
        let c = columns[k]
        let sel = c.table.selectedRowIndexes.compactMap { c.items.indices.contains($0) ? c.items[$0] : nil }
        if sel.count == 1, sel[0].isBrowsableFolder, c.url != nil {
            if k + 1 < columns.count, columns[k + 1].url?.pathKey == sel[0].url.pathKey {
                truncate(after: k + 1)
                if pane.model !== columns[k + 1].model {
                    pane.navigate(to: .folder(sel[0].url), record: false, reuse: columns[k + 1].model)
                }
                return
            }
            truncate(after: k)
            pane.navigate(to: .folder(sel[0].url), record: false)
            return
        }
        truncate(after: k)
        if pane.model !== c.model {
            pane.navigate(to: pane.location.isVirtual || c.url == nil ? pane.location : .folder(c.url!), record: false, reuse: c.model)
        }
        updatePreview()
        notifySelection()
    }

    func moveRight() {
        guard columns.indices.contains(focusedIndex) else { return }
        let c = columns[focusedIndex]
        let sel = c.table.selectedRowIndexes
        guard sel.count == 1, let row = sel.first, c.items.indices.contains(row), c.items[row].isBrowsableFolder else { return }
        if focusedIndex + 1 >= columns.count || columns[focusedIndex + 1].url?.pathKey != c.items[row].url.pathKey {
            userSelected(in: focusedIndex)
        }
        guard focusedIndex + 1 < columns.count else { return }
        let next = columns[focusedIndex + 1]
        focusedIndex += 1
        view.window?.makeFirstResponder(next.table)
        if next.items.isEmpty { next.focusFirstWhenLoaded = true } else if next.table.selectedRowIndexes.isEmpty {
            next.table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func moveLeft() {
        guard focusedIndex > 0, columns.indices.contains(focusedIndex) else { return }
        let k = focusedIndex
        let c = columns[k]
        truncate(after: k)
        if pane?.model !== c.model, let url = c.url {
            pane?.navigate(to: .folder(url), record: false, reuse: c.model)
        }
        suppressSelection += 1
        c.table.deselectAll(nil)
        suppressSelection -= 1
        hidePreview()
        focusedIndex = k - 1
        view.window?.makeFirstResponder(columns[k - 1].table)
        notifySelection()
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        let sel = selectedItems
        if sel.count == 1, sel[0].isBrowsableFolder { return }
        pane?.openSelection(sender)
    }

    func contextMenu(for table: NSTableView, event: NSEvent) -> NSMenu? {
        guard let pane, let k = column(for: table) else { return nil }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        if row >= 0, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            suppressSelection += 1
            table.deselectAll(nil)
            suppressSelection -= 1
            focusedIndex = k
            userSelected(in: k)
        }
        return ContextMenuBuilder.menu(for: pane)
    }


    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let k = column(for: tableView) else { return 0 }
        return columns[k].items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let k = column(for: tableView), columns[k].items.indices.contains(row) else { return nil }
        let it = columns[k].items[row]
        let theme = ThemeManager.shared.current
        let cell = (tableView.makeView(withIdentifier: .init("colcell"), owner: self) as? ColumnCellView) ?? ColumnCellView()
        if cell.textField?.font != theme.listFont { cell.textField?.font = theme.listFont; cell.needsLayout = true }
        cell.normalTextColor = theme.textColor
        let shown = it.isPackage ? FileManager.default.displayName(atPath: it.url.path) : it.name
        cell.textField?.stringValue = shown
        cell.textField?.isEditable = false
        cell.setAccessibilityLabel(ListViewController.accessibilityLabel(for: it, name: shown, cut: Clipboard.shared.isCut(it.url)))
        cell.setIcon(for: it, dimmed: Clipboard.shared.isCut(it.url) ? 0.4 : (it.isHidden ? 0.5 : 1))
        cell.chevron.isHidden = !it.isBrowsableFolder
        let leading = theme.layout.listLeadingInset
        if cell.leadingInset != leading { cell.leadingInset = leading }
        cell.chevronTint = theme.secondaryTextColor
        cell.refreshTextColor()
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView()
        r.rowIndex = row
        return r
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let k = column(for: tableView), columns[k].items.indices.contains(row) else { return nil }
        return columns[k].items[row].name
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let k = column(for: tableView), columns[k].items.indices.contains(row) else { return nil }
        return columns[k].items[row].url as NSURL
    }

    private func dropTarget(_ tableView: NSTableView, row: Int, op: NSTableView.DropOperation) -> (URL, Int)? {
        guard let k = column(for: tableView) else { return nil }
        let c = columns[k]
        if op == .on, c.items.indices.contains(row), c.items[row].isBrowsableFolder { return (c.items[row].url, row) }
        if let u = c.url { return (u, -1) }
        return nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let (dest, targetRow) = dropTarget(tableView, row: row, op: dropOperation) else { spring.cancel(); return [] }
        tableView.setDropRow(targetRow, dropOperation: .on)
        let op = DropSupport.operation(for: info, destination: dest)
        if targetRow >= 0, !op.isEmpty {
            spring.hover(dest) { [weak tableView] in
                tableView?.selectRowIndexes([targetRow], byExtendingSelection: false)
            }
        } else {
            spring.cancel()
        }
        return op
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        spring.cancel()
        guard let (dest, _) = dropTarget(tableView, row: row, op: dropOperation) else { return false }
        return DropSupport.perform(info, destination: dest)
    }
}

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

fileprivate final class PreviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class ColumnCellView: FileCellView {
    let chevron = NSImageView()
    var chevronTint: NSColor = .secondaryLabelColor { didSet { refreshTextColor() } }

    override func selectionColorsDidChange(selected: Bool, textColor: NSColor) {
        chevron.contentTintColor = selected ? textColor : chevronTint
    }

    init() {
        super.init(identifier: .init("colcell"), showsIcon: true)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
    }

    override func layout() {
        let lay = ThemeManager.shared.layout
        let margin = lay.isAuthenticCompact ? Spacing.xxs : Spacing.xs
        let reserve = margin * 2 + Spacing.columnChevronWidth
        if trailingInset != reserve { trailingInset = reserve }
        super.layout()
        let size = chevron.intrinsicContentSize
        let ch = size.height > 0 ? size.height : 10
        chevron.frame = NSRect(x: bounds.width - margin - Spacing.columnChevronWidth, y: ((bounds.height - ch) / 2).rounded(), width: Spacing.columnChevronWidth, height: ch)
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class ColumnTableView: NSTableView {
    weak var columnController: ColumnViewController?

    override func keyDown(with event: NSEvent) {
        guard let cc = columnController else { super.keyDown(with: event); return }
        if let pane = cc.pane, pane.handleKeyDown(event) { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && event.keyCode == 124 { cc.moveRight(); return }
        if flags.isEmpty && event.keyCode == 123 { cc.moveLeft(); return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        columnController?.contextMenu(for: self, event: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        columnController?.spring.cancel()
        super.draggingExited(sender)
    }
}

@MainActor
final class PreviewColumnView: NSView {
    static let minimumPreviewHeight: CGFloat = 120
    private let ql: QLPreviewView
    private let name = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    let scroll = NSScrollView()
    private let content = PreviewDocumentView()
    private(set) var url: URL?

    override init(frame: NSRect) {
        ql = QLPreviewView(frame: .zero, style: .compact)!
        super.init(frame: frame)
        ql.autostarts = true
        ql.shouldCloseWithWindow = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        addSubview(scroll)
        for v in [ql, name, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        info.font = .systemFont(ofSize: 11)
        info.alignment = .left
        let pad = Spacing.panelPadding
        let square = ql.heightAnchor.constraint(equalTo: ql.widthAnchor)
        square.priority = .defaultHigh
        let fit = ql.heightAnchor.constraint(lessThanOrEqualTo: clip.heightAnchor, constant: -(pad * 2 + Spacing.s + 18))
        fit.priority = NSLayoutConstraint.Priority(rawValue: 760)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            ql.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            ql.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            ql.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            square,
            fit,
            ql.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPreviewHeight),
            name.topAnchor.constraint(equalTo: ql.bottomAnchor, constant: Spacing.s),
            name.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            name.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            info.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Spacing.xs),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            info.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Preview")
        ql.setAccessibilityLabel("Quick Look preview")
    }

    var previewFrame: NSRect { ql.frame }
    var infoFrameInContent: NSRect { info.frame }
    var contentHeight: CGFloat { content.frame.height }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: Theme) {
        wantsLayer = true
        layer?.backgroundColor = theme.listBackground.cgColor
        name.textColor = theme.textColor
        info.textColor = theme.secondaryTextColor
    }

    func iconRectInWindow() -> NSRect? {
        window == nil ? nil : ql.convert(ql.bounds, to: nil)
    }

    func show(_ item: FileItem?, sizes: SizeCoordinator?) {
        url = item?.url
        guard let item else {
            ql.previewItem = nil
            return
        }
        if ql.previewItem?.previewItemURL?.pathKey != item.url.pathKey { ql.previewItem = item.url as NSURL }
        name.stringValue = item.name
        setAccessibilityValue(item.name)
        var lines: [String] = [item.kindDescription]
        if let s = item.logicalSize { lines.append("Size: \(SizeFormatter.string(s)) (\(SizeFormatter.exact(s)))") }
        let f = ListViewController.dateFormatter
        if let d = item.dateCreated { lines.append("Created: \(f.string(from: d))") }
        if let d = item.dateModified { lines.append("Modified: \(f.string(from: d))") }
        if let d = item.dateAdded { lines.append("Added: \(f.string(from: d))") }
        if !item.tagNames.isEmpty { lines.append("Tags: \(item.tagNames.joined(separator: ", "))") }
        info.stringValue = lines.joined(separator: "\n")
    }
}

private final class ColumnScrollView: NSScrollView {
    var documentHeight: NSLayoutConstraint?

    override func tile() {
        super.tile()
        documentHeight?.constant = contentSize.height - bounds.height
    }
}
