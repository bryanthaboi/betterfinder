import Foundation
import ModHostProtocol
import ModKit

public enum ModInvocationError: Error, Equatable, Sendable, LocalizedError {
    case notActive(String)
    case quarantined(String)
    case invalidInput(String)
    case invalidOutput(String)
    case script(code: String, message: String)
    case timeout(Int)
    case hostFailure(String)
    case safeMode

    public var errorDescription: String? {
        switch self {
        case .notActive(let id): return "\(id) is not active"
        case .quarantined(let h): return "handler \(h) is quarantined after a host failure"
        case .invalidInput(let m): return "invalid hook input: \(m)"
        case .invalidOutput(let m): return "invalid hook result: \(m)"
        case .script(let code, let message): return "\(code): \(message)"
        case .timeout(let ms): return "handler did not finish within \(ms) ms"
        case .hostFailure(let m): return "mod host failed: \(m)"
        case .safeMode: return "mods are paused in safe mode"
        }
    }
}

public struct ModHostEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case started, hung, crashed, memoryRestart, safeMode, quarantined, peerRejected }
    public var kind: Kind
    public var modId: String?
    public var detail: String
    public var time = Date()
}

final class ModHostSupervisor: @unchecked Sendable {
    struct Pending {
        var invocation: ModInvocation
        var continuation: CheckedContinuation<ModCallOutcome, Never>
        var timer: DispatchSourceTimer?
    }

    let factory: ModHostTransportFactory
    let config: ModHostConfig
    let deadlineGraceMs: Int
    private let lock = NSLock()
    private var transport: ModHostTransport?
    private var transportID = UUID()
    private var loads: [String: ModLoadRequest] = [:]
    private var loadWaiters: [String: [CheckedContinuation<ModCallError?, Never>]] = [:]
    private var pending: [String: Pending] = [:]
    private var mods: [String: ActiveMod] = [:]
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var restarting = false
    private var stopped = false
    private var benchmarkWaiter: CheckedContinuation<UInt64?, Never>?
    private var probeWaiter: CheckedContinuation<[String: String], Never>?
    private(set) var lastStats: ModHostStats?
    private(set) var hostInfo: ModHostInfo?
    let callHandler: ModCallHandling
    var onEvent: (@Sendable (ModHostEvent) -> Void)?
    var onHostFailure: (@Sendable (_ offender: ModInvocation?, _ reason: String) -> Void)?
    var onRestarted: (@Sendable () -> Void)?
    private let callQueue = DispatchQueue(label: "betterfinder.modhost.calls", attributes: .concurrent)

    init(factory: ModHostTransportFactory, config: ModHostConfig, deadlineGraceMs: Int = 1500, callHandler: ModCallHandling) {
        self.factory = factory
        self.config = config
        self.deadlineGraceMs = deadlineGraceMs
        self.callHandler = callHandler
    }

    var processIdentifier: pid_t? { lock.lock(); defer { lock.unlock() }; return transport?.processIdentifier }
    var isolatesProcess: Bool { lock.lock(); defer { lock.unlock() }; return transport?.isolatesProcess ?? false }

    func start() throws {
        lock.lock()
        stopped = false
        lock.unlock()
        try launch()
    }

    private func launch() throws {
        let t = try factory.makeTransport()
        let id = UUID()
        lock.lock()
        transport = t
        transportID = id
        ready = false
        lock.unlock()
        try t.start(onMessage: { [weak self] m in self?.receive(m, from: id) }, onClose: { [weak self] reason in self?.closed(reason, from: id) })
        t.send(.configure(config))
    }

