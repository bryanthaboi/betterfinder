import CoreServices
import Foundation

public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ changedPaths: [String]) -> Void

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let handler: Handler
    private let queue = DispatchQueue(label: "betterfinder.watcher", qos: .userInitiated)
    private let latency: CFTimeInterval

    public init(paths: [URL], latency: CFTimeInterval = 0.15, handler: @escaping Handler) {
        self.paths = paths.map(\.path)
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let list = (cfArray as? [String]) ?? []
            watcher.handler(Array(list.prefix(count)))
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
