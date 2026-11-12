import AppKit
import FSCore
import FileOps

@MainActor
final class TreemapView: NSView {
    var root: HogNode? { didSet { relayout() } }
    private(set) var hovered: HogNode?
    var selected: HogNode? { didSet { if selected !== oldValue { invalidate(oldValue); invalidate(selected) } } }
    var onHover: ((HogNode?) -> Void)?
    var onSelect: ((HogNode?) -> Void)?
    var onZoom: ((HogNode) -> Void)?
    var menuProvider: ((HogNode) -> NSMenu?)?
    private var tracking: NSTrackingArea?
    private static let labelShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        hovered = nil
        if let root { SpaceHogBuilder.layout(root, in: bounds) }
        needsDisplay = true
    }

    private func invalidate(_ node: HogNode?) {
        guard let node else { return }
        setNeedsDisplay(node.rect.insetBy(dx: -3, dy: -3))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func hit(_ event: NSEvent) -> HogNode? {
        root?.node(at: convert(event.locationInWindow, from: nil))
    }

    private func hover(_ node: HogNode?) {
        guard node !== hovered else { return }
        invalidate(hovered)
        hovered = node
        invalidate(node)
        onHover?(node)
    }

    override func mouseMoved(with event: NSEvent) { hover(hit(event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let node = hit(event)
        selected = node
        onSelect?(node)
        if event.clickCount == 2, let node, let root, let branch = node.ancestor(below: root), branch.isFolder { onZoom?(branch) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node = hit(event) else { return nil }
        selected = node
        onSelect?(node)
        return menuProvider?(node)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let root, root.rect.width > 0 else { return }
        draw(root, in: dirtyRect)
        if let root = self.root {
            NSColor.black.withAlphaComponent(0.55).setStroke()
            for branch in root.children where branch.rect.intersects(dirtyRect) && branch.rect.width > 2 {
                let path = NSBezierPath(rect: branch.rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }
        if let hovered, hovered !== selected, hovered.rect.intersects(dirtyRect) {
            NSColor.white.withAlphaComponent(0.18).setFill()
            hovered.rect.fill(using: .sourceOver)
            outline(hovered.rect, color: NSColor.white.withAlphaComponent(0.9), width: 1)
        }
        if let selected, selected.rect.width > 0, selected.rect.intersects(dirtyRect.insetBy(dx: -3, dy: -3)) {
            outline(selected.rect, color: .black, width: 3)
            outline(selected.rect, color: .white, width: 1.5)
        }
    }

    private func outline(_ rect: CGRect, color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }

    private func draw(_ node: HogNode, in dirty: CGRect) {
        guard node.rect.width >= 1, node.rect.height >= 1, node.rect.intersects(dirty) else { return }
        let visible = node.children.contains { $0.rect.width >= 1 && $0.rect.height >= 1 }
        guard visible else { drawLeaf(node); return }
        for child in node.children { draw(child, in: dirty) }
    }

    private func drawLeaf(_ node: HogNode) {
        let base = SpaceHogBuilder.color(for: node)
        let rect = node.rect
        if rect.width < 3 || rect.height < 3 {
            base.setFill()
            rect.fill()
            return
        }
        let light = base.blended(withFraction: 0.32, of: .white) ?? base
        let dark = base.blended(withFraction: 0.34, of: .black) ?? base
        NSGradient(starting: light, ending: dark)?.draw(in: rect, angle: 315)
        NSColor.black.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        border.stroke()
        guard rect.width >= 58, rect.height >= 17 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white, .shadow: Self.labelShadow, .paragraphStyle: style,
        ]
        (node.name as NSString).draw(in: CGRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: 14), withAttributes: attributes)
        guard rect.height >= 32 else { return }
        var small = attributes
        small[.font] = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        small[.foregroundColor] = NSColor.white.withAlphaComponent(0.85)
        let size = SizeFormatter.string(node.bytes) + (node.isCounting ? "…" : "")
        (size as NSString).draw(in: CGRect(x: rect.minX + 4, y: rect.minY + 15, width: rect.width - 8, height: 12), withAttributes: small)
    }
}

final class ShareBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: ((bounds.height - 6) / 2).rounded(), width: bounds.width, height: 6)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let width = track.width * CGFloat(min(max(fraction, 0), 1))
        guard width >= 1 else { return }
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(3, width), height: track.height), xRadius: 3, yRadius: 3).fill()
    }
}

