import AppKit

public struct BevelPalette {
    public var face: NSColor
    public var highlight: NSColor
    public var light: NSColor
    public var shadow: NSColor
    public var darkShadow: NSColor
    public var frame: NSColor

    public init(face: NSColor, highlight: NSColor, light: NSColor, shadow: NSColor, darkShadow: NSColor, frame: NSColor) {
        self.face = face
        self.highlight = highlight
        self.light = light
        self.shadow = shadow
        self.darkShadow = darkShadow
        self.frame = frame
    }

    public init(_ colors: Theme.BevelColors) {
        self.init(
            face: Theme.color(colors.face), highlight: Theme.color(colors.highlight), light: Theme.color(colors.light),
            shadow: Theme.color(colors.shadow), darkShadow: Theme.color(colors.darkShadow), frame: Theme.color(colors.frame)
        )
    }

    public func withFace(_ c: NSColor) -> BevelPalette {
        var p = self
        p.face = c
        return p
    }

    public static var win98: BevelPalette { BevelPalette(Theme.BevelColors()) }
    public static var platinum: BevelPalette {
        BevelPalette(Theme.BevelColors(face: "#DDDDDD", highlight: "#FFFFFF", light: "#EEEEEE", shadow: "#999999", darkShadow: "#555555", frame: "#000000"))
    }
}

public extension Theme {
    var bevelPalette: BevelPalette { BevelPalette(bevelColors) }
}

public enum BevelKind: Sendable {
    case raised
    case pressed
    case sunken
    case field
    case window
    case thinRaised
    case thinSunken
    case etched
    case platinumRaised
    case platinumPressed
    case platinumWell
    case outline
    case flat
}

public enum ArrowDirection: Sendable { case up, down, left, right }

@MainActor
public enum BevelDrawing {
    public static var isFlipped: Bool { NSGraphicsContext.current?.isFlipped ?? false }

