import AppKit

public enum ScrollerPart: Sendable { case decrementArrow, incrementArrow, decrementPage, incrementPage, knob }

@MainActor
public enum ScrollbarRenderer {
    public struct Layout {
        public var track: NSRect
        public var decrementArrow: NSRect?
        public var incrementArrow: NSRect?
        public var knob: NSRect?
        public var vertical: Bool
    }

    public static func layout(in bounds: NSRect, vertical: Bool, theme: Theme, proportion: CGFloat, value: Double, enabled: Bool) -> Layout {
        let sb = theme.scrollbar
        let thick = vertical ? bounds.width : bounds.height
        let len = vertical ? bounds.height : bounds.width
        let arrowLen = sb.arrows && len > thick * 3 ? thick : 0
        var dec: NSRect?
        var inc: NSRect?
        var track = bounds
        func seg(_ start: CGFloat, _ length: CGFloat) -> NSRect {
            vertical ? NSRect(x: bounds.minX, y: bounds.minY + start, width: thick, height: length)
                     : NSRect(x: bounds.minX + start, y: bounds.minY, width: length, height: thick)
        }
        if arrowLen > 0 {
            if sb.style == .aqua {
                dec = seg(len - arrowLen * 2, arrowLen)
                inc = seg(len - arrowLen, arrowLen)
                track = seg(0, len - arrowLen * 2)
            } else {
                dec = seg(0, arrowLen)
                inc = seg(len - arrowLen, arrowLen)
                track = seg(arrowLen, len - arrowLen * 2)
            }
        }
        var knob: NSRect?
        if enabled, proportion > 0, proportion < 1 {
            let trackLen = vertical ? track.height : track.width
            let minKnob = CGFloat(sb.minimumThumb)
            let knobLen: CGFloat = sb.style == .system7 ? min(thick, trackLen) : min(trackLen, max(minKnob, floor(trackLen * proportion)))
            if trackLen >= knobLen {
                let pos = floor((trackLen - knobLen) * CGFloat(max(0, min(1, value))))
                knob = vertical ? NSRect(x: track.minX, y: track.minY + pos, width: thick, height: knobLen)
                                : NSRect(x: track.minX + pos, y: track.minY, width: knobLen, height: thick)
            }
        }
        return Layout(track: track, decrementArrow: dec, incrementArrow: inc, knob: knob, vertical: vertical)
    }

    public static func draw(in bounds: NSRect, vertical: Bool, theme: Theme, proportion: CGFloat, value: Double, enabled: Bool, pressed: ScrollerPart? = nil) {
        let l = layout(in: bounds, vertical: vertical, theme: theme, proportion: proportion, value: value, enabled: enabled)
        drawTrack(l, bounds: bounds, theme: theme, enabled: enabled && l.knob != nil, pressed: pressed)
        if let d = l.decrementArrow { drawArrow(vertical ? .up : .left, in: d, theme: theme, pressed: pressed == .decrementArrow, enabled: enabled) }
        if let i = l.incrementArrow { drawArrow(vertical ? .down : .right, in: i, theme: theme, pressed: pressed == .incrementArrow, enabled: enabled) }
        if let k = l.knob { drawKnob(in: k, vertical: vertical, theme: theme, pressed: pressed == .knob) }
        if theme.scrollbar.style == .system7 {
            BevelDrawing.frameRect(bounds, Theme.color(theme.scrollbar.thumbBorder == "system:clear" ? "#000000" : theme.scrollbar.thumbBorder))
        }
    }

    static func drawTrack(_ l: Layout, bounds: NSRect, theme: Theme, enabled: Bool, pressed: ScrollerPart?) {
        let sb = theme.scrollbar
        let p = theme.bevelPalette
        let track = Theme.color(sb.track)
        let t = l.track
        switch sb.style {
        case .native, .flat:
            BevelDrawing.fill(bounds, track)
        case .win3d:
            BevelDrawing.fill(bounds, p.face)
            let fg = pressed == .decrementPage || pressed == .incrementPage ? p.darkShadow : p.highlight
            ThemePatterns.fill(t, with: ThemePatterns.dither50(fg, track))
        case .platinum:
            BevelDrawing.fill(bounds, p.face)
            if enabled {
                BevelDrawing.fill(t, track)
                BevelDrawing.ring(t, topLeft: p.shadow, bottomRight: p.highlight)
            } else {
                BevelDrawing.fill(t, p.face)
            }
            let edge: NSRectEdge = l.vertical ? .minX : .minY
            SurfaceRenderer.line(edge, of: bounds, p.darkShadow)
        case .system7:
            BevelDrawing.fill(bounds, .white)
            if enabled { ThemePatterns.fill(t, with: ThemePatterns.dither50(track, .white)) }
        case .aqua:
            let light = NSColor.white
            let shade = track
            if l.vertical {
                BevelDrawing.horizontalGradient([shade, light, light, shade], in: bounds)
            } else {
                BevelDrawing.verticalGradient([shade, light, light, shade], in: bounds)
            }
            let inset = t.insetBy(dx: l.vertical ? 2 : 1, dy: l.vertical ? 1 : 2)
            let r = min(inset.width, inset.height) / 2
            NSColor.black.withAlphaComponent(0.12).setStroke()
            NSBezierPath(roundedRect: inset.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r).stroke()
        }
    }

