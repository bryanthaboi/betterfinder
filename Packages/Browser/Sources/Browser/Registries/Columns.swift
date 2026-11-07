import AppKit
import FSCore
import Foundation

public enum ColumnValue: Hashable, Sendable {
    case none
    case string(String)
    case number(Double)
    case bytes(Int64)
    case date(Date)
    indirect case described(ColumnValue, accessibility: String)

    public var displayText: String {
        switch self {
        case .none: return "--"
        case .string(let s): return s
        case .number(let n): return Self.numberText(n)
        case .bytes(let b): return SizeFormatter.string(b)
        case .date(let d): return d.timeIntervalSinceReferenceDate.isFinite ? ColumnValue.dateFormatter.string(from: d) : "--"
        case .described(let v, _): return v.displayText
        }
    }

    public var accessibilityDescription: String? {
        if case .described(_, let a) = self { return a }
        return nil
    }

    public var underlyingValue: ColumnValue {
        if case .described(let v, _) = self { return v.underlyingValue }
        return self
    }

    public static func numberText(_ n: Double) -> String {
        guard n.isFinite else { return "--" }
        if n.rounded(.towardZero) == n, let i = Int64(exactly: n) { return i.formatted() }
        if n.rounded(.towardZero) == n { return n.formatted(.number.precision(.fractionLength(0))) }
        return n.formatted(.number.precision(.fractionLength(0...3)))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

public struct ColumnContext: Sendable {
    public var columnID: String
    public var location: BrowserLocation
    public var generation: Int
    public var batchIndex: Int
}

public protocol ColumnProvider: Sendable {
    func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue]
}

public struct ColumnSpec: BrowserContribution {
    public enum Alignment: Sendable { case leading, trailing }

    public var id: String
    public var title: String
    public var width: Double
    public var minWidth: Double
    public var alignment: Alignment
    public var isSortable: Bool
    public var defaultVisible: Bool
    public var revision: String
    public var timeout: TimeInterval
    public var provider: ColumnProvider
    public var defaultOrder: Int

    public var isVisibleByDefault: Bool { defaultVisible }

    public init(id: String, title: String, width: Double = 120, minWidth: Double = 50, alignment: Alignment = .leading, isSortable: Bool = true, defaultVisible: Bool = true,
                revision: String = "1", timeout: TimeInterval = 10, provider: ColumnProvider, defaultOrder: Int = 0) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.alignment = alignment
        self.isSortable = isSortable
        self.defaultVisible = defaultVisible
        self.revision = revision
        self.timeout = timeout
        self.provider = provider
        self.defaultOrder = defaultOrder
    }
}

@MainActor
public final class ColumnRegistry: BrowserRegistry<ColumnSpec> {
    public static let shared = ColumnRegistry()

    public init() { super.init(kind: .column) }

    override public func validate(_ item: ColumnSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A column needs a title." }
        return nil
    }

    public static func tableIdentifier(for qualifiedID: String) -> String { "x:" + qualifiedID }

    public static func qualifiedID(fromTableIdentifier id: String) -> String? {
        id.hasPrefix("x:") ? String(id.dropFirst(2)) : nil
    }
}

@MainActor
public final class ColumnValueStore {
    public static let batchLimit = 128

    struct Request {
        var qualifiedID: String
        var provider: ColumnProvider
        var specRevision: String
        var timeout: TimeInterval
    }

    private struct Chunk {
        let id: Int
        let request: Request
        let items: [FileItem]
        var task: Task<Void, Never>?
        var started: Bool
    }

    private var cache: [String: [String: (rev: String, value: ColumnValue)]] = [:]
    private var specRevisions: [String: String] = [:]
    private var chunks: [Int: Chunk] = [:]
    private var queue: [Int] = []
    private var nextChunkID = 0
    public private(set) var generation = 0
    public var maxConcurrent = 3
    public private(set) var providerCallCount = 0
    public private(set) var largestBatch = 0
    public private(set) var cancelledChunks = 0
    public private(set) var lastError: String?
    public var onUpdate: (@MainActor (_ qualifiedID: String, _ pathKeys: [String]) -> Void)?
    public var location: BrowserLocation = .computer

    public init() {}

    static func itemRevision(_ item: FileItem) -> String {
        "\(item.dateModified?.timeIntervalSince1970 ?? 0)|\(item.logicalSize ?? -1)"
    }

    public func cachedValue(column: String, for item: FileItem) -> ColumnValue? {
        guard let hit = cache[column]?[item.url.pathKey], hit.rev == Self.itemRevision(item) + "|" + (specRevisions[column] ?? "") else { return nil }
        return hit.value
    }

    public func isPending(column: String, for item: FileItem) -> Bool {
        let key = item.url.pathKey
        return chunks.values.contains { $0.request.qualifiedID == column && $0.items.contains { $0.url.pathKey == key } }
    }