    public static func fill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        rect.fill(using: .sourceOver)
    }

    public static func ring(_ r: NSRect, topLeft: NSColor, bottomRight: NSColor, width w: CGFloat = 1) {
        guard r.width >= w * 2, r.height >= w * 2 else { return }
        let flipped = isFlipped
        let topY = flipped ? r.minY : r.maxY - w
        let bottomY = flipped ? r.maxY - w : r.minY
        fill(NSRect(x: r.minX, y: bottomY, width: r.width, height: w), bottomRight)
        fill(NSRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), bottomRight)
        fill(NSRect(x: r.minX, y: topY, width: r.width - w, height: w), topLeft)
        let leftY = flipped ? r.minY : r.minY + w
        fill(NSRect(x: r.minX, y: leftY, width: w, height: r.height - w), topLeft)
    }

    public static func draw(_ kind: BevelKind, in rect: NSRect, palette p: BevelPalette, fillFace: Bool = true) {
        let r = rect.integral
        if fillFace, kind != .outline { fill(r, p.face) }
        switch kind {
        case .raised:
            ring(r, topLeft: p.highlight, bottomRight: p.darkShadow)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.light, bottomRight: p.shadow)
        case .pressed:
            ring(r, topLeft: p.darkShadow, bottomRight: p.highlight)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.shadow, bottomRight: p.light)
        case .sunken, .field:
            ring(r, topLeft: p.shadow, bottomRight: p.highlight)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.darkShadow, bottomRight: p.light)
        case .window:
            ring(r, topLeft: p.light, bottomRight: p.darkShadow)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.highlight, bottomRight: p.shadow)
        case .thinRaised:
            ring(r, topLeft: p.highlight, bottomRight: p.shadow)
        case .thinSunken:
            ring(r, topLeft: p.shadow, bottomRight: p.highlight)
        case .etched:
            ring(r, topLeft: p.shadow, bottomRight: p.highlight)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.highlight, bottomRight: p.shadow)
        case .platinumRaised:
            frameRect(r, p.frame)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.highlight, bottomRight: p.shadow)
        case .platinumPressed:
            fill(r.insetBy(dx: 1, dy: 1), p.shadow)
            frameRect(r, p.frame)
            ring(r.insetBy(dx: 1, dy: 1), topLeft: p.darkShadow, bottomRight: p.light)
        case .platinumWell:
            ring(r, topLeft: p.shadow, bottomRight: p.highlight)
            frameRect(r.insetBy(dx: 1, dy: 1), p.frame)
        case .outline:
            frameRect(r, p.frame)
        case .flat:
            break
        }
    }

    public static func frameRect(_ r: NSRect, _ color: NSColor, width: CGFloat = 1) {
        ring(r, topLeft: color, bottomRight: color, width: width)
    }

    public static func roundedBevel(_ rect: NSRect, radius: CGFloat, face: NSColor, border: NSColor, highlight: NSColor?, shadow: NSColor?) {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        face.setFill()
        path.fill()
        if let highlight {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let inner = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: isFlipped ? 0.5 : -0.5), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
            highlight.setStroke()
            inner.lineWidth = 1
            inner.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let shadow {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let bottom = isFlipped ? NSRect(x: r.minX, y: r.maxY - 1.5, width: r.width, height: 1) : NSRect(x: r.minX, y: r.minY + 0.5, width: r.width, height: 1)
            fill(bottom, shadow)
            NSGraphicsContext.restoreGraphicsState()
        }
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    public static func glossy(_ rect: NSRect, radius: CGFloat, base: NSColor, border: NSColor, pressed: Bool = false) {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let b = base.usingColorSpace(.sRGB) ?? base
        let top = b.blended(withFraction: pressed ? 0.1 : 0.55, of: .white) ?? b
        let mid = b.blended(withFraction: pressed ? 0.25 : 0.05, of: pressed ? .black : .white) ?? b
        let bottom = b.blended(withFraction: pressed ? 0.05 : 0.35, of: .white) ?? b
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        verticalGradient([top, mid, mid.blended(withFraction: 0.1, of: .black) ?? mid, bottom], locations: [0, 0.5, 0.5, 1], in: r)
        let shine = NSBezierPath(roundedRect: NSRect(x: r.minX + 2, y: isFlipped ? r.minY + 1 : r.midY, width: r.width - 4, height: r.height / 2 - 1), xRadius: max(0, radius - 2), yRadius: max(0, radius - 2))
        NSColor.white.withAlphaComponent(pressed ? 0.15 : 0.35).setFill()
        shine.fill()
        NSGraphicsContext.restoreGraphicsState()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    public static func verticalGradient(_ colors: [NSColor], locations: [CGFloat]? = nil, in rect: NSRect) {
        guard !colors.isEmpty else { return }
        if colors.count == 1 {
            fill(rect, colors[0])
            return
        }
        let g: NSGradient?
        if let locations, locations.count == colors.count {
            var locs = locations
            g = NSGradient(colors: colors, atLocations: &locs, colorSpace: .sRGB)
        } else {
            g = NSGradient(colors: colors)
        }
        g?.draw(in: rect, angle: isFlipped ? 90 : -90)
    }

    public static func horizontalGradient(_ colors: [NSColor], in rect: NSRect) {
        guard colors.count > 1 else {
            if let c = colors.first { fill(rect, c) }
            return
        }
        NSGradient(colors: colors)?.draw(in: rect, angle: 0)
    }

    public static func etchedLine(from x0: CGFloat, to x1: CGFloat, y: CGFloat, palette p: BevelPalette) {
        let flipped = isFlipped
        fill(NSRect(x: x0, y: y, width: x1 - x0, height: 1), p.shadow)
        fill(NSRect(x: x0, y: flipped ? y + 1 : y - 1, width: x1 - x0, height: 1), p.highlight)
    }

    public static func etchedVerticalLine(x: CGFloat, from y0: CGFloat, to y1: CGFloat, palette p: BevelPalette) {
        fill(NSRect(x: x, y: y0, width: 1, height: y1 - y0), p.shadow)
        fill(NSRect(x: x + 1, y: y0, width: 1, height: y1 - y0), p.highlight)
    }

    public static func triangle(_ direction: ArrowDirection, in rect: NSRect, color: NSColor, filled: Bool = true, size: CGFloat? = nil) {
        let base = size ?? max(3, floor(min(rect.width, rect.height) * 0.5))
        let h = ceil(base / 2)
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let up: CGFloat = isFlipped ? -1 : 1
        let path = NSBezierPath()
        switch direction {
        case .up, .down:
            let dir = direction == .up ? up : -up
            path.move(to: NSPoint(x: c.x - base / 2, y: c.y - dir * h / 2))
            path.line(to: NSPoint(x: c.x + base / 2, y: c.y - dir * h / 2))
            path.line(to: NSPoint(x: c.x, y: c.y + dir * h / 2))
        case .left, .right:
            let dir: CGFloat = direction == .right ? 1 : -1
            path.move(to: NSPoint(x: c.x - dir * h / 2, y: c.y - base / 2))
            path.line(to: NSPoint(x: c.x - dir * h / 2, y: c.y + base / 2))
            path.line(to: NSPoint(x: c.x + dir * h / 2, y: c.y))
        }
        path.close()
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    public static func focusDots(_ rect: NSRect, color: NSColor = .black) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        var pattern: [CGFloat] = [1, 1]
        path.setLineDash(&pattern, count: 2, phase: 0)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    public static func gripLines(in rect: NSRect, vertical: Bool, count: Int = 4, palette p: BevelPalette) {
        let spacing: CGFloat = 2
        let total = CGFloat(count) * spacing
        if vertical {
            let x0 = floor(rect.midX - total / 2)
            for i in 0..<count {
                let x = x0 + CGFloat(i) * spacing
                fill(NSRect(x: x, y: rect.minY, width: 1, height: rect.height), p.highlight)
                fill(NSRect(x: x + 1, y: rect.minY, width: 1, height: rect.height), p.shadow)
            }
        } else {
            let y0 = floor(rect.midY - total / 2)
            for i in 0..<count {
                let y = y0 + CGFloat(i) * spacing
                fill(NSRect(x: rect.minX, y: y, width: rect.width, height: 1), isFlipped ? p.highlight : p.shadow)
                fill(NSRect(x: rect.minX, y: y + 1, width: rect.width, height: 1), isFlipped ? p.shadow : p.highlight)
            }
        }
    }
}
