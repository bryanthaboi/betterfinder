import Darwin
import Foundation
import ModHost
import ModHostProtocol
import ModHostRuntime

public final class GracefulXPCModHostTransport: XPCModHostTransport, @unchecked Sendable {
    public let killGrace: TimeInterval
    public let gate: ModCheckGate?

    public init(serviceName: String, serviceRequirement: String?, killGrace: TimeInterval = 2, gate: ModCheckGate? = nil) {
        self.killGrace = killGrace
        self.gate = gate
        super.init(serviceName: serviceName, serviceRequirement: serviceRequirement, termination: .graceful(killGrace), onSpawn: gate.map { g in { g.recordSpawn() } })
    }
}

public struct GracefulXPCModHostTransportFactory: ModHostTransportFactory {
    public var serviceName: String
    public var gate: ModCheckGate?

    public init(serviceName: String = ModHostWire.checkServiceName, gate: ModCheckGate? = nil) {
        self.serviceName = serviceName
        self.gate = gate
    }

    public func makeTransport() throws -> ModHostTransport {
        GracefulXPCModHostTransport(serviceName: serviceName, serviceRequirement: ModPeerPolicy.requirement(forPeerIdentifier: serviceName), gate: gate)
    }
}

public actor ModCheckGate {
    public static let shared = ModCheckGate()
    public static let spawnInterval: TimeInterval = 10.3

    private let lock = NSLock()
    nonisolated(unsafe) private var lastSpawn: Date?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    nonisolated func recordSpawn() { lock.withLock { lastSpawn = Date() } }

    public nonisolated var remaining: TimeInterval {
        lock.withLock { lastSpawn.map { max(0, Self.spawnInterval - Date().timeIntervalSince($0)) } ?? 0 }
    }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        let wait = remaining
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return try await body()
    }
}
