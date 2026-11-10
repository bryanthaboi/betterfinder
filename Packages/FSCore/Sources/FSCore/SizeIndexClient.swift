import Foundation
import ServiceManagement

@objc public protocol SizeIndexProtocol {
    func prioritize(path: String, reply: @escaping (Bool) -> Void)
    func addRoot(path: String, reply: @escaping (Bool) -> Void)
    func pause(reply: @escaping (Bool) -> Void)
    func resume(reply: @escaping (Bool) -> Void)
    func rebuild(reply: @escaping (Bool) -> Void)
    func status(reply: @escaping (String) -> Void)
    func buildIdentity(reply: @escaping (String) -> Void)
    func refresh(path: String, reply: @escaping (Bool) -> Void)
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

public final class SizeIndexClient: @unchecked Sendable {
    public init() {}
    private func call<T>(fallback: T, _ body: @escaping (SizeIndexProtocol, @escaping (T) -> Void) -> Void) async -> T {
        guard !DemoEnvironment.isEnabled else { return fallback }
        return await withCheckedContinuation { continuation in
            let reply = IndexReply(continuation)
            let connection = NSXPCConnection(machServiceName: SizeIndexService.machServiceName)
            connection.remoteObjectInterface = NSXPCInterface(with: SizeIndexProtocol.self)
            connection.interruptionHandler = { [weak connection] in reply.finish(fallback); connection?.invalidate() }
            connection.invalidationHandler = { reply.finish(fallback) }
            connection.resume()
            let finish: (T) -> Void = { value in reply.finish(value); connection.invalidate() }
            if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(fallback) }) as? SizeIndexProtocol { body(proxy, finish) } else { finish(fallback) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { finish(fallback) }
        }
    }
    public func prioritize(path: String) async -> Bool { await call(fallback: false) { $0.prioritize(path: path, reply: $1) } }
    public func refresh(path: String) async -> Bool { await call(fallback: false) { $0.refresh(path: path, reply: $1) } }
    public func addRoot(path: String) async -> Bool { await call(fallback: false) { $0.addRoot(path: path, reply: $1) } }
    public func pause() async -> Bool { await call(fallback: false) { $0.pause(reply: $1) } }
    public func resume() async -> Bool { await call(fallback: false) { $0.resume(reply: $1) } }
    public func rebuild() async -> Bool { await call(fallback: false) { $0.rebuild(reply: $1) } }
    public func status() async -> String { await call(fallback: "unavailable") { $0.status(reply: $1) } }
    public func buildIdentity() async -> String { await call(fallback: "") { $0.buildIdentity(reply: $1) } }

    public func terminateService() async -> Bool {
        guard !DemoEnvironment.isEnabled else { return false }
        return await withCheckedContinuation { continuation in
            let reply = IndexReply(continuation)
            let connection = NSXPCConnection(machServiceName: SizeIndexService.machServiceName)
            connection.remoteObjectInterface = NSXPCInterface(with: SizeIndexProtocol.self)
            connection.invalidationHandler = { reply.finish(false) }
            connection.resume()
            let finish: (Bool) -> Void = { value in reply.finish(value); connection.invalidate() }
            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? SizeIndexProtocol
            proxy?.status { _ in
                let pid = connection.processIdentifier
                finish(pid > 0 && kill(pid, SIGTERM) == 0)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }

    public func ensureCurrent(expected: String) async -> Bool {
        let running = await buildIdentity()
        guard running != expected else { return false }
        guard await terminateService() else { return false }
        try? await Task.sleep(nanoseconds: 500_000_000)
        return true
    }
}
