import AppKit
import Foundation
import Theming

public enum PanelEdge: String, Hashable, Sendable { case left, right, bottom }
public enum PanelPresentation: String, Hashable, Sendable { case docked, slideOut }

public enum PanelContent {
    case ui(ModUINode)
    case view(@MainActor () -> NSView)
}

public struct PanelSpec: BrowserContribution {
    public var id: String
    public var title: String
    public var symbolName: String?
    public var edge: PanelEdge
    public var presentation: PanelPresentation
    public var defaultSize: Double
    public var minSize: Double
    public var maxSize: Double
    public var defaultOpen: Bool
    public var content: PanelContent
    public var accessibilityLabel: String?
    public var onEvent: ((ModUIEvent) -> Void)?
    public var defaultOrder: Int

    public init(id: String, title: String, symbolName: String? = nil, edge: PanelEdge = .right, presentation: PanelPresentation = .docked,
                defaultSize: Double = 280, minSize: Double = 160, maxSize: Double = 900, defaultOpen: Bool = false, content: PanelContent,
                accessibilityLabel: String? = nil, onEvent: ((ModUIEvent) -> Void)? = nil, defaultOrder: Int = 0) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.edge = edge
        self.presentation = presentation
        self.defaultSize = defaultSize
        self.minSize = minSize
        self.maxSize = maxSize
        self.defaultOpen = defaultOpen
        self.content = content
        self.accessibilityLabel = accessibilityLabel
        self.onEvent = onEvent
        self.defaultOrder = defaultOrder
    }
}

public enum PanelStateStore {
    private static func key(_ qualifiedID: String, _ field: String) -> String { "browserPanel.\(qualifiedID).\(field)" }

    @MainActor
    public static func isOpen(_ qualifiedID: String, default fallback: Bool) -> Bool {
        BrowserDefaults.store.object(forKey: key(qualifiedID, "open")) as? Bool ?? fallback
    }

    @MainActor
    public static func setOpen(_ qualifiedID: String, _ open: Bool) {
        BrowserDefaults.store.set(open, forKey: key(qualifiedID, "open"))
    }

    @MainActor
    public static func size(_ qualifiedID: String, default fallback: Double) -> Double {
        let v = BrowserDefaults.store.double(forKey: key(qualifiedID, "size"))
        return v > 0 ? v : fallback
    }

    @MainActor
    public static func setSize(_ qualifiedID: String, _ size: Double) {
        BrowserDefaults.store.set(size, forKey: key(qualifiedID, "size"))
    }

    @MainActor
    public static func clear(_ qualifiedID: String) {
        BrowserDefaults.store.removeObject(forKey: key(qualifiedID, "open"))
        BrowserDefaults.store.removeObject(forKey: key(qualifiedID, "size"))
    }
}

@MainActor
public final class PanelRegistry: BrowserRegistry<PanelSpec> {
    public static let shared = PanelRegistry()

    public private(set) var contentOverrides: [String: ModUINode] = [:]

    public init() { super.init(kind: .panel) }

    override public func validate(_ item: PanelSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A panel needs a title." }
        if item.minSize > item.maxSize { return "A panel's minimum size can't exceed its maximum." }
        return nil
    }

    public func updateContent(_ node: ModUINode, for qualifiedID: String) {
        guard entry(qualifiedID) != nil else { return }
        contentOverrides[qualifiedID] = node
        notify()
    }

    override public func didChange() {
        let live = Set(entries.map(\.qualifiedID))
        contentOverrides = contentOverrides.filter { live.contains($0.key) }
    }
}

@MainActor
final class PanelContentViewController: NSViewController {
    let spec: PanelSpec
    let qualifiedID: String
    private let renderer = ModUIRenderer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let header = NSStackView()
    private let body = NSView()
    private var renderedNode: ModUINode?
    private var customView: NSView?
    var onClose: (() -> Void)?

