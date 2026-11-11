import AppKit
import FSCore
import QuickLookThumbnailing
import Theming

@MainActor
final class IconViewController: BrowserContentController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection = BrowserCollectionView()
    private let scroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private(set) var items: [FileItem] = []
    let spring = SpringLoader()
    private let typeSelect = TypeSelectBuffer()
    static let itemID = NSUserInterfaceItemIdentifier("IconItem")

    override func loadView() {
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.dataSource = self
        collection.delegate = self
        collection.controller = self
        collection.register(IconItem.self, forItemWithIdentifier: Self.itemID)
        collection.registerForDraggedTypes(DropSupport.types)
        collection.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        collection.setAccessibilityLabel("Files")
        updateLayout()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        ThemeHooks.install(scroll: scroll)
        view = scroll
        NotificationCenter.default.addObserver(self, selector: #selector(optionsChanged), name: .browserViewOptionsDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    var iconSize: CGFloat { CGFloat(BrowserDefaults.iconSize) }

    private func updateLayout() {
        let theme = ThemeManager.shared.current
        let lay = theme.layout
        let inset = lay.iconGridInset
        layout.sectionInset = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        layout.minimumInteritemSpacing = lay.iconGridGapH
        layout.minimumLineSpacing = lay.iconGridGapV
        layout.itemSize = lay.iconItemSize(iconSize: iconSize, labelFont: theme.iconLabelFont, maxLines: theme.iconLabels.maxLines)
    }

    var itemSize: NSSize { layout.itemSize }

    @objc private func displayOptionsChanged() {
        let theme = ThemeManager.shared.current
        for case let item as IconItem in collection.visibleItems() { item.applyTheme(theme) }
    }

    private var layoutSignature: [CGFloat] {
        let i = layout.sectionInset
        return [layout.itemSize.width, layout.itemSize.height, layout.minimumInteritemSpacing, layout.minimumLineSpacing, i.top, i.left]
    }

    @objc private func optionsChanged() {
        let before = layoutSignature
        updateLayout()
        if before != layoutSignature {
            layout.invalidateLayout()
            collection.reloadData()
            restoreSelection(Set(selectedURLs.map(\.pathKey)))
        }
    }

    override var keyView: NSView? { collection }

    override func teardown() {
        spring.cancel()
        for case let item as IconItem in collection.visibleItems() { ThumbnailCache.shared.cancel(item.thumbnailRequest) }
        collection.dataSource = nil
        collection.delegate = nil
    }

    override func applyTheme(_ theme: Theme) {
        if isViewLoaded { optionsChanged() }
        collection.backgroundColors = [theme.listBackground]
        scroll.backgroundColor = theme.listBackground
        for case let item as IconItem in collection.visibleItems() { item.applyTheme(theme) }
    }

    override func modelDidChange(_ change: FolderModel.Change) {
        guard let model = pane?.model else { return }
        switch change {
        case .reset, .reorder:
            let sel = Set(selectedURLs.map(\.pathKey))
            items = model.items
            collection.reloadData()
            restoreSelection(sel)
        case .diff(let d):
            items = model.items
            collection.performBatchUpdates({
                if !d.removed.isEmpty { collection.deleteItems(at: Set(d.removed.map { IndexPath(item: $0, section: 0) })) }
                if !d.inserted.isEmpty { collection.insertItems(at: Set(d.inserted.map { IndexPath(item: $0, section: 0) })) }
            })
            if !d.updated.isEmpty { collection.reloadItems(at: Set(d.updated.map { IndexPath(item: $0, section: 0) })) }
        }
    }

    override func locationDidChange() {
        items = []
        collection.reloadData()
        collection.scroll(.zero)
    }

    private func restoreSelection(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        var paths = Set<IndexPath>()
        for (i, it) in items.enumerated() where keys.contains(it.url.pathKey) { paths.insert(IndexPath(item: i, section: 0)) }
        collection.selectionIndexPaths = paths
    }

    override var selectedItems: [FileItem] {
        collection.selectionIndexPaths.sorted().compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
    }

    override func select(_ urls: [URL], scroll: Bool) {
        let keys = Set(urls.map(\.pathKey))
        var paths = Set<IndexPath>()
        for (i, it) in items.enumerated() where keys.contains(it.url.pathKey) { paths.insert(IndexPath(item: i, section: 0)) }
        collection.selectionIndexPaths = paths
        if scroll, !paths.isEmpty { collection.scrollToItems(at: [paths.min()!], scrollPosition: .nearestHorizontalEdge) }
        notifySelection()
    }

    override func focus() { view.window?.makeFirstResponder(collection) }

    override func refreshDisplay() {
        for case let item as IconItem in collection.visibleItems() {
            if let ip = collection.indexPath(for: item), items.indices.contains(ip.item) { configure(item, items[ip.item]) }
        }
    }

    override func beginRename(_ url: URL) {
        guard let i = items.firstIndex(where: { $0.url.pathKey == url.pathKey }) else { return }
        let ip = IndexPath(item: i, section: 0)
        collection.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        collection.selectionIndexPaths = [ip]
        guard let item = collection.item(at: ip) as? IconItem, let tf = item.textField else { return }
        tf.isBezeled = false
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        RenameSession.begin(url: url, field: tf) { [weak self, weak item] renamed in
            guard let self else { return }
            if let item { tf.drawsBackground = false; if let it = self.items.indices.contains(i) ? self.items[i] : nil { self.configure(item, it) } }
            if let renamed { self.pane?.expectSelection([renamed]); self.pane?.model.refresh() }
            self.focus()
        }
    }

    override func previewSourceRect(for url: URL) -> NSRect? {
        guard let i = items.firstIndex(where: { $0.url.pathKey == url.pathKey }),
              let item = collection.item(at: IndexPath(item: i, section: 0)) as? IconItem,
              let iv = item.imageView, let window = view.window, !iv.isHiddenOrHasHiddenAncestor else { return nil }
        let r = iv.convert(iv.bounds, to: nil)
        guard collection.visibleRect.intersects(collection.convert(r, from: nil)) else { return nil }
        return window.convertToScreen(r)
    }

    override func previewImage(for url: URL) -> NSImage? {
        guard let it = items.first(where: { $0.url.pathKey == url.pathKey }) else { return nil }
        return ThumbnailCache.shared.cached(it.url, size: iconSize) ?? IconCache.shared.icon(for: it, size: iconSize)
    }


    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! IconItem
        if items.indices.contains(indexPath.item) { configure(item, items[indexPath.item]) }
        return item
    }

    private func configure(_ item: IconItem, _ it: FileItem) {
        let theme = ThemeManager.shared.current
        item.applyTheme(theme)
        item.representedURL = it.url
        let shown = it.isPackage ? FileManager.default.displayName(atPath: it.url.path) : HomeLabel.name(it.name, for: it.url)
        item.textField?.stringValue = shown
        item.textField?.isEditable = false
        item.iconSize = iconSize
        let dim: CGFloat = Clipboard.shared.isCut(it.url) ? 0.4 : (it.isHidden ? 0.5 : 1)
        item.imageView?.alphaValue = dim
        let key = it.url.pathKey
        if let thumb = ThumbnailCache.shared.cached(it.url, size: iconSize) {
            item.imageView?.image = thumb
        } else {
            item.imageView?.image = IconCache.shared.icon(for: it, size: iconSize) { [weak item] img in
                guard let item, item.representedURL?.pathKey == key, item.hasThumbnail == false else { return }
                item.imageView?.image = img
            }
            item.hasThumbnail = false
            ThumbnailCache.shared.cancel(item.thumbnailRequest)
            let scale = view.window?.backingScaleFactor ?? 2
            item.thumbnailRequest = ThumbnailCache.shared.request(it, size: iconSize, scale: scale) { [weak item] img in
                guard let item, item.representedURL?.pathKey == key else { return }
                item.hasThumbnail = true
                item.imageView?.image = img
            }
        }
        item.view.setAccessibilityLabel(ListViewController.accessibilityLabel(for: it, name: shown, cut: Clipboard.shared.isCut(it.url)))
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if let i = item as? IconItem { ThumbnailCache.shared.cancel(i.thumbnailRequest); i.thumbnailRequest = nil }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { notifySelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { notifySelection() }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? items[indexPath.item].url as NSURL : nil
    }


    func typeSelect(_ chars: String) -> Bool {
        guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        let prefix = typeSelect.append(chars)
        guard let i = items.firstIndex(where: { $0.name.range(of: prefix, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil })
            ?? items.firstIndex(where: { $0.name.compare(prefix, options: [.caseInsensitive, .numeric]) != .orderedAscending }) else { return true }
        select([items[i].url], scroll: true)
        return true
    }

    func open(at point: NSPoint) {
        guard collection.indexPathForItem(at: point) != nil else { return }
        pane?.openSelection(nil)
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let p = collection.convert(event.locationInWindow, from: nil)
        if let ip = collection.indexPathForItem(at: p) {
            if !collection.selectionIndexPaths.contains(ip) { collection.selectionIndexPaths = [ip]; notifySelection() }
        } else {
            collection.deselectAll(nil)
            notifySelection()
        }
        guard let pane else { return nil }
        return ContextMenuBuilder.menu(for: pane)
    }

    private var dropHighlight: IconItem?

    func dropTarget(at point: NSPoint) -> (URL, IconItem?)? {
        if let ip = collection.indexPathForItem(at: point), items.indices.contains(ip.item), items[ip.item].isBrowsableFolder {
            return (items[ip.item].url, collection.item(at: ip) as? IconItem)
        }
        if let u = pane?.destinationFolder { return (u, nil) }
        return nil
    }

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = collection.convert(info.draggingLocation, from: nil)
        guard let (dest, item) = dropTarget(at: p) else { setDropHighlight(nil); spring.cancel(); return [] }
        let op = DropSupport.operation(for: info, destination: dest)
        setDropHighlight(op.isEmpty ? nil : item)
        if item != nil, !op.isEmpty {
            spring.hover(dest) { [weak self] in self?.pane?.navigate(to: .folder(dest)) }
        } else {
            spring.cancel()
        }
        return op
    }

    func dragEnded() {
        setDropHighlight(nil)
        spring.cancel()
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        defer { dragEnded() }
        let p = collection.convert(info.draggingLocation, from: nil)
        guard let (dest, _) = dropTarget(at: p) else { return false }
        return DropSupport.perform(info, destination: dest)
    }

    private func setDropHighlight(_ item: IconItem?) {
        guard dropHighlight !== item else { return }
        dropHighlight?.isDropTarget = false
        dropHighlight = item
        item?.isDropTarget = true
    }
}

@MainActor
final class BrowserCollectionView: NSCollectionView {
    weak var controller: IconViewController?

    override func keyDown(with event: NSEvent) {
        if let pane = controller?.pane, pane.handleKeyDown(event) { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        if flags.isEmpty, let chars = event.characters, ![123, 124, 125, 126, 48, 53].contains(event.keyCode),
           controller?.typeSelect(chars) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            controller?.open(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(for: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragEnded()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}
}

final class IconItemRootView: NSView {
    var onLayout: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

final class IconItem: NSCollectionViewItem {
    nonisolated(unsafe) static var increaseContrastOverride: Bool?
    static var increaseContrast: Bool { increaseContrastOverride ?? ThemeAccessibility.increaseContrast }

    var representedURL: URL?
    var thumbnailRequest: QLThumbnailGenerator.Request?
    var hasThumbnail = false
    let highlight = NSView()
    let labelBackground = NSView()
    private var iconSizeConstraint: NSLayoutConstraint?
    private(set) var labelSelectionColor: NSColor = .selectedContentBackgroundColor
    private var labelBackgroundColor: NSColor?
    private(set) var labelShape: Theme.IconLabelShape = .pill
    private var textColor: NSColor = .labelColor
    private var selectedTextColor: NSColor = .alternateSelectedControlTextColor
    private var outlineColor: NSColor = .labelColor

    var iconSize: CGFloat = 64 {
        didSet { iconSizeConstraint?.constant = iconSize }
    }

    var isDropTarget = false { didSet { updateAppearance() } }

    override var isSelected: Bool { didSet { updateAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateAppearance() } }

    override func loadView() {
        let v = IconItemRootView()
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.group)
        let iv = NSImageView()
        iv.setAccessibilityElement(false)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(wrappingLabelWithString: "")
        tf.setAccessibilityElement(false)
        tf.alignment = .center
        tf.maximumNumberOfLines = 2
        tf.lineBreakMode = .byTruncatingMiddle
        tf.cell?.truncatesLastVisibleLine = true
        tf.font = .systemFont(ofSize: 12)
        tf.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false
        labelBackground.wantsLayer = true
        labelBackground.layer?.cornerRadius = 4
        v.addSubview(highlight)
        v.addSubview(labelBackground)
        v.addSubview(iv)
        v.addSubview(tf)
        let size = iv.widthAnchor.constraint(equalToConstant: iconSize)
        iconSizeConstraint = size
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: v.topAnchor, constant: Spacing.xs),
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            size,
            iv.heightAnchor.constraint(equalTo: iv.widthAnchor),
            highlight.centerXAnchor.constraint(equalTo: iv.centerXAnchor),
            highlight.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
            highlight.widthAnchor.constraint(equalTo: iv.widthAnchor, constant: 8),
            highlight.heightAnchor.constraint(equalTo: iv.heightAnchor, constant: 8),
            tf.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: Spacing.xs),
            tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: Spacing.xxs),
            tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -Spacing.xxs),
        ])
        v.onLayout = { [weak self] in self?.layoutLabelBackground() }
        v.onAppearanceChange = { [weak self] in self?.updateAppearance() }
        view = v
        imageView = iv
        textField = tf
        updateAppearance()
    }

    func applyTheme(_ theme: Theme) {
        let il = theme.iconLabels
        labelSelectionColor = Theme.color(il.selectionBackground)
        let clear = Theme.isSystemToken(il.background) && il.background.lowercased() == "system:clear"
        labelBackgroundColor = clear ? nil : Theme.color(il.background)
        labelShape = il.shape
        textColor = Theme.color(il.text)
        selectedTextColor = Theme.color(il.selectionText)
        outlineColor = theme.usesSystemSelection ? .keyboardFocusIndicatorColor : theme.selectionColor
        if let tf = textField {
            let font = theme.iconLabelFont
            if tf.font != font { tf.font = font }
            tf.maximumNumberOfLines = max(1, il.maxLines)
        }
        highlight.layer?.cornerRadius = CGFloat(theme.metrics.cornerRadius)
        view.needsLayout = true
        updateAppearance()
    }

    var labelBackgroundFrame: NSRect { labelBackground.frame }

    func layoutLabelBackground() {
        guard let tf = textField else { return }
        let f = tf.frame
        guard f.width > 0 else { labelBackground.frame = .zero; return }
        let fitting = tf.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: f.width, height: .greatestFiniteMagnitude)) ?? f.size
        let w = min(f.width, ceil(fitting.width) + Spacing.xxs)
        let h = f.height + 2
        let box = NSRect(x: floor(f.midX - w / 2), y: f.minY - 1, width: w, height: h)
        if labelBackground.frame != box { labelBackground.frame = box }
        labelBackground.layer?.cornerRadius = labelShape == .pill ? min(h / 2, 5) : 0
    }

    private func resolved(_ color: NSColor) -> CGColor {
        var out = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    private func updateAppearance() {
        let on = isSelected || highlightState == .forSelection
        guard isViewLoaded else { return }
        view.setAccessibilitySelected(isSelected)
        let contrast = Self.increaseContrast
        let marked = on || isDropTarget
        highlight.layer?.backgroundColor = marked ? resolved(NSColor.labelColor.withAlphaComponent(isDropTarget ? 0.25 : 0.12)) : NSColor.clear.cgColor
        highlight.layer?.borderWidth = marked && contrast ? 2 : 0
        highlight.layer?.borderColor = marked && contrast ? resolved(outlineColor) : nil
        let labelFill: NSColor? = on ? labelSelectionColor : (labelShape == .none ? nil : labelBackgroundColor)
        labelBackground.layer?.backgroundColor = labelFill.map(resolved) ?? NSColor.clear.cgColor
        labelBackground.layer?.borderWidth = on && contrast ? 1 : 0
        labelBackground.layer?.borderColor = on && contrast ? resolved(selectedTextColor) : nil
        layoutLabelBackground()
        if textField?.currentEditor() == nil { textField?.textColor = on ? selectedTextColor : textColor }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        hasThumbnail = false
        isDropTarget = false
        imageView?.image = nil
    }
}
