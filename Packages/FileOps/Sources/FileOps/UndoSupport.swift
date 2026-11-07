import Foundation

final class UndoToken {
    var onRedoStack = false
    var flipOnly = false
}

typealias UndoStep = @MainActor (@escaping @MainActor (Bool) -> Void) -> Void

@MainActor
final class FallibleAction {
    let name: String
    let undo: UndoStep
    let redo: UndoStep
    var isDone = true
    var current: UndoToken?

    init(name: String, undo: @escaping UndoStep, redo: @escaping UndoStep) {
        self.name = name
        self.undo = undo
        self.redo = redo
    }
}

@MainActor
final class UndoInvocation {
    let action: FallibleAction
    let undoing: Bool
    weak var manager: UndoManager?
    var settled: Int?
    var started = false
    var finished = false

    init(action: FallibleAction, undoing: Bool, manager: UndoManager) {
        self.action = action
        self.undoing = undoing
        self.manager = manager
    }
}

@MainActor
final class UndoStackWatcher {
    weak var manager: UndoManager?
    private(set) var epoch = 0
    private var waiting: [UndoInvocation] = []
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(manager: UndoManager) {
        self.manager = manager
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup] {
            observers.append(center.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.epoch += 1 }
            })
        }
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            })
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func awaitSettle(_ invocation: UndoInvocation) {
        waiting.append(invocation)
    }

    private func settle() {
        epoch += 1
        for inv in waiting { inv.settled = epoch }
        waiting.removeAll()
    }
}

@MainActor
final class FallibleUndoState {
    var chain: [UndoInvocation] = []
    var bouncing = false
    var bounceHit = false
    private var watchers: [ObjectIdentifier: UndoStackWatcher] = [:]

    func watcher(for manager: UndoManager) -> UndoStackWatcher {
        let key = ObjectIdentifier(manager)
        if let w = watchers[key], w.manager === manager { return w }
        watchers = watchers.filter { $0.value.manager != nil }
        let w = UndoStackWatcher(manager: manager)
        watchers[key] = w
        return w
    }
}

private final class MovePairs {
    var home: [URL]
    var away: [URL]
    var atHome: [Bool]
    init(home: [URL], away: [URL]) {
        self.home = home
        self.away = away
        self.atHome = Array(repeating: false, count: home.count)
    }
}

private final class TrackedItems {
    var urls: [URL]
    var trashed: [URL?]
    init(urls: [URL], trashed: [URL?]) { self.urls = urls; self.trashed = trashed }
}

private final class RenameState {
    var old: URL
    var new: URL
    init(old: URL, new: URL) { self.old = old; self.new = new }
}

private final class ReportBox: @unchecked Sendable {
    var report = PutBackReport()
}

struct JournalEntry: Sendable {
    var record: UndoRecord
    var undone = false
    var newTrashed: URL?
    var backup: URL?

    init(record: UndoRecord) {
        self.record = record
        if case .replaced(_, let b, _) = record { backup = b }
    }
}

struct JournalResult: Sendable {
    var entries: [JournalEntry]
    var errors: [FileOperationItemError]
    var changed: Int
}

private final class JournalBox: @unchecked Sendable {
    var entries: [JournalEntry]
    init(_ entries: [JournalEntry]) { self.entries = entries }
}