    init(spec: PanelSpec, qualifiedID: String) {
        self.spec = spec
        self.qualifiedID = qualifiedID
        super.init(nibName: nil, bundle: nil)
        renderer.onEvent = { [weak self] event in self?.spec.onEvent?(event) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedPanelRoot()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(spec.accessibilityLabel ?? "\(spec.title) panel")
        titleLabel.stringValue = spec.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(spec.title) panel")
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.setAccessibilityLabel("Close \(spec.title) panel")
        closeButton.toolTip = "Close \(spec.title)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.xs
        header.edgeInsets = NSEdgeInsets(top: Spacing.xs, left: Spacing.panelPadding, bottom: Spacing.xs, right: Spacing.panelPadding - (Spacing.hitTarget - 16) / 2)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(closeButton)
        let sep = NSBox()
        sep.boxType = .separator
        for v in [header, sep, body] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Spacing.panelHeaderHeight),
            closeButton.widthAnchor.constraint(equalToConstant: Spacing.hitTarget),
            closeButton.heightAnchor.constraint(equalToConstant: Spacing.hitTarget),
            sep.topAnchor.constraint(equalTo: header.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: sep.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        installContent(spec.content)
        observeThemeChanges()
    }

    func applyTheme(_ theme: Theme) {
        (view as? ThemedPanelRoot)?.fill = Theme.color(theme.colors.windowBg)
        let base = theme.uiFont.withSize(max(12, theme.uiFont.pointSize))
        titleLabel.font = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        titleLabel.textColor = theme.textColor
        closeButton.contentTintColor = theme.secondaryTextColor
    }

    var firstKeyView: NSView? { Self.firstKeyView(in: body) ?? (closeButton.canBecomeKeyView ? closeButton : nil) }

    @discardableResult
    func focusRoot() -> Bool {
        guard let root = view as? ThemedPanelRoot, let window = root.window else { return false }
        root.acceptsFocusFallback = true
        if window.makeFirstResponder(root) { return true }
        root.acceptsFocusFallback = false
        return false
    }

    static func firstKeyView(in view: NSView) -> NSView? {
        for sub in view.subviews where !sub.isHidden {
            if sub.canBecomeKeyView { return sub }
            if let found = firstKeyView(in: sub) { return found }
        }
        return nil
    }

    private func installContent(_ content: PanelContent) {
        switch content {
        case .ui(let node):
            show(node)
        case .view(let factory):
            let v = factory()
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: body.topAnchor, constant: Spacing.panelPadding),
                v.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Spacing.panelPadding),
                v.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Spacing.panelPadding),
                v.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Spacing.panelPadding),
            ])
            customView = v
        }
    }

    func show(_ node: ModUINode) {
        guard node != renderedNode else { return }
        renderedNode = node
        if renderer.rootView.superview !== body {
            let r = renderer.rootView
            r.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(r)
            NSLayoutConstraint.activate([
                r.topAnchor.constraint(equalTo: body.topAnchor, constant: Spacing.panelPadding),
                r.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Spacing.panelPadding),
                r.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Spacing.panelPadding),
                r.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Spacing.panelPadding),
            ])
        }
        renderer.render(node)
    }

    var renderedUI: ModUINode? { renderedNode }
    var uiRenderer: ModUIRenderer { renderer }

    @objc private func closePressed(_ sender: Any?) { onClose?() }
}

extension PanelContentViewController: ThemedSurface {}

final class ThemedPanelRoot: NSView {
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var acceptsFocusFallback = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { acceptsFocusFallback }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.insetBy(dx: 3, dy: 3).fill() }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFocusFallback else { return false }
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        acceptsFocusFallback = false
        noteFocusRingMaskChanged()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        fill.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

@MainActor
final class PanelResizeHandle: NSView {
    let edge: PanelEdge
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onAdjust: ((CGFloat) -> Void)?
    var currentSize: (() -> CGFloat)?
    var minSize: CGFloat = 0
    var maxSize: CGFloat = .greatestFiniteMagnitude
    var title: String = "" {
        didSet { setAccessibilityLabel(title.isEmpty ? "Resize panel" : "Resize \(title) panel") }
    }
    static let step: CGFloat = 16
    private var origin: NSPoint = .zero

