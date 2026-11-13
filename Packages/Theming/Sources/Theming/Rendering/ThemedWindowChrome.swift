import AppKit
import ObjectiveC

@MainActor
public final class ThemedWindowChrome: NSObject {
    private static let associationKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    public private(set) weak var window: NSWindow?
    public private(set) var theme: Theme
    public var followsCurrentTheme = true
    public var managesToolbarStyle = true
    public var onApply: ((Theme) -> Void)?

    private var themeObserver: ThemeObserver?
    private var notificationTokens: [NSObjectProtocol] = []
    private var titleObservation: NSKeyValueObservation?
    private let backgroundView = TitlebarBackgroundView()
    private var captionButtons: [WindowCaptionButton] = []
    private var captionConstraints: [NSLayoutConstraint] = []
    private var toolbarPadding: NSTitlebarAccessoryViewController?
    private var toolbarFrameTokens: [NSObjectProtocol] = []
    private var captionStyle: Theme.WindowButtonStyle?
    private var original: OriginalState?
    private var isFullScreen = false
    public private(set) var isDrawingCustomChrome = false
    var activeOverride: Bool?

    var isActive: Bool {
        if let activeOverride { return activeOverride }
        guard let window else { return false }
        return window.isMainWindow || window.isKeyWindow
    }

    private struct OriginalState {
        var titleVisibility: NSWindow.TitleVisibility
        var titlebarAppearsTransparent: Bool
        var toolbarStyle: NSWindow.ToolbarStyle
        var backgroundColor: NSColor
        var titlebarSeparatorStyle: NSTitlebarSeparatorStyle
    }

