import Darwin
import Foundation
import ModHostProtocol
import ModHostRuntime

public enum ModHostTransportClose: Equatable, Sendable {
    case exited(Int32)
    case killed
    case invalidated(String)
}

public protocol ModHostTransport: AnyObject, Sendable {
    var processIdentifier: pid_t? { get }
    var isolatesProcess: Bool { get }
    func start(onMessage: @escaping @Sendable (ModHostToApp) -> Void, onClose: @escaping @Sendable (ModHostTransportClose) -> Void) throws
    func send(_ message: ModAppToHost)
    func terminate()
}

public protocol ModHostTransportFactory: Sendable {
    func makeTransport() throws -> ModHostTransport
}

public struct ModClosureTransportFactory: ModHostTransportFactory {
    let make: @Sendable () throws -> ModHostTransport
    public init(_ make: @escaping @Sendable () throws -> ModHostTransport) { self.make = make }
    public func makeTransport() throws -> ModHostTransport { try make() }
}

public final class InProcessModHostTransport: ModHostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: ModHostEngine?
    private var onClose: (@Sendable (ModHostTransportClose) -> Void)?
    private let delivery = DispatchQueue(label: "betterfinder.modhost.inprocess")

    public init() {}

    public var processIdentifier: pid_t? { nil }
    public var isolatesProcess: Bool { false }

    public func start(onMessage: @escaping @Sendable (ModHostToApp) -> Void, onClose: @escaping @Sendable (ModHostTransportClose) -> Void) throws {
        let delivery = delivery
        let engine = ModHostEngine(exitOnHang: false) { message in
            guard let data = try? ModHostWire.encode(message), let decoded = try? ModHostWire.decode(ModHostToApp.self, from: data) else { return }
            delivery.async { onMessage(decoded) }
        }
        lock.lock()
        self.engine = engine
        self.onClose = onClose
        lock.unlock()
        engine.start()
    }

    public func send(_ message: ModAppToHost) {
        lock.lock()
        let e = engine
        lock.unlock()
        guard let e, let data = try? ModHostWire.encode(message) else { return }
        e.handle(data: data)
    }

    public func terminate() {
        lock.lock()
        let e = engine
        engine = nil
        let close = onClose
        onClose = nil
        lock.unlock()
        e?.shutdown()
        if let close { delivery.async { close(.killed) } }
    }
}

