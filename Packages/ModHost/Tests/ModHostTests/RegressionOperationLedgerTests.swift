import Foundation
import ModHostProtocol
import ModKit
import XCTest
@testable import ModHost

final class RegressionOperationLedgerTests: XCTestCase {
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testCancelBeforeStartNeverSpawns() async {
        let handle = ModProcessHandle()
        XCTAssertTrue(handle.cancel())
        let start = Date()
        let r = await ModProcessRunner.run("/bin/sleep", ["30"], environment: [:], timeout: 60, handle: handle)
        XCTAssertEqual(r?.cancelled, true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancelStopsRunningProcess() async {
        let handle = ModProcessHandle()
        let task = Task { await ModProcessRunner.run("/bin/sleep", ["30"], environment: [:], timeout: 60, handle: handle) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        XCTAssertTrue(handle.cancel())
        let r = await task.value
        XCTAssertEqual(r?.cancelled, true)
        XCTAssertNotEqual(r?.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(handle.cancel())
    }

    func testFinishedHandleCannotBeCancelled() {
        let handle = ModProcessHandle()
        XCTAssertEqual(handle.finish { true }, true)
        XCTAssertFalse(handle.cancel())
        let cancelled = ModProcessHandle()
        cancelled.cancel()
        XCTAssertNil(cancelled.finish { XCTFail("must not commit after cancel"); return true })
    }

    func testLedgerCancelUsesHandleAndReportsState() async {
        let ledger = ModOperationLedger()
        let handle = ModProcessHandle()
        ledger.register("arc_1", owner: "alice.one", external: false, progress: ModOperationProgress(state: .running, completed: 0, total: 1), handle: handle)
        let other = await ledger.cancel("arc_1", owner: "bob.two", external: nil)
        XCTAssertNil(other)
        let ok = await ledger.cancel("arc_1", owner: "alice.one", external: nil)
        XCTAssertEqual(ok, true)
        XCTAssertTrue(handle.isCancelled)
        let state = await ledger.status("arc_1", owner: "alice.one", external: nil)
        XCTAssertEqual(state?.state, .cancelled)
        ledger.update("arc_1", ModOperationProgress(state: .done, completed: 1, total: 1))
        let after = await ledger.status("arc_1", owner: "alice.one", external: nil)
        XCTAssertEqual(after?.state, .cancelled)
        let again = await ledger.cancel("arc_1", owner: "alice.one", external: nil)
        XCTAssertEqual(again, false)
    }

    func testUnloadCancelsActiveAndExpiresOwnerEntries() async {
        let ledger = ModOperationLedger()
        let running = ModProcessHandle()
        ledger.register("arc_run", owner: "alice.one", external: false, progress: ModOperationProgress(state: .running, completed: 0, total: 1), handle: running)
        ledger.register("arc_done", owner: "alice.one", external: false, progress: ModOperationProgress(state: .done, completed: 1, total: 1))
        ledger.register("op_ext", owner: "alice.one", external: true)
        ledger.register("arc_other", owner: "bob.two", external: false, progress: ModOperationProgress(state: .running, completed: 0, total: 1), handle: ModProcessHandle())
        ledger.cancelAll(owner: "alice.one")
        XCTAssertTrue(running.isCancelled)
        XCTAssertEqual(ledger.count, 1)
        for id in ["arc_run", "arc_done", "op_ext"] {
            let lookup = await ledger.lookup(id, owner: "alice.one", external: nil)
            XCTAssertEqual(lookup, .expired, id)
        }
        let foreign = await ledger.lookup("arc_run", owner: "bob.two", external: nil)
        XCTAssertEqual(foreign, .unknown)
        let never = await ledger.lookup("nope", owner: "alice.one", external: nil)
        XCTAssertEqual(never, .unknown)
        let cancelExpired = await ledger.cancel("arc_run", owner: "alice.one", external: nil)
        XCTAssertEqual(cancelExpired, false)
        let otherState = await ledger.status("arc_other", owner: "bob.two", external: nil)
        XCTAssertEqual(otherState?.state, .running)
    }

    func testTerminalEntriesAreBoundedAndRunningAreKept() async {
        let ledger = ModOperationLedger(terminalLimit: 10, totalLimit: 20, expiredLimit: 100)
        let running = ModProcessHandle()
        ledger.register("keep", owner: "m", external: false, progress: ModOperationProgress(state: .running, completed: 0, total: 1), handle: running)
        for i in 0..<500 {
            ledger.register("t\(i)", owner: "m", external: false, progress: ModOperationProgress(state: .running, completed: 0, total: 1), handle: ModProcessHandle())
            ledger.update("t\(i)", ModOperationProgress(state: .done, completed: 1, total: 1))
        }
        XCTAssertLessThanOrEqual(ledger.count, 11)
        let kept = await ledger.status("keep", owner: "m", external: nil)
        XCTAssertEqual(kept?.state, .running)
        let newest = await ledger.status("t499", owner: "m", external: nil)
        XCTAssertEqual(newest?.state, .done)
        let recentlyExpired = await ledger.lookup("t450", owner: "m", external: nil)
        XCTAssertEqual(recentlyExpired, .expired)
        let longGone = await ledger.lookup("t0", owner: "m", external: nil)
        XCTAssertEqual(longGone, .unknown)
        for i in 0..<100 {
            ledger.register("e\(i)", owner: "m", external: true)
            ledger.update("e\(i)", ModOperationProgress(state: .done, completed: 1, total: 1))
        }
        XCTAssertLessThanOrEqual(ledger.count, 20)
        let stillRunning = await ledger.status("keep", owner: "m", external: nil)
        XCTAssertEqual(stillRunning?.state, .running)
    }

    @MainActor
    func archiveFixture() throws -> (env: TestEnv, mod: ActiveMod, args: [JSONValue], dest: URL) {
        let env = try TestEnv()
        let manifest = ModManifest(id: "alice.arc", name: "a", author: "alice", version: SemVer(1, 0, 0), api: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), app: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), runtime: .ts, entry: "x.ts", license: "MIT",
                                   permissions: [
                                       ModPermission(kind: .fsRead, reason: "r", scope: .selection, recursive: true),
                                       ModPermission(kind: .fsWrite, reason: "w", scope: .selection),
                                       ModPermission(kind: .processExec, reason: "p", mode: .broker, operations: ["archive.create"]),
                                   ])
        let mod = ActiveMod(manifest: manifest, generation: 1, snapshot: env.work, mode: .live, grants: manifest.permissions, logs: ModLogBuffer(file: nil), storageURL: env.work.appendingPathComponent("s.json"), settings: nil)
        let file = try env.file("doc.txt", "hello archive")
        let dest = env.work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let refs = env.runtime.broker.makeRefs(mod, urls: [file, dest], invocation: nil)
        return (env, mod, [.array([refs[0]]), refs[1], .string("bundle"), .string("zip")], dest)
    }

    func leftovers(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testArchiveCancelStopsJobAndNeverPublishes() async throws {
        let f = try await archiveFixture()
        defer { Task { await f.env.cleanup() } }
        let broker = f.env.runtime.broker
        let started = ModOnceFlag()
        let finished = ModOnceFlag()
        broker.archiveRunner = { args, handle in
            FileManager.default.createFile(atPath: args[2], contents: Data("partial".utf8))
            started.set()
            let r = await ModProcessRunner.run("/bin/sleep", ["30"], environment: [:], timeout: 60, handle: handle)
            finished.set()
            return r
        }
        let out = try broker.archive(f.mod, f.args)
        let id = try XCTUnwrap(out["operationId"]?.stringValue)
        XCTAssertTrue(waitUntil(5) { started.isSet })
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelled = await broker.deps.ledger.cancel(id, owner: f.mod.id, external: nil)
        XCTAssertEqual(cancelled, true)
        XCTAssertTrue(waitUntil(5) { finished.isSet })
        XCTAssertTrue(waitUntil(5) { self.leftovers(f.dest).isEmpty }, "\(leftovers(f.dest))")
        let state = await broker.deps.ledger.status(id, owner: f.mod.id, external: nil)
        XCTAssertEqual(state?.state, .cancelled)
    }

    func testArchiveCancelledByUnloadBeforeStartNeverRuns() async throws {
        let f = try await archiveFixture()
        defer { Task { await f.env.cleanup() } }
        let broker = f.env.runtime.broker
        let gate = DispatchSemaphore(value: 0)
        let spawned = ModOnceFlag()
        let finished = ModOnceFlag()
        broker.archiveRunner = { args, handle in
            gate.wait()
            let r = await ModProcessRunner.run("/usr/bin/touch", [args[2]], environment: [:], timeout: 10, handle: handle)
            if r?.cancelled != true { spawned.set() }
            finished.set()
            return r
        }
        let out = try broker.archive(f.mod, f.args)
        let id = try XCTUnwrap(out["operationId"]?.stringValue)
        broker.deps.ledger.cancelAll(owner: f.mod.id)
        gate.signal()
        XCTAssertTrue(waitUntil(5) { finished.isSet })
        XCTAssertFalse(spawned.isSet)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(leftovers(f.dest), [])
        let lookup = await broker.deps.ledger.lookup(id, owner: f.mod.id, external: nil)
        XCTAssertEqual(lookup, .expired)
        let status = await broker.handle(ModCallRequest(callId: "1", invocationId: "x", modId: f.mod.id, generation: 1, name: "operations.status", args: [.string(id)]),
                                         invocation: ModInvocation(mod: f.mod, hook: try XCTUnwrap(ModCatalog.v1.hook(named: "command.run", version: 1)), handler: "h", gesture: false, parent: nil))
        XCTAssertEqual(status.error?.code, "notFound")
        XCTAssertTrue(status.error?.message.contains("expired") == true)
    }

    func testArchiveWithRealTarPublishes() async throws {
        let f = try await archiveFixture()
        defer { Task { await f.env.cleanup() } }
        let broker = f.env.runtime.broker
        let out = try broker.archive(f.mod, f.args)
        let id = try XCTUnwrap(out["operationId"]?.stringValue)
        var state: ModOperationState?
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            state = await broker.deps.ledger.status(id, owner: f.mod.id, external: nil)?.state
            if state != .running { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(state, .done)
        XCTAssertEqual(leftovers(f.dest), ["bundle.zip"])
        let late = await broker.deps.ledger.cancel(id, owner: f.mod.id, external: nil)
        XCTAssertEqual(late, false)
    }
}

final class ModOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
