import AppKit

@MainActor
public enum TitlebarRenderer {
    public static func fillColors(_ theme: Theme, active: Bool) -> [NSColor] {
        let w = theme.window
        let raw = active || w.inactiveColors.isEmpty ? w.colors : w.inactiveColors
        let colors = raw.map(Theme.color)
        return colors.isEmpty ? [Theme.color(theme.colors.windowBg)] : colors
    }

    public static func captionRect(_ strip: NSRect, theme: Theme) -> NSRect {
        let inset = CGFloat(theme.window.captionInset)
        guard inset > 0 else { return strip }
        return NSRect(x: strip.minX + inset, y: strip.minY + inset, width: strip.width - inset * 2, height: strip.height - inset * 2)
    }

    public static func drawStrip(in strip: NSRect, theme: Theme, title: String, active: Bool, leadingInset: CGFloat, trailingInset: CGFloat, patternView: NSView? = nil) {
        let w = theme.window
        let palette = theme.bevelPalette
        let colors = fillColors(theme, active: active)
        let caption = captionRect(strip, theme: theme)
        if caption != strip {
            BevelDrawing.fill(strip, palette.face)
        }
        let base = colors[0]

        switch w.effectiveFill {
        case .native, .solid:
            BevelDrawing.fill(caption, base)
        case .gradient:
            if w.horizontalGradient {
                BevelDrawing.horizontalGradient(colors, in: caption)
            } else {
                BevelDrawing.verticalGradient(colors, in: caption)
            }
        case .stripedGradient:
            BevelDrawing.verticalGradient(colors, in: caption)
            let stripe = NSColor.white.withAlphaComponent(active ? 0.42 : 0.3)
            var y = caption.minY + 1
            while y < caption.maxY - 1 {
                BevelDrawing.fill(NSRect(x: caption.minX, y: y, width: caption.width, height: 1), stripe)
                y += 2
            }
        case .pinstripe:
            BevelDrawing.verticalGradient(colors.count > 1 ? [colors[0], colors[1]] : [base], in: caption)
            if active {
                let dark = colors.count > 2 ? colors[2] : palette.shadow
                let light = colors.count > 3 ? colors[3] : palette.highlight
                let x0 = caption.minX + max(4, leadingInset)
                let x1 = caption.maxX - max(4, trailingInset)
                var y = caption.minY + 4
                while y + 2 <= caption.maxY - 4 {
                    BevelDrawing.fill(NSRect(x: x0, y: y, width: x1 - x0, height: 1), dark)
                    BevelDrawing.fill(NSRect(x: x0, y: y + 1, width: x1 - x0, height: 1), light)
                    y += 2
                }
            }
        case .lines:
            BevelDrawing.fill(caption, base)
            if active {
                let ink = colors.count > 1 ? colors[1] : Theme.color(w.titleColor)
                let count = 6
                let total = CGFloat(count * 2 - 1)
                var y = floor(caption.midY - total / 2)
                for _ in 0..<count {
                    BevelDrawing.fill(NSRect(x: caption.minX + 2, y: y, width: caption.width - 4, height: 1), ink)
                    y += 2
                }
            }
        case .brushedMetal:
            ThemePatterns.fill(caption, with: ThemePatterns.brushedMetal(base: base), in: patternView)
        }

        drawTitle(title, in: caption, theme: theme, active: active, leadingInset: leadingInset, trailingInset: trailingInset, clearColor: needsTitleBox(w.effectiveFill) && active ? base : nil)

        if w.separator && caption == strip {
            SurfaceRenderer.line(.maxY, of: strip, Theme.color(w.frameColor))
        }
    }

    private static func needsTitleBox(_ fill: Theme.TitlebarFill) -> Bool {
        fill == .pinstripe || fill == .lines
    }

