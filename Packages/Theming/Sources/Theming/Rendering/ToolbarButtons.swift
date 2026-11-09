import AppKit

public struct ThemedControlState: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let pressed = ThemedControlState(rawValue: 1 << 0)
    public static let hover = ThemedControlState(rawValue: 1 << 1)
    public static let on = ThemedControlState(rawValue: 1 << 2)
    public static let disabled = ThemedControlState(rawValue: 1 << 3)
}

@MainActor
public enum ToolbarButtonRenderer {
    public static func drawBezel(in rect: NSRect, theme: Theme, state: ThemedControlState) {
        let tb = theme.toolbar
        let p = theme.bevelPalette
        let face = Theme.color(tb.buttonFace)
        let border = Theme.color(tb.buttonBorder)
        let radius = CGFloat(tb.cornerRadius)
        let down = state.contains(.pressed) || state.contains(.on)
        switch tb.style {
        case .native:
            break
        case .bevel:
            let pressedFace = Theme.color(tb.pressed)
            BevelDrawing.roundedBevel(rect, radius: radius, face: down ? pressedFace : face, border: border,
                                      highlight: down ? p.shadow.withAlphaComponent(0.6) : p.highlight,
                                      shadow: down ? nil : p.shadow)
        case .flat:
            if radius <= 0 {
                if state.contains(.pressed) || state.contains(.on) {
                    if state.contains(.on) && !state.contains(.pressed) {
                        ThemePatterns.fill(rect.insetBy(dx: 1, dy: 1), with: ThemePatterns.dither50(p.highlight, p.face))
                    }
                    BevelDrawing.draw(.thinSunken, in: rect, palette: p, fillFace: false)
                } else if state.contains(.hover) {
                    BevelDrawing.draw(.thinRaised, in: rect, palette: p, fillFace: false)
                }
            } else if down || state.contains(.hover) {
                let c = Theme.color(down ? tb.pressed : tb.hover)
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                c.setFill()
                path.fill()
                border.withAlphaComponent(0.6).setStroke()
                path.stroke()
            }
        case .win3d:
            if state.contains(.on) && !state.contains(.pressed) {
                ThemePatterns.fill(rect, with: ThemePatterns.dither50(p.highlight, face))
                BevelDrawing.draw(.pressed, in: rect, palette: p.withFace(face), fillFace: false)
            } else {
                BevelDrawing.draw(down ? .pressed : .raised, in: rect, palette: p.withFace(face))
            }
        case .glossy:
            let r = min(rect.height / 2, max(radius, 4))
            let base = down ? Theme.color(tb.pressed) : face
            BevelDrawing.glossy(rect.insetBy(dx: 0, dy: 1), radius: r, base: base, border: border, pressed: down)
        }
    }

    public static func contentColor(_ theme: Theme, state: ThemedControlState) -> NSColor {
        contentColor(theme, state: state, isText: false)
    }

    public static func contentColor(_ theme: Theme, state: ThemedControlState, isText: Bool) -> NSColor {
        var c = Theme.color(theme.toolbar.text)
        let down = state.contains(.pressed) || state.contains(.on)
        if down, theme.toolbar.style == .bevel || theme.toolbar.style == .glossy || (theme.toolbar.style == .flat && theme.toolbar.cornerRadius > 0) {
            let face = Theme.color(theme.toolbar.pressed)
            if NSColor.contrastRatio(c, face) < (isText ? NSColor.textContrastMinimum : NSColor.glyphContrastMinimum) {
                c = NSColor.contrastRatio(.white, face) >= NSColor.contrastRatio(.black, face) ? .white : .black
            }
        }
        return state.contains(.disabled) ? c.withAlphaComponent(0.4) : c
    }

    public static func contentOffset(_ theme: Theme, state: ThemedControlState) -> NSSize {
        let style = theme.toolbar.style
        let shifts = style == .win3d || (style == .flat && theme.toolbar.cornerRadius <= 0)
        return shifts && (state.contains(.pressed) || state.contains(.on)) ? NSSize(width: 1, height: 1) : .zero
    }

    public static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        let out = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    public static func drawContent(image: NSImage?, title: String?, in rect: NSRect, theme: Theme, state: ThemedControlState, font: NSFont? = nil) {
        let off = contentOffset(theme, state: state)
        let flipped = BevelDrawing.isFlipped
        let r = rect.offsetBy(dx: off.width, dy: flipped ? off.height : -off.height)
        let color = contentColor(theme, state: state, isText: image == nil)
        if let image {
            let img = tinted(image, color: color)
            let s = img.size
            let ir = NSRect(x: floor(r.midX - s.width / 2), y: floor(r.midY - s.height / 2), width: s.width, height: s.height)
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: state.contains(.disabled) ? 0.4 : 1, respectFlipped: true, hints: nil)
        } else if let title, !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? theme.uiFont, .foregroundColor: color]
            let str = NSAttributedString(string: title, attributes: attrs)
            let s = str.size()
            str.draw(at: NSPoint(x: floor(r.midX - s.width / 2), y: floor(r.midY - s.height / 2)))
        }
    }
}

open class ThemedButtonCell: NSButtonCell {
    public final var themeOverride: Theme?

