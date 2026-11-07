import AppKit
import Combine
import Foundation
import FSCore

public enum FileOperationKind: Sendable, Hashable {
    case copy(sources: [URL], destination: URL)
    case move(sources: [URL], destination: URL)
    case trash(items: [URL])
    case duplicate(items: [URL])
}

public struct FileOperationProgress: Sendable, Hashable {
    public var completedUnits: Int64
    public var totalUnits: Int64
    public var currentItem: String?
    public var itemsCompleted: Int = 0
    public var itemsTotal: Int = 0
    public var bytesPerSecond: Double = 0
    public var estimatedSecondsRemaining: TimeInterval?

    public init(completedUnits: Int64, totalUnits: Int64, currentItem: String?) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.currentItem = currentItem
    }

    public var fractionCompleted: Double {
        if totalUnits > 0 { return min(1, Double(completedUnits) / Double(totalUnits)) }
        if itemsTotal > 0 { return min(1, Double(itemsCompleted) / Double(itemsTotal)) }
        return 0
    }
}

public enum FileOperationState: Sendable, Hashable {
    case queued, running, paused, awaitingDecision(String), finished, failed(String), cancelled
}

@MainActor
public final class FileOperation: ObservableObject, Identifiable {
    public let id = UUID()
    public internal(set) var operationID: UUID
    public let attemptID = UUID()
    public internal(set) var origin: OperationOrigin = .user
    public internal(set) var recursionDepth = 0
    public internal(set) var hookDenial: HookDenial?
    public internal(set) var pausedInfo: PausedOperationInfo?
    public let kind: FileOperationKind
    @Published public internal(set) var state: FileOperationState = .queued
    @Published public internal(set) var progress = FileOperationProgress(completedUnits: 0, totalUnits: 0, currentItem: nil)
    @Published public internal(set) var errors: [FileOperationItemError] = []
    @Published public internal(set) var skippedCount = 0
    public internal(set) var resultingURLs: [URL] = []
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?

    var plans: [ItemPlan] = []
    var itemResults: [URL?] = []
    var completedIndexes = Set<Int>()
    let control = OperationControl()
    var resolver: ConflictResolver?
    var laneKey: Int32 = 0
    var registersUndo = true
    var onFinish: ((FileOperation) -> Void)?
    weak var queue: FileOperationQueue?
    let decisionLatch = DecisionLatch()
    var hookItems: [OperationItem] = []
    var transferRequest: ResourceTransferRequest?
    var transferProvider: ResourceTransferProvider?
    var transferTask: Task<Void, Never>?
    var transferResume: [ResourceID: TransferCommit] = [:]
    public internal(set) var undoUnavailableReason: String?
    public internal(set) var transferReport: ResourceTransferReport?
    var customTitle: String?
    var journal: [UndoRecord] = []
    var undoBlockedReason: String?
    var ledger: CommitLedger?

    public var isResourceTransfer: Bool { transferRequest != nil }
    public var resultingResources: [ResourceID] { transferReport?.committed ?? [] }

    init(kind: FileOperationKind) {
        self.kind = kind
        self.operationID = id
    }

    func snapshot() -> OperationSnapshot {
        if hookItems.count != plans.count {
            hookItems = plans.map { OperationItem(source: $0.source, destination: $0.destination) }
        }
        let opKind: OperationKind
        switch kind {
        case .copy: opKind = .copy
        case .move: opKind = .move
        case .trash: opKind = .trash
        case .duplicate: opKind = .duplicate
        }
        return OperationSnapshot(operationID: operationID, attemptID: attemptID, kind: opKind, items: hookItems, origin: origin, recursionDepth: recursionDepth)
    }

    func outcome(from run: RunOutcome) -> OperationOutcome {
        let snap = snapshot()
        var items: [OperationItemOutcome] = []
        for (i, item) in snap.items.enumerated() {
            let result: OperationItemOutcome.Result
            if run.completed.contains(i) {
                result = run.skipped.contains(i) ? .skipped : .committed(i < run.results.count ? run.results[i] : nil)
            } else if let err = run.errors.first(where: { FS.isDescendant($0.url, of: plans[i].source) }) {
                result = .failed(err)
            } else {
                result = .skipped
            }
            items.append(OperationItemOutcome(index: i, item: item, result: result))
        }
        return OperationOutcome(operationID: operationID, attemptID: attemptID, items: items, errors: run.errors, aborted: run.abort)
    }