    func waitReady(timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if ready { lock.unlock(); c.resume(returning: true); return }
            readyWaiters.append(c)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let w = self.readyWaiters
                self.readyWaiters = []
                self.lock.unlock()
                for x in w { x.resume(returning: self.isReady) }
            }
        }
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    func stop() {
        lock.lock()
        stopped = true
        let t = transport
        transport = nil
        let all = pending
        pending.removeAll()
        let lw = loadWaiters
        loadWaiters.removeAll()
        lock.unlock()
        t?.terminate()
        for (_, p) in all { p.timer?.cancel(); p.continuation.resume(returning: .failure(ModCallError("hostStopped", "mod host stopped"))) }
        for (_, ws) in lw { for w in ws { w.resume(returning: ModCallError("hostStopped", "mod host stopped")) } }
    }

    private func send(_ m: ModAppToHost) {
        lock.lock()
        let t = transport
        lock.unlock()
        t?.send(m)
    }

    func load(_ mod: ActiveMod, request: ModLoadRequest) async -> ModCallError? {
        let key = "\(request.modId)#\(request.generation)"
        return await withCheckedContinuation { (c: CheckedContinuation<ModCallError?, Never>) in
            lock.lock()
            loads[key] = request
            mods[key] = mod
            loadWaiters[key, default: []].append(c)
            lock.unlock()
            send(.load(request))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(config.loadBudgetMs + 5000)) { [weak self] in
                self?.resolveLoad(key, ModCallError("loadTimeout", "mod did not load in time"))
            }
        }
    }

    private func resolveLoad(_ key: String, _ error: ModCallError?) {
        lock.lock()
        let ws = loadWaiters.removeValue(forKey: key) ?? []
        if error != nil { loads.removeValue(forKey: key); mods.removeValue(forKey: key) }
        lock.unlock()
        for w in ws { w.resume(returning: error) }
    }

    func unload(_ mod: ActiveMod) {
        let key = "\(mod.id)#\(mod.generation)"
        lock.lock()
        loads.removeValue(forKey: key)
        mods.removeValue(forKey: key)
        let mine = pending.filter { $0.value.invocation.mod === mod }
        for k in mine.keys { pending.removeValue(forKey: k) }
        lock.unlock()
        for (_, p) in mine { p.timer?.cancel(); p.continuation.resume(returning: .failure(ModCallError("unloaded", "mod unloaded"))) }
        send(.unload(modId: mod.id, generation: mod.generation))
    }

    func invoke(_ invocation: ModInvocation, input: JSONValue, context: JSONValue, deadlineMs: Int) async -> ModCallOutcome {
        let request = ModInvokeRequest(
            invocationId: invocation.id, parentInvocationId: invocation.parent?.id, modId: invocation.mod.id,
            generation: invocation.mod.generation, handler: invocation.handler, context: context, input: input, deadlineMs: deadlineMs
        )
        return await withCheckedContinuation { (c: CheckedContinuation<ModCallOutcome, Never>) in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + .milliseconds(deadlineMs + deadlineGraceMs))
            timer.setEventHandler { [weak self] in self?.deadlineMissed(invocation.id) }
            lock.lock()
            if stopped {
                lock.unlock()
                c.resume(returning: .failure(ModCallError("hostStopped", "mod host stopped")))
                return
            }
            pending[invocation.id] = Pending(invocation: invocation, continuation: c, timer: timer)
            lock.unlock()
            timer.resume()
            send(.invoke(request))
        }
    }

    func cancel(_ invocationId: String) { send(.cancel(invocationId: invocationId)) }

    private func complete(_ invocationId: String, _ outcome: ModCallOutcome) {
        lock.lock()
        let p = pending.removeValue(forKey: invocationId)
        lock.unlock()
        guard let p else { return }
        p.timer?.cancel()
        p.continuation.resume(returning: outcome)
    }

    private func deadlineMissed(_ invocationId: String) {
        lock.lock()
        let p = pending[invocationId]
        lock.unlock()
        guard let p else { return }
        hostFailed(offender: p.invocation, reason: "\(p.invocation.mod.id).\(p.invocation.handler) produced no result before its deadline", kind: .hung)
    }

    func benchmark(iterations: Int) async -> UInt64? {
        await withCheckedContinuation { (c: CheckedContinuation<UInt64?, Never>) in
            lock.withLock { benchmarkWaiter = c }
            send(.benchmark(iterations: iterations))
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self else { return }
                let w = self.lock.withLock { () -> CheckedContinuation<UInt64?, Never>? in let w = self.benchmarkWaiter; self.benchmarkWaiter = nil; return w }
                w?.resume(returning: nil)
            }
        }
    }

    func probe(paths: [String], hosts: [String], spawn: String?) async -> [String: String] {
        await withCheckedContinuation { (c: CheckedContinuation<[String: String], Never>) in
            lock.withLock { probeWaiter = c }
            send(.probe(paths: paths, hosts: hosts, spawn: spawn))
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self else { return }
                let w = self.lock.withLock { () -> CheckedContinuation<[String: String], Never>? in let w = self.probeWaiter; self.probeWaiter = nil; return w }
                w?.resume(returning: [:])
            }
        }
    }

    func ping() async -> ModHostStats? {
        send(.ping(1))
        try? await Task.sleep(nanoseconds: 200_000_000)
        return lock.withLock { lastStats }
    }

    private func receive(_ m: ModHostToApp, from id: UUID) {
        lock.lock()
        let current = id == transportID
        lock.unlock()
        guard current else { return }
        switch m {
        case .ready(let info):
            lock.lock()
            ready = true
            hostInfo = info
            let w = readyWaiters
            readyWaiters = []
            lock.unlock()
            for x in w { x.resume(returning: true) }
            onEvent?(ModHostEvent(kind: .started, modId: nil, detail: "pid \(info.pid) sandboxed=\(info.sandboxed)"))
        case .loaded(let modId, let generation, let error):
            resolveLoad("\(modId)#\(generation)", error)
        case .result(let invocationId, let outcome):
            complete(invocationId, outcome)
        case .call(let call):
            lock.lock()
            let p = pending[call.invocationId]
            lock.unlock()
            guard let inv = p?.invocation, inv.mod.id == call.modId, inv.mod.generation == call.generation else {
                send(.callResult(callId: call.callId, outcome: .failure(.denied("call does not belong to an active invocation of \(call.modId)"))))
                return
            }
            let handler = callHandler
            Task.detached { [weak self] in
                let outcome = await handler.handle(call, invocation: inv)
                self?.send(.callResult(callId: call.callId, outcome: outcome))
            }
        case .hung(let report):
            lock.lock()
            let offender = report.invocationId.flatMap { pending[$0]?.invocation }
            lock.unlock()
            hostFailed(offender: offender, reason: "\(report.modId).\(report.handler ?? "load") ran \(report.elapsedMs) ms without yielding", kind: .hung)
        case .stats(let s), .pong(_, let s):
            lock.lock()
            lastStats = s
            let busy = !pending.isEmpty || !loadWaiters.isEmpty
            lock.unlock()
            if s.footprintBytes > UInt64(config.memoryLimitMiB) * 1024 * 1024, !busy {
                onEvent?(ModHostEvent(kind: .memoryRestart, modId: nil, detail: "footprint \(s.footprintBytes / 1024 / 1024) MiB"))
                restart(reason: "memory threshold", countsAsFailure: false, offender: nil)
            }
        case .probeResult(let r):
            let w = lock.withLock { () -> CheckedContinuation<[String: String], Never>? in let w = probeWaiter; probeWaiter = nil; return w }
            w?.resume(returning: r)
        case .benchmark(_, let ns):
            let w = lock.withLock { () -> CheckedContinuation<UInt64?, Never>? in let w = benchmarkWaiter; benchmarkWaiter = nil; return w }
            w?.resume(returning: ns)
        }
    }

    private func closed(_ reason: ModHostTransportClose, from id: UUID) {
        lock.lock()
        let current = id == transportID
        let isStopped = stopped
        let busy = restarting
        lock.unlock()
        guard current, !isStopped, !busy else { return }
        lock.lock()
        let offender = pending.values.sorted { $0.invocation.started > $1.invocation.started }.first?.invocation
        lock.unlock()
        hostFailed(offender: offender, reason: "host exited: \(reason)", kind: .crashed)
    }

    private func hostFailed(offender: ModInvocation?, reason: String, kind: ModHostEvent.Kind) {
        onEvent?(ModHostEvent(kind: kind, modId: offender?.mod.id, detail: reason))
        restart(reason: reason, countsAsFailure: true, offender: offender)
    }

    private func restart(reason: String, countsAsFailure: Bool, offender: ModInvocation?) {
        lock.lock()
        guard !restarting, !stopped else { lock.unlock(); return }
        restarting = true
        let old = transport
        transport = nil
        transportID = UUID()
        ready = false
        let failed = pending
        pending.removeAll()
        let lw = loadWaiters
        loadWaiters.removeAll()
        lock.unlock()
        old?.terminate()
        for (_, p) in failed {
            p.timer?.cancel()
            let isOffender = p.invocation.id == offender?.id
            p.continuation.resume(returning: .failure(ModCallError(isOffender ? "quarantined" : "hostRestarted", reason)))
        }
        for (_, ws) in lw { for w in ws { w.resume(returning: ModCallError("hostRestarted", reason)) } }
        if countsAsFailure { onHostFailure?(offender, reason) }
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        if isStopped { lock.lock(); restarting = false; lock.unlock(); return }
        do { try launch() } catch {
            lock.withLock { restarting = false }
            return
        }
        lock.lock()
        let reloads = loads
        restarting = false
        lock.unlock()
        for (key, r) in reloads {
            lock.lock()
            loadWaiters[key] = loadWaiters[key] ?? []
            lock.unlock()
            send(.load(r))
        }
        onRestarted?()
    }

    func forceRestart(reason: String) { restart(reason: reason, countsAsFailure: false, offender: nil) }
}
