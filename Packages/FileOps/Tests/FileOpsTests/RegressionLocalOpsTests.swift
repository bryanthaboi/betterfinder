import AppKit
import XCTest
@testable import FileOps

@MainActor
final class RegressionLocalOpsTests: FileOpsTestCase {
    override func setUp() async throws {
        try await super.setUp()
        queue.hooks = FileOperationHookRegistry()
        queue.announcesStateChanges = false
    }

    func settle() async {
        let end = Date().addingTimeInterval(30)
        while (queue.operations.contains(where: \.isActive) || queue.undoWorkInFlight > 0), Date() < end {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func undoAndSettle() async {
        undo.undo()
        await settle()
    }

    func redoAndSettle() async {
        undo.redo()
        await settle()
    }

    func trashNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? []).sorted()
    }

    func testMergedCopyUndoPreservesPreexistingFile() async throws {
        let src = try dir("source/docs")
        let dst = try dir("destination/docs")
        try file("new.txt", in: src, "new")
        try file("old.txt", in: dst, "old")
        let op = await run(.copy(sources: [src], destination: dst.deletingLastPathComponent()), resolver: ScriptedResolver([ConflictDecision(.merge)]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(dst.appendingPathComponent("new.txt")), "new")
        await undoAndSettle()
        XCTAssertEqual(read(dst.appendingPathComponent("old.txt")), "old")
        XCTAssertFalse(exists(dst.appendingPathComponent("new.txt")))
        XCTAssertTrue(exists(dst))
        await redoAndSettle()
        XCTAssertEqual(read(dst.appendingPathComponent("new.txt")), "new")
        XCTAssertEqual(read(dst.appendingPathComponent("old.txt")), "old")
    }

    func testMergedMoveUndoOnlyMovesItsOwnChildren() async throws {
        let src = try dir("source/docs")
        let dst = try dir("destination/docs")
        try file("new.txt", in: src, "new")
        try file("old.txt", in: dst, "old")
        await run(.move(sources: [src], destination: dst.deletingLastPathComponent()), resolver: ScriptedResolver([ConflictDecision(.merge)]))
        XCTAssertFalse(exists(src))
        XCTAssertEqual(read(dst.appendingPathComponent("new.txt")), "new")
        await undoAndSettle()
        XCTAssertEqual(read(src.appendingPathComponent("new.txt")), "new")
        XCTAssertFalse(exists(src.appendingPathComponent("old.txt")))
        XCTAssertEqual(read(dst.appendingPathComponent("old.txt")), "old")
        XCTAssertFalse(exists(dst.appendingPathComponent("new.txt")))
    }

    func testCopyReplaceUndoRestoresOriginalBytes() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        try file("f.txt", in: src, "replacement")
        try file("f.txt", in: dst, "original")
        let op = await run(.copy(sources: [src.appendingPathComponent("f.txt")], destination: dst), resolver: ScriptedResolver([ConflictDecision(.replace)]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertNil(op.undoUnavailableReason)
        XCTAssertEqual(read(dst.appendingPathComponent("f.txt")), "replacement")
        XCTAssertEqual(trashNames(), ["f.txt"])
        await undoAndSettle()
        XCTAssertEqual(read(dst.appendingPathComponent("f.txt")), "original")
        XCTAssertEqual(read(src.appendingPathComponent("f.txt")), "replacement")
        await redoAndSettle()
        XCTAssertEqual(read(dst.appendingPathComponent("f.txt")), "replacement")
        await undoAndSettle()
        XCTAssertEqual(read(dst.appendingPathComponent("f.txt")), "original")
    }

    func testMoveReplaceUndoRestoresBothSides() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        try file("f.txt", in: src, "replacement")
        try file("f.txt", in: dst, "original")
        await run(.move(sources: [src.appendingPathComponent("f.txt")], destination: dst), resolver: ScriptedResolver([ConflictDecision(.replace)]))
        XCTAssertFalse(exists(src.appendingPathComponent("f.txt")))
        XCTAssertEqual(read(dst.appendingPathComponent("f.txt")), "replacement")
        await undoAndSettle()
        XCTAssertEqual(read(src.appendingPathComponent("f.txt")), "replacement")
        XCTAssertEqual(read(dst.appendingPathComponent("f.txt")), "original")
    }

    func testFolderReplaceUndoRestoresOriginalFolder() async throws {
        let src = try dir("src/docs")
        let dst = try dir("dst/docs")
        try file("a.txt", in: src, "a")
        try file("keep.txt", in: dst, "keep")
        await run(.copy(sources: [src], destination: dst.deletingLastPathComponent()), resolver: ScriptedResolver([ConflictDecision(.replace)]))
        XCTAssertFalse(exists(dst.appendingPathComponent("keep.txt")))
        await undoAndSettle()
        XCTAssertEqual(read(dst.appendingPathComponent("keep.txt")), "keep")
        XCTAssertFalse(exists(dst.appendingPathComponent("a.txt")))
    }

    func testPartialReplacementKeepsOriginalAndIsRetryable() async throws {
        let src = try dir("src/docs")
        let dst = try dir("dst/docs")
        try file("a.txt", in: src, "a")
        let locked = try file("locked.txt", in: src, "secret")
        try file("keep.txt", in: dst, "keep")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let op = await run(.copy(sources: [src], destination: dst.deletingLastPathComponent()), resolver: ScriptedResolver([ConflictDecision(.replace), ConflictDecision(.replace)]))
        XCTAssertFalse(op.errors.isEmpty)
        XCTAssertEqual(read(dst.appendingPathComponent("keep.txt")), "keep")
        XCTAssertFalse(exists(dst.appendingPathComponent("a.txt")))
        XCTAssertTrue(op.canRetry)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["docs"])
        chmod(locked.path, 0o644)
        let retried = try XCTUnwrap(op.retry())
        await settle()
        XCTAssertEqual(retried.state, .finished)
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertEqual(read(dst.appendingPathComponent("locked.txt")), "secret")
        XCTAssertFalse(exists(dst.appendingPathComponent("keep.txt")))
    }

