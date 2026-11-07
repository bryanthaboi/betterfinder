import CoreServices
import Foundation

public final class ModFolderWatcher: @unchecked Sendable {
    public let folder: URL
    public let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "betterfinder.appbridge.watch")
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval

    public init(folder: URL, latency: TimeInterval = 0.2, debounce: TimeInterval = 0.35, onChange: @escaping @Sendable () -> Void) {
        self.folder = folder
        self.latency = latency
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ModFolderWatcher>.fromOpaque(info).takeUnretainedValue().fired()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        pending?.cancel()
    }

    private func fired() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