    @discardableResult
    public static func install(on window: NSWindow, theme: Theme? = nil) -> ThemedWindowChrome {
        if let existing = chrome(for: window) {
            if let theme { existing.apply(theme) }
            return existing
        }
        let chrome = ThemedWindowChrome(window: window, theme: theme ?? ThemeManager.shared.current)
        objc_setAssociatedObject(window, associationKey, chrome, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        chrome.apply(chrome.theme)
        return chrome
    }

    public static func chrome(for window: NSWindow) -> ThemedWindowChrome? {
        objc_getAssociatedObject(window, associationKey) as? ThemedWindowChrome
    }

    public static func uninstall(from window: NSWindow) {
        chrome(for: window)?.uninstall()
    }

    private init(window: NSWindow, theme: Theme) {
        self.window = window
        self.theme = theme
        super.init()
        backgroundView.chrome = self
        themeObserver = ThemeObserver(fireImmediately: false) { [weak self] t in
            guard let self, self.followsCurrentTheme else { return }
            self.apply(t)
        }
        let nc = NotificationCenter.default
        let refreshNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
        ]
        for name in refreshNames {
            notificationTokens.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        notificationTokens.append(nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFullScreen = true
                self.apply(self.theme)
            }
        })
        notificationTokens.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFullScreen = false
                self.apply(self.theme)
            }
        })
        titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        isFullScreen = window.styleMask.contains(.fullScreen)
    }

    public func uninstall() {
        applyNative()
        themeObserver?.invalidate()
        themeObserver = nil
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        titleObservation = nil
        if let window { objc_setAssociatedObject(window, Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    public func apply(_ theme: Theme) {
        self.theme = theme
        guard let window else { return }
        window.appearance = theme.appearance
        if theme.window.isNative || isFullScreen {
            applyNative()
        } else {
            applyCustom(theme, to: window)
        }
        onApply?(theme)
    }

    public var closeButtonView: NSView? {
        if let custom = captionButtons.first(where: { $0.kind == .close }), !custom.isHidden { return custom }
        guard let standard = window?.standardWindowButton(.closeButton), !standard.isHidden else { return nil }
        return standard
    }

    public func refresh() {
        backgroundView.needsDisplay = true
        captionButtons.forEach { $0.needsDisplay = true }
    }

    public var titlebarView: NSView? {
        window?.standardWindowButton(.closeButton)?.superview
    }

    public var titleStripHeight: CGFloat {
        guard let close = window?.standardWindowButton(.closeButton), let tv = close.superview else { return 28 }
        let f = close.convert(close.bounds, to: tv)
        let topGap = tv.isFlipped ? f.minY : tv.bounds.height - f.maxY
        let h = topGap * 2 + f.height
        return min(tv.bounds.height, max(22, h.rounded()))
    }

    func titleInsets(in view: NSView) -> (leading: CGFloat, trailing: CGFloat) {
        let buttons: [NSView]
        if captionButtons.isEmpty {
            buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }.filter { !$0.isHidden }
        } else {
            buttons = captionButtons
        }
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        let width = view.bounds.width
        for b in buttons {
            guard let sv = b.superview else { continue }
            let f = sv.convert(b.frame, to: view)
            if f.midX < width / 2 {
                leading = max(leading, f.maxX + 4)
            } else {
                trailing = max(trailing, width - f.minX + 4)
            }
        }
        return (leading, trailing)
    }

    private func captureOriginal(_ window: NSWindow) {
        guard original == nil else { return }
        original = OriginalState(
            titleVisibility: window.titleVisibility,
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            toolbarStyle: window.toolbarStyle,
            backgroundColor: window.backgroundColor,
            titlebarSeparatorStyle: window.titlebarSeparatorStyle
        )
    }

    private var toolbarView: NSView? {
        titlebarView?.subviews.first { String(describing: type(of: $0)).contains("NSToolbarView") }
    }

    private func installToolbarPadding(in window: NSWindow) {
        guard window.toolbar != nil else { return }
        if toolbarPadding == nil {
            let vc = NSTitlebarAccessoryViewController()
            vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            vc.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(vc)
            toolbarPadding = vc
        }
        observeToolbarFrames()
        syncToolbarOffset()
        for delay in [0.0, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.syncToolbarOffset()
            }
        }
    }

    private func observeToolbarFrames() {
        toolbarFrameTokens.forEach { NotificationCenter.default.removeObserver($0) }
        toolbarFrameTokens.removeAll()
        for view in [toolbarView, toolbarPadding?.view].compactMap({ $0 }) {
            view.postsFrameChangedNotifications = true
            toolbarFrameTokens.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncToolbarOffset() }
            })
        }
    }

    private func removeToolbarPadding() {
        if let vc = toolbarPadding, let window, let i = window.titlebarAccessoryViewControllers.firstIndex(of: vc) {
            window.removeTitlebarAccessoryViewController(at: i)
        }
        toolbarPadding = nil
        toolbarFrameTokens.forEach { NotificationCenter.default.removeObserver($0) }
        toolbarFrameTokens.removeAll()
        if let bar = toolbarView, bar.bounds.origin != .zero { bar.setBoundsOrigin(.zero) }
    }

    func syncToolbarOffset() {
        guard let vc = toolbarPadding, let bar = toolbarView else { return }
        var platters: [NSRect] = []
        var content: [NSRect] = []
        func visit(_ v: NSView, depth: Int) {
            for c in v.subviews where !c.isHidden {
                let f = c.convert(c.bounds, to: bar)
                if String(describing: type(of: c)).contains("Platter") {
                    platters.append(f)
                } else if f.height > 0, f.height < bar.bounds.height - 0.5 {
                    content.append(f)
                } else if depth < 3 {
                    visit(c, depth: depth + 1)
                }
            }
        }
        visit(bar, depth: 0)
        let frames = platters.isEmpty ? content : platters
        guard let minY = frames.map(\.minY).min(), let maxY = frames.map(\.maxY).max(), minY < maxY else { return }
        let area = bar.frame.height + vc.view.frame.height
        let gap = ((area - (maxY - minY)) / 2).rounded()
        let leading = bar.isFlipped ? minY - bar.bounds.minY : bar.bounds.maxY - maxY
        let delta = gap - leading
        guard abs(delta) > 0.5 else { return }
        bar.setBoundsOrigin(NSPoint(x: 0, y: bar.bounds.minY + (bar.isFlipped ? -delta : delta)))
        bar.needsDisplay = true
    }

    private func applyNative() {
        guard let window else { return }
        removeToolbarPadding()
        removeCaptionButtons()
        backgroundView.removeFromSuperview()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
        if let o = original {
            window.titleVisibility = o.titleVisibility
            window.titlebarAppearsTransparent = o.titlebarAppearsTransparent
            if managesToolbarStyle, window.toolbar != nil { window.toolbarStyle = o.toolbarStyle }
            window.backgroundColor = o.backgroundColor
            window.titlebarSeparatorStyle = o.titlebarSeparatorStyle
            original = nil
        }
        isDrawingCustomChrome = false
    }

    private func applyCustom(_ theme: Theme, to window: NSWindow) {
        captureOriginal(window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        if managesToolbarStyle, window.toolbar != nil, window.toolbarStyle != .expanded {
            window.toolbarStyle = .expanded
        }
        window.backgroundColor = theme.windowBackgroundColor
        guard let tv = titlebarView else { return }
        installBackground(in: tv)
        configureButtons(theme, in: tv, window: window)
        installToolbarPadding(in: window)
        isDrawingCustomChrome = true
        tv.needsLayout = true
        refresh()
    }

    private func installBackground(in tv: NSView) {
        guard backgroundView.superview !== tv else { return }
        backgroundView.removeFromSuperview()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        let anchor = tv.subviews.first { v in
            let name = String(describing: type(of: v))
            return v is NSButton || name.contains("Toolbar") || name.contains("TabBar")
        }
        tv.addSubview(backgroundView, positioned: .below, relativeTo: anchor)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: tv.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: tv.bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: tv.trailingAnchor),
        ])
    }

    private func configureButtons(_ theme: Theme, in tv: NSView, window: NSWindow) {
        let standard = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let style = theme.window.buttons
        if style == .native {
            standard.forEach { $0.isHidden = false }
            removeCaptionButtons()
            return
        }
        standard.forEach { $0.isHidden = true }
        var kinds: [WindowButtonKind] = []
        if window.styleMask.contains(.closable) { kinds.append(.close) }
        if window.styleMask.contains(.miniaturizable), theme.window.showsMinimize { kinds.append(.minimize) }
        if window.styleMask.contains(.resizable) { kinds.append(.zoom) }

        let needsRebuild = captionStyle != style || captionButtons.map(\.kind) != kinds || captionButtons.first?.superview !== tv
        if needsRebuild {
            removeCaptionButtons()
            for kind in kinds {
                let b = WindowCaptionButton(kind: kind)
                b.translatesAutoresizingMaskIntoConstraints = false
                b.target = self
                b.action = #selector(captionButtonPressed(_:))
                tv.addSubview(b)
                captionButtons.append(b)
            }
            captionStyle = style
        }
        captionButtons.forEach { $0.theme = theme }
        layoutCaptionButtons(theme, in: tv, standard: standard)
    }

    private func layoutCaptionButtons(_ theme: Theme, in tv: NSView, standard: [NSButton]) {
        NSLayoutConstraint.deactivate(captionConstraints)
        captionConstraints.removeAll()
        let size = WindowButtonRenderer.size(for: theme)
        let spacing = WindowButtonRenderer.spacing(for: theme)
        let inset = CGFloat(theme.window.captionInset)
        let centerAnchor = standard.first?.centerYAnchor ?? tv.topAnchor
        let centerOffset: CGFloat = standard.isEmpty ? 14 : 0
        var cs: [NSLayoutConstraint] = []
        for b in captionButtons {
            cs.append(b.widthAnchor.constraint(equalToConstant: size.width))
            cs.append(b.heightAnchor.constraint(equalToConstant: size.height))
            cs.append(b.centerYAnchor.constraint(equalTo: centerAnchor, constant: centerOffset))
        }
        let byKind = Dictionary(uniqueKeysWithValues: captionButtons.map { ($0.kind, $0) })
        switch theme.window.buttons {
        case .classicBoxes:
            if let close = byKind[.close] {
                cs.append(close.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 9 + inset))
            }
            var trailingAnchor = tv.trailingAnchor
            var gap: CGFloat = 9 + inset
            for kind in [WindowButtonKind.minimize, .zoom] {
                guard let b = byKind[kind] else { continue }
                cs.append(b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap))
                trailingAnchor = b.leadingAnchor
                gap = spacing
            }
        case .winCaption:
            var trailingAnchor = tv.trailingAnchor
            var gap: CGFloat = 2 + inset
            for kind in [WindowButtonKind.close, .zoom, .minimize] {
                guard let b = byKind[kind] else { continue }
                cs.append(b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap))
                trailingAnchor = b.leadingAnchor
                gap = kind == .close ? 2 : spacing
            }
        case .native:
            break
        }
        captionConstraints = cs
        NSLayoutConstraint.activate(cs)
    }

    private func removeCaptionButtons() {
        NSLayoutConstraint.deactivate(captionConstraints)
        captionConstraints.removeAll()
        captionButtons.forEach { $0.removeFromSuperview() }
        captionButtons.removeAll()
        captionStyle = nil
    }

    @objc private func captionButtonPressed(_ sender: WindowCaptionButton) {
        guard let window else { return }
        switch sender.kind {
        case .close:
            window.performClose(sender)
        case .minimize:
            window.performMiniaturize(sender)
        case .zoom:
            if NSEvent.modifierFlags.contains(.option) {
                window.toggleFullScreen(sender)
            } else {
                window.performZoom(sender)
            }
        }
    }
}