    static func drawArrow(_ dir: ArrowDirection, in r: NSRect, theme: Theme, pressed: Bool, enabled: Bool) {
        let sb = theme.scrollbar
        let p = theme.bevelPalette
        let glyph = enabled ? p.darkShadow : p.shadow
        let size = CGFloat(max(5, Int(min(r.width, r.height) * 0.45) | 1))
        switch sb.style {
        case .win3d:
            BevelDrawing.draw(pressed ? .pressed : .raised, in: r, palette: p)
            let off: CGFloat = pressed ? 1 : 0
            BevelDrawing.triangle(dir, in: r.offsetBy(dx: off, dy: off), color: glyph, size: size)
        case .platinum:
            if pressed {
                BevelDrawing.fill(r, p.shadow)
                BevelDrawing.ring(r, topLeft: p.darkShadow, bottomRight: p.light)
            } else {
                BevelDrawing.verticalGradient([p.highlight, p.face], in: r)
                BevelDrawing.ring(r, topLeft: p.highlight, bottomRight: p.shadow)
            }
            BevelDrawing.frameRect(r, p.darkShadow.withAlphaComponent(0.5))
            BevelDrawing.triangle(dir, in: r, color: glyph, size: size)
        case .system7:
            BevelDrawing.fill(r, .white)
            BevelDrawing.frameRect(r, .black)
            BevelDrawing.triangle(dir, in: r, color: .black, filled: pressed, size: size + 2)
        case .aqua:
            BevelDrawing.glossy(r.insetBy(dx: 1, dy: 1), radius: 3, base: NSColor(white: 0.92, alpha: 1), border: NSColor(white: 0.6, alpha: 1), pressed: pressed)
            BevelDrawing.triangle(dir, in: r, color: NSColor(white: 0.25, alpha: 1), size: size)
        case .native, .flat:
            BevelDrawing.triangle(dir, in: r, color: Theme.color(sb.thumb).withAlphaComponent(pressed ? 1 : 0.7), size: size)
        }
    }

    static func drawKnob(in k: NSRect, vertical: Bool, theme: Theme, pressed: Bool) {
        let sb = theme.scrollbar
        let p = theme.bevelPalette
        let thumb = Theme.color(sb.thumb)
        switch sb.style {
        case .win3d:
            BevelDrawing.draw(.raised, in: k, palette: p.withFace(thumb))
        case .platinum:
            let dark = thumb.blended(withFraction: 0.35, of: .black) ?? p.shadow
            let light = thumb.blended(withFraction: 0.6, of: .white) ?? p.highlight
            BevelDrawing.fill(k, pressed ? dark : thumb)
            BevelDrawing.frameRect(k, p.darkShadow)
            BevelDrawing.ring(k.insetBy(dx: 1, dy: 1), topLeft: light, bottomRight: dark)
            let grip = BevelPalette(face: thumb, highlight: light, light: light, shadow: dark, darkShadow: dark, frame: dark)
            let gripRect = vertical ? NSRect(x: k.minX + 4, y: k.midY - 4, width: k.width - 8, height: 8)
                                    : NSRect(x: k.midX - 4, y: k.minY + 4, width: 8, height: k.height - 8)
            if (vertical ? k.height : k.width) > 16 {
                BevelDrawing.gripLines(in: gripRect, vertical: !vertical, count: 4, palette: grip)
            }
        case .system7:
            BevelDrawing.fill(k, pressed ? NSColor(white: 0.85, alpha: 1) : thumb)
            BevelDrawing.frameRect(k, .black)
        case .aqua:
            let r = (vertical ? k.width : k.height) / 2 - 2
            BevelDrawing.glossy(k.insetBy(dx: vertical ? 2 : 1, dy: vertical ? 1 : 2), radius: r, base: thumb,
                                border: thumb.blended(withFraction: 0.4, of: .black) ?? thumb, pressed: pressed)
        case .native, .flat:
            let inner = k.insetBy(dx: vertical ? 3 : 2, dy: vertical ? 2 : 3)
            let r = min(inner.width, inner.height) / 2
            (pressed ? thumb : thumb.withAlphaComponent(0.75)).setFill()
            NSBezierPath(roundedRect: inner, xRadius: r, yRadius: r).fill()
        }
    }
}

