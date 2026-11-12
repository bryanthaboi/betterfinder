import Foundation
import ServiceManagement

@objc public protocol SizeIndexProtocol {
    func focus(paths: [String], reply: @escaping (Bool) -> Void)
    func refresh(paths: [String], reply: @escaping (Bool) -> Void)
    func pause(reply: @escaping (Bool) -> Void)
    func resume(reply: @escaping (Bool) -> Void)
    func rebuild(reply: @escaping (Bool) -> Void)
    func status(reply: @escaping (String) -> Void)
    func buildIdentity(reply: @escaping (String) -> Void)
}

public enum SizeIndexService {
    public static let machServiceName = "com.bryanthaboi.betterfinder.indexer"
    public static var status: SMAppService.Status { if DemoEnvironment.isEnabled { return .notRegistered }; return SMAppService.agent(plistName: machServiceName + ".plist").status }
    public static func register() throws { guard !DemoEnvironment.isEnabled else { return }; try SMAppService.agent(plistName: machServiceName + ".plist").register() }
    public static func buildIdentity(ofExecutable url: URL, bundleVersion: String?) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(bundleVersion ?? "0")-\(Int64(modified))-\(size)"
    }

    public static func unregister() async throws { guard !DemoEnvironment.isEnabled else { return }; try await SMAppService.agent(plistName: machServiceName + ".plist").unregister() }

    public static let executableName = "BetterFinderIndexer"

    static func processes(named name: String, parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 256)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }
        let user = getuid()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(count).filter { pid in
            var info = proc_bsdinfo()
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return false }
            guard info.pbi_uid == user, info.pbi_ppid == UInt32(parent) else { return false }
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: path)).lastPathComponent == name
        }
    }

    static func terminate(_ pids: [pid_t], timeout: TimeInterval = 5) async -> Bool {
        let signalled = pids.filter { kill($0, SIGTERM) == 0 }
        guard !signalled.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while signalled.contains(where: { kill($0, 0) == 0 }) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}

private final class IndexReply<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func finish(_ value: T) {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        saved?.resume(returning: value)
    }
}

public final class SizeIndexClient: @unchecked Sendable, SizeIndexControl {
    public init() {}
    private func call<T>(unreachable: T, _ body: @escaping (SizeIndexProtocol, @escaping (T) -> Void) -> Void) async -> T {
        guard !DemoEnvironment.isEnabled else { return unreachable }
        return await withCheckedContinuation { continuation in
            let reply = IndexReply(continuation)
            let connection = NSXPCConnection(machServiceName: SizeIndexService.machServiceName)
            connection.remoteObjectInterface = NSXPCInterface(with: SizeIndexProtocol.self)
            connection.interruptionHandler = { [weak connection] in reply.finish(unreachable); connection?.invalidate() }
            connection.invalidationHandler = { reply.finish(unreachable) }
            connection.resume()
            let finish: (T) -> Void = { value in reply.finish(value); connection.invalidate() }
            if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(unreachable) }) as? SizeIndexProtocol { body(proxy, finish) } else { finish(unreachable) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { finish(unreachable) }
        }
    }
    public func focus(paths: [String]) async -> Bool { await call(unreachable: false) { $0.focus(paths: paths, reply: $1) } }
    public func refresh(paths: [String]) async -> Bool { await call(unreachable: false) { $0.refresh(paths: paths, reply: $1) } }
    public func pause() async -> Bool { await call(unreachable: false) { $0.pause(reply: $1) } }
    public func resume() async -> Bool { await call(unreachable: false) { $0.resume(reply: $1) } }
    public func rebuild() async -> Bool { await call(unreachable: false) { $0.rebuild(reply: $1) } }
    public func status() async -> String { await call(unreachable: "unavailable") { $0.status(reply: $1) } }
    public func buildIdentity() async -> String { await call(unreachable: "") { $0.buildIdentity(reply: $1) } }

    public func terminateService() async -> Bool {
        guard !DemoEnvironment.isEnabled else { return false }
        return await SizeIndexService.terminate(SizeIndexService.processes(named: SizeIndexService.executableName, parent: 1))
    }

    public func ensureCurrent(expected: String) async -> Bool {
        guard await buildIdentity() != expected else { return false }
        return await terminateService()
    }
}