@MainActor
final class TitlebarBackgroundView: NSView {
    weak var chrome: ThemedWindowChrome?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        chrome?.syncToolbarOffset()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        chrome?.syncToolbarOffset()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let chrome, let window = chrome.window else { return }
        let theme = chrome.theme
        let active = chrome.isActive
        let stripHeight = min(bounds.height, chrome.titleStripHeight)
        let strip = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        let insets = chrome.titleInsets(in: self)
        TitlebarRenderer.drawStrip(in: strip, theme: theme, title: window.title, active: active,
                                   leadingInset: insets.leading, trailingInset: insets.trailing, patternView: self)
        func toolbarArea(height: CGFloat) {
            guard height > stripHeight + 1 else { return }
            TitlebarRenderer.drawToolbarArea(in: NSRect(x: 0, y: stripHeight, width: bounds.width, height: height - stripHeight),
                                             theme: theme, active: active, patternView: self)
        }
        guard let cut = sidebarTabBarCut(stripHeight: stripHeight) else {
            toolbarArea(height: bounds.height)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: cut.x, y: 0, width: bounds.width - cut.x, height: bounds.height).clip()
        toolbarArea(height: bounds.height)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: 0, width: cut.x, height: cut.height).clip()
        toolbarArea(height: cut.height)
        NSGraphicsContext.restoreGraphicsState()
    }

    func sidebarTabBarCut(stripHeight: CGFloat) -> (x: CGFloat, height: CGFloat)? {
        guard let root = window?.contentView?.superview, let bar = Self.tabBar(in: root), !bar.isHidden, bar.window != nil else { return nil }
        let r = bar.convert(bar.bounds, to: self)
        guard r.minX > 1, r.minX < bounds.width, r.minY > stripHeight, r.minY < bounds.maxY else { return nil }
        return (r.minX, r.minY)
    }

    static func tabBar(in view: NSView) -> NSView? {
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "NSTabBar" { return sub }
            if let found = tabBar(in: sub) { return found }
        }
        return nil
    }
}