open class ThemedScroller: NSScroller {
    public var theme: Theme = ThemeManager.shared.current {
        didSet { needsDisplay = true }
    }
    public private(set) var pressedPart: ScrollerPart? {
        didSet { needsDisplay = true }
    }

    public static var preferredWidth: CGFloat = 15

    override open class var isCompatibleWithOverlayScrollers: Bool { false }

    override open class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        preferredWidth
    }

    override open var isFlipped: Bool { true }
    override open var isOpaque: Bool { true }

    var isVertical: Bool { bounds.height >= bounds.width }
    var isScrollable: Bool { knobProportion > 0 && knobProportion < 1 }

    var currentLayout: ScrollbarRenderer.Layout {
        ScrollbarRenderer.layout(in: bounds, vertical: isVertical, theme: theme, proportion: knobProportion, value: doubleValue, enabled: isScrollable)
    }

    override open func draw(_ dirtyRect: NSRect) {
        ScrollbarRenderer.draw(in: bounds, vertical: isVertical, theme: theme, proportion: knobProportion, value: doubleValue, enabled: isScrollable, pressed: pressedPart)
    }

    override open func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(bounds)
    }

    override open var doubleValue: Double {
        didSet { needsDisplay = true }
    }

    override open var knobProportion: CGFloat {
        didSet { needsDisplay = true }
    }

    override open func rect(for partCode: NSScroller.Part) -> NSRect {
        let l = currentLayout
        switch partCode {
        case .knob: return l.knob ?? .zero
        case .knobSlot: return l.track
        case .decrementPage:
            guard let k = l.knob else { return .zero }
            return isVertical ? NSRect(x: l.track.minX, y: l.track.minY, width: l.track.width, height: k.minY - l.track.minY)
                              : NSRect(x: l.track.minX, y: l.track.minY, width: k.minX - l.track.minX, height: l.track.height)
        case .incrementPage:
            guard let k = l.knob else { return .zero }
            return isVertical ? NSRect(x: l.track.minX, y: k.maxY, width: l.track.width, height: l.track.maxY - k.maxY)
                              : NSRect(x: k.maxX, y: l.track.minY, width: l.track.maxX - k.maxX, height: l.track.height)
        case .noPart: return .zero
        default: return super.rect(for: partCode)
        }
    }

    override open func drawKnob() {}
    override open func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    private var scrollView: NSScrollView? { superview as? NSScrollView ?? enclosingScrollView }

    override open func mouseDown(with event: NSEvent) {
        guard isScrollable, let sv = scrollView else { return }
        let l = currentLayout
        var mouse = convert(event.locationInWindow, from: nil)
        if let k = l.knob, k.contains(mouse) {
            trackKnob(from: mouse, layout: l, scrollView: sv)
            return
        }
        let part: ScrollerPart
        if let d = l.decrementArrow, d.contains(mouse) {
            part = .decrementArrow
        } else if let i = l.incrementArrow, i.contains(mouse) {
            part = .incrementArrow
        } else if let k = l.knob {
            let before = isVertical ? mouse.y < k.minY : mouse.x < k.minX
            part = before ? .decrementPage : .incrementPage
        } else {
            return
        }
        let step: () -> Void = { [weak self] in
            guard let self else { return }
            switch part {
            case .decrementArrow: self.scroll(sv, by: -self.lineAmount(sv))
            case .incrementArrow: self.scroll(sv, by: self.lineAmount(sv))
            case .decrementPage: self.scroll(sv, by: -self.pageAmount(sv))
            case .incrementPage: self.scroll(sv, by: self.pageAmount(sv))
            case .knob: break
            }
        }
        pressedPart = part
        step()
        NSEvent.startPeriodicEvents(afterDelay: 0.35, withPeriod: 0.05)
        defer {
            NSEvent.stopPeriodicEvents()
            pressedPart = nil
        }
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic]) {
            if e.type == .leftMouseUp { break }
            if e.type == .leftMouseDragged {
                mouse = convert(e.locationInWindow, from: nil)
                continue
            }
            let now = currentLayout
            var stillOn = false
            switch part {
            case .decrementArrow: stillOn = now.decrementArrow?.contains(mouse) ?? false
            case .incrementArrow: stillOn = now.incrementArrow?.contains(mouse) ?? false
            case .decrementPage:
                if let k = now.knob { stillOn = now.track.contains(mouse) && (isVertical ? mouse.y < k.minY : mouse.x < k.minX) }
            case .incrementPage:
                if let k = now.knob { stillOn = now.track.contains(mouse) && (isVertical ? mouse.y > k.maxY : mouse.x > k.maxX) }
            case .knob: break
            }
            pressedPart = stillOn ? part : nil
            if stillOn { step() }
        }
    }

    private func trackKnob(from start: NSPoint, layout l: ScrollbarRenderer.Layout, scrollView sv: NSScrollView) {
        guard let k = l.knob else { return }
        let trackLen = isVertical ? l.track.height : l.track.width
        let knobLen = isVertical ? k.height : k.width
        let travel = trackLen - knobLen
        guard travel > 0 else { return }
        let startValue = doubleValue
        let startPos = isVertical ? start.y : start.x
        pressedPart = .knob
        defer { pressedPart = nil }
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if e.type == .leftMouseUp { break }
            let p = convert(e.locationInWindow, from: nil)
            let delta = (isVertical ? p.y : p.x) - startPos
            let v = max(0, min(1, startValue + Double(delta / travel)))
            setScroll(sv, to: v)
        }
    }

    private func lineAmount(_ sv: NSScrollView) -> CGFloat {
        max(16, isVertical ? sv.verticalLineScroll : sv.horizontalLineScroll)
    }

    private func pageAmount(_ sv: NSScrollView) -> CGFloat {
        let clip = sv.contentView.bounds
        let page = isVertical ? clip.height - sv.verticalPageScroll : clip.width - sv.horizontalPageScroll
        return max(lineAmount(sv), page - lineAmount(sv))
    }

    private func range(_ sv: NSScrollView) -> (min: CGFloat, max: CGFloat)? {
        guard let doc = sv.documentView else { return nil }
        let clip = sv.contentView
        let insets = clip.contentInsets
        if isVertical {
            let lo = doc.frame.minY - insets.top
            let hi = doc.frame.maxY - clip.bounds.height + insets.bottom
            return hi > lo ? (lo, hi) : nil
        } else {
            let lo = doc.frame.minX - insets.left
            let hi = doc.frame.maxX - clip.bounds.width + insets.right
            return hi > lo ? (lo, hi) : nil
        }
    }

    private func setScroll(_ sv: NSScrollView, to value: Double) {
        guard let r = range(sv), let doc = sv.documentView else { return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        let v = CGFloat(value)
        if isVertical {
            o.y = doc.isFlipped ? r.min + v * (r.max - r.min) : r.max - v * (r.max - r.min)
        } else {
            o.x = r.min + v * (r.max - r.min)
        }
        commit(sv, origin: o, range: r)
    }

    private func scroll(_ sv: NSScrollView, by delta: CGFloat) {
        guard let r = range(sv), let doc = sv.documentView else { return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        if isVertical {
            o.y += doc.isFlipped ? delta : -delta
        } else {
            o.x += delta
        }
        commit(sv, origin: o, range: r)
    }

    private func commit(_ sv: NSScrollView, origin: NSPoint, range r: (min: CGFloat, max: CGFloat)) {
        var o = origin
        if isVertical { o.y = max(r.min, min(r.max, o.y)) } else { o.x = max(r.min, min(r.max, o.x)) }
        sv.contentView.scroll(to: o)
        sv.reflectScrolledClipView(sv.contentView)
    }

    public static func apply(_ theme: Theme, to scrollView: NSScrollView) {
        preferredWidth = CGFloat(max(8, theme.scrollbar.width))
        if theme.scrollbar.style == .native {
            if scrollView.verticalScroller is ThemedScroller { scrollView.verticalScroller = NSScroller() }
            if scrollView.horizontalScroller is ThemedScroller { scrollView.horizontalScroller = NSScroller() }
            scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        } else {
            if scrollView.hasVerticalScroller {
                let v = scrollView.verticalScroller as? ThemedScroller ?? ThemedScroller()
                v.theme = theme
                if scrollView.verticalScroller !== v { scrollView.verticalScroller = v }
            }
            if scrollView.hasHorizontalScroller {
                let h = scrollView.horizontalScroller as? ThemedScroller ?? ThemedScroller()
                h.theme = theme
                if scrollView.horizontalScroller !== h { scrollView.horizontalScroller = h }
            }
            scrollView.scrollerStyle = .legacy
        }
        scrollView.tile()
        scrollView.needsDisplay = true
    }

    @discardableResult
    public static func install(in scrollView: NSScrollView) -> ThemeObserver {
        let styleObserver = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let scrollView else { return }
                if ThemeManager.shared.current.scrollbar.style != .native { scrollView.scrollerStyle = .legacy }
            }
        }
        let holder = NotificationTokenHolder(styleObserver)
        return ThemeObserver.bind(scrollView) { sv, theme in
            _ = holder
            ThemedScroller.apply(theme, to: sv)
        }
    }
}

final class NotificationTokenHolder: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
