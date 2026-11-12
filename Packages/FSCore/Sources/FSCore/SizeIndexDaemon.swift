import CoreGraphics
import Foundation

public protocol SizeIndexControl: AnyObject, Sendable {
    func focus(paths: [String]) async -> Bool
    func refresh(paths: [String]) async -> Bool
    func pause() async -> Bool
    func resume() async -> Bool
    func rebuild() async -> Bool
    func status() async -> String
}

public struct SizeIndexStatus: Equatable, Sendable {
    public var isPaused: Bool
    public var pendingFolders: Int
    public var folders: Int

    public init(isPaused: Bool, pendingFolders: Int, folders: Int) {
        self.isPaused = isPaused
        self.pendingFolders = pendingFolders
        self.folders = folders
    }

    public init?(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == " " })
        guard parts.count == 5, parts[2] == "pending", parts[4] == "folders", let pending = Int(parts[1]), let folders = Int(parts[3]) else { return nil }
        guard parts[0] == "running" || parts[0] == "paused" else { return nil }
        self.init(isPaused: parts[0] == "paused", pendingFolders: pending, folders: folders)
    }

    public var text: String { "\(isPaused ? "paused" : "running"): \(pendingFolders) pending, \(folders) folders" }
}

public final class SizeIndexDaemon: @unchecked Sendable, SizeIndexControl {
    public let databaseURL: URL
    private let queue = DispatchQueue(label: "betterfinder.indexer", qos: .utility)
    private let writer: SizeIndexWriter
    private var events: SizeIndexEvents!
    private var paused = false
    private var tick: DispatchWorkItem?
    private var deadline = DispatchTime.distantFuture
    private var busy = false
    private var lastReconciliation = Date()
    private var lastReverify = Date.distantPast
    private var reverifyDue = false
    private let bulkWidth: Int
    private let stateLock = NSLock()
    private var published = SizeIndexStatus(isPaused: false, pendingFolders: 0, folders: 0)
    private var workingSince: Date?
    private var countedAt = DispatchTime(uptimeNanoseconds: 0)

    public var reconciliationInterval: TimeInterval = 7 * 86400
    public var reverifyInterval: TimeInterval = 900
    public var stallLimit: TimeInterval = 60

    public init(databaseURL: URL = SizeIndexLocation.database, cacheKiB: Int = 32768) throws {
        self.databaseURL = databaseURL
        writer = try SizeIndexWriter(databaseURL: databaseURL, cacheKiB: cacheKiB)
        bulkWidth = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        events = SizeIndexEvents(writer: writer, queue: queue)
        writer.readBudget = 0.15
        writer.rescanInterval = 3
        writer.rescanIntervalPerItem = 0.002
        events.onChange = { [weak self] in self?.schedule(after: 0.25) }
        events.onDropped = { [weak self] in
            guard let self else { return }
            if !self.reverifyDue { NSLog("Indexer: file events were dropped, scheduling a re-verify") }
            self.reverifyDue = true
            self.schedule(after: 1)
        }
        publish(counting: true)
    }

    private func working(_ body: () -> Void) {
        stateLock.lock()
        workingSince = Date()
        stateLock.unlock()
        body()
        stateLock.lock()
        workingSince = nil
        stateLock.unlock()
    }

    private func publish(counting: Bool = false) {
        let now = DispatchTime.now()
        let recount = counting || now.uptimeNanoseconds - countedAt.uptimeNanoseconds >= 1_000_000_000
        let pending = writer.pendingCount
        let folders = recount ? writer.directoryCount : nil
        if recount { countedAt = now }
        stateLock.lock()
        published = SizeIndexStatus(isPaused: paused, pendingFolders: pending, folders: folders ?? published.folders)
        stateLock.unlock()
    }

    func occupy(_ body: @escaping () -> Void) {
        queue.async { self.working(body) }
    }

    deinit {
        tick?.cancel()
        events.stop()
    }

    public func start(roots: [URL]) {
        queue.async {
            do {
                for root in roots { try self.events.watch(root) }
                try self.events.restore()
                for root in roots { try self.writer.addRoot(root) }
            } catch { NSLog("Indexer: %@", String(describing: error)) }
            self.publish(counting: true)
            self.schedule()
        }
    }

