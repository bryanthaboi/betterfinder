import Foundation
import FSCore

func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
}

enum MemoryRelief {
    private static let queue = DispatchQueue(label: "betterfinder.memory-relief", qos: .utility)
    nonisolated(unsafe) private static var scheduled = false
    private static let lock = NSLock()

    static func schedule(after delay: TimeInterval = 1.5) {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) {
            lock.lock()
            scheduled = false
            lock.unlock()
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

struct ListingResult: Sendable {
    var visible: [FileItem]
    var hiddenCount: Int
}

enum DirectoryStream {
    static let queue = DispatchQueue(label: "betterfinder.listing", qos: .userInitiated, attributes: .concurrent)

    static func enumerate(
        _ directory: URL,
        showHidden: Bool,
        token: CancelToken,
        batchInterval: TimeInterval = 0.35,
        firstBatch: Int = 500,
        onBatch: ([FileItem], Int) -> Void
    ) async throws -> ListingResult {
        var out: [FileItem] = []
        out.reserveCapacity(1024)
        var hidden = 0
        var sentFirst = false
        var lastFlush = Date()
        let stream = DirectoryLister.stream(directory, batchSize: 256, options: ListingOptions(showHidden: true, fetchTags: true))
        for try await batch in stream {
            if token.isCancelled { break }
            for item in batch {
                if item.isHidden {
                    hidden += 1
                    if !showHidden { continue }
                }
                out.append(item)
            }
            if !sentFirst && out.count >= firstBatch {
                sentFirst = true
                lastFlush = Date()
                onBatch(out, hidden)
            } else if sentFirst && Date().timeIntervalSince(lastFlush) > batchInterval {
                lastFlush = Date()
                onBatch(out, hidden)
            }
        }
        return ListingResult(visible: out, hiddenCount: hidden)
    }

    static func list(_ directory: URL, showHidden: Bool) throws -> ListingResult {
        let all = try DirectoryLister.list(directory, options: ListingOptions(showHidden: true, fetchTags: true))
        var out: [FileItem] = []
        out.reserveCapacity(all.count)
        var hidden = 0
        for item in all {
            if item.isHidden {
                hidden += 1
                if !showHidden { continue }
            }
            out.append(item)
        }
        return ListingResult(visible: out, hiddenCount: hidden)
    }

    static func listVolumes() -> [FileItem] {
        let vols = DemoEnvironment.volumes
        return vols.compactMap { url in
            guard var item = DirectoryLister.item(for: url) else { return nil }
            if let name = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName { item.name = name }
            return item
        }
    }

    static func harvestTags(_ items: [FileItem], limit: Int = 5000) -> Set<String> {
        var out = Set<String>()
        for item in items.prefix(limit) { out.formUnion(item.tagNames) }
        return out
    }
}

struct NaturalKey: Comparable, Sendable {
    let bytes: [UInt8]
    let prefix: UInt64

    init(_ name: String) {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [UInt8] = []
        out.reserveCapacity(folded.utf8.count + 4)
        var digits: [UInt8] = []
        func flush() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1 && digits[start] == 0x30 { start += 1 }
            let trimmed = digits[start...]
            out.append(0x30)
            out.append(UInt8(min(trimmed.count, 200)) &+ 0x30)
            out.append(contentsOf: trimmed)
            digits.removeAll(keepingCapacity: true)
        }
        for b in folded.utf8 {
            if b >= 0x30 && b <= 0x39 { digits.append(b) } else { flush(); out.append(b) }
        }
        flush()
        bytes = out
        var p: UInt64 = 0
        for i in 0..<8 { p = (p << 8) | UInt64(i < out.count ? out[i] : 0) }
        prefix = p
    }

    static func compare(_ a: NaturalKey, _ b: NaturalKey) -> Int32 {
        if a.prefix != b.prefix { return a.prefix < b.prefix ? -1 : 1 }
        return a.bytes.withUnsafeBufferPointer { pa in
            b.bytes.withUnsafeBufferPointer { pb in
                let n = min(pa.count, pb.count)
                let r = n == 0 ? 0 : memcmp(pa.baseAddress!, pb.baseAddress!, n)
                if r != 0 { return r }
                return pa.count == pb.count ? 0 : (pa.count < pb.count ? -1 : 1)
            }
        }
    }

    static func < (a: NaturalKey, b: NaturalKey) -> Bool { compare(a, b) < 0 }
    static func == (a: NaturalKey, b: NaturalKey) -> Bool { compare(a, b) == 0 }
}

struct ItemSorter: Sendable {
    var spec: SortSpec
    var sizes: [String: Int64] = [:]
    var dimensions: [String: Int] = [:]
    var customValues: [String: ColumnValue] = [:]

