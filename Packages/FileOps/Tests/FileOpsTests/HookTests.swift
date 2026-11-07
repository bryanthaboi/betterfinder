import XCTest
@testable import FileOps

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class TestHook: FileOperationHook, @unchecked Sendable {
    let id: String
    let priority: Int
    var timeout: TimeInterval?
    var beforeBehavior: @Sendable (OperationSnapshot) async throws -> HookDecision = { _ in .allow }
    var afterBehavior: @Sendable (OperationSnapshot, OperationOutcome) async throws -> Void = { _, _ in }
    var recorder: Recorder?
    private let lock = NSLock()
    private var beforeList: [OperationSnapshot] = []
    private var afterList: [(OperationSnapshot, OperationOutcome)] = []

    init(id: String, priority: Int = 0) {
        self.id = id
        self.priority = priority
    }

    var befores: [OperationSnapshot] { lock.lock(); defer { lock.unlock() }; return beforeList }
    var afters: [(OperationSnapshot, OperationOutcome)] { lock.lock(); defer { lock.unlock() }; return afterList }

    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision {
        lock.lock(); beforeList.append(snapshot); lock.unlock()
        recorder?.add(id)
        return try await beforeBehavior(snapshot)
    }

    func after(_ snapshot: OperationSnapshot, _ outcome: OperationOutcome) async throws {
        lock.lock(); afterList.append((snapshot, outcome)); lock.unlock()
        try await afterBehavior(snapshot, outcome)
    }
}

final class StubPresenter: HookDecisionPresenting, @unchecked Sendable {
    let decision: HookUserDecision
    private let lock = NSLock()
    private var asked: [PausedOperationInfo] = []
    init(_ decision: HookUserDecision) { self.decision = decision }
    var infos: [PausedOperationInfo] { lock.lock(); defer { lock.unlock() }; return asked }
    func decide(_ info: PausedOperationInfo) async -> HookUserDecision {
        record(info)
        return decision
    }

    private func record(_ info: PausedOperationInfo) {
        lock.lock(); asked.append(info); lock.unlock()
    }
}

struct DenyAllAuthorizer: OperationAuthorizer {
    func authorize(_ snapshot: OperationSnapshot) async -> HookDecision { .deny("no grant") }
}

struct BoomError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class HookTests: FileOpsTestCase {
    var registry: FileOperationHookRegistry!

    override func setUp() async throws {
        try await super.setUp()
        registry = FileOperationHookRegistry()
        queue.hooks = registry
    }