    public func stop() {
        queue.sync {
            tick?.cancel()
            tick = nil
            paused = true
            events.stop()
        }
    }

    private func schedule(after delay: TimeInterval = 0) {
        let wanted = DispatchTime.now() + delay
        if tick != nil, deadline <= wanted { return }
        tick?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.run() }
        tick = item
        deadline = wanted
        queue.asyncAfter(deadline: wanted, execute: item)
    }

    private func run() {
        tick = nil
        deadline = .distantFuture
        guard !paused else { return }
        working {
            do {
                if reverifyDue, Date().timeIntervalSince(lastReverify) >= reverifyInterval {
                    reverifyDue = false
                    lastReverify = Date()
                    try writer.rebuild()
                }
                writer.scanWidth = writer.hasBulkWork ? bulkWidth : 1
                if try writer.processBatch(limit: 4096, budget: 0.12) > 0 {
                    busy = true
                    publish()
                    schedule()
                    return
                }
                if try writer.collectGarbage() > 0 { schedule(); return }
                if busy {
                    busy = false
                    writer.relax()
                }
                publish(counting: true)
                if Date().timeIntervalSince(lastReconciliation) > reconciliationInterval,
                   CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) > 60 {
                    lastReconciliation = Date()
                    lastReverify = Date()
                    reverifyDue = false
                    try writer.rebuild()
                    schedule()
                    return
                }
                let wait = reverifyDue ? max(1, reverifyInterval - Date().timeIntervalSince(lastReverify)) : 45
                schedule(after: writer.isCooling ? min(3, wait) : min(45, wait))
            } catch {
                NSLog("Indexer: %@", String(describing: error))
                schedule(after: 45)
            }
        }
    }

    private func perform(_ work: @escaping (SizeIndexDaemon) throws -> Void, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.working {
                do { try work(self) } catch { NSLog("Indexer: %@", String(describing: error)) }
                self.publish()
            }
            self.schedule()
        }
        reply(true)
    }

    private func watch(_ paths: [String]) {
        for path in paths { try? events.watch(URL(fileURLWithPath: path)) }
    }

    public func focus(paths: [String], reply: @escaping (Bool) -> Void) {
        perform({ daemon in
            try daemon.writer.focus(on: paths.map { URL(fileURLWithPath: $0) })
            daemon.watch(paths)
        }, reply: reply)
    }

    public func refresh(paths: [String], reply: @escaping (Bool) -> Void) {
        perform({ try $0.writer.refresh(paths: paths) }, reply: reply)
    }

    public func pause(reply: @escaping (Bool) -> Void) {
        perform({ $0.paused = true }, reply: reply)
    }

    public func resume(reply: @escaping (Bool) -> Void) {
        perform({ $0.paused = false }, reply: reply)
    }

    public func rebuild(reply: @escaping (Bool) -> Void) {
        perform({ try $0.writer.rebuild() }, reply: reply)
    }

    public func status(reply: @escaping (String) -> Void) {
        stateLock.lock()
        let status = published
        let stalled = workingSince.map { Date().timeIntervalSince($0) > stallLimit } ?? false
        stateLock.unlock()
        reply(stalled ? "unavailable" : status.text)
    }

    public func focus(paths: [String]) async -> Bool { await withCheckedContinuation { c in focus(paths: paths) { c.resume(returning: $0) } } }
    public func refresh(paths: [String]) async -> Bool { await withCheckedContinuation { c in refresh(paths: paths) { c.resume(returning: $0) } } }
    public func pause() async -> Bool { await withCheckedContinuation { c in pause { c.resume(returning: $0) } } }
    public func resume() async -> Bool { await withCheckedContinuation { c in resume { c.resume(returning: $0) } } }
    public func rebuild() async -> Bool { await withCheckedContinuation { c in rebuild { c.resume(returning: $0) } } }
    public func status() async -> String { await withCheckedContinuation { c in status { c.resume(returning: $0) } } }

    public func drain() {
        queue.sync {
            while (try? writer.processBatch()) ?? 0 > 0 {}
            while (try? writer.collectGarbage(olderThan: 0)) ?? 0 > 0 {}
            publish(counting: true)
        }
    }
}
