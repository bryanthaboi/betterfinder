import Foundation

enum OperationAbort: Error {
    case cancelled
    case stopped
}

public struct FileOperationItemError: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let url: URL
    public let message: String
    public let code: Int32

    public init(url: URL, message: String, code: Int32 = 0) {
        self.url = url
        self.message = message
        self.code = code
    }

    static func from(_ error: Error, url: URL) -> FileOperationItemError {
        if let c = error as? ChecksumMismatch {
            return FileOperationItemError(url: url, message: c.localizedDescription, code: 0)
        }
        let ns = error as NSError
        var code: Int32 = 0
        if ns.domain == NSPOSIXErrorDomain { code = Int32(ns.code) }
        else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { code = Int32(underlying.code) }
        return FileOperationItemError(url: url, message: error.localizedDescription, code: code)
    }

    static func posix(_ code: Int32, url: URL) -> FileOperationItemError {
        FileOperationItemError(url: url, message: String(cString: strerror(code)), code: code)
    }
}

public struct ChecksumMismatch: Error, LocalizedError, Sendable {
    public let url: URL
    public var errorDescription: String? { "Checksum verification failed for “\(url.lastPathComponent)”." }
}

final class OperationControl: @unchecked Sendable {
    private let cond = NSCondition()
    private var paused = false
    private var cancelled = false

    var isCancelled: Bool {
        cond.lock(); defer { cond.unlock() }
        return cancelled
    }

    var isPaused: Bool {
        cond.lock(); defer { cond.unlock() }
        return paused
    }

    func pause() {
        cond.lock(); paused = true; cond.unlock()
    }

    func resume() {
        cond.lock(); paused = false; cond.broadcast(); cond.unlock()
    }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    func checkpoint() throws {
        cond.lock(); defer { cond.unlock() }
        while paused && !cancelled { cond.wait() }
        if cancelled { throw OperationAbort.cancelled }
    }
}

final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let startTime = CFAbsoluteTimeGetCurrent()
    private var lastPublish: CFAbsoluteTime = 0
    private var samples: [(time: CFAbsoluteTime, bytes: Int64)] = []
    private var totalBytes: Int64
    private var totalItems: Int
    private var doneItems = 0
    private var settledBytes: Int64 = 0
    private var itemSettled: Int64 = 0
    private var fileInFlight: Int64 = 0
    private var itemLimit: Int64 = 0
    private var currentItem: String?
    private let sink: @Sendable (FileOperationProgress) -> Void
    nonisolated(unsafe) static var minInterval: CFAbsoluteTime = 0.1

    init(totalBytes: Int64, totalItems: Int, sink: @escaping @Sendable (FileOperationProgress) -> Void) {
        self.totalBytes = totalBytes
        self.totalItems = totalItems
        self.sink = sink
    }

    func beginItem(name: String, size: Int64) {
        lock.lock()
        currentItem = name
        itemSettled = 0
        fileInFlight = 0
        itemLimit = size
        publishLocked(force: false)
        lock.unlock()
    }

    func setCurrent(_ name: String) {
        lock.lock()
        currentItem = name
        lock.unlock()
    }

    func setFileBytes(_ copied: Int64) {
        lock.lock()
        fileInFlight = copied
        publishLocked(force: false)
        lock.unlock()
    }

    func settleFile(_ size: Int64) {
        lock.lock()
        itemSettled += size
        fileInFlight = 0
        publishLocked(force: false)
        lock.unlock()
    }

    func markCopied(_ size: Int64) {
        lock.lock()
        itemSettled = size
        fileInFlight = 0
        lock.unlock()
    }

    func addExtra(_ bytes: Int64) {
        lock.lock()
        fileInFlight += bytes
        publishLocked(force: false)
        lock.unlock()
    }

    func completeItem(size: Int64, counted: Bool = true) {
        lock.lock()
        settledBytes += size
        itemSettled = 0
        fileInFlight = 0
        itemLimit = 0
        if counted { doneItems += 1 }
        publishLocked(force: false)
        lock.unlock()
    }

    func completeItemKeepingBytes() {
        lock.lock()
        settledBytes += itemSettled + fileInFlight
        itemSettled = 0
        fileInFlight = 0
        itemLimit = 0
        doneItems += 1
        publishLocked(force: false)
        lock.unlock()
    }

    func addTotal(bytes: Int64) {
        lock.lock()
        totalBytes += bytes
        lock.unlock()
    }

    func finish() {
        lock.lock()
        publishLocked(force: true)
        lock.unlock()
    }

    private func currentBytesLocked() -> Int64 {
        let inItem = min(itemSettled + fileInFlight, itemLimit > 0 ? itemLimit : itemSettled + fileInFlight)
        return min(settledBytes + inItem, totalBytes > 0 ? totalBytes : settledBytes + inItem)
    }

    private func publishLocked(force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastPublish >= Self.minInterval else { return }
        lastPublish = now
        let done = currentBytesLocked()
        samples.append((now, done))
        while let first = samples.first, now - first.time > 4, samples.count > 2 { samples.removeFirst() }
        var throughput = 0.0
        if let first = samples.first, let last = samples.last, last.time - first.time > 0.2 {
            throughput = Double(last.bytes - first.bytes) / (last.time - first.time)
        }
        var eta: TimeInterval?
        if throughput > 1, totalBytes > done { eta = Double(totalBytes - done) / throughput }
        var p = FileOperationProgress(completedUnits: done, totalUnits: totalBytes, currentItem: currentItem)
        p.itemsCompleted = doneItems
        p.itemsTotal = totalItems
        p.bytesPerSecond = throughput
        p.estimatedSecondsRemaining = eta
        sink(p)
    }
}

final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FileOperationItemError] = []

    func add(_ error: FileOperationItemError) {
        lock.lock(); items.append(error); lock.unlock()
    }

    var all: [FileOperationItemError] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func contains(url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items.contains { $0.url == url }
    }
}

enum FS {
    static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard let st = lstatInfo(url.path) else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func device(of url: URL) -> dev_t? {
        var current = url.standardizedFileURL
        while true {
            var st = stat()
            if stat(current.path, &st) == 0 { return st.st_dev }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let x = lstatInfo(a.path), let y = lstatInfo(b.path) else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    static func size(of url: URL, control: OperationControl?) throws -> (bytes: Int64, items: Int) {
        guard let st = lstatInfo(url.path) else { return (0, 0) }
        if (st.st_mode & S_IFMT) != S_IFDIR { return ((st.st_mode & S_IFMT) == S_IFREG ? Int64(st.st_size) : 0, 1) }
        var bytes: Int64 = 0
        var items = 1
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return (0, 1) }
        var n = 0
        for case let child as URL in e {
            n += 1
            if n % 256 == 0 { try control?.checkpoint() }
            items += 1
            if let v = try? child.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let s = v.fileSize { bytes += Int64(s) }
        }
        return (bytes, items)
    }

    static func uniqueSibling(of url: URL) -> URL {
        FileOperationQueue.uniqueDestination(for: url.lastPathComponent, in: url.deletingLastPathComponent())
    }

    static func tempSibling(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".bftmp-" + UUID().uuidString.prefix(8))
    }

    static func remove(_ url: URL) {
        guard exists(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