extension FileOperationQueue {
    func registerUndoPair(name: String, undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void, origin: OperationOrigin = .undo) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let previous = target.ambientOrigin
                target.ambientOrigin = origin
                undo()
                target.ambientOrigin = previous
                target.registerUndoPair(name: name, undo: redo, redo: undo, origin: origin == .undo ? .redo : .undo)
            }
        }
        um.setActionName(name)
    }

    func registerFallible(name: String, undo: @escaping UndoStep, redo: @escaping UndoStep, origin: OperationOrigin = .undo) {
        guard let um = undoManager else { return }
        pushEntry(for: FallibleAction(name: name, undo: undo, redo: redo), on: um)
    }

    @discardableResult
    private func pushEntry(for action: FallibleAction, on um: UndoManager) -> UndoToken {
        let token = UndoToken()
        token.onRedoStack = um.isUndoing
        _ = fallible.watcher(for: um)
        um.registerUndo(withTarget: token) { [weak self, weak um, token] _ in
            MainActor.assumeIsolated {
                guard let self, let um else { return }
                self.invokeFallible(action, token: token, manager: um)
            }
        }
        um.setActionName(action.name)
        action.current = token
        return token
    }

    private func invokeFallible(_ action: FallibleAction, token: UndoToken, manager um: UndoManager) {
        if fallible.bouncing || token.flipOnly {
            if fallible.bouncing { fallible.bounceHit = true }
            pushEntry(for: action, on: um)
            return
        }
        let undoing = um.isUndoing
        pushEntry(for: action, on: um)
        let inv = UndoInvocation(action: action, undoing: undoing, manager: um)
        fallible.watcher(for: um).awaitSettle(inv)
        fallible.chain.append(inv)
        if fallible.chain.count == 1 { startNextInvocation() }
    }

    private func startNextInvocation() {
        guard let inv = fallible.chain.first, !inv.started else { return }
        inv.started = true
        if inv.action.isDone != inv.undoing {
            finishInvocation(inv, ok: true)
            return
        }
        let step = inv.undoing ? inv.action.undo : inv.action.redo
        let previous = ambientOrigin
        ambientOrigin = inv.undoing ? .undo : .redo
        step { [weak self] ok in self?.finishInvocation(inv, ok: ok) }
        ambientOrigin = previous
    }

    private func finishInvocation(_ inv: UndoInvocation, ok: Bool) {
        guard !inv.finished, let idx = fallible.chain.firstIndex(where: { $0 === inv }) else { return }
        inv.finished = true
        if ok {
            inv.action.isDone = !inv.undoing
            fallible.chain.remove(at: idx)
            startNextInvocation()
            return
        }
        let failed = Array(fallible.chain[idx...])
        fallible.chain.removeSubrange(idx...)
        for f in failed { f.finished = true }
        reconcile(failed, attempt: 0)
        startNextInvocation()
    }

    private func reconcile(_ invs: [UndoInvocation], attempt: Int) {
        guard let um = invs.last?.manager else { return }
        let ready = invs.allSatisfy { $0.settled != nil } && um.groupingLevel == 0 && !um.isUndoing && !um.isRedoing
        guard ready else {
            if attempt < 20 {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.reconcile(invs, attempt: attempt + 1) }
                }
            } else {
                fallbackReconcile(invs)
            }
            return
        }
        guard invs.allSatisfy({ $0.manager === um }), fallible.watcher(for: um).epoch == invs.last?.settled else {
            fallbackReconcile(invs)
            return
        }
        for k in invs.indices.reversed() {
            let inv = invs[k]
            fallible.bouncing = true
            fallible.bounceHit = false
            if inv.undoing {
                if um.canRedo { um.redo() }
            } else {
                if um.canUndo { um.undo() }
            }
            fallible.bouncing = false
            if !fallible.bounceHit {
                fallbackReconcile(Array(invs[...k]))
                return
            }
        }
    }

    private func fallbackReconcile(_ invs: [UndoInvocation]) {
        var seen = Set<ObjectIdentifier>()
        for inv in invs.reversed() {
            let action = inv.action
            guard seen.insert(ObjectIdentifier(action)).inserted, let token = action.current, let um = inv.manager else { continue }
            let wantsRedoSide = !action.isDone
            if token.onRedoStack == wantsRedoSide { continue }
            if wantsRedoSide {
                token.flipOnly = true
            } else {
                um.removeAllActions(withTarget: token)
                pushEntry(for: action, on: um)
            }
        }
    }

    func runStep(registry: FileOperationHookRegistry, kind: OperationKind, items: [OperationItem], body: @escaping () throws -> [URL?]) {
        let origin = ambientOrigin
        guard registry.isIntercepting else {
            _ = try? body()
            return
        }
        beginBackgroundMutation()
        Task {
            _ = try? await registry.guarded(kind: kind, items: items, origin: origin) {
                GuardedResult(value: (), urls: try body())
            }
            self.endBackgroundMutation()
        }
    }

    func runStep(registry: FileOperationHookRegistry, kind: OperationKind, items: [OperationItem], name: String, done: @escaping @MainActor (Bool) -> Void, body: @escaping () throws -> [URL?]) {
        let origin = ambientOrigin
        let fallback = items.first?.primaryURL ?? URL(fileURLWithPath: "/")
        let fail: @MainActor (Error) -> Void = { [weak self] error in
            self?.reportUndoFailure(name: name, origin: origin, errors: [.from(error, url: fallback)])
            done(false)
        }
        guard registry.isIntercepting else {
            do {
                _ = try body()
                done(true)
            } catch {
                fail(error)
            }
            return
        }
        beginBackgroundMutation()
        Task {
            do {
                _ = try await registry.guarded(kind: kind, items: items, origin: origin) {
                    GuardedResult(value: (), urls: try body())
                }
                done(true)
            } catch {
                fail(error)
            }
            self.endBackgroundMutation()
        }
    }

    func reportUndoFailure(name: String, origin: OperationOrigin, errors: [FileOperationItemError]) {
        guard !errors.isEmpty else { return }
        let verb = origin == .redo ? "Redo" : "Undo"
        let op = FileOperation(kind: .move(sources: errors.map(\.url), destination: errors[0].url.deletingLastPathComponent()))
        op.customTitle = "\(verb) \(name)"
        op.origin = origin
        op.queue = self
        op.startedAt = Date()
        op.finishedAt = Date()
        op.errors = errors
        op.state = .failed(errors.count == 1 ? errors[0].message : "\(errors.count) items couldn’t be restored")
        record(finished: op)
    }

    private func putBackStep(name: String, trashed: [URL], done: @escaping @MainActor (Bool) -> Void, apply: @escaping @MainActor (PutBackReport) -> Void) {
        let service = trashService
        let box = ReportBox()
        let origin = ambientOrigin
        runStep(registry: hooks, kind: .move, items: trashed.map { OperationItem(source: $0, destination: nil) }, name: name, done: { [weak self] ok in
            guard ok else { return done(false) }
            apply(box.report)
            self?.reportUndoFailure(name: name, origin: origin, errors: box.report.failures.map { .from($0.error, url: $0.trashed) })
            done(!box.report.restored.isEmpty)
        }) {
            box.report = service.putBack(trashed)
            return box.report.restored.map(\.restored)
        }
    }

    nonisolated static func registerOnMain(name: String, undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { shared.registerUndoPair(name: name, undo: undo, redo: redo) }
    }

    nonisolated static func registerRenameOnMain(from old: URL, to new: URL, registry: FileOperationHookRegistry = .shared) {
        guard Thread.isMainThread else { return }
        let state = RenameState(old: old, new: new)
        MainActor.assumeIsolated {
            let queue = shared
            queue.registerFallible(name: "Rename", undo: { done in
                queue.runStep(registry: registry, kind: .rename, items: [OperationItem(source: state.new, destination: state.old)], name: "Rename", done: done) {
                    try FileActions.renameWithoutUndoExact(state.new, to: state.old)
                    return [state.old]
                }
            }, redo: { done in
                queue.runStep(registry: registry, kind: .rename, items: [OperationItem(source: state.old, destination: state.new)], name: "Rename", done: done) {
                    try FileActions.renameWithoutUndoExact(state.old, to: state.new)
                    return [state.new]
                }
            })
        }
    }

    nonisolated static func registerCreatedOnMain(name: String, url: URL) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { shared.registerCreatedUndo(name: name, created: [url], async: false) }
    }

    func registerCreatedUndo(name: String, created: [URL], async: Bool) {
        guard undoManager != nil, !created.isEmpty else { return }
        let state = TrackedItems(urls: created, trashed: Array(repeating: nil, count: created.count))
        let service = trashService
        let undo: UndoStep = { [weak self] done in
            guard let self else { return }
            let pending = state.urls.indices.filter { state.trashed[$0] == nil }
            let urls = pending.map { state.urls[$0] }
            guard !urls.isEmpty else { return done(false) }
            if async || self.hooks.isIntercepting {
                let plans = urls.map { ItemPlan(action: .trash, source: $0, destination: nil, forcedChoice: nil) }
                _ = self.submit(kind: .trash(items: urls), plans: plans, registersUndo: false, resolver: nil) { op in
                    var any = false
                    for (k, i) in pending.enumerated() where k < op.itemResults.count {
                        if let result = op.itemResults[k] { state.trashed[i] = result; any = true }
                    }
                    done(any)
                }
            } else {
                var errors: [FileOperationItemError] = []
                for i in pending {
                    do { state.trashed[i] = try service.trash(state.urls[i]) } catch { errors.append(.from(error, url: state.urls[i])) }
                }
                self.reportUndoFailure(name: name, origin: .undo, errors: errors)
                done(errors.count < pending.count)
            }
        }
        let redo: UndoStep = { [weak self] done in
            guard let self else { return }
            let pending = state.urls.indices.filter { state.trashed[$0] != nil }
            let trashed = pending.compactMap { state.trashed[$0] }
            guard !trashed.isEmpty else { return done(false) }
            self.putBackStep(name: name, trashed: trashed, done: done) { report in
                for (t, restored) in report.restored {
                    if let i = pending.first(where: { state.trashed[$0] == t }) {
                        state.urls[i] = restored
                        state.trashed[i] = nil
                    }
                }
            }
        }
        registerFallible(name: name, undo: undo, redo: redo)
    }

    func registerUndo(for op: FileOperation) {
        guard undoManager != nil else { return }
        switch op.kind {
        case .trash:
            var originals: [URL] = []
            var trashed: [URL] = []
            for (plan, result) in zip(op.plans, op.itemResults) {
                if let result { originals.append(plan.source); trashed.append(result) }
            }
            registerTrashUndo(originals: originals, trashed: trashed)
        case .copy, .move, .duplicate:
            if let reason = op.undoBlockedReason {
                op.undoUnavailableReason = reason
                return
            }
            let records = op.journal
            guard !records.isEmpty else { return }
            let name: String
            switch op.kind {
            case .move: name = "Move"
            case .copy: name = "Copy"
            default: name = "Duplicate"
            }
            var created: [URL] = []
            var home: [URL] = []
            var away: [URL] = []
            var replaced = false
            for r in records {
                switch r {
                case .created(let u): created.append(u)
                case .moved(let f, let t): home.append(f); away.append(t)
                case .replaced: replaced = true
                }
            }
            if !replaced && home.isEmpty {
                registerCreatedUndo(name: name, created: created, async: true)
            } else if !replaced && created.isEmpty {
                registerMoveUndo(name: name, home: home, away: away)
            } else {
                registerJournalUndo(name: name, records: records)
            }
        }
    }

    func registerMoveUndo(name: String, home: [URL], away: [URL]) {
        guard !home.isEmpty else { return }
        let state = MovePairs(home: home, away: away)
        let undo: UndoStep = { [weak self] done in
            guard let self else { return }
            let pending = state.home.indices.filter { !state.atHome[$0] }
            guard !pending.isEmpty else { return done(false) }
            self.runExactMoves(from: pending.map { state.away[$0] }, to: pending.map { state.home[$0] }) { landed in
                var any = false
                for (k, i) in pending.enumerated() where k < landed.count {
                    if let l = landed[k] { state.home[i] = l; state.atHome[i] = true; any = true }
                }
                done(any)
            }
        }
        let redo: UndoStep = { [weak self] done in
            guard let self else { return }
            let pending = state.home.indices.filter { state.atHome[$0] }
            guard !pending.isEmpty else { return done(false) }
            self.runExactMoves(from: pending.map { state.home[$0] }, to: pending.map { state.away[$0] }) { landed in
                var any = false
                for (k, i) in pending.enumerated() where k < landed.count {
                    if let l = landed[k] { state.away[i] = l; state.atHome[i] = false; any = true }
                }
                done(any)
            }
        }
        registerFallible(name: name, undo: undo, redo: redo)
    }

    func runExactMoves(from: [URL], to: [URL], completion: @escaping ([URL?]) -> Void) {
        var plans: [ItemPlan] = []
        for (src, dst) in zip(from, to) {
            plans.append(ItemPlan(action: .move, source: src, destination: dst, forcedChoice: .keepBoth, createsParents: true))
        }
        guard let dir = to.first?.deletingLastPathComponent() else { return completion([]) }
        _ = submit(kind: .move(sources: from, destination: dir), plans: plans, registersUndo: false, resolver: nil) { op in
            completion(plans.indices.map { i in
                op.completedIndexes.contains(i) && i < op.itemResults.count ? op.itemResults[i] : nil
            })
        }
    }

    func registerTrashUndo(originals: [URL], trashed: [URL]) {
        guard !originals.isEmpty else { return }
        let state = TrackedItems(urls: originals, trashed: trashed.map { Optional($0) })
        let undo: UndoStep = { [weak self] done in
            guard let self else { return }
            let pending = state.urls.indices.filter { state.trashed[$0] != nil }
            let items = pending.compactMap { state.trashed[$0] }
            guard !items.isEmpty else { return done(false) }
            self.putBackStep(name: "Move to Trash", trashed: items, done: done) { report in
                for (t, restored) in report.restored {
                    if let i = pending.first(where: { state.trashed[$0] == t }) {
                        state.urls[i] = restored
                        state.trashed[i] = nil
                    }
                }
            }
        }
        let redo: UndoStep = { [weak self] done in
            guard let self else { return }
            let pending = state.urls.indices.filter { state.trashed[$0] == nil }
            let sources = pending.map { state.urls[$0] }
            guard !sources.isEmpty else { return done(false) }
            let plans = sources.map { ItemPlan(action: .trash, source: $0, destination: nil, forcedChoice: nil) }
            _ = self.submit(kind: .trash(items: sources), plans: plans, registersUndo: false, resolver: nil) { op in
                var any = false
                for (k, i) in pending.enumerated() where k < op.itemResults.count {
                    if let result = op.itemResults[k] { state.trashed[i] = result; any = true }
                }
                done(any)
            }
        }
        registerFallible(name: "Move to Trash", undo: undo, redo: redo)
    }

    func registerJournalUndo(name: String, records: [UndoRecord]) {
        let box = JournalBox(records.map(JournalEntry.init(record:)))
        func step(_ undoing: Bool) -> UndoStep {
            { [weak self] done in
                guard let self else { return }
                let snapshot = box.entries
                let service = self.trashService
                let registry = self.hooks
                let origin = self.ambientOrigin
                let items = snapshot.map { OperationItem(source: $0.record.landedURL, destination: nil) }
                self.undoWorkInFlight += 1
                Task.detached {
                    var result: JournalResult
                    if registry.isIntercepting {
                        do {
                            result = try await registry.guarded(kind: .move, items: items, origin: origin) {
                                let r = FileOperationQueue.performJournal(snapshot, undoing: undoing, service: service)
                                return GuardedResult(value: r, urls: r.entries.map { Optional($0.record.landedURL) })
                            }
                        } catch {
                            result = JournalResult(entries: snapshot, errors: [.from(error, url: items.first?.primaryURL ?? URL(fileURLWithPath: "/"))], changed: 0)
                        }
                    } else {
                        result = FileOperationQueue.performJournal(snapshot, undoing: undoing, service: service)
                    }
                    let final = result
                    await MainActor.run {
                        box.entries = final.entries
                        self.reportUndoFailure(name: name, origin: undoing ? .undo : .redo, errors: final.errors)
                        done(final.changed > 0)
                        self.undoWorkInFlight -= 1
                    }
                }
            }
        }
        registerFallible(name: name, undo: step(true), redo: step(false))
    }

    nonisolated static func performJournal(_ entries: [JournalEntry], undoing: Bool, service: TrashService) -> JournalResult {
        var out = entries
        var errors: [FileOperationItemError] = []
        var changed = 0
        let fm = FileManager.default
        func move(_ a: URL, _ b: URL) throws {
            if FS.exists(b) { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: b.path]) }
            let parent = b.deletingLastPathComponent()
            if !FS.exists(parent) { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
            try fm.moveItem(at: a, to: b)
        }
        let order = undoing ? Array(out.indices.reversed()) : Array(out.indices)
        for k in order where out[k].undone != undoing {
            var e = out[k]
            do {
                switch e.record {
                case .created(let u):
                    if undoing {
                        e.newTrashed = try service.trash(u)
                    } else {
                        guard let t = e.newTrashed else { throw PutBackError.noRecord(u) }
                        try service.restore(t, to: u)
                        e.newTrashed = nil
                    }
                case .moved(let f, let t):
                    if undoing { try move(t, f) } else { try move(f, t) }
                case .replaced(let d, _, let from):
                    if undoing {
                        guard let backup = e.backup else { throw PutBackError.noRecord(d) }
                        if let from { try move(d, from) } else { e.newTrashed = try service.trash(d) }
                        do {
                            try service.restore(backup, to: d)
                            e.backup = nil
                        } catch {
                            if let from {
                                try? move(from, d)
                            } else if let t = e.newTrashed {
                                try? service.restore(t, to: d)
                                e.newTrashed = nil
                            }
                            throw error
                        }
                    } else {
                        let backup = try service.trash(d)
                        do {
                            if let from {
                                try move(from, d)
                            } else {
                                guard let t = e.newTrashed else { throw PutBackError.noRecord(d) }
                                try service.restore(t, to: d)
                                e.newTrashed = nil
                            }
                            e.backup = backup
                        } catch {
                            try? service.restore(backup, to: d)
                            throw error
                        }
                    }
                }
                e.undone = undoing
                out[k] = e
                changed += 1
            } catch {
                errors.append(.from(error, url: e.record.landedURL))
            }
        }
        return JournalResult(entries: out, errors: errors, changed: changed)
    }
}

extension FileActions {
    static func renameWithoutUndoExact(_ url: URL, to target: URL) throws {
        try renameExact(url, to: target)
    }
}
