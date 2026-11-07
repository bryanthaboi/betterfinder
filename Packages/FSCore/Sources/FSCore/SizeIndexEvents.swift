import CoreServices
import Foundation

public final class SizeIndexEvents {
    private let writer: SizeIndexWriter
    private let queue: DispatchQueue
    private var mounts: [Int32: String] = [:]
    private var streams: [Int32: FSEventStreamRef] = [:]
    public var onChange: (() -> Void)?
    public init(writer: SizeIndexWriter, queue: DispatchQueue) { self.writer = writer; self.queue = queue }
    deinit { stop() }

    public func watch(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0, streams[st.st_dev] == nil else { return }
        guard let volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return }
        let journal = FSEventsCopyUUIDForDevice(st.st_dev).map { CFUUIDCreateString(nil, $0) as String } ?? ""
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { throw POSIXError(.EIO) }
        mounts[st.st_dev] = withUnsafePointer(to: &fs.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let previous = try writer.db.row("SELECT journal,event_id FROM volumes WHERE uuid=?", [volume])
        let since = previous?[0] == journal ? (UInt64(previous?[1] ?? "") ?? FSEventsGetCurrentEventId()) : FSEventsGetCurrentEventId()
        try writer.db.run("INSERT INTO volumes VALUES(?,?,?,?) ON CONFLICT(uuid) DO UPDATE SET device=excluded.device,journal=excluded.journal", [volume,String(st.st_dev),journal,String(since)])
        if previous?[0] != journal { try writer.rebuild() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { stream, info, count, paths, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<SizeIndexEvents>.fromOpaque(info).takeUnretainedValue()
            let records = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [[String: Any]]
            let list = records.map { $0[kFSEventStreamEventExtendedDataPathKey] as? String ?? "" }
            let device = FSEventStreamGetDeviceBeingWatched(stream)
            let events = (0..<min(count, list.count)).map { Event(path: list[$0], flags: flags[$0], id: ids[$0]) }
            let rebind = owner.apply(events, device: device, mount: owner.mounts[device] ?? "/")
            owner.onChange?()
            if rebind {
                owner.queue.async {
                    owner.stop()
                    try? owner.restore()
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFullHistory)
        guard let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, st.st_dev, [""] as CFArray, since, 1, flags) else { throw POSIXError(.EIO) }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); throw POSIXError(.EIO) }
        streams[st.st_dev] = stream
    }
    struct Event {
        var path: String
        var flags: UInt32
        var id: UInt64
    }

    func apply(_ events: [Event], device: Int32, mount: String) -> Bool {
        var rebind = false
        do {
            try writer.db.transaction {
                for event in events {
                    let flag = event.flags
                    if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                    if flag & UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                        try writer.rebuild()
                        if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { rebind = true }
                    } else {
                        let path = SizeIndexLocation.canonical(URL(fileURLWithPath: mount).appendingPathComponent(event.path)).path
                        if writer.excludes(path) { continue }
                        let directory = flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                        let recursive = flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                        if try writer.contains(path) {
                            if recursive {
                                try writer.enqueue(path: path, recursive: true)
                            } else {
                                if path != "/" {
                                    let parent = (path as NSString).deletingLastPathComponent
                                    if try writer.contains(parent) { try writer.enqueue(path: parent, recursive: false) }
                                }
                                if directory { try writer.enqueue(path: path, recursive: false) }
                            }
                        } else if recursive {
                            for root in try writer.roots(within: path, device: device) { try writer.enqueue(path: root, recursive: true) }
                        }
                    }
                    if event.id != 0 && flag & UInt32(kFSEventStreamEventFlagRootChanged) == 0 {
                        try writer.db.run("UPDATE volumes SET event_id=? WHERE device=?", [String(event.id), String(device)])
                    }
                }
            }
        } catch { try? writer.rebuild() }
        return rebind
    }

    public func restore() throws {
        var previous = ""
        while let row = try writer.db.row("SELECT path FROM roots WHERE path>? ORDER BY path LIMIT 1", [previous]) {
            previous = row[0]
            try watch(URL(fileURLWithPath: previous))
        }
    }
    public func stop() {
        for stream in streams.values { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        streams.removeAll()
    }
}