    func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func isAwaiting(_ op: FileOperation) -> Bool {
        if case .awaitingDecision = op.state { return true }
        return false
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testAllowPathRunsOperationAndNotifiesAfterHook() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("a.txt", in: src, "alpha")
        let hook = TestHook(id: "mod.a")
        registry.register(hook, owner: "mod")

        let op = await run(.copy(sources: [f], destination: dst))
        await registry.waitForAfterHooks()

        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(dst.appendingPathComponent("a.txt")), "alpha")
        XCTAssertEqual(hook.befores.count, 1)
        let snap = hook.befores[0]
        XCTAssertEqual(snap.kind, .copy)
        XCTAssertEqual(snap.origin, .user)
        XCTAssertEqual(snap.recursionDepth, 0)
        XCTAssertEqual(snap.operationID, op.operationID)
        XCTAssertEqual(snap.items.first?.source, f)
        XCTAssertEqual(snap.items.first?.destination, dst.appendingPathComponent("a.txt"))
        XCTAssertEqual(hook.afters.count, 1)
        let outcome = hook.afters[0].1
        XCTAssertEqual(outcome.committed.count, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.isPartialFailure)
    }

    func testDenyBlocksWithoutMutation() async throws {
        let src = try dir("src")
        let f = try file("keep.txt", in: src, "precious")
        let hook = TestHook(id: "guard.protect")
        hook.beforeBehavior = { _ in .deny("protected folder") }
        registry.register(hook, owner: "Guard")

        let op = await run(.trash(items: [f]))
        await registry.waitForAfterHooks()

        XCTAssertTrue(exists(f))
        XCTAssertEqual(read(f), "precious")
        XCTAssertEqual(names(trashDir), [])
        XCTAssertEqual(op.state, .failed("Guard blocked this operation: protected folder"))
        XCTAssertEqual(op.hookDenial?.hookID, "guard.protect")
        XCTAssertEqual(op.hookDenial?.reason, "protected folder")
        XCTAssertTrue(hook.afters.isEmpty)
        XCTAssertTrue(op.canRetry)
        XCTAssertFalse(undo.canUndo)
    }

    func testTimeoutPausesThenOverrideProceeds() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("slow.txt", in: src, "slow")
        let hook = TestHook(id: "mod.slow")
        hook.beforeBehavior = { _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return .allow
        }
        registry.defaultTimeout = 0.05
        registry.register(hook, owner: "SlowMod")

        let op = queue.enqueue(.copy(sources: [f], destination: dst))
        await waitUntil { self.isAwaiting(op) }
        XCTAssertTrue(isAwaiting(op))
        XCTAssertTrue(op.isActive)
        XCTAssertEqual(op.pausedInfo?.owner, "SlowMod")
        XCTAssertTrue(op.summary.contains("SlowMod blocked this operation"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(names(dst), [])
        XCTAssertTrue(isAwaiting(op))

        op.overrideHooks()
        await waitIdle()
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(names(dst), ["slow.txt"])
        XCTAssertEqual(read(dst.appendingPathComponent("slow.txt")), "slow")
        XCTAssertEqual(read(f), "slow")
    }

    func testBeforeHookErrorPausesAndCancelLeavesFilesAlone() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("x.txt", in: src, "x")
        let hook = TestHook(id: "mod.err")
        hook.beforeBehavior = { _ in throw BoomError() }
        registry.register(hook, owner: "Err")

        let op = queue.enqueue(.move(sources: [f], destination: dst))
        await waitUntil { self.isAwaiting(op) }
        XCTAssertTrue(isAwaiting(op))
        XCTAssertTrue(op.summary.contains("failed: boom"))

        op.cancel()
        await waitIdle()
        XCTAssertEqual(op.state, .cancelled)
        XCTAssertTrue(exists(f))
        XCTAssertEqual(names(dst), [])
        XCTAssertTrue(hook.afters.isEmpty)
    }

    func testOverrideAfterErrorMovesExactlyOnce() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("once.txt", in: src, "once")
        let counter = Recorder()
        let hook = TestHook(id: "mod.flaky")
        hook.beforeBehavior = { _ in
            counter.add("before")
            throw BoomError()
        }
        registry.register(hook, owner: "Flaky")

        let op = queue.enqueue(.move(sources: [f], destination: dst))
        await waitUntil { self.isAwaiting(op) }
        op.overrideHooks()
        await waitIdle()
        await registry.waitForAfterHooks()

        XCTAssertEqual(op.state, .finished)
        XCTAssertFalse(exists(f))
        XCTAssertEqual(names(dst), ["once.txt"])
        XCTAssertEqual(counter.all.count, 1)
        XCTAssertEqual(hook.afters.count, 1)
    }

    func testOverrideOnlyBypassesFailingHookNotLaterDenial() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("x.txt", in: src, "x")
        let flaky = TestHook(id: "a.flaky", priority: 0)
        flaky.beforeBehavior = { _ in throw BoomError() }
        let strict = TestHook(id: "b.strict", priority: 1)
        strict.beforeBehavior = { _ in .deny("nope") }
        registry.register(flaky, owner: "Flaky")
        registry.register(strict, owner: "Strict")

        let op = queue.enqueue(.copy(sources: [f], destination: dst))
        await waitUntil { self.isAwaiting(op) }
        op.overrideHooks()
        await waitIdle()

        XCTAssertEqual(op.state, .failed("Strict blocked this operation: nope"))
        XCTAssertEqual(names(dst), [])
    }

    func testPresenterRunAnywayResolvesAutomatically() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("p.txt", in: src, "p")
        let hook = TestHook(id: "mod.err")
        hook.beforeBehavior = { _ in throw BoomError() }
        registry.register(hook, owner: "Err")
        let presenter = StubPresenter(.runAnyway)
        registry.decisionPresenter = presenter

        let op = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(names(dst), ["p.txt"])
        XCTAssertEqual(presenter.infos.count, 1)
        XCTAssertEqual(presenter.infos[0].owner, "Err")
    }

    func testPresenterCancelCancelsOperation() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("p.txt", in: src, "p")
        let hook = TestHook(id: "mod.err")
        hook.beforeBehavior = { _ in throw BoomError() }
        registry.register(hook, owner: "Err")
        registry.decisionPresenter = StubPresenter(.cancel)

        let op = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .cancelled)
        XCTAssertEqual(names(dst), [])
    }

    func testAfterHookReceivesPartialFailure() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let good = try file("good.txt", in: src, "g")
        let missing = src.appendingPathComponent("missing.txt")
        let hook = TestHook(id: "mod.logging")
        registry.register(hook, owner: "Logging")

        let op = await run(.copy(sources: [good, missing], destination: dst))
        await registry.waitForAfterHooks()

        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(hook.afters.count, 1)
        let outcome = hook.afters[0].1
        XCTAssertEqual(outcome.items.count, 2)
        XCTAssertEqual(outcome.committed.count, 1)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertTrue(outcome.isPartialFailure)
        XCTAssertEqual(outcome.committed[0].item.source, good)
        if case .committed(let url) = outcome.committed[0].result {
            XCTAssertEqual(url, dst.appendingPathComponent("good.txt"))
        }
        XCTAssertEqual(outcome.failed[0].item.source, missing)
        XCTAssertFalse(outcome.errors.isEmpty)
        XCTAssertEqual(outcome.items.map(\.index), [0, 1])
        XCTAssertNotEqual(outcome.committed[0].id, outcome.failed[0].id)
    }

    func testAfterHookThrowingNeverRepeatsOperation() async throws {
        let src = try dir("src")
        let f = try file("d.txt", in: src, "d")
        let logs = Recorder()
        registry.logHandler = { logs.add($0) }
        let hook = TestHook(id: "mod.badobserver")
        hook.afterBehavior = { _, _ in throw BoomError() }
        registry.register(hook, owner: "Bad")

        let op = await run(.duplicate(items: [f]))
        await registry.waitForAfterHooks()

        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(names(src), ["d copy.txt", "d.txt"])
        XCTAssertEqual(hook.afters.count, 1)
        XCTAssertTrue(logs.all.contains { $0.contains("mod.badobserver") && $0.contains("boom") })
        XCTAssertEqual(read(f), "d")
    }

    func testAfterHookTimeoutIsLoggedAndDoesNotBlockQueue() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("t.txt", in: src, "t")
        let logs = Recorder()
        registry.logHandler = { logs.add($0) }
        registry.defaultTimeout = 0.05
        let hook = TestHook(id: "mod.sleepy")
        hook.afterBehavior = { _, _ in try? await Task.sleep(nanoseconds: 2_000_000_000) }
        registry.register(hook, owner: "Sleepy")

        let op = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .finished)
        await registry.waitForAfterHooks()
        XCTAssertTrue(logs.all.contains { $0.contains("mod.sleepy") && $0.contains("timed out") })
        XCTAssertEqual(names(dst), ["t.txt"])
    }

    func testHooksRunInPriorityThenIdOrder() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("o.txt", in: src)
        let order = Recorder()
        for (id, priority) in [("b", 1), ("a", 1), ("z", 0), ("c", 2)] {
            let hook = TestHook(id: id, priority: priority)
            hook.recorder = order
            registry.register(hook, owner: "o")
        }
        XCTAssertEqual(registry.registeredHookIDs, ["z", "a", "b", "c"])
        await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(order.all, ["z", "a", "b", "c"])
    }

    func testDenyStopsLaterHooks() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("o.txt", in: src)
        let order = Recorder()
        let first = TestHook(id: "first", priority: 0)
        first.recorder = order
        first.beforeBehavior = { _ in .deny("stop") }
        let second = TestHook(id: "second", priority: 1)
        second.recorder = order
        registry.register(second, owner: "o")
        registry.register(first, owner: "o")
        await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(order.all, ["first"])
    }

    func testUndoAndRedoTraverseHooksWithOrigins() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("u.txt", in: src, "u")
        let hook = TestHook(id: "mod.watch")
        registry.register(hook, owner: "Watch")

        await run(.move(sources: [f], destination: dst))
        XCTAssertEqual(hook.befores.map(\.origin), [.user])

        undo.undo()
        await waitIdle()
        await waitUntil { self.exists(f) }
        XCTAssertTrue(exists(f))
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .undo])

        undo.redo()
        await waitIdle()
        await waitUntil { !self.exists(f) }
        XCTAssertFalse(exists(f))
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .undo, .redo])

        undo.undo()
        await waitIdle()
        await waitUntil { self.exists(f) }
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .undo, .redo, .undo])
    }

    func testDenyingUndoLeavesFilesAndDoesNotDuplicate() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("u.txt", in: src, "u")
        await run(.move(sources: [f], destination: dst))

        let hook = TestHook(id: "mod.deny")
        hook.beforeBehavior = { snap in snap.origin == .undo ? .deny("no undo") : .allow }
        registry.register(hook, owner: "Deny")

        undo.undo()
        await waitIdle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(exists(f))
        XCTAssertEqual(names(dst), ["u.txt"])
        XCTAssertEqual(names(src), [])
    }

    func testRetryTraversesHooksWithRetryOriginAndKeepsOperationID() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("r.txt", in: src, "r")
        let hook = TestHook(id: "mod.denyfirst")
        let counter = Recorder()
        hook.beforeBehavior = { _ in
            counter.add("x")
            return counter.all.count == 1 ? .deny("not yet") : .allow
        }
        registry.register(hook, owner: "Gate")

        let first = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(first.state, .failed("Gate blocked this operation: not yet"))
        XCTAssertEqual(names(dst), [])

        let second = first.retry()
        await waitIdle()
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.state, .finished)
        XCTAssertEqual(names(dst), ["r.txt"])
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .retry])
        XCTAssertEqual(hook.befores[0].operationID, hook.befores[1].operationID)
        XCTAssertNotEqual(hook.befores[0].attemptID, hook.befores[1].attemptID)
    }

    func testAuthorizerDenyBlocksQueueAndSyncPaths() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("g.txt", in: src, "g")
        registry.authorizer = DenyAllAuthorizer()
        XCTAssertTrue(registry.isIntercepting)

        let op = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .failed("Permissions blocked this operation: no grant"))
        XCTAssertEqual(names(dst), [])

        do {
            _ = try await FileActions.renameAsync(f, to: "h.txt", registry: registry)
            XCTFail("expected denial")
        } catch let error as HookDeniedError {
            XCTAssertEqual(error.denial.owner, "Permissions")
        }
        XCTAssertTrue(exists(f))
    }

    func testRenameAsyncRunsHooksAndRenames() async throws {
        let src = try dir("src")
        let f = try file("old.txt", in: src, "o")
        let hook = TestHook(id: "mod.rename")
        registry.register(hook, owner: "Ren")

        let url = try await FileActions.renameAsync(f, to: "new.txt", registry: registry)
        await registry.waitForAfterHooks()

        XCTAssertEqual(url, src.appendingPathComponent("new.txt"))
        XCTAssertFalse(exists(f))
        XCTAssertEqual(read(url), "o")
        XCTAssertEqual(hook.befores.count, 1)
        XCTAssertEqual(hook.befores[0].kind, .rename)
        XCTAssertEqual(hook.befores[0].items.first?.source, f)
        XCTAssertEqual(hook.befores[0].items.first?.destination, url)
        XCTAssertEqual(hook.afters[0].1.committed.count, 1)
    }

    func testRenameAsyncDenyDoesNotRename() async throws {
        let src = try dir("src")
        let f = try file("old.txt", in: src, "o")
        let hook = TestHook(id: "mod.rename")
        hook.beforeBehavior = { _ in .deny("locked") }
        registry.register(hook, owner: "Ren")
        do {
            _ = try await FileActions.renameAsync(f, to: "new.txt", registry: registry)
            XCTFail("expected denial")
        } catch let error as HookDeniedError {
            XCTAssertEqual(error.denial.reason, "locked")
        }
        XCTAssertTrue(exists(f))
        XCTAssertFalse(exists(src.appendingPathComponent("new.txt")))
        XCTAssertTrue(hook.afters.isEmpty)
    }

    func testRenameAsyncHookErrorWithoutPresenterThrowsAndKeepsFile() async throws {
        let src = try dir("src")
        let f = try file("old.txt", in: src, "o")
        let hook = TestHook(id: "mod.rename")
        hook.beforeBehavior = { _ in throw BoomError() }
        registry.register(hook, owner: "Ren")
        do {
            _ = try await FileActions.renameAsync(f, to: "new.txt", registry: registry)
            XCTFail("expected pause")
        } catch is HookDecisionRequired {}
        XCTAssertTrue(exists(f))

        registry.decisionPresenter = StubPresenter(.runAnyway)
        let url = try await FileActions.renameAsync(f, to: "new.txt", registry: registry)
        XCTAssertEqual(read(url), "o")
        XCTAssertFalse(exists(f))
    }

    func testRenameAsyncFailureReportsFailedOutcomeAndLeavesFiles() async throws {
        let src = try dir("src")
        let a = try file("a.txt", in: src, "a")
        let b = try file("b.txt", in: src, "b")
        let hook = TestHook(id: "mod.rename")
        registry.register(hook, owner: "Ren")
        do {
            _ = try await FileActions.renameAsync(a, to: "b.txt", registry: registry)
            XCTFail("expected exists error")
        } catch {}
        await registry.waitForAfterHooks()
        XCTAssertEqual(read(a), "a")
        XCTAssertEqual(read(b), "b")
        XCTAssertEqual(hook.afters.count, 1)
        XCTAssertEqual(hook.afters[0].1.failed.count, 1)
        XCTAssertTrue(hook.afters[0].1.committed.isEmpty)
    }

    func testSyncMutationsThrowWhenHooksRegisteredAndWorkWhenNot() async throws {
        let src = try dir("src")
        let f = try file("s.txt", in: src, "s")
        let shared = FileOperationHookRegistry.shared
        XCTAssertFalse(shared.isIntercepting)

        let renamed = try FileActions.rename(f, to: "t.txt")
        XCTAssertEqual(renamed.lastPathComponent, "t.txt")
        XCTAssertTrue(exists(renamed))

        let token = shared.register(TestHook(id: "mod.sync"), owner: "Sync")
        defer { token.cancel() }

        XCTAssertThrowsError(try FileActions.rename(renamed, to: "u.txt")) { XCTAssertTrue($0 is HooksRequireAsync) }
        XCTAssertThrowsError(try FileActions.createFolder(in: src)) { XCTAssertTrue($0 is HooksRequireAsync) }
        XCTAssertThrowsError(try FileActions.createFile(in: src)) { XCTAssertTrue($0 is HooksRequireAsync) }
        XCTAssertThrowsError(try TagOps.setTags(["Red"], for: renamed)) { XCTAssertTrue($0 is HooksRequireAsync) }
        XCTAssertThrowsError(try BatchRename.apply(urls: [renamed], rules: [.addPrefix("x-")])) { XCTAssertTrue($0 is HooksRequireAsync) }
        XCTAssertTrue(exists(renamed))
        XCTAssertEqual(names(src), ["t.txt"])
    }

    func testCreateBatchAndTagAsyncPathsAllTraverseHooks() async throws {
        let src = try dir("src")
        let a = try file("a.txt", in: src, "a")
        let b = try file("b.txt", in: src, "b")
        let hook = TestHook(id: "mod.all")
        registry.register(hook, owner: "All")

        let folder = try await FileActions.createFolderAsync(in: src, name: "Folder", registry: registry)
        let made = try await FileActions.createFileAsync(in: src, name: "made.txt", contents: Data("m".utf8), registry: registry)
        let renamed = try await BatchRename.applyAsync(urls: [a, b], rules: [.addPrefix("x-")], registry: registry)
        try await TagOps.setTagsAsync(["Red"], for: made, registry: registry)
        await registry.waitForAfterHooks()

        XCTAssertTrue(FS.isDirectory(folder))
        XCTAssertEqual(read(made), "m")
        XCTAssertEqual(renamed.map(\.lastPathComponent), ["x-a.txt", "x-b.txt"])
        XCTAssertEqual(TagOps.tags(for: made), ["Red"])
        XCTAssertEqual(hook.befores.map(\.kind), [.newFolder, .newFile, .batchRename, .tag])
        XCTAssertEqual(hook.afters.map { $0.0.kind }, [.newFolder, .newFile, .batchRename, .tag])
        XCTAssertEqual(hook.befores[2].items.count, 2)
        XCTAssertEqual(hook.befores[3].tags, ["Red"])
        XCTAssertNil(hook.befores[0].items[0].source)
        XCTAssertEqual(hook.befores[0].items[0].destination, folder)
    }

    func testDenyBatchRenameAndTagsLeavesFilesUntouched() async throws {
        let src = try dir("src")
        let a = try file("a.txt", in: src, "a")
        let hook = TestHook(id: "mod.deny")
        hook.beforeBehavior = { _ in .deny("frozen") }
        registry.register(hook, owner: "Freeze")

        do {
            _ = try await BatchRename.applyAsync(urls: [a], rules: [.addPrefix("x-")], registry: registry)
            XCTFail("expected denial")
        } catch is HookDeniedError {}
        do {
            try await TagOps.setTagsAsync(["Red"], for: a, registry: registry)
            XCTFail("expected denial")
        } catch is HookDeniedError {}
        do {
            _ = try await FileActions.createFolderAsync(in: src, name: "F", registry: registry)
            XCTFail("expected denial")
        } catch is HookDeniedError {}
        XCTAssertEqual(names(src), ["a.txt"])
        XCTAssertEqual(TagOps.tags(for: a), [])
    }

    func testRenameUndoTraversesSharedHooksWithUndoOrigin() async throws {
        let src = try dir("src")
        let f = try file("old.txt", in: src, "o")
        let shared = FileOperationHookRegistry.shared
        let hook = TestHook(id: "mod.renameundo")
        let token = shared.register(hook, owner: "RU")
        defer { token.cancel() }
        let um = FileOperationQueue.shared.undoManager
        um?.removeAllActions()

        let url = try await FileActions.renameAsync(f, to: "new.txt")
        XCTAssertEqual(um?.canUndo, true)
        um?.undo()
        await waitUntil { self.exists(f) }
        XCTAssertTrue(exists(f))
        XCTAssertFalse(exists(url))
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .undo])
        um?.redo()
        await waitUntil { self.exists(url) }
        XCTAssertTrue(exists(url))
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .undo, .redo])
        um?.removeAllActions()
    }

    func testRecursionLimitStopsHookInitiatedOperations() async throws {
        let src = try dir("src")
        registry.recursionLimit = 2
        registry.defaultTimeout = 10
        let hook = TestHook(id: "mod.recurse")
        let errors = Recorder()
        let reg = registry!
        let target = src
        hook.beforeBehavior = { snap in
            do {
                _ = try await FileActions.createFolderAsync(in: target, name: "n\(snap.recursionDepth)", registry: reg)
            } catch let error as OperationRecursionLimitExceeded {
                errors.add("limit \(error.depth)/\(error.limit)")
            } catch {
                errors.add("other \(error)")
            }
            return .allow
        }
        registry.register(hook, owner: "Rec")

        _ = try await FileActions.createFolderAsync(in: src, name: "root", registry: registry)
        await registry.waitForAfterHooks()

        XCTAssertEqual(hook.befores.map(\.recursionDepth), [0, 1, 2])
        XCTAssertEqual(hook.befores.map(\.origin), [.user, .mod("Rec"), .mod("Rec")])
        XCTAssertEqual(errors.all, ["limit 3/2"])
        XCTAssertEqual(names(src), ["n0", "n1", "root"])
    }

    func testQueueOperationStartedInsideHookIsMarkedModAndDepthLimited() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("m.txt", in: src, "m")
        registry.recursionLimit = 0
        let denied = Recorder()
        let hook = TestHook(id: "mod.spawn")
        let q = queue!
        hook.beforeBehavior = { snap in
            guard snap.recursionDepth == 0 else { return .allow }
            let nested: FileOperation = await MainActor.run { q.enqueue(.trash(items: [f])) }
            await MainActor.run { denied.add("\(nested.origin) depth \(nested.recursionDepth)") }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let state = await MainActor.run { nested.state }
            denied.add("\(state)")
            return .allow
        }
        registry.register(hook, owner: "Spawn")

        await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(denied.all.first, "mod(\"Spawn\") depth 1")
        XCTAssertTrue(denied.all.last?.contains("failed") == true)
        XCTAssertTrue(exists(f))
        XCTAssertEqual(names(dst), ["m.txt"])
    }

    func testTokenCancelUnregistersHook() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("k.txt", in: src)
        let hook = TestHook(id: "mod.tok")
        let token = registry.register(hook, owner: "Tok")
        XCTAssertEqual(registry.hookCount, 1)
        XCTAssertTrue(registry.isIntercepting)
        XCTAssertTrue(token.isActive)

        token.cancel()
        token.cancel()
        XCTAssertEqual(registry.hookCount, 0)
        XCTAssertFalse(registry.isIntercepting)
        XCTAssertFalse(token.isActive)

        await run(.copy(sources: [f], destination: dst))
        XCTAssertTrue(hook.befores.isEmpty)
        XCTAssertTrue(hook.afters.isEmpty)
        XCTAssertEqual(names(dst), ["k.txt"])
    }

    func testPerHookTimeoutOverrideAndCustomDefault() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("k.txt", in: src)
        registry.defaultTimeout = 0.05
        let hook = TestHook(id: "mod.long")
        hook.beforeBehavior = { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .allow
        }
        registry.register(hook, owner: "Long", timeout: 5)
        let op = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(names(dst), ["k.txt"])
    }

    func testResourceTransferProviderRegistry() async throws {
        struct Stub: ResourceTransferProvider {
            let id = "stub.sftp"
            func canTransfer(_ request: ResourceTransferRequest) -> Bool { request.items.allSatisfy { $0.source?.scheme == "sftp" } }
            func transfer(_ request: ResourceTransferRequest, progress: @escaping @Sendable (FileOperationProgress) -> Void) async throws -> [URL?] { [] }
        }
        let providers = ResourceTransferProviderRegistry()
        let token = providers.register(Stub(), owner: "sftp")
        let remote = ResourceTransferRequest(mode: .copy, items: [OperationItem(source: URL(string: "sftp://host/a"), destination: nil)])
        let local = ResourceTransferRequest(mode: .copy, items: [OperationItem(source: URL(fileURLWithPath: "/a"), destination: nil)])
        XCTAssertEqual(providers.provider(for: remote)?.id, "stub.sftp")
        XCTAssertNil(providers.provider(for: local))
        token.cancel()
        XCTAssertNil(providers.provider(for: remote))
        XCTAssertTrue(providers.providerIDs.isEmpty)
    }
}