    init(edge: PanelEdge) {
        self.edge = edge
        super.init(frame: .zero)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panel")
        setAccessibilityHelp(edge == .bottom ? "Use the up and down arrow keys to resize" : "Use the left and right arrow keys to resize")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor && NSApp.isFullKeyboardAccessEnabled }
    override func drawFocusRingMask() { bounds.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        let delta: CGFloat?
        switch (edge, event.keyCode) {
        case (.left, 124), (.right, 123), (.bottom, 126): delta = Self.step
        case (.left, 123), (.right, 124), (.bottom, 125): delta = -Self.step
        default: delta = nil
        }
        guard let delta else { super.keyDown(with: event); return }
        adjust(by: delta)
    }

    func adjust(by delta: CGFloat) {
        onAdjust?(delta)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityOrientation() -> NSAccessibilityOrientation { edge == .bottom ? .horizontal : .vertical }
    override func accessibilityValue() -> Any? { NSNumber(value: Double(currentSize?() ?? 0)) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: Double(minSize)) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: Double(maxSize)) }
    override func accessibilityValueDescription() -> String? { "\(Int((currentSize?() ?? 0).rounded())) points" }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(by: Self.step)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(by: -Self.step)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .bottom ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        switch edge {
        case .left: onDrag?(p.x - origin.x)
        case .right: onDrag?(origin.x - p.x)
        case .bottom: onDrag?(p.y - origin.y)
        }
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

@MainActor
final class PanelOverlayView: NSView {
    let handle: PanelResizeHandle
    let edge: PanelEdge
    var sizeConstraint: NSLayoutConstraint!
    var offsetConstraint: NSLayoutConstraint!