    private enum Value: Comparable {
        case none
        case key(NaturalKey)
        case date(Date)
        case int(Int64)
        case double(Double)

        static func < (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case (.none, .none): return false
            case (.none, _): return true
            case (_, .none): return false
            case let (.key(x), .key(y)): return x < y
            case let (.date(x), .date(y)): return x < y
            case let (.int(x), .int(y)): return x < y
            case let (.double(x), .double(y)): return x < y
            default: return false
            }
        }
    }

    private func value(_ item: FileItem, kinds: inout [String: NaturalKey]) -> Value {
        switch spec.key {
        case .name: return .none
        case .modified: return item.dateModified.map(Value.date) ?? .none
        case .created: return item.dateCreated.map(Value.date) ?? .none
        case .added: return item.dateAdded.map(Value.date) ?? .none
        case .kind:
            let id = item.isBrowsableFolder ? "public.folder" : (item.contentTypeIdentifier ?? "")
            if let k = kinds[id] { return .key(k) }
            let k = NaturalKey(item.kindDescription)
            kinds[id] = k
            return .key(k)
        case .tags:
            let t = item.tagNames
            return t.isEmpty ? .none : .key(NaturalKey(t.joined(separator: ",")))
        case .location: return .key(NaturalKey(item.url.deletingLastPathComponent().path))
        case .dimensions: return dimensions[item.url.pathKey].map { .int(Int64($0)) } ?? .none
        case .custom:
            switch customValues[item.url.pathKey] {
            case .string(let s)?: return .key(NaturalKey(s))
            case .number(let n)?: return .double(n)
            case .bytes(let b)?: return .int(b)
            case .date(let d)?: return .date(d)
            default: return .none
            }
        case .size:
            if item.isBrowsableFolder { return sizes[item.url.pathKey].map(Value.int) ?? .none }
            return item.logicalSize.map(Value.int) ?? .none
        }
    }

    func sorted(_ items: [FileItem]) -> [FileItem] {
        var kinds: [String: NaturalKey] = [:]
        let names = items.map { NaturalKey($0.name) }
        let byName = spec.key == .name
        let values = byName ? [] : items.map { value($0, kinds: &kinds) }
        let folders = items.map { $0.isBrowsableFolder }
        let asc = spec.ascending
        let foldersFirst = spec.foldersFirst
        var order = Array(items.indices)
        names.withUnsafeBufferPointer { nb in
            folders.withUnsafeBufferPointer { fb in
                order.sort { i, j in
                    if foldersFirst, fb[i] != fb[j] { return fb[i] }
                    if !byName {
                        let va = values[i], vb = values[j]
                        if va != vb { return asc ? va < vb : vb < va }
                    }
                    let a = nb[i], b = nb[j]
                    if a.prefix != b.prefix { return (byName && !asc) ? a.prefix > b.prefix : a.prefix < b.prefix }
                    let c = NaturalKey.compare(a, b)
                    if c != 0 { return (byName && !asc) ? c > 0 : c < 0 }
                    let ni = items[i].name, nj = items[j].name
                    if ni != nj { return (byName && !asc) ? ni > nj : ni < nj }
                    return i < j
                }
            }
        }
        return order.map { items[$0] }
    }
}

struct ListDiff: Equatable, Sendable {
    var removed: IndexSet
    var inserted: IndexSet
    var updated: IndexSet

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }
    var size: Int { removed.count + inserted.count + updated.count }

    static func compute(old: [FileItem], new: [FileItem]) -> ListDiff? {
        let oldKeys = old.map { $0.url.pathKey }
        let newKeys = new.map { $0.url.pathKey }
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(oldKeys.count)
        for (i, k) in oldKeys.enumerated() { oldIndex[k] = i }
        let newSet = Set(newKeys)
        guard oldIndex.count == oldKeys.count, newSet.count == newKeys.count else { return nil }
        var removed = IndexSet()
        var commonOld: [String] = []
        for (i, k) in oldKeys.enumerated() {
            if newSet.contains(k) { commonOld.append(k) } else { removed.insert(i) }
        }
        var inserted = IndexSet()
        var updated = IndexSet()
        var commonNew: [String] = []
        for (i, k) in newKeys.enumerated() {
            if let oi = oldIndex[k] {
                commonNew.append(k)
                if old[oi] != new[i] { updated.insert(i) }
            } else {
                inserted.insert(i)
            }
        }
        guard commonOld == commonNew else { return nil }
        return ListDiff(removed: removed, inserted: inserted, updated: updated)
    }
}