    public func overrideHooks() {
        guard case .awaitingDecision = state else { return }
        decisionLatch.resolve(.runAnyway)
    }

    public var title: String {
        if let customTitle { return customTitle }
        if let request = transferRequest {
            let n = request.items.count
            let dest = request.destinationDirectory.map { $0.isRoot ? (ResourceProviderRegistry.shared.provider(for: $0)?.displayName ?? "server") : $0.name } ?? "destination"
            let verb = request.mode == .move ? "Moving" : "Copying"
            return "\(verb) \(n) item\(n == 1 ? "" : "s") to \(dest)"
        }
        switch kind {
        case .copy(let s, let d): return "Copying \(s.count) item\(s.count == 1 ? "" : "s") to \(d.lastPathComponent)"
        case .move(let s, let d): return "Moving \(s.count) item\(s.count == 1 ? "" : "s") to \(d.lastPathComponent)"
        case .trash(let s): return "Moving \(s.count) item\(s.count == 1 ? "" : "s") to Trash"
        case .duplicate(let s): return "Duplicating \(s.count) item\(s.count == 1 ? "" : "s")"
        }
    }

    public var isActive: Bool {
        switch state {
        case .queued, .running, .paused, .awaitingDecision: return true
        default: return false
        }
    }

    public var isPaused: Bool { state == .paused }

    public var canRetry: Bool {
        guard !isActive else { return false }
        return plans.indices.contains { !completedIndexes.contains($0) } && (state != .finished || !errors.isEmpty)
    }

    public var failedURLs: [URL] { errors.map(\.url) }

    func compact() {
        guard !isActive, !canRetry else { return }
        plans = []
        hookItems = []
        journal = []
        ledger = nil
        resolver = nil
        onFinish = nil
        transferProvider = nil
        transferTask = nil
        transferResume = [:]
    }

    public var summary: String {
        switch state {
        case .queued: return "Waiting…"
        case .running: return progress.currentItem ?? "Working…"
        case .paused: return "Paused"
        case .awaitingDecision(let reason): return "Waiting for your decision: \(reason)"
        case .cancelled: return "Cancelled"
        case .failed(let m): return m
        case .finished:
            if errors.isEmpty { return skippedCount > 0 ? "Finished, \(skippedCount) skipped" : "Finished" }
            return "Finished with \(errors.count) error\(errors.count == 1 ? "" : "s")"
        }
    }

    public func pause() {
        guard state == .running || state == .queued else { return }
        control.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        control.resume()
        state = startedAt == nil ? .queued : .running
        queue?.pump()
    }

    public func cancel() {
        guard isActive else { return }
        queue?.cancel(self)
    }

    @discardableResult
    public func retry() -> FileOperation? { queue?.retry(self) }

    @discardableResult
    public func retryFailed() -> FileOperation? { queue?.retry(self) }
}

public enum OperationsAttention: Sendable, Hashable {
    case none
    case completed(Int)
    case failed(Int)
}

@MainActor
public final class FileOperationQueue: ObservableObject {
    public static let shared = FileOperationQueue()

    @Published public private(set) var operations: [FileOperation] = []
    @Published public private(set) var overallProgress: Double?
    @Published public private(set) var activeOperationCount = 0
    public var undoManager: UndoManager? = UndoManager()
    public var conflictResolver: ConflictResolver?
    public var defaultConflictChoice: ConflictChoice = .keepBoth
    public var trashService: TrashService
    public var onOperationFinished: ((FileOperation) -> Void)?
    public var hooks: FileOperationHookRegistry = .shared
    @Published public private(set) var attention: OperationsAttention = .none
    public var historyLimit = 100
    public var historyMaxAge: TimeInterval = 24 * 60 * 60
    public var announcesStateChanges = true
    var ambientOrigin: OperationOrigin = .user
    var forcesCopyMoves = false
    var afterCopyProbe: (@Sendable (URL) -> Void)?
    let fallible = FallibleUndoState()
    @Published public private(set) var backgroundMutationCount = 0
    var undoWorkInFlight = 0 {
        didSet { backgroundMutationCount = max(0, backgroundMutationCount + undoWorkInFlight - oldValue) }
    }
    private var active: [ObjectIdentifier: FileOperation] = [:]
    private var pendingAnnouncements: [String] = []