@MainActor
public final class WindowCaptionButton: NSButton {
    public let kind: WindowButtonKind
    public var theme: Theme = ThemeManager.shared.current {
        didSet {
            needsDisplay = true
            noteFocusRingMaskChanged()
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    public init(kind: WindowButtonKind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 14))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        switch kind {
        case .close: setAccessibilityLabel("Close"); setAccessibilitySubrole(.closeButton)
        case .minimize: setAccessibilityLabel("Minimize"); setAccessibilitySubrole(.minimizeButton)
        case .zoom: setAccessibilityLabel("Zoom"); setAccessibilitySubrole(.zoomButton)
        }
    }

    public required init?(coder: NSCoder) { fatalError() }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override public var intrinsicContentSize: NSSize { WindowButtonRenderer.size(for: theme) }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override public func mouseEntered(with event: NSEvent) { hovering = true }
    override public func mouseExited(with event: NSEvent) { hovering = false }

    override public var focusRingMaskBounds: NSRect { bounds }

    override public func drawFocusRingMask() {
        WindowButtonRenderer.focusPath(in: bounds, theme: theme).fill()
    }

    override public func draw(_ dirtyRect: NSRect) {
        let active = window.flatMap { ThemedWindowChrome.chrome(for: $0)?.isActive } ?? true
        WindowButtonRenderer.draw(kind, in: bounds, theme: theme, pressed: isHighlighted, active: active, hovering: hovering)
    }
}