    init(edge: PanelEdge, content: NSView) {
        self.edge = edge
        handle = PanelResizeHandle(edge: edge)
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(handle)
        let thickness: CGFloat = 6
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        switch edge {
        case .left:
            NSLayoutConstraint.activate([handle.trailingAnchor.constraint(equalTo: trailingAnchor), handle.topAnchor.constraint(equalTo: topAnchor), handle.bottomAnchor.constraint(equalTo: bottomAnchor), handle.widthAnchor.constraint(equalToConstant: thickness)])
        case .right:
            NSLayoutConstraint.activate([handle.leadingAnchor.constraint(equalTo: leadingAnchor), handle.topAnchor.constraint(equalTo: topAnchor), handle.bottomAnchor.constraint(equalTo: bottomAnchor), handle.widthAnchor.constraint(equalToConstant: thickness)])
        case .bottom:
            NSLayoutConstraint.activate([handle.topAnchor.constraint(equalTo: topAnchor), handle.leadingAnchor.constraint(equalTo: leadingAnchor), handle.trailingAnchor.constraint(equalTo: trailingAnchor), handle.heightAnchor.constraint(equalToConstant: thickness)])
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class ContentHostViewController: NSViewController {
    let contentSplit: NSSplitViewController

    init(contentSplit: NSSplitViewController) {
        self.contentSplit = contentSplit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        addChild(contentSplit)
        contentSplit.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentSplit.view)
        NSLayoutConstraint.activate([
            contentSplit.view.topAnchor.constraint(equalTo: container.topAnchor),
            contentSplit.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentSplit.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentSplit.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
}

@MainActor
final class PanelHostController: NSObject {
    @MainActor
    final class Instance {
        let qualifiedID: String
        let owner: String
        let sequence: Int
        var spec: PanelSpec
        let vc: PanelContentViewController
        var item: NSSplitViewItem?
        var overlay: PanelOverlayView?
        var isOpen = false
        init(qualifiedID: String, owner: String, sequence: Int, spec: PanelSpec, vc: PanelContentViewController) {
            self.qualifiedID = qualifiedID
            self.owner = owner
            self.sequence = sequence
            self.spec = spec
            self.vc = vc
        }
    }

    private(set) var instances: [String: Instance] = [:]
    private let registries: BrowserRegistries
    private let splitController: NSSplitViewController
    private let contentSplit: NSSplitViewController
    private let host: ContentHostViewController
    private var applyingSize = false
    var isAnimationEnabled = true

    init(registries: BrowserRegistries, splitController: NSSplitViewController, contentSplit: NSSplitViewController, host: ContentHostViewController) {
        self.registries = registries
        self.splitController = splitController
        self.contentSplit = contentSplit
        self.host = host
        super.init()
        registries.panels.addObserver(self) { [weak self] in self?.sync() }
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView)
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: contentSplit.splitView)
        sync()
    }

    func tearDown() {
        registries.panels.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        for i in Array(instances.values) { detach(i) }
        instances.removeAll()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !isAnimationEnabled }

    func isOpen(_ qualifiedID: String) -> Bool { instances[qualifiedID]?.isOpen ?? false }

    func sync() {
        let desired = registries.panels.visibleEntries
        let sequences = Dictionary(uniqueKeysWithValues: desired.map { ($0.qualifiedID, $0.sequence) })
        for (id, inst) in instances where sequences[id] != inst.sequence {
            detach(inst)
            instances[id] = nil
        }
        for e in desired {
            if let inst = instances[e.qualifiedID] {
                if let node = registries.panels.contentOverrides[e.qualifiedID] { inst.vc.show(node) }
                continue
            }
            let vc = PanelContentViewController(spec: e.item, qualifiedID: e.qualifiedID)
            let inst = Instance(qualifiedID: e.qualifiedID, owner: e.owner, sequence: e.sequence, spec: e.item, vc: vc)
            vc.onClose = { [weak self] in self?.setOpen(e.qualifiedID, false) }
            instances[e.qualifiedID] = inst
            attach(inst)
            if let node = registries.panels.contentOverrides[e.qualifiedID] { vc.show(node) }
            let open = PanelStateStore.isOpen(e.qualifiedID, default: e.item.defaultOpen)
            apply(inst, open: open, animated: false)
        }
    }

    private func attach(_ inst: Instance) {
        _ = inst.vc.view
        switch inst.spec.presentation {
        case .docked:
            let item = NSSplitViewItem(viewController: inst.vc)
            item.minimumThickness = CGFloat(inst.spec.minSize)
            item.maximumThickness = CGFloat(inst.spec.maxSize)
            item.canCollapse = true
            item.holdingPriority = NSLayoutConstraint.Priority(260)
            item.isCollapsed = true
            inst.item = item
            switch inst.spec.edge {
            case .left:
                let idx = splitController.splitViewItems.firstIndex { $0.viewController === host } ?? splitController.splitViewItems.count
                splitController.insertSplitViewItem(item, at: idx)
            case .right:
                splitController.addSplitViewItem(item)
            case .bottom:
                contentSplit.addSplitViewItem(item)
            }
        case .slideOut:
            let overlay = PanelOverlayView(edge: inst.spec.edge, content: inst.vc.view)
            host.view.addSubview(overlay)
            let size = CGFloat(PanelStateStore.size(inst.qualifiedID, default: inst.spec.defaultSize))
            let hostView = host.view
            switch inst.spec.edge {
            case .left:
                overlay.sizeConstraint = overlay.widthAnchor.constraint(equalToConstant: size)
                overlay.offsetConstraint = overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: -size)
                NSLayoutConstraint.activate([overlay.topAnchor.constraint(equalTo: hostView.topAnchor), overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)])
            case .right:
                overlay.sizeConstraint = overlay.widthAnchor.constraint(equalToConstant: size)
                overlay.offsetConstraint = overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: size)
                NSLayoutConstraint.activate([overlay.topAnchor.constraint(equalTo: hostView.topAnchor), overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)])
            case .bottom:
                overlay.sizeConstraint = overlay.heightAnchor.constraint(equalToConstant: size)
                overlay.offsetConstraint = overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor, constant: size)
                NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor)])
            }
            NSLayoutConstraint.activate([overlay.sizeConstraint, overlay.offsetConstraint])
            overlay.isHidden = true
            let qualifiedID = inst.qualifiedID
            let spec = inst.spec
            let setSize: (CGFloat) -> Void = { [weak overlay, weak inst] target in
                guard let overlay else { return }
                overlay.sizeConstraint.constant = min(max(target, CGFloat(spec.minSize)), CGFloat(spec.maxSize))
                if inst?.isOpen == true { overlay.offsetConstraint.constant = 0 }
            }
            let handle = overlay.handle
            handle.title = spec.title
            handle.minSize = CGFloat(spec.minSize)
            handle.maxSize = CGFloat(spec.maxSize)
            handle.currentSize = { [weak overlay] in overlay?.sizeConstraint.constant ?? 0 }
            handle.onDrag = { delta in
                setSize(CGFloat(PanelStateStore.size(qualifiedID, default: spec.defaultSize)) + delta)
            }
            handle.onEnd = { [weak overlay] in
                guard let overlay else { return }
                PanelStateStore.setSize(qualifiedID, Double(overlay.sizeConstraint.constant))
            }
            handle.onAdjust = { [weak overlay] delta in
                guard let overlay else { return }
                setSize(overlay.sizeConstraint.constant + delta)
                PanelStateStore.setSize(qualifiedID, Double(overlay.sizeConstraint.constant))
            }
            inst.overlay = overlay
        }
    }

    private func detach(_ inst: Instance) {
        restoreFocusIfNeeded(leaving: inst)
        if let item = inst.item {
            switch inst.spec.edge {
            case .bottom: contentSplit.removeSplitViewItem(item)
            default: splitController.removeSplitViewItem(item)
            }
        }
        inst.overlay?.removeFromSuperview()
        inst.item = nil
        inst.overlay = nil
    }

    func setOpen(_ qualifiedID: String, _ open: Bool, animated: Bool = true) {
        guard let inst = instances[qualifiedID] else { return }
        if open && inst.spec.presentation == .slideOut {
            for other in instances.values where other !== inst && other.spec.presentation == .slideOut && other.spec.edge == inst.spec.edge && other.isOpen {
                PanelStateStore.setOpen(other.qualifiedID, false)
                apply(other, open: false, animated: animated)
            }
        }
        PanelStateStore.setOpen(qualifiedID, open)
        apply(inst, open: open, animated: animated)
    }

    func toggle(_ qualifiedID: String) {
        guard let inst = instances[qualifiedID] else { return }
        if inst.isOpen {
            setOpen(qualifiedID, false)
        } else {
            open(qualifiedID, focus: true)
        }
    }

    private var invokers: [String: WeakResponder] = [:]

    func open(_ qualifiedID: String, focus: Bool, animated: Bool = true) {
        guard let inst = instances[qualifiedID] else { return }
        let window = host.view.window
        if focus, let responder = window?.firstResponder {
            let owner: NSResponder
            if let tv = responder as? NSTextView, tv.isFieldEditor, let field = tv.delegate as? NSView { owner = field } else { owner = responder }
            invokers[qualifiedID] = WeakResponder(owner)
        }
        setOpen(qualifiedID, true, animated: animated)
        guard focus, let window else { return }
        inst.vc.view.layoutSubtreeIfNeeded()
        window.recalculateKeyViewLoop()
        let focused = inst.vc.firstKeyView.map { window.makeFirstResponder($0) } ?? false
        if !focused { inst.vc.focusRoot() }
        NSAccessibility.post(element: inst.vc.view, notification: .layoutChanged, userInfo: [.uiElements: [inst.vc.view]])
    }

    static func focusIsInside(_ view: NSView) -> Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        if responder === view || responder.isDescendant(of: view) { return true }
        if let tv = responder as? NSTextView, tv.isFieldEditor, let owner = tv.delegate as? NSView, owner.isDescendant(of: view) { return true }
        return false
    }

    private func restoreFocusIfNeeded(leaving inst: Instance) {
        let invoker = invokers.removeValue(forKey: inst.qualifiedID)?.responder
        guard inst.vc.isViewLoaded, let window = inst.vc.view.window, Self.focusIsInside(inst.vc.view) else { return }
        var restored = false
        if let v = invoker as? NSView, v.window === window, !v.isHiddenOrHasHiddenAncestor, !v.isDescendant(of: inst.vc.view) {
            restored = window.makeFirstResponder(v)
        }
        if !restored, let wc = window.windowController as? BrowserWindowController { wc.activePane.focusVisibleContent() }
        if Self.focusIsInside(inst.vc.view) { window.makeFirstResponder(nil) }
        window.recalculateKeyViewLoop()
        NSAccessibility.post(element: window, notification: .layoutChanged)
    }

    private func apply(_ inst: Instance, open: Bool, animated: Bool) {
        if !open { restoreFocusIfNeeded(leaving: inst) }
        inst.isOpen = open
        let animate = animated && !reduceMotion
        if let item = inst.item {
            if open { applyDockedSize(inst) }
            if animate { item.animator().isCollapsed = !open } else { item.isCollapsed = !open }
        }
        if let overlay = inst.overlay {
            let size = overlay.sizeConstraint.constant
            let closedOffset: CGFloat = inst.spec.edge == .left ? -size : size
            if open { overlay.isHidden = false }
            let target: CGFloat = open ? 0 : closedOffset
            if animate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    ctx.allowsImplicitAnimation = true
                    overlay.offsetConstraint.animator().constant = target
                    overlay.superview?.layoutSubtreeIfNeeded()
                }, completionHandler: { [weak overlay, weak inst] in
                    MainActor.assumeIsolated { if inst?.isOpen == false { overlay?.isHidden = true } }
                })
            } else {
                overlay.offsetConstraint.constant = target
                overlay.isHidden = !open
            }
        }
        if let node = registries.panels.contentOverrides[inst.qualifiedID] { inst.vc.show(node) }
    }

    private func applyDockedSize(_ inst: Instance) {
        let size = CGFloat(min(max(PanelStateStore.size(inst.qualifiedID, default: inst.spec.defaultSize), inst.spec.minSize), inst.spec.maxSize))
        let split = inst.spec.edge == .bottom ? contentSplit : splitController
        guard let item = inst.item, let index = split.splitViewItems.firstIndex(where: { $0 === item }) else { return }
        applyingSize = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let sv = split.splitView
                sv.layoutSubtreeIfNeeded()
                let thickness = sv.dividerThickness
                switch inst.spec.edge {
                case .left:
                    if index < sv.subviews.count { sv.setPosition(inst.vc.view.frame.minX + size, ofDividerAt: index) }
                case .right:
                    if index > 0 { sv.setPosition(sv.bounds.maxX - size - thickness, ofDividerAt: index - 1) }
                case .bottom:
                    if index > 0 { sv.setPosition(sv.bounds.maxY - size - thickness, ofDividerAt: index - 1) }
                }
                self.applyingSize = false
            }
        }
    }

    @objc private func splitResized(_ note: Notification) {
        guard !applyingSize else { return }
        for inst in instances.values where inst.isOpen {
            guard let item = inst.item, !item.isCollapsed, inst.vc.isViewLoaded, inst.vc.view.window != nil else { continue }
            let frame = inst.vc.view.frame
            let size = inst.spec.edge == .bottom ? frame.height : frame.width
            guard size > 1 else { continue }
            PanelStateStore.setSize(inst.qualifiedID, Double(min(max(size, CGFloat(inst.spec.minSize)), CGFloat(inst.spec.maxSize))))
        }
    }
}

final class WeakResponder {
    weak var responder: NSResponder?
    init(_ responder: NSResponder) { self.responder = responder }
}
