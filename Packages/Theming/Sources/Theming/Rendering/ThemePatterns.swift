import AppKit

@MainActor
public enum ThemePatterns {
    static let countLimit = 48
    static let costLimit = 8 * 1024 * 1024
    private static var cache: [String: (image: NSImage, cost: Int)] = [:]
    private static var order: [String] = []
    private static var cost = 0
    private static var pressureSource: DispatchSourceMemoryPressure?
    private static var themeObserver: NSObjectProtocol?

    static var cachedCount: Int { cache.count }
    static var cachedCost: Int { cost }

    public static func purgeCache() {
        cache.removeAll()
        order.removeAll()
        cost = 0
    }

    private static func lookup(_ key: String) -> NSImage? {
        guard let entry = cache[key] else { return nil }
        if let i = order.lastIndex(of: key), i != order.count - 1 {
            order.remove(at: i)
            order.append(key)
        }
        return entry.image
    }

    private static func store(_ image: NSImage, key: String, pixels: NSSize) {
        startObservingIfNeeded()
        let entryCost = max(1, Int(pixels.width * pixels.height) * 4)
        if let old = cache[key] {
            cost -= old.cost
            order.removeAll { $0 == key }
        }
        cache[key] = (image, entryCost)
        order.append(key)
        cost += entryCost
        while (cache.count > countLimit || cost > costLimit), order.count > 1 {
            let victim = order.removeFirst()
            if let e = cache.removeValue(forKey: victim) { cost -= e.cost }
        }
    }

