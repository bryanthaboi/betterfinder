import XCTest
@testable import FileOps

@MainActor
final class UndoTrashTests: FileOpsTestCase {
    func undoAndWait() async {
        undo.undo()
        await waitIdle()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func redoAndWait() async {
        undo.redo()
        await waitIdle()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func testUndoRedoOfMove() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("m.txt", in: src, "moved")
        let moved = dst.appendingPathComponent("m.txt")
        await run(.move(sources: [f], destination: dst))
        XCTAssertTrue(exists(moved))
        XCTAssertTrue(undo.canUndo)

        await undoAndWait()
        XCTAssertTrue(exists(f))
        XCTAssertFalse(exists(moved))
        XCTAssertTrue(undo.canRedo)

        await redoAndWait()
        XCTAssertFalse(exists(f))
        XCTAssertEqual(read(moved), "moved")
        XCTAssertTrue(undo.canUndo)

        await undoAndWait()
        XCTAssertEqual(read(f), "moved")
    }

    func testUndoRedoOfCopy() async throws {
        let src = try dir("src")
        let dst = try dir("dst")
        let f = try file("c.txt", in: src, "copy")
        let copied = dst.appendingPathComponent("c.txt")
        await run(.copy(sources: [f], destination: dst))
        XCTAssertTrue(exists(copied))

        await undoAndWait()
        XCTAssertFalse(exists(copied))
        XCTAssertTrue(exists(f))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path), ["c.txt"])

        await redoAndWait()
        XCTAssertEqual(read(copied), "copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path), [])
    }

    func testUndoOfDuplicate() async throws {
        let src = try dir("src")
        let f = try file("d.txt", in: src, "dup")
        await run(.duplicate(items: [f]))
        let copy = src.appendingPathComponent("d copy.txt")
        XCTAssertTrue(exists(copy))
        await undoAndWait()
        XCTAssertFalse(exists(copy))
        XCTAssertTrue(exists(f))
    }

