import AppKit
import FSCore
import ImageIO
import QuickLookThumbnailing
import Theming
import UniformTypeIdentifiers

enum IconRaster {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor static var scale: CGFloat { NSScreen.screens.map(\.backingScaleFactor).max() ?? 2 }

    nonisolated static func render(_ image: NSImage, points: CGFloat, scale: CGFloat) -> NSImage {
        let px = max(1, Int((points * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        ctx.interpolationQuality = .high
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.current = previous
        guard let cg = ctx.makeImage() else { return image }
        return NSImage(cgImage: cg, size: NSSize(width: points, height: points))
    }

    nonisolated static func cost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1024 }
        return max(1024, rep.pixelsWide * rep.pixelsHigh * 4)
    }

    nonisolated static func fileIcon(_ path: String, points: CGFloat, scale: CGFloat) -> NSImage {
        render(NSWorkspace.shared.icon(forFile: path), points: points, scale: scale)
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private var typeIcons: [String: NSImage] = [:]
    private var inflight: [String: [(NSImage) -> Void]] = [:]
    private var started: Set<String> = []
    private let queue = DispatchQueue(label: "betterfinder.icons", qos: .userInitiated, attributes: .concurrent)
    private let gate = DispatchSemaphore(value: 4)

    init() {
        cache.countLimit = 3000
        cache.totalCostLimit = 24 * 1024 * 1024
        NotificationCenter.default.addObserver(forName: .iconSetDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.iconSetChanged() }
        }
    }

    private func iconSetChanged() {
        purge()
        inflight.removeAll()
        started.removeAll()
        NotificationCenter.default.post(name: .browserIconsDidInvalidate, object: nil)
    }

    private static func kind(for item: FileItem) -> IconFileKind {
        if item.isSymlink { return .symlink }
        if item.isPackage { return item.contentType?.conforms(to: .applicationBundle) == true ? .application : .package }
        return item.isDirectory ? .folder : .file
    }

    private func themedTypeIcon(for item: FileItem, size: CGFloat) -> NSImage? {
        let request = IconRequest(contentTypeIdentifier: item.contentTypeIdentifier, kind: Self.kind(for: item))
        return IconResolver.icon(for: request, size: size)
    }

    private func themedIcon(for item: FileItem, size: CGFloat) -> NSImage? {
        let request = IconRequest(url: item.url, isDirectory: item.isDirectory, isPackage: item.isPackage, isSymlink: item.isSymlink, contentTypeIdentifier: item.contentTypeIdentifier)
        return IconResolver.icon(for: request, size: size)
    }

    var typeIconCount: Int { typeIcons.count }

    private var usedBuckets: Set<Int> = []

    static func bucket(_ size: CGFloat) -> CGFloat { size <= 16 ? max(8, size.rounded(.up)) : (size / 8).rounded(.up) * 8 }

    private func key(_ url: URL, _ points: CGFloat) -> String {
        usedBuckets.insert(Int(points))
        return "\(url.pathKey)|\(Int(points))"
    }

    private func needsFileIcon(_ item: FileItem) -> Bool {
        item.isDirectory || item.isPackage || item.isSymlink || item.contentType?.conforms(to: .aliasFile) == true
            || item.contentType?.conforms(to: .applicationBundle) == true
    }

    func typeIcon(for item: FileItem, size: CGFloat = 16) -> NSImage {
        let id = item.isBrowsableFolder ? UTType.folder.identifier : (item.contentTypeIdentifier ?? UTType.data.identifier)
        let points = Self.bucket(size)
        let key = "\(id)|\(Int(points))"
        if let hit = typeIcons[key] { return hit }
        if typeIcons.count > 600 { typeIcons.removeAll(keepingCapacity: true) }
        if let themed = themedTypeIcon(for: item, size: points) {
            typeIcons[key] = themed
            return themed
        }
        let img = IconRaster.render(NSWorkspace.shared.icon(for: UTType(id) ?? .data), points: points, scale: IconRaster.scale)
        typeIcons[key] = img
        return img
    }

    func icon(for item: FileItem, size: CGFloat = 16, completion: ((NSImage) -> Void)? = nil) -> NSImage {
        let points = Self.bucket(size)
        let k = key(item.url, points)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if let themed = themedIcon(for: item, size: points) {
            cache.setObject(themed, forKey: k as NSString, cost: IconRaster.cost(themed))
            return themed
        }
        let placeholder = typeIcon(for: item, size: points)
        guard needsFileIcon(item) else { return placeholder }
        if let completion { inflight[k, default: []].append(completion) }
        guard started.insert(k).inserted else { return placeholder }
        let path = item.url.path
        let scale = IconRaster.scale
        let gate = gate
        queue.async { [weak self] in
            gate.wait()
            let img = IconRaster.fileIcon(path, points: points, scale: scale)
            gate.signal()
            onMain {
                guard let self else { return }
                self.cache.setObject(img, forKey: k as NSString, cost: IconRaster.cost(img))
                self.started.remove(k)
                let waiters = self.inflight.removeValue(forKey: k) ?? []
                for w in waiters { w(img) }
            }
        }
        return placeholder
    }

    func cancelWaiters(for item: FileItem, size: CGFloat = 16) {
        inflight[key(item.url, Self.bucket(size))] = nil
    }

    func fileIcon(_ url: URL, size: CGFloat) -> NSImage {
        let points = Self.bucket(size)
        let k = key(url, points)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if IconSetRegistry.shared.providerCount > 0, let item = DirectoryLister.item(for: url), let themed = themedIcon(for: item, size: points) {
            cache.setObject(themed, forKey: k as NSString, cost: IconRaster.cost(themed))
            return themed
        }
        let img = IconRaster.fileIcon(url.path, points: points, scale: IconRaster.scale)
        cache.setObject(img, forKey: k as NSString, cost: IconRaster.cost(img))
        return img
    }

    func invalidate(_ url: URL) {
        let base = url.pathKey
        for points in usedBuckets { cache.removeObject(forKey: "\(base)|\(points)" as NSString) }
    }

    func purge() {
        cache.removeAllObjects()
        typeIcons.removeAll()
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString { "\(url.pathKey)|\(Int(size))" as NSString }

    func cached(_ url: URL, size: CGFloat) -> NSImage? { cache.object(forKey: key(url, size)) }

    @discardableResult
    func request(_ item: FileItem, size: CGFloat, scale: CGFloat, completion: @escaping (NSImage) -> Void) -> QLThumbnailGenerator.Request? {
        let k = key(item.url, size) as String
        if let hit = cache.object(forKey: k as NSString) { completion(hit); return nil }
        if VolumeInfo.isNetworkVolume(item.url) && !BrowserDefaults.networkThumbnails { return nil }
        if item.isBrowsableFolder { return nil }
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep else { return }
            let cg = rep.cgImage
            let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
            let cost = max(1024, cg.bytesPerRow * cg.height)
            onMain {
                self?.cache.setObject(img, forKey: k as NSString, cost: cost)
                completion(img)
            }
        }
        return req
    }

    func cancel(_ req: QLThumbnailGenerator.Request?) {
        if let req { QLThumbnailGenerator.shared.cancel(req) }
    }

    func purge() { cache.removeAllObjects() }
}

@MainActor
final class DimensionsCache {
    static let shared = DimensionsCache()

