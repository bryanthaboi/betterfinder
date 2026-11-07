import Combine
import XCTest
@testable import FileOps

@MainActor
final class FileOpsTests: FileOpsTestCase {
    func testUniqueDestination() throws {
        let dir = try dir("u")
        try file("a.txt", in: dir)
        XCTAssertEqual(FileOperationQueue.uniqueDestination(for: "a.txt", in: dir).lastPathComponent, "a 2.txt")
    }

    func testCopyReportsProgress() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let big = src.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 8 << 20).write(to: big)
        try file("small.txt", in: src, "hello")

        var samples: [FileOperationProgress] = []
        let op = queue.enqueue(.copy(sources: [big, src.appendingPathComponent("small.txt")], destination: dst))
        let cancellable = op.$progress.sink { samples.append($0) }
        await waitIdle()
        cancellable.cancel()

        XCTAssertEqual(op.state, .finished)
        XCTAssertTrue(op.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("big.bin")).count, 8 << 20)
        XCTAssertEqual(read(dst.appendingPathComponent("small.txt")), "hello")
        XCTAssertEqual(op.progress.totalUnits, Int64(8 << 20) + 5)
        XCTAssertEqual(op.progress.completedUnits, op.progress.totalUnits)
        XCTAssertEqual(op.progress.itemsCompleted, 2)
        XCTAssertEqual(op.progress.fractionCompleted, 1, accuracy: 0.0001)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(op.resultingURLs.count, 2)
    }

    func testCopyDirectoryTreeRecursively() async throws {
        let src = try dir("src")
        let tree = try dir("src/tree")
        try file("a.txt", in: tree, "A")
        let sub = try dir("src/tree/sub")
        try file("b.txt", in: sub, "B")
        let dst = try dir("dst")
        let op = await run(.copy(sources: [tree], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(dst.appendingPathComponent("tree/a.txt")), "A")
        XCTAssertEqual(read(dst.appendingPathComponent("tree/sub/b.txt")), "B")
        XCTAssertTrue(exists(src.appendingPathComponent("tree/a.txt")))
    }

    func testMoveAcrossFolders() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("m.txt", in: src, "moved")
        let op = await run(.move(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertFalse(exists(f))
        XCTAssertEqual(read(dst.appendingPathComponent("m.txt")), "moved")
        XCTAssertEqual(op.resultingURLs, [dst.appendingPathComponent("m.txt")])
    }

    func testConflictKeepBothWithoutResolverIsDefault() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("c.txt", in: src, "new")
        try file("c.txt", in: dst, "old")
        let op = await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(dst.appendingPathComponent("c.txt")), "old")
        XCTAssertEqual(read(dst.appendingPathComponent("c 2.txt")), "new")
    }

    func testConflictKeepBothViaResolver() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("c.txt", in: src, "new")
        try file("c.txt", in: dst, "old")
        let resolver = ScriptedResolver([ConflictDecision(.keepBoth)])
        await run(.copy(sources: [f], destination: dst), resolver: resolver)
        XCTAssertEqual(resolver.asked.count, 1)
        XCTAssertEqual(read(dst.appendingPathComponent("c.txt")), "old")
        XCTAssertEqual(read(dst.appendingPathComponent("c 2.txt")), "new")
    }

    func testConflictSkip() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("c.txt", in: src, "new")
        try file("c.txt", in: dst, "old")
        let op = await run(.copy(sources: [f], destination: dst), resolver: ScriptedResolver([ConflictDecision(.skip)]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(op.skippedCount, 1)
        XCTAssertEqual(read(dst.appendingPathComponent("c.txt")), "old")
        XCTAssertFalse(exists(dst.appendingPathComponent("c 2.txt")))
        XCTAssertTrue(op.resultingURLs.isEmpty)
    }

    func testConflictReplace() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("c.txt", in: src, "new")
        try file("c.txt", in: dst, "old")
        let op = await run(.copy(sources: [f], destination: dst), resolver: ScriptedResolver([ConflictDecision(.replace)]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(dst.appendingPathComponent("c.txt")), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dst.path)
        XCTAssertEqual(leftovers, ["c.txt"])
    }

    func testConflictApplyToAll() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let a = try file("a.txt", in: src, "newA")
        let b = try file("b.txt", in: src, "newB")
        try file("a.txt", in: dst, "oldA")
        try file("b.txt", in: dst, "oldB")
        let resolver = ScriptedResolver([ConflictDecision(.replace, applyToAll: true)])
        await run(.copy(sources: [a, b], destination: dst), resolver: resolver)
        XCTAssertEqual(resolver.asked.count, 1)
        XCTAssertEqual(read(dst.appendingPathComponent("a.txt")), "newA")
        XCTAssertEqual(read(dst.appendingPathComponent("b.txt")), "newB")
    }

    func testConflictStopCancels() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let a = try file("a.txt", in: src, "newA")
        let b = try file("b.txt", in: src, "newB")
        try file("a.txt", in: dst, "oldA")
        let op = await run(.copy(sources: [a, b], destination: dst), resolver: ScriptedResolver([ConflictDecision(.stop)]))
        XCTAssertEqual(op.state, .cancelled)
        XCTAssertEqual(read(dst.appendingPathComponent("a.txt")), "oldA")
        XCTAssertFalse(exists(dst.appendingPathComponent("b.txt")))
    }

    func testMergeFolders() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let s = try dir("src/box")
        let d = try dir("dst/box")
        try file("same.txt", in: s, "fromSrc")
        try file("only-src.txt", in: s, "x")
        try file("same.txt", in: d, "fromDst")
        try file("only-dst.txt", in: d, "y")
        let resolver = ScriptedResolver([ConflictDecision(.merge), ConflictDecision(.keepBoth)])
        let op = await run(.copy(sources: [s], destination: dst), resolver: resolver)
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(resolver.asked.count, 2)
        XCTAssertEqual(read(d.appendingPathComponent("same.txt")), "fromDst")
        XCTAssertEqual(read(d.appendingPathComponent("same 2.txt")), "fromSrc")
        XCTAssertEqual(read(d.appendingPathComponent("only-src.txt")), "x")
        XCTAssertEqual(read(d.appendingPathComponent("only-dst.txt")), "y")
        XCTAssertTrue(exists(src.appendingPathComponent("box/only-src.txt")))
    }

    func testMoveMergeRemovesSourceFolder() async throws {
        let dst = try dir("dst")
        let s = try dir("src/box")
        let d = try dir("dst/box")
        try file("one.txt", in: s, "1")
        try file("two.txt", in: d, "2")
        let op = await run(.move(sources: [s], destination: dst), resolver: ScriptedResolver([ConflictDecision(.merge)]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertFalse(exists(s))
        XCTAssertEqual(read(d.appendingPathComponent("one.txt")), "1")
        XCTAssertEqual(read(d.appendingPathComponent("two.txt")), "2")
    }

    func testCancelCleansPartialFile() throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let big = src.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: 160 << 20).write(to: big)
        let savedFlags = CopyEngine.flags
        let savedInterval = ProgressTracker.minInterval
        CopyEngine.flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        ProgressTracker.minInterval = 0
        defer {
            CopyEngine.flags = savedFlags
            ProgressTracker.minInterval = savedInterval
        }
        let control = OperationControl()
        let runner = OperationRunner(
            plans: [ItemPlan(action: .copy, source: big, destination: dst.appendingPathComponent("big.bin"), forcedChoice: nil)],
            control: control, resolver: nil, defaultChoice: .keepBoth, trashService: service, verify: false,
            sink: { p in if p.completedUnits > 0 { control.cancel() } }
        )
        let outcome = runner.run()
        XCTAssertEqual(outcome.abort, "cancelled")
        XCTAssertTrue(outcome.completed.isEmpty)
        XCTAssertFalse(exists(dst.appendingPathComponent("big.bin")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path), [])
    }

    func testCancelQueuedOperation() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let big = src.appendingPathComponent("big.bin")
        try Data(repeating: 3, count: 4 << 20).write(to: big)
        let first = queue.enqueue(.copy(sources: [big], destination: dst))
        let second = queue.enqueue(.copy(sources: [big], destination: dst))
        XCTAssertEqual(second.state, .queued)
        second.cancel()
        XCTAssertEqual(second.state, .cancelled)
        await waitIdle()
        XCTAssertEqual(first.state, .finished)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path), ["big.bin"])
    }

    func testPausedQueuedOperationWaitsForResume() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let a = try file("a.txt", in: src, "A")
        let b = try file("b.txt", in: src, "B")
        let first = queue.enqueue(.copy(sources: [a], destination: dst))
        let second = queue.enqueue(.copy(sources: [b], destination: dst))
        second.pause()
        XCTAssertEqual(second.state, .paused)
        while first.isActive { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(second.state, .paused)
        XCTAssertFalse(exists(dst.appendingPathComponent("b.txt")))
        second.resume()
        await waitIdle()
        XCTAssertEqual(second.state, .finished)
        XCTAssertEqual(read(dst.appendingPathComponent("b.txt")), "B")
    }

    func testPerItemErrorsAndRetry() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let good = try file("good.txt", in: src, "ok")
        let missing = src.appendingPathComponent("missing.txt")
        let op = await run(.copy(sources: [missing, good], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(op.errors.count, 1)
        XCTAssertEqual(op.failedURLs, [missing])
        XCTAssertEqual(read(dst.appendingPathComponent("good.txt")), "ok")
        XCTAssertTrue(op.canRetry)

        try file("missing.txt", in: src, "late")
        let retried = op.retryFailed()
        XCTAssertNotNil(retried)
        await waitIdle()
        XCTAssertEqual(retried?.state, .finished)
        XCTAssertTrue(retried?.errors.isEmpty ?? false)
        XCTAssertEqual(read(dst.appendingPathComponent("missing.txt")), "late")
        XCTAssertEqual(queue.operations.count, 1)
    }

    func testAllItemsFailedMarksOperationFailed() async throws {
        let dst = try dir("dst")
        let op = await run(.copy(sources: [root.appendingPathComponent("nope")], destination: dst))
        guard case .failed = op.state else { return XCTFail("expected failed, got \(op.state)") }
        XCTAssertEqual(op.errors.count, 1)
    }

    func testCannotCopyFolderIntoItself() async throws {
        let folder = try dir("folder")
        let op = await run(.copy(sources: [folder], destination: folder))
        guard case .failed = op.state else { return XCTFail("expected failed, got \(op.state)") }
    }

    func testVerifyCopiesOption() async throws {
        UserDefaults.standard.set(true, forKey: "verifyCopies")
        defer { UserDefaults.standard.removeObject(forKey: "verifyCopies") }
        let src = try dir("src")
        let dst = try dir("dst")
        let tree = try dir("src/tree")
        try file("a.txt", in: tree, "alpha")
        try Data(repeating: 9, count: 3 << 20).write(to: tree.appendingPathComponent("b.bin"))
        let op = await run(.copy(sources: [tree], destination: dst))
        XCTAssertEqual(op.state, .finished)
        XCTAssertTrue(op.errors.isEmpty)
        XCTAssertEqual(op.progress.totalUnits, 2 * (5 + Int64(3 << 20)))
        XCTAssertEqual(op.progress.completedUnits, op.progress.totalUnits)
        _ = src
    }

    func testVerifierDetectsMismatch() throws {
        let d = try dir("v")
        let a = try file("a.txt", in: d, "one")
        let b = try file("b.txt", in: d, "two")
        let tracker = ProgressTracker(totalBytes: 100, totalItems: 1) { _ in }
        XCTAssertThrowsError(try Verifier.verify(source: a, destination: b, control: OperationControl(), tracker: tracker)) { error in
            XCTAssertTrue(error is ChecksumMismatch)
        }
        XCTAssertNoThrow(try Verifier.verify(source: a, destination: a, control: OperationControl(), tracker: tracker))
    }

    func testOverallProgressPublishedWhileActive() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("a.txt", in: src, "A")
        let idle = queue.overallProgress
        XCTAssertNil(idle)
        queue.enqueue(.copy(sources: [f], destination: dst))
        let busy = queue.overallProgress
        let busyCount = queue.activeOperationCount
        XCTAssertNotNil(busy)
        XCTAssertEqual(busyCount, 1)
        await waitIdle()
        let done = queue.overallProgress
        let doneCount = queue.activeOperationCount
        XCTAssertNil(done)
        XCTAssertEqual(doneCount, 0)
    }

    func testDuplicate() async throws {
        let src = try dir("src")
        let f = try file("d.txt", in: src, "dup")
        let op = await run(.duplicate(items: [f]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(src.appendingPathComponent("d copy.txt")), "dup")
    }

    func testNestedUnreadableFileIsReportedAndSiblingsStillCopy() async throws {
        let tree = try dir("src/tree")
        try file("ok.txt", in: tree, "ok")
        let locked = try file("locked.txt", in: tree, "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let dst = try dir("dst")
        let op = await run(.copy(sources: [tree], destination: dst))
        XCTAssertEqual(read(dst.appendingPathComponent("tree/ok.txt")), "ok")
        XCTAssertEqual(op.errors.count, 1)
        XCTAssertEqual(op.errors.first?.url.lastPathComponent, "locked.txt")
        XCTAssertEqual(op.errors.first?.code, EACCES)
    }
}