    override open func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! ThemedButtonCell
        withUnsafeMutablePointer(to: &copy.themeOverride) { $0.initialize(to: themeOverride) }
        return copy
    }
    public var isHovering = false

    @MainActor
    public var theme: Theme { themeOverride ?? ThemeManager.shared.current }

    @MainActor
    var themedState: ThemedControlState {
        var s: ThemedControlState = []
        if isHighlighted { s.insert(.pressed) }
        if isHovering { s.insert(.hover) }
        if state == .on, !showsStateBy.isEmpty { s.insert(.on) }
        if !isEnabled { s.insert(.disabled) }
        return s
    }

    override open func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let t = MainActor.assumeIsolated { theme }
        guard t.toolbar.style != .native else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        MainActor.assumeIsolated {
            let s = themedState
            ToolbarButtonRenderer.drawBezel(in: cellFrame.insetBy(dx: 0, dy: 1), theme: t, state: s)
            ToolbarButtonRenderer.drawContent(image: image, title: imagePosition == .imageOnly ? nil : title, in: cellFrame, theme: t, state: s, font: font)
        }
    }
}

open class ThemedToolbarButton: NSButton {
    override open class var cellClass: AnyClass? {
        get { ThemedButtonCell.self }
        set {}
    }

    private var themeObserver: ThemeObserver?
    private var hoverArea: NSTrackingArea?

    public static func make(symbol: String, label: String, target: AnyObject?, action: Selector?) -> ThemedToolbarButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let b = ThemedToolbarButton(image: image, target: target, action: action)
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        return b
    }

    public var themedCell: ThemedButtonCell? { cell as? ThemedButtonCell }

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard themeObserver == nil, window != nil else { return }
        themeObserver = ThemeObserver(fireImmediately: false) { [weak self] _ in
            self?.invalidateIntrinsicContentSize()
            self?.needsDisplay = true
        }
    }

    override open var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        let style = themedCell?.theme.toolbar.style ?? .native
        guard style != .native else { return base }
        let imgW = image?.size.width ?? 0
        let titleW = imagePosition == .imageOnly ? 0 : attributedTitle.size().width
        return NSSize(width: max(28, ceil(max(imgW, titleW)) + 14), height: max(24, base.height))
    }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        hoverArea = t
    }

    override open func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        themedCell?.isHovering = true
        needsDisplay = true
    }

    override open func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        themedCell?.isHovering = false
        needsDisplay = true
    }
}

open class ThemedSegmentedCell: NSSegmentedCell {
    public final var themeOverride: Theme?

    override open func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! ThemedSegmentedCell
        withUnsafeMutablePointer(to: &copy.themeOverride) { $0.initialize(to: themeOverride) }
        return copy
    }

    @MainActor
    public var theme: Theme { themeOverride ?? ThemeManager.shared.current }

    @MainActor
    func segmentRects(in frame: NSRect) -> [NSRect] {
        let n = segmentCount
        guard n > 0 else { return [] }
        let fixed = (0..<n).map { width(forSegment: $0) }
        let fixedTotal = fixed.reduce(0, +)
        let autoCount = fixed.filter { $0 == 0 }.count
        let autoWidth = autoCount > 0 ? max(0, (frame.width - fixedTotal) / CGFloat(autoCount)) : 0
        var x = frame.minX
        var rects: [NSRect] = []
        for i in 0..<n {
            let w = fixed[i] > 0 ? fixed[i] : autoWidth
            rects.append(NSRect(x: x, y: frame.minY, width: w, height: frame.height))
            x += w
        }
        return rects
    }

    override open func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let t = MainActor.assumeIsolated { theme }
        guard t.toolbar.style != .native else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        MainActor.assumeIsolated {
            let rects = segmentRects(in: cellFrame)
            let momentary = trackingMode == .momentary
            let gap: CGFloat = t.toolbar.style == .glossy ? 0 : 1
            for (i, r) in rects.enumerated() {
                var s: ThemedControlState = []
                if isSelected(forSegment: i) { s.insert(momentary ? .pressed : .on) }
                if !isEnabled || !isEnabled(forSegment: i) { s.insert(.disabled) }
                let bezelRect = r.insetBy(dx: gap, dy: 1)
                ToolbarButtonRenderer.drawBezel(in: bezelRect, theme: t, state: s)
                ToolbarButtonRenderer.drawContent(image: image(forSegment: i), title: label(forSegment: i), in: bezelRect, theme: t, state: s, font: font)
            }
        }
    }
}

open class ThemedSegmentedControl: NSSegmentedControl {
    override open class var cellClass: AnyClass? {
        get { ThemedSegmentedCell.self }
        set {}
    }

    private var themeObserver: ThemeObserver?

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard themeObserver == nil, window != nil else { return }
        themeObserver = ThemeObserver(fireImmediately: false) { [weak self] _ in
            self?.invalidateIntrinsicContentSize()
            self?.needsDisplay = true
        }
    }

    override open var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        let style = (cell as? ThemedSegmentedCell)?.theme.toolbar.style ?? .native
        guard style != .native else { return base }
        return NSSize(width: max(base.width, CGFloat(segmentCount) * 30), height: max(24, base.height))
    }
}