    private struct Entry {
        var revision: String
        var size: CGSize
        var stamp: UInt64
    }

    private struct Failure {
        var revision: String
        var expires: Date
    }

    typealias Reader = @Sendable (URL) -> CGSize?

    let limit: Int
    let failureLimit: Int
    let failureTTL: TimeInterval
    private var entries: [String: Entry] = [:]
    private var failures: [String: Failure] = [:]
    private var inFlight: [String: String] = [:]
    private var clock: UInt64 = 0
    private let queue = DispatchQueue(label: "betterfinder.dimensions", qos: .utility)
    private let reader: Reader
    private var pressure: DispatchSourceMemoryPressure?
    var onUpdate: ((String) -> Void)?
    private var listeners: [ObjectIdentifier: (String) -> Void] = [:]

    init(limit: Int = 4000, failureLimit: Int = 1000, failureTTL: TimeInterval = 30, reader: @escaping Reader = { DimensionsCache.readDimensions($0) }) {
        self.limit = max(1, limit)
        self.failureLimit = max(1, failureLimit)
        self.failureTTL = failureTTL
        self.reader = reader
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.purge() } }
        source.resume()
        pressure = source
    }

    func addListener(_ owner: AnyObject, _ f: @escaping (String) -> Void) { listeners[ObjectIdentifier(owner)] = f }
    func removeListener(_ owner: AnyObject) { listeners[ObjectIdentifier(owner)] = nil }

    var values: [String: CGSize] { entries.mapValues(\.size) }
    var pixelCounts: [String: Int] { entries.mapValues { Int($0.size.width * $0.size.height) } }
    var count: Int { entries.count }
    var failureCount: Int { failures.count }
    var inFlightCount: Int { inFlight.count }

    static func isImage(_ item: FileItem) -> Bool {
        guard let t = item.contentType else { return false }
        return t.conforms(to: .image)
    }

    static func revision(_ item: FileItem) -> String {
        "\(item.deviceID ?? 0):\(item.fileID ?? 0):\(item.dateModified?.timeIntervalSinceReferenceDate ?? 0):\(item.logicalSize ?? -1)"
    }

    nonisolated static func readDimensions(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    func isPending(_ item: FileItem) -> Bool {
        let key = item.url.pathKey
        return inFlight[key] == Self.revision(item)
    }

    func dimensions(for item: FileItem) -> CGSize? {
        let key = item.url.pathKey
        let rev = Self.revision(item)
        if var e = entries[key] {
            if e.revision == rev {
                clock += 1
                e.stamp = clock
                entries[key] = e
                return e.size
            }
            entries[key] = nil
        }
        guard Self.isImage(item) else { return nil }
        if let f = failures[key] {
            if f.revision == rev && f.expires > Date() { return nil }
            failures[key] = nil
        }
        guard inFlight[key] != rev else { return nil }
        inFlight[key] = rev
        let url = item.url
        let reader = reader
        queue.async { [weak self] in
            let size = reader(url)
            onMain { self?.complete(key: key, revision: rev, size: size) }
        }
        return nil
    }

    private func complete(key: String, revision: String, size: CGSize?) {
        guard inFlight[key] == revision else { return }
        inFlight[key] = nil
        if let size {
            failures[key] = nil
            clock += 1
            entries[key] = Entry(revision: revision, size: size, stamp: clock)
            trimEntries()
        } else {
            failures[key] = Failure(revision: revision, expires: Date().addingTimeInterval(failureTTL))
            trimFailures()
        }
        onUpdate?(key)
        for l in listeners.values { l(key) }
    }

    func invalidate(_ url: URL) {
        let key = url.pathKey
        entries[key] = nil
        failures[key] = nil
    }

    func purge() {
        entries.removeAll()
        failures.removeAll()
    }

    private func trimEntries() {
        guard entries.count > limit else { return }
        let keep = max(1, limit * 3 / 4)
        let victims = entries.sorted { $0.value.stamp < $1.value.stamp }.prefix(entries.count - keep)
        for (k, _) in victims { entries[k] = nil }
    }

    private func trimFailures() {
        guard failures.count > failureLimit else { return }
        let now = Date()
        failures = failures.filter { $0.value.expires > now }
        guard failures.count > failureLimit else { return }
        let victims = failures.sorted { $0.value.expires < $1.value.expires }.prefix(failures.count - failureLimit * 3 / 4)
        for (k, _) in victims { failures[k] = nil }
    }
}

