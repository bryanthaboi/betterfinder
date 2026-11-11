import CoreServices
import Foundation

public final class SizeIndexEvents {
    static let backlogLimit = 400_000
    private let writer: SizeIndexWriter
    private let queue: DispatchQueue
    private let intake = DispatchQueue(label: "betterfinder.indexer.events", qos: .utility)
    private let lock = NSLock()
    private var backlog = 0
    private var mounts: [Int32: String] = [:]
    private var streams: [Int32: FSEventStreamRef] = [:]
    private var watched: [Int32: String] = [:]
    public var onChange: (() -> Void)?
    public var onDropped: () -> Void
    public init(writer: SizeIndexWriter, queue: DispatchQueue) {
        self.writer = writer
        self.queue = queue
        onDropped = { try? writer.rebuild() }
    }
    deinit { stop() }

    public func watch(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return }
        if streams[st.st_dev] != nil, watched[st.st_dev] != nil, stable(st.st_dev) { return }
        guard let volume = IndexVolume.identifier(forPath: url.path) else { return }
        if let stale = streams[st.st_dev] {
            guard watched[st.st_dev] != volume else { return }
            FSEventStreamStop(stale)
            FSEventStreamInvalidate(stale)
            intake.sync {}
            FSEventStreamRelease(stale)
            streams[st.st_dev] = nil
        }
        let journal = FSEventsCopyUUIDForDevice(st.st_dev).map { CFUUIDCreateString(nil, $0) as String } ?? ""
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { throw POSIXError(.EIO) }
        let mount = withUnsafePointer(to: &fs.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        lock.lock()
        mounts[st.st_dev] = mount
        lock.unlock()
        writer.forgetVolumes()
        let previous = try writer.db.first("SELECT journal,event_id FROM volumes WHERE uuid=?", args: [.text(volume)]) {
            (IndexDatabase.text($0, 0), IndexDatabase.text($0, 1))
        }
        let known = previous != nil && previous?.0 == journal
        let since = known ? (UInt64(previous?.1 ?? "") ?? FSEventsGetCurrentEventId()) : FSEventsGetCurrentEventId()
        try writer.transaction {
            try writer.db.run("UPDATE volumes SET device=NULL WHERE device=? AND uuid!=?", args: [.int(Int64(st.st_dev)), .text(volume)])
            try writer.db.run("""
            INSERT INTO volumes(uuid,device,journal,event_id) VALUES(?,?,?,?) ON CONFLICT(uuid) DO UPDATE SET device=excluded.device,
            event_id=CASE WHEN journal IS excluded.journal AND event_id IS NOT NULL THEN event_id ELSE excluded.event_id END,journal=excluded.journal
            """, args: [.text(volume), .int(Int64(st.st_dev)), .text(journal), .text(String(since))])
            if !known { try writer.rebuild() }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { stream, info, count, paths, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<SizeIndexEvents>.fromOpaque(info).takeUnretainedValue()
            let records = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [[String: Any]]
            let list = records.map { $0[kFSEventStreamEventExtendedDataPathKey] as? String ?? "" }
            let device = FSEventStreamGetDeviceBeingWatched(stream)
            owner.receive((0..<min(count, list.count)).map { Event(path: list[$0], flags: flags[$0], id: ids[$0]) }, device: device)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFullHistory)
        guard let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, st.st_dev, [""] as CFArray, since, 1, flags) else { throw POSIXError(.EIO) }
        FSEventStreamSetDispatchQueue(stream, intake)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); throw POSIXError(.EIO) }
        streams[st.st_dev] = stream
        watched[st.st_dev] = volume
        checked[st.st_dev] = DispatchTime.now().uptimeNanoseconds
    }

    private var checked: [Int32: UInt64] = [:]

    private func stable(_ device: Int32) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = checked[device], now &- last < 30_000_000_000 { return true }
        checked[device] = now
        return false
    }

    struct Event {
        var path: String
        var flags: UInt32
        var id: UInt64
    }

    private func receive(_ events: [Event], device: Int32) {
        lock.lock()
        let mount = mounts[device] ?? "/"
        let accepted = backlog < Self.backlogLimit
        if accepted { backlog += events.count }
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            guard accepted else {
                self.onDropped()
                return
            }
            self.lock.lock()
            self.backlog -= events.count
            self.lock.unlock()
            let rebind = self.apply(events, device: device, mount: mount)
            self.onChange?()
            if rebind {
                self.stop()
                try? self.restore()
            }
        }
    }

    static func resolve(mount: String, relative: String) -> String {
        var path = relative.isEmpty ? mount : (mount == "/" ? "/" + relative : mount + "/" + relative)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return SizeIndexLocation.stripDataPrefix(path)
    }

    func apply(_ events: [Event], device: Int32, mount: String) -> Bool {
        var rebind = false
        var lost = false
        let dropped = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagEventIdsWrapped)
        do {
            try writer.transaction {
                var dirty = Set<String>()
                var deep = Set<String>()
                var cursor: UInt64 = 0
                for event in events {
                    let flag = event.flags
                    if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                    if flag & dropped != 0 {
                        lost = true
                        if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { rebind = true }
                    } else {
                        let path = Self.resolve(mount: mount, relative: event.path)
                        if !writer.excludes(path) {
                            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                                if try writer.contains(path) { deep.insert(path) } else {
                                    for root in try writer.roots(within: path, device: device) { deep.insert(root) }
                                }
                            } else if try writer.contains(path) {
                                if path != "/" {
                                    let parent = (path as NSString).deletingLastPathComponent
                                    if try writer.contains(parent) { dirty.insert(parent) }
                                }
                                if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { dirty.insert(path) }
                            }
                        }
                    }
                    if event.id != 0 && flag & UInt32(kFSEventStreamEventFlagRootChanged) == 0 { cursor = event.id }
                }
                for path in deep { try writer.mark(path: path, recursive: true) }
                for path in dirty where !deep.contains(path) { try writer.touch(path, recursive: false, retryDenied: false) }
                if cursor != 0 {
                    try writer.db.run("UPDATE volumes SET event_id=? WHERE device=?", args: [.text(String(cursor)), .int(Int64(device))])
                }
            }
        } catch { lost = true }
        if lost { onDropped() }
        return rebind
    }

    public func restore() throws {
        var roots: [String] = []
        try writer.db.each("SELECT path FROM roots ORDER BY path", args: []) { s in
            if let path = IndexDatabase.text(s, 0) { roots.append(path) }
        }
        for root in roots { try watch(URL(fileURLWithPath: root)) }
    }

    public func stop() {
        for stream in streams.values { FSEventStreamStop(stream); FSEventStreamInvalidate(stream) }
        intake.sync {}
        for stream in streams.values { FSEventStreamRelease(stream) }
        streams.removeAll()
        watched.removeAll()
        checked.removeAll()
    }
}