    private var pending: [Int32: [FileOperation]] = [:]
    private var running: [Int32: FileOperation] = [:]
    private var batch: [UUID: Double] = [:]

    public init(trashService: TrashService = .shared) {
        self.trashService = trashService
    }

    public func beginBackgroundMutation() {
        backgroundMutationCount += 1
    }

    public func endBackgroundMutation() {
        backgroundMutationCount = max(0, backgroundMutationCount - 1)
    }

    public func trackBackgroundMutation<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        beginBackgroundMutation()
        defer { endBackgroundMutation() }
        return await work()
    }

    nonisolated static func trackingShared<T>(_ work: () async throws -> T) async throws -> T {
        await MainActor.run { shared.beginBackgroundMutation() }
        do {
            let value = try await work()
            await MainActor.run { shared.endBackgroundMutation() }
            return value
        } catch {
            await MainActor.run { shared.endBackgroundMutation() }
            throw error
        }
    }

    @discardableResult
    public func enqueue(_ kind: FileOperationKind, resolver: ConflictResolver? = nil, origin: OperationOrigin? = nil, recursionDepth: Int = 0) -> FileOperation {
        if let request = Self.resourceRequest(for: kind, origin: origin ?? ambientOrigin) {
            return enqueueTransfer(request, resolver: resolver, recursionDepth: recursionDepth)
        }
        return submit(kind: kind, plans: Self.plans(for: kind), registersUndo: true, resolver: resolver, onFinish: nil, origin: origin, recursionDepth: recursionDepth)
    }

    nonisolated static func resourceRequest(for kind: FileOperationKind, origin: OperationOrigin) -> ResourceTransferRequest? {
        let mode: ResourceTransferRequest.Mode
        let sources: [URL]
        let dest: URL
        switch kind {
        case .copy(let s, let d): mode = .copy; sources = s; dest = d
        case .move(let s, let d): mode = .move; sources = s; dest = d
        default: return nil
        }
        guard !sources.isEmpty, (sources + [dest]).contains(where: { !$0.isFileURL }) else { return nil }
        let ids = sources.compactMap(ResourceID.init(uri:))
        guard ids.count == sources.count, let d = ResourceID(uri: dest) else { return nil }
        return ResourceTransferRequest(mode: mode, sources: ids, into: d, origin: origin)
    }

    public var transferProviders: ResourceTransferProviderRegistry = .shared
    public var undoUnavailableMessage = "Undo isn’t available for operations on remote servers."

    @discardableResult
    public func enqueueTransfer(_ request: ResourceTransferRequest, resolver: ConflictResolver? = nil, provider: ResourceTransferProvider? = nil, recursionDepth: Int = 0) -> FileOperation {
        submitTransfer(request, resolver: resolver, provider: provider, onFinish: nil, origin: request.origin, recursionDepth: recursionDepth, operationID: nil)
    }

    func submitTransfer(_ request: ResourceTransferRequest, resolver: ConflictResolver?, provider: ResourceTransferProvider?, onFinish: ((FileOperation) -> Void)?, origin: OperationOrigin, recursionDepth: Int, operationID: UUID?, resume: [ResourceID: TransferCommit] = [:]) -> FileOperation {
        let fallback = URL(fileURLWithPath: "/")
        let sources = request.items.map { $0.source ?? $0.sourceResource?.uri ?? fallback }
        let destDir = request.destinationDirectory?.uri ?? fallback
        let kind: FileOperationKind = request.mode == .move ? .move(sources: sources, destination: destDir) : .copy(sources: sources, destination: destDir)
        let plans = request.items.map { ItemPlan(action: request.mode == .move ? .move : .copy, source: $0.source ?? $0.sourceResource?.uri ?? fallback, destination: $0.destination ?? $0.destinationResource?.uri, forcedChoice: nil) }
        let op = FileOperation(kind: kind)
        op.transferRequest = request
        op.transferProvider = provider ?? transferProviders.provider(for: request)
        op.hookItems = request.items
        op.transferResume = resume
        op.undoUnavailableReason = undoUnavailableMessage
        return submit(prepared: op, plans: plans, registersUndo: false, resolver: resolver, onFinish: onFinish, origin: origin, recursionDepth: recursionDepth, operationID: operationID, laneKey: Self.laneKey(for: request))
    }

    nonisolated static func laneKey(for request: ResourceTransferRequest) -> Int32 {
        let ids = Set(request.items.flatMap { [$0.sourceResource?.providerID, $0.destinationResource?.providerID].compactMap { $0 } }).sorted().joined(separator: "|")
        var h: UInt32 = 5381
        for b in ids.utf8 { h = (h &* 33) &+ UInt32(b) }
        return -Int32(truncatingIfNeeded: (h & 0x3FFF_FFFF) | 1)
    }

    func submit(kind: FileOperationKind, plans: [ItemPlan], registersUndo: Bool, resolver: ConflictResolver?, onFinish: ((FileOperation) -> Void)?, origin: OperationOrigin? = nil, recursionDepth: Int = 0, operationID: UUID? = nil) -> FileOperation {
        submit(prepared: FileOperation(kind: kind), plans: plans, registersUndo: registersUndo, resolver: resolver, onFinish: onFinish, origin: origin, recursionDepth: recursionDepth, operationID: operationID, laneKey: Self.laneKey(for: plans))
    }

    func submit(prepared op: FileOperation, plans: [ItemPlan], registersUndo: Bool, resolver: ConflictResolver?, onFinish: ((FileOperation) -> Void)?, origin: OperationOrigin?, recursionDepth: Int, operationID: UUID?, laneKey: Int32) -> FileOperation {
        let context = FileOperationHookRegistry.resolveContext(origin: origin ?? ambientOrigin, explicitDepth: recursionDepth)
        op.origin = context.origin
        op.recursionDepth = context.depth
        if let operationID { op.operationID = operationID }
        op.plans = plans
        op.resolver = resolver
        op.registersUndo = registersUndo
        op.onFinish = onFinish
        op.queue = self
        op.laneKey = laneKey
        operations.append(op)
        active[ObjectIdentifier(op)] = op
        if let violation = hooks.recursionViolation(op.snapshot()) {
            batch[op.id] = 0
            reject(op, denial: HookDenial(hookID: "recursion-limit", owner: "BetterFinder", reason: violation.localizedDescription))
            return op
        }
        pending[op.laneKey, default: []].append(op)
        batch[op.id] = 0
        refreshOverall()
        pump()
        return op
    }

    nonisolated static func plans(for kind: FileOperationKind) -> [ItemPlan] {
        switch kind {
        case .copy(let sources, let dest):
            return sources.map { ItemPlan(action: .copy, source: $0, destination: dest.appendingPathComponent($0.lastPathComponent), forcedChoice: nil) }
        case .move(let sources, let dest):
            return sources.map { ItemPlan(action: .move, source: $0, destination: dest.appendingPathComponent($0.lastPathComponent), forcedChoice: nil) }
        case .trash(let items):
            return items.map { ItemPlan(action: .trash, source: $0, destination: nil, forcedChoice: nil) }
        case .duplicate(let items):
            return items.map {
                let target = uniqueDestination(for: duplicateName($0), in: $0.deletingLastPathComponent())
                return ItemPlan(action: .copy, source: $0, destination: target, forcedChoice: .keepBoth)
            }
        }
    }

    nonisolated static func laneKey(for plans: [ItemPlan]) -> Int32 {
        guard let first = plans.first else { return 0 }
        let probe = first.destination?.deletingLastPathComponent() ?? first.source.deletingLastPathComponent()
        return FS.device(of: probe).map { Int32(truncatingIfNeeded: $0) } ?? 0
    }

    func pump() {
        for lane in Array(pending.keys) {
            guard running[lane] == nil, var list = pending[lane] else { continue }
            guard let idx = list.firstIndex(where: { !$0.control.isPaused && $0.state == .queued }) else { continue }
            let op = list.remove(at: idx)
            pending[lane] = list.isEmpty ? nil : list
            start(op)
        }
    }

    private enum Admission {
        case proceed
        case rejected(HookDenial)
        case cancelled
    }

    private func start(_ op: FileOperation) {
        running[op.laneKey] = op
        op.state = .running
        op.startedAt = Date()
        guard hooks.isIntercepting else {
            launch(op)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            switch await self.admit(op) {
            case .proceed: self.launch(op)
            case .rejected(let denial): self.reject(op, denial: denial)
            case .cancelled: self.reject(op, denial: nil)
            }
        }
    }

    private func admit(_ op: FileOperation) async -> Admission {
        let registry = hooks
        let snapshot = op.snapshot()
        let evaluation = HookEvaluation()
        while true {
            if op.control.isCancelled { return .cancelled }
            let verdict = await registry.evaluate(snapshot, state: evaluation)
            if op.control.isCancelled { return .cancelled }
            switch verdict {
            case .allow:
                return .proceed
            case .denied(let denial):
                return .rejected(denial)
            case .needsDecision(let info, let seq):
                op.decisionLatch.reset()
                op.pausedInfo = info
                op.state = .awaitingDecision(info.message)
                announce("\(op.title) needs your decision: \(info.message)")
                if op.control.isCancelled { op.decisionLatch.resolve(.cancel) }
                var presenterTask: Task<Void, Never>?
                if let presenter = registry.decisionPresenter {
                    presenterTask = Task { @MainActor [weak op] in
                        let decision = await presenter.decide(info)
                        guard !Task.isCancelled, let op else { return }
                        switch decision {
                        case .runAnyway: op.overrideHooks()
                        case .cancel: op.cancel()
                        }
                    }
                }
                let decision = await op.decisionLatch.wait()
                presenterTask?.cancel()
                op.pausedInfo = nil
                switch decision {
                case .cancel:
                    return .cancelled
                case .runAnyway:
                    evaluation.settled.insert(seq)
                    if case .awaitingDecision = op.state { op.state = op.control.isPaused ? .paused : .running }
                }
            }
        }
    }

    private func reject(_ op: FileOperation, denial: HookDenial?) {
        op.itemResults = [URL?](repeating: nil, count: op.plans.count)
        op.completedIndexes = []
        op.resultingURLs = []
        op.pausedInfo = nil
        op.finishedAt = Date()
        if let denial {
            op.hookDenial = denial
            op.errors = op.plans.map { FileOperationItemError(url: $0.source, message: denial.message) }
            op.state = .failed(denial.message)
        } else {
            op.state = .cancelled
        }
        conclude(op)
    }

    private func launchTransfer(_ op: FileOperation, sink: @escaping @Sendable (FileOperationProgress) -> Void) {
        guard let request = op.transferRequest else { return }
        let control = op.control
        let resolver = op.resolver ?? conflictResolver
        guard let provider = op.transferProvider else {
            let message = "No transfer provider is available for these locations."
            let errors = op.plans.map { FileOperationItemError(url: $0.source, message: message) }
            finish(op, RunOutcome(results: [URL?](repeating: nil, count: op.plans.count), completed: [], skipped: [], errors: errors, abort: nil))
            return
        }
        let resume = op.transferResume
        op.transferTask = Task { [weak self] in
            let outcome: RunOutcome
            if let cross = provider as? CrossProviderTransfer {
                let report = await cross.run(request, resolver: resolver, control: ResourceTransferControl(isCancelled: { control.isCancelled }, isPaused: { control.isPaused }), resume: resume, progress: sink)
                op.transferReport = report
                outcome = Self.outcome(from: report)
            } else {
                do {
                    let urls = try await provider.transfer(request, progress: sink)
                    outcome = RunOutcome(results: urls, completed: Set(urls.indices), skipped: [], errors: [], abort: nil)
                } catch {
                    let errors = op.plans.map { FileOperationItemError.from(error, url: $0.source) }
                    outcome = RunOutcome(results: [URL?](repeating: nil, count: op.plans.count), completed: [], skipped: [], errors: errors, abort: control.isCancelled ? "Cancelled" : nil)
                }
            }
            self?.finish(op, outcome)
        }
    }

    nonisolated static func outcome(from report: ResourceTransferReport) -> RunOutcome {
        var results: [URL?] = []
        var completed = Set<Int>()
        var skipped = Set<Int>()
        for (i, r) in report.results.enumerated() {
            switch r {
            case .committed(let id):
                results.append(id.uri)
                completed.insert(i)
            case .skipped:
                results.append(nil)
                if report.aborted == nil { completed.insert(i); skipped.insert(i) }
            case .failed:
                results.append(nil)
            }
        }
        return RunOutcome(results: results, completed: completed, skipped: skipped, errors: report.errors, abort: report.aborted)
    }

    private func launch(_ op: FileOperation) {
        let sink: @Sendable (FileOperationProgress) -> Void = { [weak op, weak self] p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let op, op.isActive else { return }
                    op.progress = p
                    self?.noteProgress(op)
                }
            }
        }
        if op.transferRequest != nil {
            launchTransfer(op, sink: sink)
            return
        }
        let runner = OperationRunner(
            plans: op.plans,
            control: op.control,
            resolver: op.resolver ?? conflictResolver,
            defaultChoice: defaultConflictChoice,
            trashService: trashService,
            verify: UserDefaults.standard.bool(forKey: "verifyCopies"),
            sink: sink
        )
        runner.forcesCopyMoves = forcesCopyMoves
        runner.afterCopy = afterCopyProbe
        Task { [weak self] in
            let outcome: RunOutcome = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: runner.run()) }
            }
            self?.finish(op, outcome)
        }
    }

    private func finish(_ op: FileOperation, _ outcome: RunOutcome) {
        op.itemResults = outcome.results
        op.completedIndexes = outcome.completed
        op.resultingURLs = outcome.results.compactMap { $0 }
        op.errors = outcome.errors
        op.skippedCount = outcome.skipped.count
        op.finishedAt = Date()
        op.journal = outcome.journal
        op.undoBlockedReason = outcome.undoBlocked
        op.ledger = outcome.ledger
        if hooks.hookCount > 0, !outcome.completed.isEmpty || !outcome.errors.isEmpty {
            hooks.dispatchAfter(op.snapshot(), op.outcome(from: outcome))
        }
        if outcome.abort != nil {
            op.state = .cancelled
        } else if outcome.completed.isEmpty && !outcome.errors.isEmpty && !op.plans.isEmpty {
            op.state = .failed(outcome.errors.count == 1 ? outcome.errors[0].message : "\(outcome.errors.count) items failed")
        } else {
            var p = op.progress
            p.completedUnits = p.totalUnits
            p.itemsCompleted = p.itemsTotal
            p.bytesPerSecond = 0
            p.estimatedSecondsRemaining = nil
            p.currentItem = nil
            op.progress = p
            op.state = .finished
        }
        if op.registersUndo { registerUndo(for: op) }
        conclude(op)
    }

    private func conclude(_ op: FileOperation) {
        if running[op.laneKey] === op { running[op.laneKey] = nil }
        active[ObjectIdentifier(op)] = nil
        batch[op.id] = 1
        op.onFinish?(op)
        record(finished: op)
        refreshOverall()
        pump()
    }

    func record(finished op: FileOperation) {
        if !operations.contains(where: { $0 === op }) { operations.append(op) }
        noteAttention(op)
        announceFinished(op)
        onOperationFinished?(op)
        op.compact()
        pruneHistory()
    }

    private func noteAttention(_ op: FileOperation) {
        let failed: Bool
        switch op.state {
        case .failed: failed = true
        case .finished: failed = !op.errors.isEmpty
        default: return
        }
        switch attention {
        case .failed(let n): if failed { attention = .failed(n + 1) }
        case .completed(let n): attention = failed ? .failed(1) : .completed(n + 1)
        case .none: attention = failed ? .failed(1) : .completed(1)
        }
    }

    public func acknowledgeFinished() {
        if attention != .none { attention = .none }
    }

    public var hasActiveOperations: Bool { !active.isEmpty }

    private func pruneHistory() {
        let finished = operations.filter { !$0.isActive }
        let cutoff = Date().addingTimeInterval(-historyMaxAge)
        var drop = Set<ObjectIdentifier>()
        for op in finished where (op.finishedAt ?? .distantPast) < cutoff { drop.insert(ObjectIdentifier(op)) }
        var excess = finished.count - drop.count - max(0, historyLimit)
        if excess > 0 {
            for op in finished where excess > 0 && !op.canRetry && !drop.contains(ObjectIdentifier(op)) {
                drop.insert(ObjectIdentifier(op))
                excess -= 1
            }
            for op in finished where excess > 0 && !drop.contains(ObjectIdentifier(op)) {
                drop.insert(ObjectIdentifier(op))
                excess -= 1
            }
        }
        guard !drop.isEmpty else { return }
        operations.removeAll { drop.contains(ObjectIdentifier($0)) }
    }

    private func announceFinished(_ op: FileOperation) {
        switch op.state {
        case .finished:
            announce(op.errors.isEmpty ? "\(op.title) finished" : "\(op.title) finished with \(op.errors.count) error\(op.errors.count == 1 ? "" : "s")")
        case .failed(let message):
            announce("\(op.title) failed: \(message)")
        case .cancelled:
            announce("\(op.title) cancelled")
        default:
            break
        }
    }

    func announce(_ text: String) {
        guard announcesStateChanges else { return }
        pendingAnnouncements.append(text)
        guard pendingAnnouncements.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let items = self.pendingAnnouncements
                self.pendingAnnouncements = []
                guard !items.isEmpty, let app = NSApp else { return }
                let message = items.count <= 3 ? items.joined(separator: ". ") : items.suffix(2).joined(separator: ". ") + ". \(items.count - 2) more file operations updated"
                NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
            }
        }
    }

    func noteProgress(_ op: FileOperation) {
        batch[op.id] = op.progress.fractionCompleted
        refreshOverall()
    }

    private func refreshOverall() {
        let count = active.count
        if activeOperationCount != count { activeOperationCount = count }
        if count == 0 {
            batch.removeAll()
            if overallProgress != nil { overallProgress = nil }
            return
        }
        let values = batch.values
        overallProgress = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    func cancel(_ op: FileOperation) {
        if op.startedAt == nil && (op.state == .queued || op.state == .paused) {
            pending[op.laneKey]?.removeAll { $0 === op }
            op.control.cancel()
            op.state = .cancelled
            op.finishedAt = Date()
            active[ObjectIdentifier(op)] = nil
            batch[op.id] = 1
            op.onFinish?(op)
            record(finished: op)
            refreshOverall()
            pump()
        } else {
            op.control.cancel()
            op.decisionLatch.resolve(.cancel)
            op.transferTask?.cancel()
        }
    }

    @discardableResult
    func retry(_ op: FileOperation) -> FileOperation? {
        guard op.canRetry else { return nil }
        let indexes = op.plans.indices.filter { !op.completedIndexes.contains($0) }
        let owned = op.journal.map { $0.landedURL.standardizedFileURL.path }
        let plans = indexes.map { i -> ItemPlan in
            var plan = op.plans[i]
            if plan.action != .trash, op.transferRequest == nil, i < op.itemResults.count, let partial = op.itemResults[i] {
                plan.destination = partial
                plan.resumeOwned = (plan.resumeOwned ?? []) + owned
                plan.resumeLedger = op.ledger ?? plan.resumeLedger
            }
            return plan
        }
        if let request = op.transferRequest {
            let report = op.transferReport
            let items = indexes.map { i -> OperationItem in
                let item = request.items[i]
                guard let partial = report?.partialTargets[i], let s = item.sourceResource else { return item }
                return OperationItem(id: item.id, sourceResource: s, destinationResource: partial)
            }
            let remaining = ResourceTransferRequest(mode: request.mode, items: items, origin: .retry)
            let resume = report?.commits ?? [:]
            let new = submitTransfer(remaining, resolver: op.resolver, provider: op.transferProvider, onFinish: op.onFinish, origin: .retry, recursionDepth: op.recursionDepth, operationID: op.operationID, resume: resume)
            if let oldIndex = operations.firstIndex(where: { $0 === op }) {
                operations.removeLast()
                operations[oldIndex] = new
            }
            batch[op.id] = nil
            return new
        }
        let kind = op.kind.replacingSources(plans.map(\.source))
        let new = submit(kind: kind, plans: plans, registersUndo: op.registersUndo, resolver: op.resolver, onFinish: op.onFinish, origin: .retry, recursionDepth: op.recursionDepth, operationID: op.operationID)
        if let oldIndex = operations.firstIndex(where: { $0 === op }) {
            operations.removeLast()
            operations[oldIndex] = new
        }
        batch[op.id] = nil
        return new
    }

    public func clearFinished() {
        operations.removeAll { !$0.isActive }
        refreshOverall()
    }

    public func remove(_ op: FileOperation) {
        guard !op.isActive else { return }
        operations.removeAll { $0 === op }
        refreshOverall()
    }

    public func pauseAll() { operations.filter { $0.state == .running || $0.state == .queued }.forEach { $0.pause() } }
    public func resumeAll() { operations.filter { $0.state == .paused }.forEach { $0.resume() } }
    public func cancelAll() { operations.filter(\.isActive).forEach { $0.cancel() } }

    nonisolated public static func uniqueDestination(for name: String, in dir: URL) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard FS.exists(candidate) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            n += 1
        } while FS.exists(candidate)
        return candidate
    }

    nonisolated static func duplicateName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
    }
}