public final class SubprocessModHostTransport: ModHostTransport, @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var killed = false
    private var buffer = Data()

    public init(executable: URL, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    public var processIdentifier: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    public var isolatesProcess: Bool { true }

    public func start(onMessage: @escaping @Sendable (ModHostToApp) -> Void, onClose: @escaping @Sendable (ModHostTransportClose) -> Void) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let environment = ProcessInfo.processInfo.environment
        if environment["BETTERFINDER_DEMO"] == "1" {
            for key in ["CFFIXED_USER_HOME", "TMPDIR", "BETTERFINDER_DEMO", "BETTERFINDER_DEMO_COMPUTER", "BETTERFINDER_DEMO_USER", "BETTERFINDER_DEMO_VOLUMES"] {
                p.environment?[key] = environment[key]
            }
        }
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let reader = outPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            self.buffer.append(chunk)
            var frames = [Data]()
            do { while let f = try ModHostFraming.nextFrame(&self.buffer) { frames.append(f) } } catch { self.buffer.removeAll() }
            self.lock.unlock()
            for f in frames { if let m = try? ModHostWire.decode(ModHostToApp.self, from: f) { onMessage(m) } }
        }
        p.terminationHandler = { [weak self] proc in
            reader.readabilityHandler = nil
            let wasKilled: Bool = {
                guard let self else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.killed
            }()
            onClose(wasKilled ? .killed : .exited(proc.terminationStatus))
        }
        try p.run()
        lock.lock()
        process = p
        stdin = inPipe.fileHandleForWriting
        lock.unlock()
    }

    public func send(_ message: ModAppToHost) {
        guard let data = try? ModHostWire.encode(message) else { return }
        lock.lock()
        let h = stdin
        lock.unlock()
        do { try h?.write(contentsOf: ModHostFraming.frame(data)) } catch {}
    }

    public func terminate() {
        lock.lock()
        killed = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

public enum XPCModHostTermination: Sendable, Equatable {
    case immediate
    case graceful(TimeInterval)
}

open class XPCModHostTransport: NSObject, ModHostTransport, ModHostXPCEndpoint, @unchecked Sendable {
    public let serviceName: String
    public let serviceRequirement: String?
    public let termination: XPCModHostTermination
    private let onSpawn: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var onMessage: (@Sendable (ModHostToApp) -> Void)?
    private var onClose: (@Sendable (ModHostTransportClose) -> Void)?
    private var closed = false
    private var killed = false
    private var pid: pid_t?

    public convenience init(serviceName: String = ModHostWire.serviceName, serviceRequirement: String? = ModPeerPolicy.requirement(forPeerIdentifier: ModHostWire.serviceName)) {
        self.init(serviceName: serviceName, serviceRequirement: serviceRequirement, termination: .immediate, onSpawn: nil)
    }

    public init(serviceName: String, serviceRequirement: String?, termination: XPCModHostTermination, onSpawn: (@Sendable () -> Void)?) {
        self.serviceName = serviceName
        self.serviceRequirement = serviceRequirement
        self.termination = termination
        self.onSpawn = onSpawn
    }

    public var processIdentifier: pid_t? {
        lock.lock(); defer { lock.unlock() }
        if let pid { return pid }
        guard let c = connection, c.processIdentifier > 0 else { return nil }
        return c.processIdentifier
    }

    public var isolatesProcess: Bool { true }

    public var isClosed: Bool { lock.withLock { closed } }

    public func start(onMessage: @escaping @Sendable (ModHostToApp) -> Void, onClose: @escaping @Sendable (ModHostTransportClose) -> Void) throws {
        let c = NSXPCConnection(serviceName: serviceName)
        let interface = NSXPCInterface(with: ModHostXPCEndpoint.self)
        c.remoteObjectInterface = interface
        c.exportedInterface = interface
        c.exportedObject = self
        if let serviceRequirement { c.setCodeSigningRequirement(serviceRequirement) }
        c.invalidationHandler = { [weak self] in self?.connectionInvalidated() }
        c.interruptionHandler = { [weak self] in self?.connectionInterrupted() }
        guard prepare(connection: c, onMessage: onMessage, onClose: onClose) else { c.invalidate(); return }
        onSpawn?()
        c.resume()
        send(.ping(0))
    }

    func prepare(connection c: NSXPCConnection?, onMessage: @escaping @Sendable (ModHostToApp) -> Void, onClose: @escaping @Sendable (ModHostTransportClose) -> Void) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            connection = c
            self.onMessage = onMessage
            self.onClose = onClose
            return true
        }
    }

    func connectionInvalidated() { close(.invalidated("connection invalidated")) }

    func connectionInterrupted() { close(.invalidated("service interrupted")) }

    private func close(_ reason: ModHostTransportClose) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let cb = onClose
        let r = killed ? ModHostTransportClose.killed : reason
        let c = connection
        connection = nil
        onMessage = nil
        onClose = nil
        lock.unlock()
        c?.invalidate()
        cb?(r)
    }

    public func deliver(_ message: Data) {
        guard let m = try? ModHostWire.decode(ModHostToApp.self, from: message) else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if case .ready(let info) = m { pid = info.pid }
        let cb = onMessage
        lock.unlock()
        cb?(m)
    }

    public func send(_ message: ModAppToHost) {
        guard let data = try? ModHostWire.encode(message) else { return }
        lock.lock()
        let c = connection
        lock.unlock()
        let proxy = c?.remoteObjectProxyWithErrorHandler { [weak self] e in self?.close(.invalidated(e.localizedDescription)) } as? ModHostXPCEndpoint
        proxy?.deliver(data)
    }

    public func terminate() {
        let p = processIdentifier
        lock.withLock { killed = true }
        switch termination {
        case .immediate:
            if let p, p > 0 { kill(p, SIGKILL) }
            close(.killed)
        case .graceful(let grace):
            close(.killed)
            guard let p, p > 0 else { return }
            let name = serviceName
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if kill(p, 0) == 0, ModPeerPolicy.signingInfo(pid: p)?.identifier == name { kill(p, SIGKILL) }
            }
        }
    }
}

public struct XPCModHostTransportFactory: ModHostTransportFactory {
    public var serviceName: String
    public var checkServiceName: String?

    public init(serviceName: String = ModHostWire.serviceName, checkServiceName: String? = ModHostWire.checkServiceName) {
        self.serviceName = serviceName
        self.checkServiceName = checkServiceName
    }

    public func makeTransport() throws -> ModHostTransport {
        XPCModHostTransport(serviceName: serviceName, serviceRequirement: ModPeerPolicy.requirement(forPeerIdentifier: serviceName))
    }

    public var checkCounterpart: ModHostTransportFactory? {
        checkServiceName.map { XPCModHostTransportFactory(serviceName: $0, checkServiceName: nil) }
    }
}

public enum ModHostTransports {
    public static func xpc() -> ModHostTransportFactory { XPCModHostTransportFactory() }

    public static func xpcCheck() -> ModHostTransportFactory { XPCModHostTransportFactory(serviceName: ModHostWire.checkServiceName, checkServiceName: nil) }

    public static func inProcess() -> ModHostTransportFactory {
        ModClosureTransportFactory { InProcessModHostTransport() }
    }

    public static func subprocess(_ executable: URL, arguments: [String] = []) -> ModHostTransportFactory {
        ModClosureTransportFactory { SubprocessModHostTransport(executable: executable, arguments: arguments) }
    }
}