    func testTrashRecordsJournalAndPutBack() async throws {
        let src = try dir("src")
        let f = try file("t.txt", in: src, "trash me")
        let op = await run(.trash(items: [f]))
        XCTAssertEqual(op.state, .finished)
        XCTAssertFalse(exists(f))
        let trashed = trashDir.appendingPathComponent("t.txt")
        XCTAssertEqual(op.resultingURLs, [trashed])
        XCTAssertTrue(exists(trashed))

        let entry = journal.entry(forTrashedURL: trashed)
        XCTAssertEqual(entry?.originalURL.path, f.path)
        XCTAssertEqual(entry?.trashedURL.path, trashed.path)
        XCTAssertNotNil(entry?.date)

        let report = service.putBack([trashed])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.restored.first?.restored.path, f.path)
        XCTAssertEqual(read(f), "trash me")
        XCTAssertFalse(exists(trashed))
        XCTAssertNil(journal.entry(forTrashedURL: trashed))
    }

    func testPutBackKeepsBothWhenOriginalOccupiedAndRecreatesParent() async throws {
        let src = try dir("src")
        let f = try file("t.txt", in: src, "first")
        await run(.trash(items: [f]))
        try file("t.txt", in: src, "occupant")
        let trashed = trashDir.appendingPathComponent("t.txt")
        let report = service.putBack([trashed])
        XCTAssertEqual(report.restored.first?.restored.lastPathComponent, "t 2.txt")
        XCTAssertEqual(read(f), "occupant")
        XCTAssertEqual(read(src.appendingPathComponent("t 2.txt")), "first")

        let nested = try dir("gone/deeper")
        let g = try file("g.txt", in: nested, "g")
        await run(.trash(items: [g]))
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone"))
        let r2 = service.putBack([trashDir.appendingPathComponent("g.txt")])
        XCTAssertTrue(r2.failures.isEmpty)
        XCTAssertEqual(read(g), "g")
    }

    func testPutBackWithoutRecordFails() throws {
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let stray = try file("stray.txt", in: trashDir)
        let report = service.putBack([stray])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].error is PutBackError)
        XCTAssertTrue(exists(stray))
    }

    func testUndoRedoOfTrash() async throws {
        let src = try dir("src")
        let f = try file("t.txt", in: src, "x")
        await run(.trash(items: [f]))
        XCTAssertFalse(exists(f))

        await undoAndWait()
        XCTAssertEqual(read(f), "x")

        await redoAndWait()
        XCTAssertFalse(exists(f))
        XCTAssertTrue(exists(trashDir.appendingPathComponent("t.txt")))

        await undoAndWait()
        XCTAssertEqual(read(f), "x")
    }

    func testEmptyTrashRemovesItemsAndJournal() async throws {
        let src = try dir("src")
        let f = try file("e.txt", in: src)
        await run(.trash(items: [f]))
        XCTAssertEqual(service.trashItemCount(), 1)
        let report = try service.emptyTrash()
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(service.trashItemCount(), 0)
        XCTAssertTrue(journal.entries().isEmpty)
    }

    func testJournalPersistsOnDisk() throws {
        let db = root.appendingPathComponent("db/trash.sqlite")
        let original = URL(fileURLWithPath: "/tmp/orig/a.txt")
        let trashed = URL(fileURLWithPath: "/tmp/.Trash/a.txt")
        do {
            let j = try TrashJournal(databaseURL: db)
            try j.record(originalURL: original, trashedURL: trashed)
        }
        let j2 = try TrashJournal(databaseURL: db)
        XCTAssertEqual(j2.entries().count, 1)
        XCTAssertEqual(j2.entry(forTrashedURL: trashed)?.originalURL.path, original.path)
        XCTAssertEqual(j2.purgeMissing(), 1)
        XCTAssertTrue(j2.entries().isEmpty)
    }

    func testFileActionsRenameUndoRedo() throws {
        let saved = FileOperationQueue.shared.undoManager
        FileOperationQueue.shared.undoManager = undo
        defer { FileOperationQueue.shared.undoManager = saved }
        let d = try dir("r")
        let f = try file("old.txt", in: d, "r")
        let renamed = try FileActions.rename(f, to: "new.txt")
        XCTAssertEqual(read(renamed), "r")
        XCTAssertFalse(exists(f))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        undo.undo()
        XCTAssertEqual(read(f), "r")
        XCTAssertFalse(exists(renamed))
        undo.redo()
        XCTAssertEqual(read(renamed), "r")
    }

    func testRenameRefusesToOverwrite() throws {
        let d = try dir("r")
        let a = try file("a.txt", in: d, "a")
        try file("b.txt", in: d, "b")
        XCTAssertThrowsError(try FileActions.rename(a, to: "b.txt"))
        XCTAssertEqual(read(d.appendingPathComponent("b.txt")), "b")
        XCTAssertThrowsError(try FileActions.rename(a, to: "x/y"))
    }

    func testCaseOnlyRename() throws {
        let d = try dir("r")
        let a = try file("name.txt", in: d, "a")
        let renamed = try FileActions.rename(a, to: "NAME.txt")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: d.path).contains("NAME.txt"))
        XCTAssertEqual(renamed.lastPathComponent, "NAME.txt")
    }

    func testNewFolderUndoRedo() throws {
        let saved = FileOperationQueue.shared.undoManager
        let savedService = FileOperationQueue.shared.trashService
        FileOperationQueue.shared.undoManager = undo
        FileOperationQueue.shared.trashService = service
        defer {
            FileOperationQueue.shared.undoManager = saved
            FileOperationQueue.shared.trashService = savedService
        }
        let d = try dir("n")
        let folder = try FileActions.createFolder(in: d)
        XCTAssertTrue(exists(folder))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        undo.undo()
        XCTAssertFalse(exists(folder))
        undo.redo()
        XCTAssertTrue(exists(folder))
    }

    func testTagsSetAndUndo() throws {
        let saved = FileOperationQueue.shared.undoManager
        FileOperationQueue.shared.undoManager = undo
        defer { FileOperationQueue.shared.undoManager = saved }
        let d = try dir("tags")
        let f = try file("t.txt", in: d)
        XCTAssertEqual(TagOps.tags(for: f), [])
        try TagOps.setTags(["Red", "Project"], for: f)
        XCTAssertEqual(Set(TagOps.tags(for: f)), ["Red", "Project"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        undo.undo()
        XCTAssertEqual(TagOps.tags(for: f), [])
        undo.redo()
        XCTAssertEqual(Set(TagOps.tags(for: f)), ["Red", "Project"])
        try TagOps.removeTags(["Red"], from: f)
        XCTAssertEqual(TagOps.tags(for: f), ["Project"])
    }

    func testParseLsof() {
        let output = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Preview   412 bryan  txt   REG   1,18   1234  56 /Volumes/X/a.pdf
        Preview   412 bryan  4r    REG   1,18   1234  56 /Volumes/X/a.pdf
        mds_store 99  root   5r    DIR   1,18   1234  57 /Volumes/X
        Visual\\x20Studio 700 bryan 6r REG 1,18 1 2 /Volumes/X/b
        """
        let procs = VolumeOps.parseLsof(output)
        XCTAssertEqual(procs.map(\.pid), [412, 99, 700])
        XCTAssertEqual(procs.map(\.name), ["Preview", "mds_store", "Visual Studio"])
    }

    func testEjectErrorShape() {
        let err = VolumeOps.EjectError.busy(volume: "Backup", processes: [.init(pid: 1, name: "Preview"), .init(pid: 2, name: "mds")], message: nil)
        XCTAssertTrue(err.canRetryWithForce)
        XCTAssertEqual(err.blockingProcesses.count, 2)
        XCTAssertTrue(err.localizedDescription.contains("Preview"))
        XCTAssertFalse(VolumeOps.EjectError.failed(volume: "X", message: "no").canRetryWithForce)
    }

    func testEjectNonVolumeThrows() async throws {
        let d = try dir("notvol")
        do {
            try await VolumeOps.eject(d)
            XCTFail("expected error")
        } catch let error as VolumeOps.EjectError {
            guard case .notAVolume = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