extension FileOperationKind {
    func replacingSources(_ sources: [URL]) -> FileOperationKind {
        switch self {
        case .copy(_, let d): return .copy(sources: sources, destination: d)
        case .move(_, let d): return .move(sources: sources, destination: d)
        case .trash: return .trash(items: sources)
        case .duplicate: return .duplicate(items: sources)
        }
    }
}

public enum FileActions {
    public static func createFolder(in dir: URL, name: String = "untitled folder") throws -> URL {
        try FileOperationHookRegistry.shared.throwIfAsyncRequired()
        let url = FileOperationQueue.uniqueDestination(for: name, in: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        FileOperationQueue.registerCreatedOnMain(name: "New Folder", url: url)
        return url
    }

    public static func createFile(in dir: URL, name: String = "untitled.txt", contents: Data = Data()) throws -> URL {
        try FileOperationHookRegistry.shared.throwIfAsyncRequired()
        let url = FileOperationQueue.uniqueDestination(for: name, in: dir)
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw CocoaError(.fileWriteUnknown)
        }
        FileOperationQueue.registerCreatedOnMain(name: "New File", url: url)
        return url
    }

    public static func rename(_ url: URL, to newName: String) throws -> URL {
        try FileOperationHookRegistry.shared.throwIfAsyncRequired()
        let target = try renameWithoutUndo(url, to: newName)
        FileOperationQueue.registerRenameOnMain(from: url, to: target)
        return target
    }

