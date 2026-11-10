import AppKit
import CoreImage
import FSCore

enum HomeLabel {
    static var display: HomeNameDisplay { HomeNameDisplay.current(defaults: BrowserDefaults.store) }

    static func name(_ name: String, for url: URL) -> String {
        display.name(name, forPath: url.path)
    }

    static func name(for url: URL) -> String {
        name(FileManager.default.displayName(atPath: url.path), for: url)
    }

    static func accessibilityName(_ name: String, for url: URL) -> String {
        display.accessibilityName(name, forPath: url.path)
    }

    static func path(_ url: URL) -> String { display.path(url.path) }

    static func isRedacted(_ url: URL) -> Bool {
        let d = display
        return d.isRedacted && d.isHome(url.path)
    }

    static func hidesProxy(for url: URL?) -> Bool {
        guard let url else { return false }
        let d = display
        return d.isActive && d.contains(url.path)
    }

    static func masked(_ items: [FileItem]) -> [FileItem] {
        let d = display
        guard d.isActive, items.contains(where: { d.isHome($0.url.path) }) else { return items }
        return items.map { item in
            guard d.isHome(item.url.path) else { return item }
            var copy = item
            copy.name = d.name(item.name, forPath: item.url.path)
            return copy
        }
    }

    @MainActor
    static func attributed(for url: URL, font: NSFont, color: NSColor) -> NSAttributedString? {
        guard isRedacted(url) else { return nil }
        return RedactedText.attributed(FileManager.default.displayName(atPath: url.path), font: font, color: color)
    }
}

@MainActor
enum RedactedText {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static let pixelScale: CGFloat = 2

    static func blurRadius(for font: NSFont) -> CGFloat { max(3, font.pointSize * 0.3) }

    static func image(_ text: String, font: NSFont, color: NSColor) -> NSImage {
        let appearance = NSApp?.effectiveAppearance.name.rawValue ?? ""
        let key = "\(text)|\(font.fontName)|\(font.pointSize)|\(color)|\(appearance)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: max(1, ceil(measured.width)), height: max(1, ceil(measured.height)))
        let fallback = NSImage(size: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * pixelScale), pixelsHigh: Int(size.height * pixelScale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return fallback }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        (text as NSString).draw(at: .zero, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let source = rep.cgImage else { return fallback }
        let input = CIImage(cgImage: source)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blurRadius(for: font) * pixelScale))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.7)])
            .cropped(to: input.extent)
        guard let output = context.createCGImage(blurred, from: input.extent) else { return fallback }
        let image = NSImage(cgImage: output, size: size)
        cache.setObject(image, forKey: key)
        return image
    }

    static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let img = image(text, font: font, color: color)
        let attachment = NSTextAttachment()
        attachment.image = img
        attachment.bounds = NSRect(x: 0, y: font.descender, width: img.size.width, height: img.size.height)
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttribute(.font, value: font, range: NSRange(location: 0, length: out.length))
        return out
    }
}
