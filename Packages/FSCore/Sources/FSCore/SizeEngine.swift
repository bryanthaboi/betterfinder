import Foundation

public struct SizeResult: Sendable, Hashable {
    public var allocatedBytes: Int64
    public var logicalBytes: Int64
    public var itemCount: Int
    public var isComplete: Bool

    public var isPartial: Bool = false
    public var isStale: Bool = false

    public init(allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0, itemCount: Int = 0, isComplete: Bool = false) {
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.itemCount = itemCount
        self.isComplete = isComplete
    }
}

public actor SizeEngine {
    public static let shared = SizeEngine()

    private let client = SizeIndexClient()
    public init() {}

    public func cachedSize(of url: URL) -> SizeResult? {
        guard let indexed = SharedIndexReader.size(for: url) else { return nil }
        return Self.result(indexed)
    }

    public func invalidate(path: String) {
        var st = stat()
        let directory = lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        let target = directory ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
        Task { _ = await client.prioritize(path: target) }
    }

    fileprivate static func result(_ size: IndexedSize) -> SizeResult {
        var result = SizeResult(allocatedBytes: size.allocatedBytes, logicalBytes: size.logicalBytes, itemCount: size.items, isComplete: size.state == .complete)
        result.isPartial = size.state == .partial
        result.isStale = size.state == .stale || Date().timeIntervalSince(size.scannedAt) >= 60
        if result.isStale { result.isComplete = false }
        return result
    }

    public func size(of url: URL) -> AsyncStream<SizeResult> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .background) {
                let client = SizeIndexClient()
                if let hit = SharedIndexReader.size(for: url) {
                    continuation.yield(Self.result(hit))
                    if hit.state == .complete && Date().timeIntervalSince(hit.scannedAt) < 60 { continuation.finish(); return }
                }
                if await client.prioritize(path: url.path) {
                    var last: IndexedSize?
                    var failures = 0
                    while !Task.isCancelled {
                        if let hit = SharedIndexReader.size(for: url), hit != last {
                            last = hit
                            continuation.yield(Self.result(hit))
                            if hit.state == .complete || hit.state == .partial { break }
                        }
                        try? await Task.sleep(for: .seconds(1))
                        failures += 1
                        if last == nil && failures >= 30 { break }
                        if failures % 10 == 0 {
                            if await client.status() == "unavailable" { break }
                        }
                    }
                    if last != nil || Task.isCancelled { continuation.finish(); return }
                }
                await FallbackSizeScanner.gate.acquire()
                if !Task.isCancelled { FallbackSizeScanner.scan(url, continuation: continuation) }
                await FallbackSizeScanner.gate.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum SharedIndexReader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reader: SizeIndexReader?
    nonisolated(unsafe) private static var lastAttempt = Date.distantPast

    static func size(for url: URL) -> IndexedSize? {
        lock.lock()
        if reader == nil, Date().timeIntervalSince(lastAttempt) > 5 {
            lastAttempt = Date()
            if FileManager.default.fileExists(atPath: SizeIndexLocation.database.path) { reader = try? SizeIndexReader() }
        }
        let current = reader
        lock.unlock()
        return current?.size(for: url)
    }
}

private actor ScanGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ permits: Int) { available = permits }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

private enum FallbackSizeScanner {
    static let gate = ScanGate(2)
    static func scan(_ url: URL, continuation: AsyncStream<SizeResult>.Continuation) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("betterfinder-size-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let database = temporary.appendingPathComponent("index.sqlite")
            let writer = try SizeIndexWriter(databaseURL: database)
            let reader = try SizeIndexReader(databaseURL: database)
            try writer.addRoot(url, allowNetwork: true)
            var lastYield = Date.distantPast
            while try writer.processBatch(limit: 512, budget: 0.1) > 0 {
                try Task.checkCancellation()
                if Date().timeIntervalSince(lastYield) > 0.5, let hit = reader.size(for: url) {
                    continuation.yield(SizeEngine.result(hit)); lastYield = Date()
                }
            }
            if let hit = reader.size(for: url) { continuation.yield(SizeEngine.result(hit)) }
        } catch is CancellationError { } catch {
            var result = SizeResult()
            result.isPartial = true
            continuation.yield(result)
        }
    }
}