    public static func renameAsync(_ url: URL, to newName: String, registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> URL {
        let target = try renameTarget(url, to: newName)
        try await FileOperationQueue.trackingShared {
            try await registry.guarded(kind: .rename, items: [OperationItem(source: url, destination: target)], origin: origin) {
                try renameExact(url, to: target)
                return GuardedResult(value: (), urls: [target])
            }
            if url.path != target.path {
                await MainActor.run { FileOperationQueue.registerRenameOnMain(from: url, to: target, registry: registry) }
            }
        }
        return target
    }

    public static func createFolderAsync(in dir: URL, name: String = "untitled folder", registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> URL {
        let url = FileOperationQueue.uniqueDestination(for: name, in: dir)
        try await FileOperationQueue.trackingShared {
            try await registry.guarded(kind: .newFolder, items: [OperationItem(source: nil, destination: url)], origin: origin) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return GuardedResult(value: (), urls: [url])
            }
            await MainActor.run { FileOperationQueue.registerCreatedOnMain(name: "New Folder", url: url) }
        }
        return url
    }

    public static func createFileAsync(in dir: URL, name: String = "untitled.txt", contents: Data = Data(), registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> URL {
        let url = FileOperationQueue.uniqueDestination(for: name, in: dir)
        try await FileOperationQueue.trackingShared {
            try await registry.guarded(kind: .newFile, items: [OperationItem(source: nil, destination: url)], origin: origin) {
                guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return GuardedResult(value: (), urls: [url])
            }
            await MainActor.run { FileOperationQueue.registerCreatedOnMain(name: "New File", url: url) }
        }
        return url
    }

    static func renameTarget(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return url.deletingLastPathComponent().appendingPathComponent(newName)
    }

    static func renameWithoutUndo(_ url: URL, to newName: String) throws -> URL {
        let target = try renameTarget(url, to: newName)
        try renameExact(url, to: target)
        return target
    }

    static func renameExact(_ url: URL, to target: URL) throws {
        if url.path == target.path { return }
        if FS.exists(target) && !FS.sameFile(url, target) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        if Darwin.rename(url.path, target.path) != 0 {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
