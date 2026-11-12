import Foundation

public struct SizeResult: Sendable, Hashable {
    public var allocatedBytes: Int64
    public var logicalBytes: Int64
    public var itemCount: Int
    public var isComplete: Bool

    public var isPartial: Bool = false
    public var isStale: Bool = false
    public var isCounting: Bool = false

    public init(allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0, itemCount: Int = 0, isComplete: Bool = false) {
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.itemCount = itemCount
        self.isComplete = isComplete
    }

    public var isSettled: Bool { isComplete || (!isCounting && (isPartial || isStale)) }
    public var isUnreadable: Bool { isPartial && !isCounting }
}

final class IndexLink: @unchecked Sendable {
    private let lock = NSLock()
    private var database: URL?
    private var control: any SizeIndexControl
    private var reader: SizeIndexReader?
    private var lastCheck: UInt64 = 0

    init(database: URL?, control: any SizeIndexControl) {
        self.database = database
        self.control = control
    }

    func attach(database: URL, control: any SizeIndexControl) {
        lock.lock()
        self.database = database
        self.control = control
        reader = nil
        lastCheck = 0
        lock.unlock()
    }

    var currentControl: any SizeIndexControl {
        lock.lock(); defer { lock.unlock() }
        return control
    }

    var location: URL {
        lock.lock(); defer { lock.unlock() }
        return database ?? SizeIndexLocation.database
    }

    func current() -> SizeIndexReader? {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastCheck == 0 || now &- lastCheck > 2_000_000_000 {
            lastCheck = now
            let url = database ?? SizeIndexLocation.database
            var st = stat()
            let exists = stat(url.path, &st) == 0
            if let open = reader, !exists || open.fileIdentity.dev != st.st_dev || open.fileIdentity.ino != UInt64(st.st_ino) { reader = nil }
            if reader == nil, exists, let opened = try? SizeIndexReader(databaseURL: url), opened.isUsable { reader = opened }
        }
        return reader
    }
}

public actor SizeEngine {
    public static let shared = SizeEngine()

    private nonisolated let link: IndexLink

    public init() {
        link = IndexLink(database: nil, control: SizeIndexClient())
    }

    public init(databaseURL: URL, control: any SizeIndexControl) {
        link = IndexLink(database: databaseURL, control: control)
    }

    public nonisolated func attach(databaseURL: URL, control: any SizeIndexControl) {
        link.attach(database: databaseURL, control: control)
    }

    public func cachedSize(of url: URL) -> SizeResult? {
        snapshot(of: [url])[0]
    }

    public nonisolated func snapshot(of urls: [URL]) -> [SizeResult?] {
        guard !urls.isEmpty else { return [] }
        guard let reader = link.current() else { return urls.map { _ in nil } }
        return reader.sizes(for: urls).map { $0.map(Self.result) }
    }

    public nonisolated func focus(on urls: [URL]) {
        guard !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        let control = link.currentControl
        Task.detached(priority: .utility) { _ = await control.focus(paths: paths) }
    }

    public nonisolated func refresh(paths: [String]) {
        guard !paths.isEmpty else { return }
        var folders = Set<String>()
        for path in paths {
            var st = stat()
            let directory = lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
            folders.insert(directory ? path : (path as NSString).deletingLastPathComponent)
        }
        let list = Array(folders.prefix(SizeIndexWriter.focusLimit))
        let control = link.currentControl
        Task.detached(priority: .utility) { _ = await control.refresh(paths: list) }
    }

    public func invalidate(path: String) async {
        var st = stat()
        let directory = lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        _ = await link.currentControl.refresh(paths: [directory ? path : (path as NSString).deletingLastPathComponent])
    }

    static func computerRoots() -> [String] {
        var roots = ["/Applications", "/Library", "/Users"]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" && (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
            roots.append(volume.path)
        }
        return roots
    }

    static func result(_ size: IndexedSize) -> SizeResult {
        var result = SizeResult(allocatedBytes: size.allocatedBytes, logicalBytes: size.logicalBytes, itemCount: size.items, isComplete: size.state == .complete)
        result.isPartial = size.state == .partial || size.unreadableFolders > 0
        result.isStale = size.state == .stale
        result.isCounting = size.isCounting
        return result
    }

    public func size(of url: URL) -> AsyncStream<SizeResult> {
        let link = link
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                var last = link.current()?.size(for: url)
                if let last {
                    continuation.yield(Self.result(last))
                    if last.state != .stale { continuation.finish(); return }
                }
                _ = await link.currentControl.focus(paths: [url.path])
                var waited = 0.0
                var interval = 0.1
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    waited += interval
                    interval = min(1, interval * 1.5)
                    if let hit = link.current()?.size(for: url) {
                        if hit != last {
                            last = hit
                            continuation.yield(Self.result(hit))
                        }
                        if hit.state != .stale { break }
                        if !hit.isCounting && waited > 6 { break }
                    } else if waited > 10 { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func search(_ query: String, under scope: URL, includeHidden: Bool, limit: Int) -> AsyncStream<IndexSearchEvent> {
        let link = link
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let flag = ScanCancellation()
            let task = Task.detached(priority: .userInitiated) {
                guard !NameMatcher(query).isEmpty else {
                    continuation.yield(.finished(IndexSearchSummary()))
                    continuation.finish()
                    return
                }
                let control = link.currentControl
                let wanted = scope.path == "/" ? Self.computerRoots() : [scope.path]
                Task.detached(priority: .userInitiated) { _ = await control.focus(paths: wanted) }
                let searcher = SizeIndexSearcher(databaseURL: link.location)
                var delivered = Set<String>()
                var waited = 0.0
                var summary = IndexSearchSummary(hitLimit: false, indexed: false)
                while !flag.isCancelled {
                    let pass = searcher.pass(query: query, under: scope, includeHidden: includeHidden, limit: limit, skipping: delivered, isCancelled: { flag.isCancelled }) {
                        continuation.yield(.paths($0))
                    }
                    delivered = pass.delivered
                    summary = IndexSearchSummary(hitLimit: pass.hitLimit, indexed: pass.found)
                    if pass.hitLimit || (pass.found && !pass.counting) { break }
                    if !pass.found && waited > 12 { break }
                    try? await Task.sleep(for: .seconds(pass.found ? 1.5 : 0.3))
                    waited += pass.found ? 1.5 : 0.3
                }
                if !flag.isCancelled { continuation.yield(.finished(summary)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                flag.cancel()
                task.cancel()
            }
        }
    }
}

final class ScanCancellation: @unchecked Sendable {
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
