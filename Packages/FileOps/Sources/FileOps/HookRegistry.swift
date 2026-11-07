import Foundation
import os

enum HookCallFailure: Error, Sendable {
    case timedOut
    case threw(String)
}

private final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var stored: Result<T, HookCallFailure>?
    private var continuation: CheckedContinuation<Result<T, HookCallFailure>, Never>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ c: CheckedContinuation<Result<T, HookCallFailure>, Never>) {
        lock.lock()
        if let stored {
            lock.unlock()
            c.resume(returning: stored)
        } else {
            continuation = c
            lock.unlock()
        }
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        let cancelNow = finished
        if !cancelNow { tasks.append(task) }
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func finish(_ result: Result<T, HookCallFailure>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        if c == nil { stored = result }
        let pending = tasks
        tasks = []
        lock.unlock()
        c?.resume(returning: result)
        pending.forEach { $0.cancel() }
    }
}

final class HookEvaluation: @unchecked Sendable {
    var settled = Set<UInt64>()
    var authorized = false
}

enum HookVerdict: Sendable {
    case allow
    case denied(HookDenial)
    case needsDecision(PausedOperationInfo, UInt64)
}

struct GuardedResult<T> {
    var value: T
    var urls: [URL?]
}

public final class FileOperationHookRegistry: @unchecked Sendable {
    public static let shared = FileOperationHookRegistry()

    public typealias RegistrationToken = FileOpsRegistrationToken

    struct Entry {
        let seq: UInt64
        let hook: FileOperationHook
        let owner: String
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextSeq: UInt64 = 0
    private var timeoutValue: TimeInterval = 0.25
    private var recursionLimitValue = 3
    private var authorizerValue: OperationAuthorizer = AllowAllAuthorizer()
    private var presenterValue: HookDecisionPresenting?
    private var logValue: (@Sendable (String) -> Void)?
    private var afterTail: Task<Void, Never>?
    private let logger = Logger(subsystem: "betterfinder.fileops", category: "hooks")

    public init() {}