final class ShareCellView: NSTableCellView {
    let chip = NSView()
    let name = NSTextField(labelWithString: "")
    let size = NSTextField(labelWithString: "")
    let bar = ShareBarView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12)
        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .secondaryLabelColor
        size.alignment = .right
        for view in [chip, name, size, bar] as [NSView] { addSubview(view) }
        textField = name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        chip.frame = NSRect(x: 6, y: ((h - 10) / 2).rounded(), width: 10, height: 10)
        let barWidth: CGFloat = 54
        let sizeWidth: CGFloat = 70
        bar.frame = NSRect(x: bounds.width - barWidth - 8, y: 0, width: barWidth, height: h)
        size.frame = NSRect(x: bar.frame.minX - sizeWidth - 6, y: ((h - 15) / 2).rounded(), width: sizeWidth, height: 15)
        name.frame = NSRect(x: 22, y: ((h - 16) / 2).rounded(), width: max(0, size.frame.minX - 28), height: 16)
    }
}

@MainActor
final class SpaceHogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var rootURL: URL
    private(set) var root: HogNode?
    private(set) var stats: IndexStatistics?
    private var tree: SizeIndexTree?
    private var loading: Task<Void, Never>?
    private var timer: Timer?
    private var generation = 0

    let treemap = TreemapView()
    let table = NSTableView()
    let pathLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "")
    let statusStack = NSStackView()
    let upButton = NSButton(title: "Enclosing Folder", target: nil, action: nil)
    let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    let trashButton = NSButton(title: "Move to Trash", target: nil, action: nil)
    let junkButton = NSButton(title: "Clean Up Junk…", target: nil, action: nil)
    var database: () -> URL = { SizeEngine.shared.indexLocation }
    var onTitle: ((String) -> Void)?

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 680))

        for (button, action) in [(upButton, #selector(zoomOut)), (revealButton, #selector(reveal)), (trashButton, #selector(trash)), (junkButton, #selector(showJunk))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        upButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        upButton.imagePosition = .imageLeading
        pathLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [upButton, pathLabel, revealButton, trashButton, junkButton])
        bar.orientation = .horizontal
        bar.distribution = .fill
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("share"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .fullWidth
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(zoomIntoRow)
        table.setAccessibilityLabel("Largest items")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        treemap.translatesAutoresizingMaskIntoConstraints = false
        treemap.setAccessibilityLabel("Space map")

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.spacing = 5
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.setAccessibilityLabel("Index status")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [bar, scroll, treemap, detailLabel, statusStack, emptyLabel] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 300),
            scroll.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -6),
            treemap.topAnchor.constraint(equalTo: scroll.topAnchor),
            treemap.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 1),
            treemap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            treemap.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            detailLabel.bottomAnchor.constraint(equalTo: statusStack.topAnchor, constant: -3),
            statusStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            statusStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            emptyLabel.centerXAnchor.constraint(equalTo: treemap.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: treemap.centerYAnchor),
        ])

        treemap.onHover = { [weak self] node in self?.describe(node ?? self?.treemap.selected) }
        treemap.onSelect = { [weak self] node in self?.selectionChanged(node) }
        treemap.onZoom = { [weak self] node in self?.show(node.url) }
        treemap.menuProvider = { [weak self] node in self?.menu(for: node) }
        view = container
        apply(root: nil, stats: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
        loading?.cancel()
    }

    func show(_ url: URL) {
        rootURL = url
        treemap.selected = nil
        reload()
    }

    func reload() {
        generation += 1
        let token = generation
        let url = rootURL
        let database = database()
        let existing = tree
        loading?.cancel()
        loading = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (SizeIndexTree?, HogNode?, IndexStatistics?) in
                guard let tree = existing ?? (try? SizeIndexTree(databaseURL: database)) else { return (nil, nil, nil) }
                let stats = tree.statistics()
                guard !stats.roots.isEmpty else { return (nil, nil, nil) }
                return (tree, SpaceHogBuilder.build(tree: tree, root: url), stats)
            }.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.tree = result.0
            self.apply(root: result.1, stats: result.2)
        }
    }

    private func poll() {
        guard loading == nil || root != nil || stats != nil else { return }
        let database = database()
        let existing = tree
        let token = generation
        Task { [weak self] in
            let latest = await Task.detached(priority: .utility) { () -> IndexStatistics? in
                (existing ?? (try? SizeIndexTree(databaseURL: database)))?.statistics()
            }.value
            guard let self, token == self.generation else { return }
            if latest != self.stats || (latest?.roots.isEmpty ?? true) { self.reload() }
        }
    }

    func apply(root: HogNode?, stats: IndexStatistics?) {
        let keep = treemap.selected.map { ($0.url.path, $0.kind) }
        self.root = root
        self.stats = stats
        treemap.root = root
        table.reloadData()
        let shown = rootURL.abbreviatedPath
        pathLabel.stringValue = root.map { "\(shown)  ·  \(SizeFormatter.string($0.bytes))\($0.isCounting ? "…" : "")" } ?? shown
        onTitle?("Space Hog — \(shown)")
        if stats == nil {
            emptyLabel.stringValue = "The file index isn’t available yet."
        } else if root == nil {
            emptyLabel.stringValue = "This folder isn’t in the file index yet."
        } else if root?.children.isEmpty ?? true {
            emptyLabel.stringValue = "Nothing in here takes up space."
        } else {
            emptyLabel.stringValue = ""
        }
        emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
        upButton.isEnabled = rootURL.path != "/"
        renderStatus()
        var restored: HogNode?
        if let keep, let root { restored = Self.find(path: keep.0, kind: keep.1, in: root) }
        treemap.selected = restored
        selectionChanged(restored)
    }

    static func find(path: String, kind: HogNode.Kind, in node: HogNode) -> HogNode? {
        if node.url.path == path, Self.sameKind(node.kind, kind) { return node }
        guard path == node.url.path || path.hasPrefix(node.url.path == "/" ? "/" : node.url.path + "/") else { return nil }
        for child in node.children { if let hit = find(path: path, kind: kind, in: child) { return hit } }
        return nil
    }

    private static func sameKind(_ a: HogNode.Kind, _ b: HogNode.Kind) -> Bool {
        switch (a, b) {
        case (.folder, .folder), (.looseFiles, .looseFiles), (.file, .file), (.remainder, .remainder): return true
        default: return false
        }
    }

    private func renderStatus() {
        for view in statusStack.arrangedSubviews { statusStack.removeArrangedSubview(view); view.removeFromSuperview() }
        let parts = IndexStatusLine.parts(stats)
        for (index, part) in parts.enumerated() {
            let label = NSTextField(labelWithString: part.text)
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: index == 0 ? .semibold : .regular)
            label.textColor = part.isAlert ? .systemOrange : (index == 0 ? .labelColor : .secondaryLabelColor)
            label.toolTip = part.help
            statusStack.addArrangedSubview(label)
            if index < parts.count - 1 {
                let dot = NSTextField(labelWithString: "·")
                dot.font = .systemFont(ofSize: 10)
                dot.textColor = .tertiaryLabelColor
                statusStack.addArrangedSubview(dot)
            }
        }
    }

    private func describe(_ node: HogNode?) {
        guard let node, let root else {
            detailLabel.stringValue = root == nil ? "" : "Hover the map to see what a block is. Double-click to zoom in."
            return
        }
        let place = (node.kind == .file ? node.url : node.folderURL).abbreviatedPath
        let share = root.bytes > 0 ? Double(node.bytes) / Double(root.bytes) : 0
        let what: String
        switch node.kind {
        case .folder, .file: what = place
        case .looseFiles: what = "Files directly in \(place)"
        case .remainder: what = "Smaller files in \(place)"
        }
        detailLabel.stringValue = "\(what)  —  \(SizeFormatter.string(node.bytes))\(node.isCounting ? "…" : "")  ·  \(String(format: "%.1f%%", share * 100)) of \(root.name)"
    }

    private func selectionChanged(_ node: HogNode?) {
        describe(node)
        revealButton.isEnabled = node != nil
        trashButton.isEnabled = node?.isActionable ?? false
        guard let root else { return }
        let row = node?.ancestor(below: root).flatMap { branch in root.children.firstIndex { $0 === branch } }
        if let row {
            if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { root?.children.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let root, root.children.indices.contains(row) else { return nil }
        let node = root.children[row]
        let id = NSUserInterfaceItemIdentifier("share-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ShareCellView) ?? ShareCellView(identifier: id)
        let share = root.bytes > 0 ? Double(node.bytes) / Double(root.bytes) : 0
        cell.chip.layer?.backgroundColor = SpaceHogBuilder.color(for: node).cgColor
        cell.name.stringValue = node.name
        cell.size.stringValue = SizeFormatter.string(node.bytes) + (node.isCounting ? "…" : "")
        cell.bar.fraction = share
        cell.bar.tint = HeatScale.color(level: HeatScale.level(node.bytes))
        cell.toolTip = "\(String(format: "%.1f%%", share * 100)) of \(root.name) · \(HeatScale.label(node.bytes))"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let root, root.children.indices.contains(table.selectedRow) else { return }
        let node = root.children[table.selectedRow]
        if treemap.selected?.ancestor(below: root) !== node {
            treemap.selected = node
            describe(node)
            revealButton.isEnabled = true
            trashButton.isEnabled = node.isActionable
        }
    }

    @objc private func zoomIntoRow() {
        guard let root, root.children.indices.contains(table.clickedRow) else { return }
        let node = root.children[table.clickedRow]
        if node.isFolder { show(node.url) }
    }

    @objc func zoomOut() {
        guard rootURL.path != "/" else { return }
        show(rootURL.deletingLastPathComponent())
    }

    @objc func reveal() {
        guard let node = treemap.selected else { return }
        if node.kind == .file || (node.isFolder && node !== root) {
            BrowserWindowManager.shared.open(at: .folder(node.url.deletingLastPathComponent()), select: [node.url])
        } else {
            BrowserWindowManager.shared.open(at: .folder(node.folderURL))
        }
    }

    @objc func trash() {
        guard let node = treemap.selected, node.isActionable, node !== root else { return }
        FileOperationQueue.shared.enqueue(.trash(items: [node.url]))
        treemap.selected = nil
        selectionChanged(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reload() }
    }

    @objc func copyPath() {
        guard let node = treemap.selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.kind == .file ? node.url.path : node.folderURL.path, forType: .string)
    }

    @objc func zoomIntoSelection() {
        guard let node = treemap.selected else { return }
        show(node.folderURL)
    }

    @objc func showJunk() {
        JunkCleanupWindowController.shared.show()
    }

    func menu(for node: HogNode) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Zoom Into “\(node.folderURL.lastPathComponent)”", #selector(zoomIntoSelection), enabled: node.folderURL.path != rootURL.path)
        add("Zoom Out", #selector(zoomOut), enabled: rootURL.path != "/")
        menu.addItem(.separator())
        add("Reveal in betterfinder", #selector(reveal))
        add("Copy Path", #selector(copyPath))
        menu.addItem(.separator())
        add("Move to Trash", #selector(trash), enabled: node.isActionable && node !== root)
        return menu
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.specialKey == .upArrow { zoomOut(); return }
        if event.keyCode == 36, treemap.selected != nil { zoomIntoSelection(); return }
        if event.keyCode == 53 { treemap.selected = nil; selectionChanged(nil); return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class SpaceHogWindowController: NSWindowController {
    public static let shared = SpaceHogWindowController()
    let content: SpaceHogViewController

    public init() {
        content = SpaceHogViewController(rootURL: DemoEnvironment.home)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Space Hog"
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setFrameAutosaveName("BetterFinderSpaceHog")
        super.init(window: window)
        content.onTitle = { [weak window] in window?.title = $0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show(at url: URL? = nil) {
        let wasVisible = window?.isVisible ?? false
        if !wasVisible, window?.frameAutosaveName.isEmpty == false, UserDefaults.standard.string(forKey: "NSWindow Frame BetterFinderSpaceHog") == nil { window?.center() }
        if let url { content.show(SizeIndexLocation.canonical(url)) } else if wasVisible { content.reload() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func showForActiveWindow() {
        show(at: BrowserWindowManager.shared.activeController?.location.url ?? DemoEnvironment.home)
    }
}