@MainActor
enum TagColors {
    private static var map: [String: NSColor]?

    static func color(for tag: String) -> NSColor? {
        if map == nil {
            var m: [String: NSColor] = [:]
            let names = NSWorkspace.shared.fileLabels
            let colors = NSWorkspace.shared.fileLabelColors
            for (i, n) in names.enumerated() where i > 0 && i < colors.count { m[n] = colors[i] }
            map = m
        }
        return map?[tag]
    }

    static var systemTags: [String] {
        Array(NSWorkspace.shared.fileLabels.dropFirst())
    }

    static let labelTintAlpha: CGFloat = 0.38

    static func labelColor(for tags: [DirectoryLister.UserTag]) -> NSColor? {
        let colors = NSWorkspace.shared.fileLabelColors
        for tag in tags.reversed() {
            if tag.colorIndex > 0, tag.colorIndex < colors.count { return colors[tag.colorIndex] }
            if tag.colorIndex == 0, let named = color(for: tag.name) { return named }
        }
        return nil
    }

    static func labelColor(for url: URL) -> NSColor? {
        guard BrowserDefaults.coloredLabels else { return nil }
        return labelColor(for: DirectoryLister.userTags(url))
    }

    static func dot(_ color: NSColor?, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            (color ?? .secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            if color == nil {
                NSColor.labelColor.withAlphaComponent(0.4).setStroke()
                NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            }
            return true
        }
    }

    static func attributed(_ tags: [String], font: NSFont, textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, t) in tags.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ")) }
            out.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: color(for: t) ?? NSColor.tertiaryLabelColor, .font: font]))
            out.append(NSAttributedString(string: t, attributes: [.foregroundColor: textColor, .font: font]))
        }
        return out
    }
}