    public var inflightChunkCount: Int { chunks.count }

    public func snapshot(column: String) -> [String: ColumnValue] {
        (cache[column] ?? [:]).mapValues(\.value.underlyingValue)
    }

    func request(_ request: Request, items: [FileItem]) {
        let column = request.qualifiedID
        if specRevisions[column] != request.specRevision {
            specRevisions[column] = request.specRevision
            cache[column] = nil
            cancel(column: column, keeping: [])
        }
        let visibleKeys = Set(items.map { $0.url.pathKey })
        cancel(column: column, keeping: visibleKeys)
        var pendingKeys = Set<String>()
        for c in chunks.values where c.request.qualifiedID == column { for i in c.items { pendingKeys.insert(i.url.pathKey) } }
        let needed = items.filter { item in
            let key = item.url.pathKey
            return !pendingKeys.contains(key) && cachedValue(column: column, for: item) == nil
        }
        guard !needed.isEmpty else { pump(); return }
        var start = 0
        while start < needed.count {
            let end = min(start + Self.batchLimit, needed.count)
            nextChunkID += 1
            chunks[nextChunkID] = Chunk(id: nextChunkID, request: request, items: Array(needed[start..<end]), task: nil, started: false)
            queue.append(nextChunkID)
            start = end
        }
        pump()
    }

    public func cancel(column: String, keeping visible: Set<String>) {
        for (id, chunk) in chunks where chunk.request.qualifiedID == column {
            if chunk.items.contains(where: { visible.contains($0.url.pathKey) }) { continue }
            chunk.task?.cancel()
            if chunk.started { cancelledChunks += 1 }
            chunks[id] = nil
            queue.removeAll { $0 == id }
        }
        pump()
    }

    public func cancelAll() {
        for chunk in chunks.values {
            chunk.task?.cancel()
            if chunk.started { cancelledChunks += 1 }
        }
        chunks.removeAll()
        queue.removeAll()
    }

    public func reset() {
        cancelAll()
        cache.removeAll()
        generation += 1
    }

    public func invalidate(pathKeys: [String]) {
        for column in cache.keys { for k in pathKeys { cache[column]?[k] = nil } }
    }

    public func forget(column: String) {
        cache[column] = nil
        specRevisions[column] = nil
        cancel(column: column, keeping: [])
    }

    private var running: Int { chunks.values.filter { $0.started }.count }

    private func pump() {
        while running < maxConcurrent, let id = queue.first {
            queue.removeFirst()
            guard var chunk = chunks[id] else { continue }
            chunk.started = true
            providerCallCount += 1
            largestBatch = max(largestBatch, chunk.items.count)
            let provider = chunk.request.provider
            let items = chunk.items
            let context = ColumnContext(columnID: chunk.request.qualifiedID, location: location, generation: generation, batchIndex: providerCallCount)
            let timeout = chunk.request.timeout
            let work = Task.detached(priority: .utility) { () -> Result<[URL: ColumnValue], Error> in
                do {
                    let values = try await withThrowingTaskGroup(of: [URL: ColumnValue].self) { group in
                        group.addTask { try await provider.values(for: items, context: context) }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(min(max(0.05, timeout), 3600) * 1_000_000_000))
                            throw ColumnProviderTimeout()
                        }
                        let first = try await group.next() ?? [:]
                        group.cancelAll()
                        return first
                    }
                    return .success(values)
                } catch {
                    return .failure(error)
                }
            }
            chunk.task = Task { [weak self] in
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                self?.finish(chunkID: id, result: result)
            }
            chunks[id] = chunk
        }
    }

    private func finish(chunkID: Int, result: Result<[URL: ColumnValue], Error>) {
        guard let chunk = chunks.removeValue(forKey: chunkID) else { pump(); return }
        let column = chunk.request.qualifiedID
        var updated: [String] = []
        switch result {
        case .success(let values):
            var byKey: [String: ColumnValue] = [:]
            for (url, v) in values { byKey[url.pathKey] = v }
            let specRev = specRevisions[column] ?? ""
            for item in chunk.items {
                let key = item.url.pathKey
                cache[column, default: [:]][key] = (Self.itemRevision(item) + "|" + specRev, byKey[key] ?? .none)
                updated.append(key)
            }
            lastError = nil
        case .failure(let error):
            if error is CancellationError { break }
            lastError = error.localizedDescription
            let specRev = specRevisions[column] ?? ""
            for item in chunk.items {
                let key = item.url.pathKey
                cache[column, default: [:]][key] = (Self.itemRevision(item) + "|" + specRev, .none)
                updated.append(key)
            }
        }
        pump()
        if !updated.isEmpty { onUpdate?(column, updated) }
    }
}

struct ColumnProviderTimeout: Error, LocalizedError {
    var errorDescription: String? { "The column provider took too long." }
}