    public static func titleAttributes(_ theme: Theme, active: Bool) -> [NSAttributedString.Key: Any] {
        let w = theme.window
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.titleFont,
            .foregroundColor: Theme.color(active ? w.titleColor : w.inactiveTitleColor),
            .paragraphStyle: para,
        ]
        if active, let s = w.titleShadow, !s.isEmpty {
            let shadow = NSShadow()
            shadow.shadowColor = Theme.color(s)
            shadow.shadowOffset = NSSize(width: 1, height: -1)
            shadow.shadowBlurRadius = 0
            attrs[.shadow] = shadow
        }
        return attrs
    }

    public static func drawTitle(_ title: String, in caption: NSRect, theme: Theme, active: Bool, leadingInset: CGFloat, trailingInset: CGFloat, clearColor: NSColor?) {
        guard !title.isEmpty else { return }
        let attrs = titleAttributes(theme, active: active)
        let str = NSAttributedString(string: title, attributes: attrs)
        let size = str.size()
        let availMinX = caption.minX + leadingInset + 4
        let availMaxX = caption.maxX - trailingInset - 4
        guard availMaxX - availMinX > 16 else { return }
        let width = min(ceil(size.width), availMaxX - availMinX - (clearColor != nil ? 12 : 0))
        var x: CGFloat
        switch theme.window.titleAlignment {
        case .center:
            x = floor(caption.midX - width / 2)
            x = max(availMinX + (clearColor != nil ? 6 : 0), min(x, availMaxX - width - (clearColor != nil ? 6 : 0)))
        case .leading:
            x = availMinX + (clearColor != nil ? 6 : 0)
        }
        let h = ceil(size.height)
        let y = floor(caption.midY - h / 2)
        if let clearColor {
            let box = NSRect(x: x - 6, y: caption.minY + 2, width: width + 12, height: caption.height - 4)
            BevelDrawing.fill(box, clearColor)
        }
        str.draw(with: NSRect(x: x, y: y, width: width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    public static func drawToolbarArea(in rect: NSRect, theme: Theme, active: Bool, patternView: NSView? = nil) {
        guard rect.height > 0 else { return }
        let palette = theme.bevelPalette
        if theme.window.brushedMetal || theme.window.titlebar == .brushedMetal {
            ThemePatterns.fill(rect, with: ThemePatterns.brushedMetal(base: fillColors(theme, active: true)[0]), in: patternView)
        } else if let p = theme.window.backgroundPattern, theme.toolbar.surface == .native {
            ThemePatterns.fill(rect, with: ThemePatterns.color(for: p, themeID: theme.id), in: patternView)
        } else {
            SurfaceRenderer.draw(theme.toolbar.surface == .native ? .flat : theme.toolbar.surface, in: rect,
                                 background: Theme.color(theme.toolbar.background), border: Theme.color(theme.colors.border),
                                 palette: palette, edge: nil)
        }
        if theme.window.separator {
            SurfaceRenderer.line(.maxY, of: rect, Theme.color(theme.window.frameColor))
        }
    }
}

public enum WindowButtonKind: Sendable { case close, minimize, zoom }

@MainActor
public enum WindowButtonRenderer {
    public static func size(for theme: Theme) -> NSSize {
        let w = theme.window
        let s = CGFloat(w.buttonSize)
        switch w.buttons {
        case .native: return NSSize(width: 14, height: 14)
        case .classicBoxes: return s > 0 ? NSSize(width: s, height: s) : NSSize(width: 13, height: 13)
        case .winCaption: return s > 0 ? NSSize(width: s, height: s) : NSSize(width: 16, height: 14)
        }
    }

    public static func spacing(for theme: Theme) -> CGFloat {
        switch theme.window.buttons {
        case .winCaption: return theme.window.buttonBevel ? 0 : 2
        default: return 6
        }
    }

    public static func focusPath(in rect: NSRect, theme: Theme) -> NSBezierPath {
        switch theme.window.buttons {
        case .native:
            let d = min(rect.width, rect.height) - 1
            return NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
        case .classicBoxes, .winCaption:
            return NSBezierPath(rect: rect.integral)
        }
    }

    public static func draw(_ kind: WindowButtonKind, in rect: NSRect, theme: Theme, pressed: Bool, active: Bool, hovering: Bool = false) {
        switch theme.window.buttons {
        case .native: drawTrafficLight(kind, rect, active: active, pressed: pressed, hovering: hovering)
        case .classicBoxes: drawClassicBox(kind, rect, theme: theme, pressed: pressed, active: active)
        case .winCaption: drawWinCaption(kind, rect, theme: theme, pressed: pressed, active: active, hovering: hovering)
        }
    }

    private static func drawTrafficLight(_ kind: WindowButtonKind, _ rect: NSRect, active: Bool, pressed: Bool, hovering: Bool) {
        let colors: [WindowButtonKind: String] = [.close: "#FF5F57", .minimize: "#FEBC2E", .zoom: "#28C840"]
        let c = active ? Theme.color(colors[kind] ?? "#CCCCCC") : NSColor(white: 0.8, alpha: 1)
        let d = min(rect.width, rect.height) - 1
        let r = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        (pressed ? (c.blended(withFraction: 0.25, of: .black) ?? c) : c).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)).stroke()
    }

    private static func drawClassicBox(_ kind: WindowButtonKind, _ rect: NSRect, theme: Theme, pressed: Bool, active: Bool) {
        guard active else { return }
        let w = theme.window
        let p = theme.bevelPalette
        let margin = TitlebarRenderer.fillColors(theme, active: true)[0]
        let box = rect.integral
        BevelDrawing.fill(box.insetBy(dx: -2, dy: 0), margin)
        let glyph = Theme.color(w.buttonGlyph)
        if !w.buttonBevel {
            BevelDrawing.fill(box, Theme.color(w.buttonFace))
            BevelDrawing.frameRect(box, glyph)
            let inner = box.insetBy(dx: 2, dy: 2)
            switch kind {
            case .close:
                if pressed {
                    let path = NSBezierPath()
                    let c = NSPoint(x: box.midX, y: box.midY)
                    for i in 0..<8 {
                        let a = CGFloat(i) * .pi / 4
                        path.move(to: NSPoint(x: c.x + cos(a) * 1.5, y: c.y + sin(a) * 1.5))
                        path.line(to: NSPoint(x: c.x + cos(a) * (inner.width / 2), y: c.y + sin(a) * (inner.width / 2)))
                    }
                    glyph.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            case .zoom:
                let small = NSRect(x: box.minX, y: BevelDrawing.isFlipped ? box.minY : box.maxY - ceil(box.height * 0.6), width: ceil(box.width * 0.6), height: ceil(box.height * 0.6))
                BevelDrawing.frameRect(small, glyph)
                if pressed { BevelDrawing.fill(inner, glyph.withAlphaComponent(0.4)) }
            case .minimize:
                BevelDrawing.fill(NSRect(x: box.minX, y: floor(box.midY) - 1, width: box.width, height: 1), glyph)
                BevelDrawing.fill(NSRect(x: box.minX, y: floor(box.midY) + 1, width: box.width, height: 1), glyph)
                if pressed { BevelDrawing.fill(inner, glyph.withAlphaComponent(0.4)) }
            }
            return
        }
        BevelDrawing.frameRect(box, p.darkShadow)
        let face = box.insetBy(dx: 1, dy: 1)
        if pressed {
            BevelDrawing.verticalGradient([p.shadow, p.light], in: face)
            BevelDrawing.ring(face, topLeft: p.darkShadow, bottomRight: p.highlight)
        } else {
            BevelDrawing.verticalGradient([p.highlight, Theme.color(w.buttonFace)], in: face)
            BevelDrawing.ring(face, topLeft: p.highlight, bottomRight: p.shadow)
        }
        let inner = face.insetBy(dx: 2, dy: 2)
        switch kind {
        case .close:
            break
        case .zoom:
            let s = ceil(inner.width * 0.65)
            let small = NSRect(x: inner.minX, y: BevelDrawing.isFlipped ? inner.minY : inner.maxY - s, width: s, height: s)
            BevelDrawing.frameRect(small, p.darkShadow)
            BevelDrawing.frameRect(inner, p.darkShadow)
        case .minimize:
            BevelDrawing.fill(NSRect(x: inner.minX, y: floor(inner.midY) - 1, width: inner.width, height: 1), p.darkShadow)
            BevelDrawing.fill(NSRect(x: inner.minX, y: floor(inner.midY) + 1, width: inner.width, height: 1), p.darkShadow)
        }
    }

    private static func drawWinCaption(_ kind: WindowButtonKind, _ rect: NSRect, theme: Theme, pressed: Bool, active: Bool, hovering: Bool) {
        let w = theme.window
        let box = rect.integral
        var glyphColor = Theme.color(w.buttonGlyph)
        if w.buttonBevel {
            let p = theme.bevelPalette.withFace(Theme.color(w.buttonFace))
            BevelDrawing.draw(pressed ? .pressed : .raised, in: box, palette: p)
        } else {
            var face = Theme.color(kind == .close && !w.closeButtonFace.isEmpty ? w.closeButtonFace : w.buttonFace)
            if !active { face = face.blended(withFraction: 0.35, of: .white) ?? face }
            if hovering { face = face.blended(withFraction: 0.2, of: .white) ?? face }
            BevelDrawing.glossy(box, radius: CGFloat(w.buttonCornerRadius), base: face, border: NSColor.white.withAlphaComponent(active ? 0.9 : 0.6), pressed: pressed)
            if !active { glyphColor = glyphColor.withAlphaComponent(0.8) }
        }
        let off: CGFloat = pressed && w.buttonBevel ? 1 : 0
        let thick: CGFloat = w.buttonBevel ? 2 : max(2, floor(box.width / 9))
        let g = NSRect(x: box.minX + off, y: box.minY + off, width: box.width, height: box.height)
        let flipped = BevelDrawing.isFlipped
        let gs = floor(min(g.width, g.height) * (w.buttonBevel ? 0.5 : 0.45))
        let gr = NSRect(x: floor(g.midX - gs / 2), y: floor(g.midY - gs / 2), width: gs, height: gs)
        switch kind {
        case .close:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: gr.minX, y: gr.minY))
            path.line(to: NSPoint(x: gr.maxX, y: gr.maxY))
            path.move(to: NSPoint(x: gr.maxX, y: gr.minY))
            path.line(to: NSPoint(x: gr.minX, y: gr.maxY))
            path.lineWidth = thick
            path.lineCapStyle = .square
            glyphColor.setStroke()
            path.stroke()
        case .minimize:
            let barY = flipped ? gr.maxY - thick : gr.minY
            BevelDrawing.fill(NSRect(x: gr.minX, y: barY, width: ceil(gs * 0.75), height: thick), glyphColor)
        case .zoom:
            BevelDrawing.frameRect(gr, glyphColor)
            BevelDrawing.fill(NSRect(x: gr.minX, y: flipped ? gr.minY : gr.maxY - thick, width: gr.width, height: thick), glyphColor)
        }
    }
}