    private static func startObservingIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { purgeCache() } }
        source.resume()
        pressureSource = source
        themeObserver = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { trimToActiveTheme() }
        }
    }

    private static func trimToActiveTheme() {
        while order.count > countLimit / 2 {
            let victim = order.removeFirst()
            if let e = cache.removeValue(forKey: victim) { cost -= e.cost }
        }
    }

    public static func color(for pattern: Theme.Pattern, themeID: String? = nil, manager: ThemeManager? = nil) -> NSColor {
        let fg = Theme.color(pattern.foreground)
        let bg = Theme.color(pattern.background)
        let s = CGFloat(max(1, pattern.scale))
        switch pattern.kind {
        case .solid: return bg
        case .checkerboard: return checkerboard(fg, bg, cell: 4 * s)
        case .dither50: return checkerboard(fg, bg, cell: s)
        case .dither25: return dither25(fg, bg, scale: s)
        case .pinstripe: return lines(fg, bg, thickness: s, gap: s, horizontal: true)
        case .hlines: return lines(fg, bg, thickness: s, gap: 3 * s, horizontal: true)
        case .vlines: return lines(fg, bg, thickness: s, gap: 3 * s, horizontal: false)
        case .dots: return dots(fg, bg, spacing: 4 * s)
        case .grid: return grid(fg, bg, spacing: 8 * s)
        case .brushedMetal: return brushedMetal(base: bg)
        case .image:
            if let rel = pattern.image, let id = themeID,
               let url = (manager ?? ThemeManager.shared).assetURL(rel, for: id),
               let img = NSImage(contentsOf: url) {
                return NSColor(patternImage: img)
            }
            return bg
        }
    }

    public static func image(for pattern: Theme.Pattern) -> NSImage? {
        color(for: pattern).patternImageIfAny
    }

    private static func cached(_ key: String, size: NSSize, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        if let img = lookup(key) { return img }
        let img = NSImage(size: size, flipped: true) { r in
            draw(r)
            return true
        }
        store(img, key: key, pixels: NSSize(width: size.width * 2, height: size.height * 2))
        return img
    }

    private static func key(_ parts: Any...) -> String {
        parts.map { p in
            if let c = p as? NSColor { return (c.usingColorSpace(.sRGB)?.hexString ?? "\(c)") }
            return "\(p)"
        }.joined(separator: "|")
    }

    public static func checkerboard(_ a: NSColor, _ b: NSColor, cell: CGFloat) -> NSColor {
        let size = NSSize(width: cell * 2, height: cell * 2)
        let img = cached(key("checker", a, b, cell), size: size) { r in
            b.setFill()
            r.fill()
            a.setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
            NSRect(x: cell, y: cell, width: cell, height: cell).fill()
        }
        return NSColor(patternImage: img)
    }

    public static func dither50(_ fg: NSColor, _ bg: NSColor) -> NSColor {
        checkerboard(fg, bg, cell: 1)
    }

    public static func dither25(_ fg: NSColor, _ bg: NSColor, scale: CGFloat = 1) -> NSColor {
        let size = NSSize(width: 4 * scale, height: 4 * scale)
        let img = cached(key("d25", fg, bg, scale), size: size) { r in
            bg.setFill()
            r.fill()
            fg.setFill()
            NSRect(x: 0, y: 0, width: scale, height: scale).fill()
            NSRect(x: 2 * scale, y: 2 * scale, width: scale, height: scale).fill()
        }
        return NSColor(patternImage: img)
    }

    public static func lines(_ fg: NSColor, _ bg: NSColor, thickness: CGFloat, gap: CGFloat, horizontal: Bool) -> NSColor {
        let period = thickness + gap
        let size = horizontal ? NSSize(width: 8, height: period) : NSSize(width: period, height: 8)
        let img = cached(key("lines", fg, bg, thickness, gap, horizontal), size: size) { r in
            bg.setFill()
            r.fill()
            fg.setFill()
            if horizontal {
                NSRect(x: 0, y: 0, width: r.width, height: thickness).fill()
            } else {
                NSRect(x: 0, y: 0, width: thickness, height: r.height).fill()
            }
        }
        return NSColor(patternImage: img)
    }

    public static func pinstripe(light: NSColor, dark: NSColor, period: CGFloat = 2) -> NSColor {
        lines(dark, light, thickness: period / 2, gap: period / 2, horizontal: true)
    }

    public static func dots(_ fg: NSColor, _ bg: NSColor, spacing: CGFloat) -> NSColor {
        let img = cached(key("dots", fg, bg, spacing), size: NSSize(width: spacing, height: spacing)) { r in
            bg.setFill()
            r.fill()
            fg.setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            NSRect(x: spacing / 2, y: spacing / 2, width: 1, height: 1).fill()
        }
        return NSColor(patternImage: img)
    }

    public static func grid(_ fg: NSColor, _ bg: NSColor, spacing: CGFloat) -> NSColor {
        let img = cached(key("grid", fg, bg, spacing), size: NSSize(width: spacing, height: spacing)) { r in
            bg.setFill()
            r.fill()
            fg.setFill()
            NSRect(x: 0, y: 0, width: r.width, height: 1).fill()
            NSRect(x: 0, y: 0, width: 1, height: r.height).fill()
        }
        return NSColor(patternImage: img)
    }

    public static func brushedMetal(base: NSColor) -> NSColor {
        NSColor(patternImage: brushedMetalImage(base: base))
    }

    public static func brushedMetalImage(base: NSColor) -> NSImage {
        let k = key("metal", base)
        if let img = lookup(k) { return img }
        let w = 512, h = 128
        let b = base.usingColorSpace(.sRGB) ?? NSColor(white: 0.75, alpha: 1)
        let gray = (b.redComponent + b.greenComponent + b.blueComponent) / 3
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        ctx.setFillColor(b.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var rng = SplitMix(seed: 0xB1F1_D3A5)
        for _ in 0..<3200 {
            let y = CGFloat(rng.next() % UInt64(h))
            let x = CGFloat(rng.next() % UInt64(w))
            let len = CGFloat(30 + rng.next() % 260)
            let lighter = rng.next() % 2 == 0
            let delta = CGFloat(rng.next() % 100) / 100 * 0.12
            let v = max(0, min(1, gray + (lighter ? delta : -delta)))
            let tint = NSColor(srgbRed: v * (b.redComponent / max(gray, 0.01)), green: v * (b.greenComponent / max(gray, 0.01)), blue: v * (b.blueComponent / max(gray, 0.01)), alpha: 0.35)
            ctx.setFillColor(tint.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: len, height: 1))
            if x + len > CGFloat(w) { ctx.fill(CGRect(x: x - CGFloat(w), y: y, width: len, height: 1)) }
        }
        guard let cg = ctx.makeImage() else { return NSImage(size: NSSize(width: 1, height: 1)) }
        let img = NSImage(cgImage: cg, size: NSSize(width: w / 2, height: h / 2))
        store(img, key: k, pixels: NSSize(width: w, height: h))
        return img
    }

    public static func fill(_ rect: NSRect, with color: NSColor, in view: NSView? = nil) {
        NSGraphicsContext.saveGraphicsState()
        if let view, let ctx = NSGraphicsContext.current {
            let origin = view.convert(NSPoint.zero, to: nil)
            ctx.patternPhase = NSPoint(x: origin.x, y: origin.y)
        }
        color.setFill()
        rect.fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension NSColor {
    var patternImageIfAny: NSImage? {
        type == .pattern ? patternImage : nil
    }
}

public extension Theme {
    @MainActor
    var windowBackgroundColor: NSColor {
        if window.brushedMetal { return ThemePatterns.brushedMetal(base: Theme.color(window.colors.first ?? "#BEBEBE")) }
        if let p = window.backgroundPattern { return ThemePatterns.color(for: p, themeID: id) }
        return Theme.color(colors.windowBg)
    }

    @MainActor
    var emptyListBackgroundColor: NSColor {
        if let p = desktopPattern { return ThemePatterns.color(for: p, themeID: id) }
        return Theme.color(colors.listBg)
    }
}