    public var defaultTimeout: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return timeoutValue }
        set { lock.lock(); timeoutValue = newValue; lock.unlock() }
    }

    public var recursionLimit: Int {
        get { lock.lock(); defer { lock.unlock() }; return recursionLimitValue }
        set { lock.lock(); recursionLimitValue = newValue; lock.unlock() }
    }

    public var authorizer: OperationAuthorizer {
        get { lock.lock(); defer { lock.unlock() }; return authorizerValue }
        set { lock.lock(); authorizerValue = newValue; lock.unlock() }
    }

    public var decisionPresenter: HookDecisionPresenting? {
        get { lock.lock(); defer { lock.unlock() }; return presenterValue }
        set { lock.lock(); presenterValue = newValue; lock.unlock() }
    }

    public var logHandler: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return logValue }
        set { lock.lock(); logValue = newValue; lock.unlock() }
    }

    public var hookCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var registeredHookIDs: [String] { orderedEntries().map(\.hook.id) }

    public var isIntercepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return !entries.isEmpty || !(authorizerValue is AllowAllAuthorizer)
    }

    @discardableResult
    public func register(_ hook: FileOperationHook, owner: String, timeout: TimeInterval? = nil) -> RegistrationToken {
        lock.lock()
        nextSeq += 1
        let seq = nextSeq
        entries.append(Entry(seq: seq, hook: hook, owner: owner, timeout: timeout))
        lock.unlock()
        return FileOpsRegistrationToken { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.entries.removeAll { $0.seq == seq }
            self.lock.unlock()
        }
    }

    public func throwIfAsyncRequired() throws {
        if isIntercepting { throw HooksRequireAsync() }
    }

    public func waitForAfterHooks() async {
        await currentAfterTail()?.value
    }

    private func currentAfterTail() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return afterTail
    }

    func orderedEntries() -> [Entry] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.sorted {
            if $0.hook.priority != $1.hook.priority { return $0.hook.priority < $1.hook.priority }
            if $0.hook.id != $1.hook.id { return $0.hook.id < $1.hook.id }
            return $0.seq < $1.seq
        }
    }

    func log(_ message: String) {
        logger.error("\(message, privacy: .public)")
        logHandler?(message)
    }

    static func resolveContext(origin: OperationOrigin?, explicitDepth: Int) -> (origin: OperationOrigin, depth: Int) {
        let requested = origin ?? .user
        guard let ambient = HookContext.current else { return (requested, max(0, explicitDepth)) }
        return (requested.isMod ? requested : .mod(ambient.owner), max(explicitDepth, ambient.depth + 1))
    }

    func recursionViolation(_ snapshot: OperationSnapshot) -> OperationRecursionLimitExceeded? {
        let limit = recursionLimit
        return snapshot.recursionDepth > limit ? OperationRecursionLimitExceeded(depth: snapshot.recursionDepth, limit: limit) : nil
    }

    func invoke<T: Sendable>(owner: String, depth: Int, timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async -> Result<T, HookCallFailure> {
        let box = RaceBox<T>()
        let nanos = UInt64(max(0, timeout) * 1_000_000_000)
        let info = HookContext.Info(owner: owner, depth: depth)
        return await withCheckedContinuation { (c: CheckedContinuation<Result<T, HookCallFailure>, Never>) in
            box.install(c)
            let worker = HookContext.$current.withValue(info) {
                Task {
                    do {
                        box.finish(.success(try await work()))
                    } catch {
                        box.finish(.failure(.threw(error.localizedDescription)))
                    }
                }
            }
            box.track(worker)
            let timer = Task {
                do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                box.finish(.failure(.timedOut))
            }
            box.track(timer)
        }
    }

    func evaluate(_ snapshot: OperationSnapshot, state: HookEvaluation) async -> HookVerdict {
        if !state.authorized {
            if case .deny(let reason) = await authorizer.authorize(snapshot) {
                return .denied(HookDenial(hookID: "authorizer", owner: "Permissions", reason: reason.isEmpty ? "not permitted" : reason))
            }
            state.authorized = true
        }
        for entry in orderedEntries() where !state.settled.contains(entry.seq) {
            let timeout = entry.timeout ?? entry.hook.timeout ?? defaultTimeout
            let hook = entry.hook
            let result = await invoke(owner: entry.owner, depth: snapshot.recursionDepth, timeout: timeout) { try await hook.before(snapshot) }
            switch result {
            case .success(.allow):
                state.settled.insert(entry.seq)
            case .success(.deny(let reason)):
                return .denied(HookDenial(hookID: hook.id, owner: entry.owner, reason: reason.isEmpty ? "no reason given" : reason))
            case .failure(.timedOut):
                log("before-hook \(hook.id) timed out after \(Int(timeout * 1000)) ms")
                return .needsDecision(PausedOperationInfo(snapshot: snapshot, hookID: hook.id, owner: entry.owner, reason: "didn’t respond within \(Int(timeout * 1000)) ms"), entry.seq)
            case .failure(.threw(let message)):
                log("before-hook \(hook.id) failed: \(message)")
                return .needsDecision(PausedOperationInfo(snapshot: snapshot, hookID: hook.id, owner: entry.owner, reason: "failed: \(message)"), entry.seq)
            }
        }
        return .allow
    }

    func admit(_ snapshot: OperationSnapshot) async throws {
        if let violation = recursionViolation(snapshot) { throw violation }
        let state = HookEvaluation()
        while true {
            switch await evaluate(snapshot, state: state) {
            case .allow:
                return
            case .denied(let denial):
                throw HookDeniedError(denial: denial)
            case .needsDecision(let info, let seq):
                guard let presenter = decisionPresenter else { throw HookDecisionRequired(info: info) }
                switch await presenter.decide(info) {
                case .runAnyway: state.settled.insert(seq)
                case .cancel: throw CocoaError(.userCancelled)
                }
            }
        }
    }

    func dispatchAfter(_ snapshot: OperationSnapshot, _ outcome: OperationOutcome) {
        let chain = orderedEntries()
        guard !chain.isEmpty else { return }
        lock.lock()
        let previous = afterTail
        afterTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for entry in chain {
                let timeout = entry.timeout ?? entry.hook.timeout ?? self.defaultTimeout
                let hook = entry.hook
                let result = await self.invoke(owner: entry.owner, depth: snapshot.recursionDepth, timeout: timeout) { try await hook.after(snapshot, outcome) }
                if case .failure(let failure) = result {
                    switch failure {
                    case .timedOut: self.log("after-hook \(hook.id) timed out")
                    case .threw(let message): self.log("after-hook \(hook.id) failed: \(message)")
                    }
                }
            }
        }
        lock.unlock()
    }

    func makeSnapshot(kind: OperationKind, items: [OperationItem], origin: OperationOrigin?, recursionDepth: Int, tags: [String]? = nil) -> OperationSnapshot {
        let resolved = Self.resolveContext(origin: origin, explicitDepth: recursionDepth)
        return OperationSnapshot(kind: kind, items: items, origin: resolved.origin, recursionDepth: resolved.depth, tags: tags)
    }

    func guardedAsync<T>(kind: OperationKind, items: [OperationItem], origin: OperationOrigin?, recursionDepth: Int = 0, body: () async throws -> GuardedResult<T>) async throws -> T {
        guard isIntercepting else { return try await body().value }
        let snapshot = makeSnapshot(kind: kind, items: items, origin: origin, recursionDepth: recursionDepth)
        try await admit(snapshot)
        do {
            let result = try await body()
            let outcomes = items.enumerated().map { index, item in
                OperationItemOutcome(index: index, item: item, result: .committed(index < result.urls.count ? result.urls[index] : nil))
            }
            dispatchAfter(snapshot, OperationOutcome(operationID: snapshot.operationID, attemptID: snapshot.attemptID, items: outcomes))
            return result.value
        } catch {
            let failure = items.enumerated().map { index, item in
                OperationItemOutcome(index: index, item: item, result: .failed(.from(error, url: item.primaryURL)))
            }
            dispatchAfter(snapshot, OperationOutcome(operationID: snapshot.operationID, attemptID: snapshot.attemptID, items: failure, errors: failure.compactMap { if case .failed(let e) = $0.result { return e } else { return nil } }))
            throw error
        }
    }

    func guarded<T>(kind: OperationKind, items: [OperationItem], origin: OperationOrigin?, recursionDepth: Int = 0, tags: [String]? = nil, body: () throws -> GuardedResult<T>) async throws -> T {
        guard isIntercepting else { return try body().value }
        let snapshot = makeSnapshot(kind: kind, items: items, origin: origin, recursionDepth: recursionDepth, tags: tags)
        try await admit(snapshot)
        do {
            let result = try body()
            let outcomes = items.enumerated().map { index, item in
                OperationItemOutcome(index: index, item: item, result: .committed(index < result.urls.count ? result.urls[index] : nil))
            }
            dispatchAfter(snapshot, OperationOutcome(operationID: snapshot.operationID, attemptID: snapshot.attemptID, items: outcomes))
            return result.value
        } catch {
            let failure = items.enumerated().map { index, item in
                OperationItemOutcome(index: index, item: item, result: .failed(.from(error, url: item.primaryURL)))
            }
            dispatchAfter(snapshot, OperationOutcome(operationID: snapshot.operationID, attemptID: snapshot.attemptID, items: failure, errors: failure.compactMap { if case .failed(let e) = $0.result { return e } else { return nil } }))
            throw error
        }
    }
}
