import AppKit
import FSCore

enum Treemap {
    static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let areas = weights.map { max(0, $0) * scale }
        var remaining = rect
        var index = 0
        func worst(_ sum: Double, _ smallest: Double, _ largest: Double, _ side: Double) -> Double {
            guard sum > 0, smallest > 0, side > 0 else { return .infinity }
            let square = side * side
            return max(square * largest / (sum * sum), sum * sum / (square * smallest))
        }
        while index < areas.count {
            guard areas[index] > 0 else { index += 1; continue }
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = index + 1
            var sum = areas[index]
            var smallest = areas[index]
            let largest = areas[index]
            while end < areas.count, areas[end] > 0 {
                let next = areas[end]
                guard worst(sum + next, min(smallest, next), largest, side) <= worst(sum, smallest, largest, side) else { break }
                sum += next
                smallest = min(smallest, next)
                end += 1
            }
            let thickness = CGFloat(sum / side)
            var offset: CGFloat = 0
            if remaining.width >= remaining.height {
                for item in index..<end {
                    let length = CGFloat(areas[item] / sum) * remaining.height
                    out[item] = CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    offset += length
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                for item in index..<end {
                    let length = CGFloat(areas[item] / sum) * remaining.width
                    out[item] = CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                    offset += length
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            index = end
        }
        return out
    }
}

final class HogNode: @unchecked Sendable {
    enum Kind: Equatable { case folder(Int64), looseFiles, file, remainder }

    let name: String
    let bytes: Int64
    let kind: Kind
    let url: URL
    var children: [HogNode] = []
    weak var parent: HogNode?
    var branch = -1
    var hue = 0.0
    var depth = 0
    var isCounting = false
    var entries = 0
    var rect: CGRect = .zero

    init(name: String, bytes: Int64, kind: Kind, url: URL) {
        self.name = name
        self.bytes = bytes
        self.kind = kind
        self.url = url
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var isActionable: Bool { isFolder || kind == .file }

    var folderURL: URL { kind == .file ? url.deletingLastPathComponent() : url }

    var leafCount: Int { children.isEmpty ? 1 : children.reduce(0) { $0 + $1.leafCount } }

    func adopt(_ nodes: [HogNode]) {
        children = nodes.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        for (index, child) in children.enumerated() {
            child.parent = self
            child.depth = depth + 1
            child.branch = depth == 0 ? (child.isFolder ? index : -1) : branch
            if depth == 0 {
                child.hue = (0.58 + Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            } else {
                let step = (Double(index) * 0.381_966_011).truncatingRemainder(dividingBy: 1) - 0.5
                child.hue = (hue + step * 0.18 / Double(depth) + 1).truncatingRemainder(dividingBy: 1)
            }
        }
    }

    func node(at point: CGPoint) -> HogNode? {
        guard rect.contains(point) else { return nil }
        for child in children where child.rect.width > 0 && child.rect.height > 0 {
            if let hit = child.node(at: point) { return hit }
        }
        return self
    }

    func ancestor(below root: HogNode) -> HogNode? {
        var current: HogNode? = self
        while let node = current, node.parent !== root { current = node.parent }
        return current
    }
}

enum SpaceHogBuilder {
    static let listableEntries = 5000

    static func build(tree: SizeIndexTree, root url: URL, budget: Int = 3000, looseLimit: Int = 40,
                      listFiles: (URL) -> [IndexedFile] = { SizeIndexTree.files(in: $0, limit: 200) }) -> HogNode? {
        guard let top = tree.folder(at: url) else { return nil }
        let root = HogNode(name: top.name, bytes: top.allocatedBytes, kind: .folder(top.id), url: url)
        root.isCounting = top.isCounting
        root.entries = top.ownItems
        let floor = max(1, top.allocatedBytes / 4000)
        var queue = [root]
        var leaves = 1
        var loose: [HogNode] = []
        while leaves < budget, let node = queue.popLast() {
            guard case .folder(let id) = node.kind, node.bytes >= floor else { continue }
            var children: [HogNode] = []
            var used: Int64 = 0
            for kid in tree.children(of: id) where kid.allocatedBytes > 0 {
                let child = HogNode(name: kid.name, bytes: kid.allocatedBytes, kind: .folder(kid.id), url: node.url.appendingPathComponent(kid.name, isDirectory: true))
                child.isCounting = kid.isCounting
                child.entries = kid.ownItems
                used += kid.allocatedBytes
                children.append(child)
            }
            let rest = node.bytes - used
            if rest > 0 {
                let files = HogNode(name: "Files in \(node.name)", bytes: rest, kind: .looseFiles, url: node.url)
                files.entries = node.entries
                children.append(files)
                loose.append(files)
            }
            guard !children.isEmpty else { continue }
            node.adopt(children)
            leaves += children.count - 1
            for child in children where child.isFolder {
                let at = queue.firstIndex { $0.bytes >= child.bytes } ?? queue.count
                queue.insert(child, at: at)
            }
        }
        let worthListing = max(1, top.allocatedBytes / 300)
        for group in loose.filter({ $0.bytes >= worthListing && $0.entries <= listableEntries }).sorted(by: { $0.bytes > $1.bytes }).prefix(looseLimit) {
            var shown: [HogNode] = []
            var used: Int64 = 0
            for file in listFiles(group.url) where file.allocatedBytes >= floor && used + file.allocatedBytes <= group.bytes {
                shown.append(HogNode(name: file.name, bytes: file.allocatedBytes, kind: .file, url: group.url.appendingPathComponent(file.name)))
                used += file.allocatedBytes
            }
            guard !shown.isEmpty else { continue }
            if group.bytes > used { shown.append(HogNode(name: "Other files", bytes: group.bytes - used, kind: .remainder, url: group.url)) }
            group.adopt(shown)
        }
        return root
    }

    static func layout(_ node: HogNode, in rect: CGRect) {
        node.rect = rect
        guard !node.children.isEmpty else { return }
        let inner = node.depth == 0 ? rect : rect.insetBy(dx: 1, dy: 1)
        guard inner.width >= 3, inner.height >= 3 else {
            for child in node.children { clear(child) }
            return
        }
        for (child, frame) in zip(node.children, Treemap.squarify(node.children.map { Double($0.bytes) }, in: inner)) {
            if frame.width >= 1, frame.height >= 1 { layout(child, in: frame) } else { clear(child) }
        }
    }

    private static func clear(_ node: HogNode) {
        node.rect = .zero
        for child in node.children { clear(child) }
    }

    static func color(for node: HogNode) -> NSColor {
        guard node.branch >= 0 else { return NSColor(calibratedWhite: node.kind == .file ? 0.62 : 0.5, alpha: 1) }
        let saturation: CGFloat
        switch node.kind {
        case .file: saturation = 0.72
        case .folder: saturation = 0.56
        case .looseFiles, .remainder: saturation = 0.3
        }
        return NSColor(calibratedHue: CGFloat(node.hue), saturation: saturation, brightness: 0.9 - 0.04 * CGFloat(node.depth % 4), alpha: 1)
    }
}

struct IndexStatusLine {
    struct Part: Equatable {
        let text: String
        let help: String
        var isAlert = false
    }

    static func compact(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        if magnitude >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if magnitude >= 10_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return value.formatted()
    }

    static func parts(_ stats: IndexStatistics?) -> [Part] {
        guard let stats, !stats.roots.isEmpty else {
            return [Part(text: "no index", help: "The file index isn’t available, so there is nothing to draw yet.", isAlert: true)]
        }
        var parts = [
            Part(text: stats.isComplete ? "up to date" : "indexing", help: stats.isComplete
                ? "Every known folder has been counted. Changes are picked up as they happen."
                : "The indexer is still working. Sizes can keep growing until it catches up."),
            Part(text: "\(compact(stats.folders)) folders", help: "Folders the index knows about: \(stats.folders.formatted())."),
            Part(text: "\(compact(stats.items)) items", help: "Files and folders counted so far: \(stats.items.formatted())."),
            Part(text: SizeFormatter.string(stats.allocatedBytes), help: "Space on disk taken by everything counted so far."),
        ]
        if stats.unscannedFolders > 0 {
            parts.append(Part(text: "\(compact(stats.unscannedFolders)) never scanned", help: "Folders that were found but not counted yet. Anything above them is still missing their size.", isAlert: true))
        }
        if stats.pendingFolders > stats.unscannedFolders {
            parts.append(Part(text: "\(compact(stats.pendingFolders - stats.unscannedFolders)) to re-check", help: "Folders that were already counted and are queued for another look. Their sizes are shown meanwhile."))
        }
        if stats.unreadableFolders > 0 {
            parts.append(Part(text: "\(compact(stats.unreadableFolders)) unreadable", help: "Folders macOS wouldn’t let the indexer open. Their contents aren’t in any total."))
        }
        parts.append(Part(text: "index \(SizeFormatter.string(stats.databaseBytes))", help: "Size of the index file itself."))
        return parts
    }
}