    func testPartialCopyIsRetryableWithoutDuplicating() async throws {
        let src = try dir("src/docs")
        let dst = try dir("dst")
        try file("a.txt", in: src, "a")
        let locked = try file("locked.txt", in: src, "secret")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let resolver = ScriptedResolver([])
        let op = await run(.copy(sources: [src], destination: dst), resolver: resolver)
        XCTAssertFalse(op.errors.isEmpty)
        XCTAssertTrue(op.canRetry)
        XCTAssertEqual(read(dst.appendingPathComponent("docs/a.txt")), "a")
        chmod(locked.path, 0o644)
        let retried = try XCTUnwrap(op.retry())
        await settle()
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertTrue(resolver.asked.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path), ["docs"])
        XCTAssertEqual(read(dst.appendingPathComponent("docs/locked.txt")), "secret")
        XCTAssertEqual(read(dst.appendingPathComponent("docs/a.txt")), "a")
    }

    func testRetryOfPartialMergeStillAsksAboutPreexistingFiles() async throws {
        let src = try dir("src/docs")
        let dst = try dir("dst/docs")
        try file("same.txt", in: src, "incoming")
        let locked = try file("locked.txt", in: src, "secret")
        try file("same.txt", in: dst, "preexisting")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let resolver = ScriptedResolver([ConflictDecision(.merge), ConflictDecision(.skip), ConflictDecision(.skip)])
        let op = await run(.copy(sources: [src], destination: dst.deletingLastPathComponent()), resolver: resolver)
        XCTAssertTrue(op.canRetry)
        XCTAssertEqual(resolver.asked.count, 2)
        chmod(locked.path, 0o644)
        _ = try XCTUnwrap(op.retry())
        await settle()
        XCTAssertEqual(read(dst.appendingPathComponent("same.txt")), "preexisting")
        XCTAssertEqual(read(dst.appendingPathComponent("locked.txt")), "secret")
        XCTAssertEqual(resolver.asked.count, 3)
    }

    func testFailedUndoRenameIsReportedAndStaysUndoable() throws {
        let shared = FileOperationQueue.shared
        let saved = shared.undoManager
        shared.undoManager = undo
        shared.announcesStateChanges = false
        defer { shared.undoManager = saved }
        let d = try dir("r")
        let original = try file("old.txt", in: d, "mine")
        let renamed = try FileActions.rename(original, to: "new.txt")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try file("old.txt", in: d, "blocker")
        let before = shared.operations.count
        undo.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let reported = shared.operations.dropFirst(before)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.title, "Undo Rename")
        XCTAssertFalse(reported.first?.errors.isEmpty ?? true)
        XCTAssertEqual(read(renamed), "mine")
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        for op in reported { shared.remove(op) }
        try FileManager.default.removeItem(at: original)
        undo.undo()
        XCTAssertEqual(read(original), "mine")
        XCTAssertTrue(undo.canRedo)
    }

    func testUndoTrashWithMissingItemReportsAndKeepsJournal() async throws {
        let src = try dir("src")
        let f = try file("t.txt", in: src, "x")
        await run(.trash(items: [f]))
        let trashed = trashDir.appendingPathComponent("t.txt")
        let parked = root.appendingPathComponent("parked.txt")
        try FileManager.default.moveItem(at: trashed, to: parked)
        let before = queue.operations.count
        await undoAndSettle()
        XCTAssertEqual(queue.operations.count, before + 1)
        XCTAssertEqual(queue.operations.last?.title, "Undo Move to Trash")
        XCTAssertNotNil(journal.entry(forTrashedURL: trashed))
        XCTAssertTrue(undo.canUndo)
        try FileManager.default.moveItem(at: parked, to: trashed)
        await undoAndSettle()
        XCTAssertEqual(read(f), "x")
    }

    func testCrossVolumeMoveCleanupKeepsChangedAndNewFiles() throws {
        let src = try dir("src/docs")
        let copy = root.appendingPathComponent("copy/docs")
        try file("same.txt", in: src, "same")
        try file("edited.txt", in: src, "before")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: copy)
        Thread.sleep(forTimeInterval: 0.02)
        let since = timespec.now
        Thread.sleep(forTimeInterval: 0.02)
        try file("edited.txt", in: src, "after!")
        try file("late.txt", in: src, "late")
        let runner = OperationRunner(plans: [], control: OperationControl(), resolver: nil, defaultChoice: .keepBoth, trashService: service, verify: false, sink: { _ in })
        guard case .partial(let removed) = runner.removeCopied(src, copy: copy, since: since) else { return XCTFail("expected a partial cleanup") }
        XCTAssertEqual(removed.map(\.source.lastPathComponent), ["same.txt"])
        XCTAssertFalse(exists(src.appendingPathComponent("same.txt")))
        XCTAssertEqual(read(src.appendingPathComponent("edited.txt")), "after!")
        XCTAssertEqual(read(src.appendingPathComponent("late.txt")), "late")
        XCTAssertEqual(runner.errors.all.count, 2)
    }

    func testJournalKeepsEntriesOnUnmountedVolumes() throws {
        try journal.record(originalURL: URL(fileURLWithPath: "/Volumes/bf-missing-\(UUID().uuidString)/a.txt"), trashedURL: URL(fileURLWithPath: "/Volumes/bf-missing-\(UUID().uuidString)/.Trashes/501/a.txt"))
        try journal.record(originalURL: URL(fileURLWithPath: "/tmp/gone/b.txt"), trashedURL: URL(fileURLWithPath: "/tmp/.Trash-missing/b.txt"))
        XCTAssertEqual(journal.purgeMissing(), 1)
        XCTAssertEqual(journal.entries().count, 1)
    }

    func testFinishedHistoryIsBoundedAndCompacted() async throws {
        queue.historyLimit = 5
        let src = try dir("src")
        let dst = try dir("dst")
        for i in 0..<12 {
            let f = try file("f\(i).txt", in: src, "\(i)")
            await run(.copy(sources: [f], destination: dst))
        }
        XCTAssertLessThanOrEqual(queue.operations.count, 5)
        for op in queue.operations {
            XCTAssertTrue(op.plans.isEmpty)
            XCTAssertNil(op.onFinish)
        }
        XCTAssertTrue(undo.canUndo)
        await undoAndSettle()
        XCTAssertFalse(exists(dst.appendingPathComponent("f11.txt")))
    }

    func testRetryableHistoryOutlivesCleanHistory() async throws {
        queue.historyLimit = 3
        let src = try dir("src")
        let dst = try dir("dst")
        let locked = try file("locked.txt", in: src, "secret")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let failing = await run(.copy(sources: [locked], destination: dst))
        XCTAssertTrue(failing.canRetry)
        for i in 0..<6 {
            let f = try file("f\(i).txt", in: src, "\(i)")
            await run(.copy(sources: [f], destination: dst))
        }
        XCTAssertTrue(queue.operations.contains { $0 === failing })
        XCTAssertLessThanOrEqual(queue.operations.count, 3)
    }

    func testAttentionBadgeUntilAcknowledged() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("ok.txt", in: src, "ok")
        await run(.copy(sources: [f], destination: dst))
        XCTAssertEqual(queue.attention, .completed(1))
        let locked = try file("locked.txt", in: src, "secret")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        await run(.copy(sources: [locked], destination: dst))
        XCTAssertEqual(queue.attention, .failed(1))
        await run(.copy(sources: [f], destination: try dir("dst2")))
        XCTAssertEqual(queue.attention, .failed(1))
        queue.acknowledgeFinished()
        XCTAssertEqual(queue.attention, .none)
    }

    func testIndicatorIsAccessibleButtonAndKeepsBadge() async throws {
        let indicator = OperationsIndicatorView(queue: queue)
        let button = indicator.accessibleButton
        XCTAssertEqual(button.accessibilityLabel(), "File operations")
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertTrue(indicator.isHidden)
        let src = try dir("src")
        let f = try file("ok.txt", in: src, "ok")
        await run(.copy(sources: [f], destination: try dir("dst")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue((button.accessibilityValue() as? String)?.contains("finished") ?? false)
        var clicked = false
        indicator.onClick = { clicked = true }
        XCTAssertTrue(indicator.accessibilityPerformPress())
        XCTAssertTrue(clicked)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(queue.attention, .none)
        XCTAssertTrue(indicator.isHidden)
    }

    func testOperationRowLabelsIdentifyTheOperation() async throws {
        let src = try dir("src")
        let f = try file("ok.txt", in: src, "ok")
        let op = await run(.copy(sources: [f], destination: try dir("dst")))
        let row = OperationRowView(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
        row.bind(op)
        row.refresh(op: op, state: .running, progress: FileOperationProgress(completedUnits: 5, totalUnits: 10, currentItem: nil), errors: [])
        let bar = try XCTUnwrap(row.descendants.compactMap { $0 as? NSProgressIndicator }.first)
        XCTAssertEqual(bar.accessibilityLabel(), "Progress for \(op.title)")
        let labels = row.descendants.compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        XCTAssertTrue(labels.contains("Cancel \(op.title)"), "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Pause ") || $0.hasPrefix("Resume ") })
        XCTAssertTrue(labels.contains("Run \(op.title) Anyway"))
    }

    func testRecentlyTrashedModelPutsBackAndReportsConflicts() async throws {
        let src = try dir("src")
        let a = try file("a.txt", in: src, "a")
        let b = try file("b.txt", in: src, "b")
        await run(.trash(items: [a, b]))
        let model = RecentlyTrashedModel(service: service)
        model.reload()
        XCTAssertEqual(model.entries.count, 2)
        try file("a.txt", in: src, "occupant")
        XCTAssertEqual(model.conflicts(model.entries).map { $0.originalURL.lastPathComponent }, ["a.txt"])
        let report = await model.putBack(model.entries)
        XCTAssertEqual(report.restored.count, 2)
        XCTAssertEqual(read(src.appendingPathComponent("a.txt")), "occupant")
        XCTAssertEqual(read(src.appendingPathComponent("a 2.txt")), "a")
        XCTAssertEqual(read(b), "b")
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(RecentlyTrashedModel.summary(of: report), "Put back 2 items")
    }

    func testRecentlyTrashedWindowListsEntries() async throws {
        let src = try dir("src")
        let a = try file("a.txt", in: src, "a")
        await run(.trash(items: [a]))
        let controller = RecentlyTrashedWindowController(service: service)
        let vc = try XCTUnwrap(controller.contentViewController as? RecentlyTrashedViewController)
        _ = vc.view
        vc.reload()
        XCTAssertEqual(vc.table.numberOfRows, 1)
        XCTAssertEqual(vc.table.accessibilityLabel(), "Recently trashed items")
        XCTAssertFalse(vc.putBackButton.isEnabled)
        vc.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(vc.putBackButton.isEnabled)
    }
}

extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
