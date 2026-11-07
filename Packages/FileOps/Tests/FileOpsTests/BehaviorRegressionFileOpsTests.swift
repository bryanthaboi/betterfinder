import Combine
import FSCore
import XCTest
@testable import FileOps

final class StrictResourceProvider: ResourceProvider, @unchecked Sendable {
    let providerID: String
    let displayName: String
    let capabilities: ResourceCapabilities
    let root: ResourceID
    private let lock = NSLock()
    private var files: [String: (data: Data, rev: Int)] = [:]
    private var dirs: Set<String> = ["/"]
    private var counter = 0
    private var uploadCounts: [String: Int] = [:]
    private var failedDeletes: Set<String> = []
    var copyFailsAfter: Int?
    var copyDelay: TimeInterval = 0
    var moveDelayContaining: String?
    var moveDelay: TimeInterval = 0
    var partialMoveContaining: String?
    var failMoveContaining: Set<String> = []
    var moveError: ResourceError?
    var refuseDeleteNames: Set<String> = []
    var failDeleteOnce: Set<String> = []
    var onUpload: ((ResourceID) -> Void)?
    var onMove: ((ResourceID, ResourceID) throws -> Void)?
    var afterMove: ((ResourceID, ResourceID) throws -> Void)?
    var suppliesHashes = true

    init(_ id: String, capabilities: ResourceCapabilities = [.read, .write, .rename, .delete, .makeDirectory, .serverSideCopy]) {
        providerID = id
        displayName = id
        self.capabilities = capabilities
        root = ResourceID(providerID: id, path: "/")
    }

    func rid(_ path: String) -> ResourceID { ResourceID(providerID: providerID, path: path) }

    func seed(_ path: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        writeLocked(rid(path).path, Data(text.utf8))
    }

    private func writeLocked(_ path: String, _ data: Data) {
        counter += 1
        files[path] = (data, counter)
        var p = ResourceID(providerID: providerID, path: path).lexicalParent
        while let d = p { dirs.insert(d.path); p = d.lexicalParent }
    }

    func text(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[ResourceID.normalize(path)].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func hasDir(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return dirs.contains(ResourceID.normalize(path)) }
    var allPaths: [String] { lock.lock(); defer { lock.unlock() }; return (Array(files.keys) + Array(dirs)).sorted() }
    func uploads(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return uploadCounts[name] ?? 0 }

    private func itemLocked(_ path: String) -> ResourceItem? {
        let id = rid(path)
        if dirs.contains(id.path) { return ResourceItem(id: id, isDirectory: true) }
        guard let f = files[id.path] else { return nil }
        return ResourceItem(id: id, isDirectory: false, size: Int64(f.data.count), modified: Date(timeIntervalSince1970: TimeInterval(f.rev)), etag: suppliesHashes ? "rev-\(f.rev)" : nil)
    }

    private func existsLocked(_ path: String) -> Bool { dirs.contains(path) || files[path] != nil }

    private func childrenLocked(_ path: String) -> [String] {
        let prefix = path == "/" ? "/" : path + "/"
        return Set((Array(files.keys) + Array(dirs)).filter { $0 != path && $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }).sorted()
    }

    private func treeFilesLocked(_ path: String) -> [String] {
        let prefix = path + "/"
        return files.keys.filter { $0 == path || $0.hasPrefix(prefix) }.sorted()
    }

    func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        lock.lock()
        let items = childrenLocked(directory.path).compactMap(itemLocked)
        lock.unlock()
        return AsyncThrowingStream { c in
            c.yield(items)
            c.finish()
        }
    }

    func stat(_ id: ResourceID) async throws -> ResourceItem {
        lock.lock(); defer { lock.unlock() }
        guard let i = itemLocked(id.path) else { throw ResourceError.notFound(id.path) }
        return i
    }

    func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        try Task.checkCancellation()
        lock.lock()
        guard let f = files[id.path] else { lock.unlock(); throw ResourceError.notFound(id.path) }
        lock.unlock()
        try f.data.write(to: localFile)
        progress(Int64(f.data.count))
        return try await stat(id)
    }

    func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        try Task.checkCancellation()
        let d = try Data(contentsOf: localFile)
        onUpload?(id)
        lock.lock()
        if existsLocked(id.path) && !options.overwrite { lock.unlock(); throw ResourceError.alreadyExists(id.name) }
        uploadCounts[id.name, default: 0] += 1
        writeLocked(id.path, d)
        lock.unlock()
        progress(Int64(d.count))
        return try await stat(id)
    }

    func makeDirectory(_ id: ResourceID) async throws -> ResourceItem {
        lock.lock(); defer { lock.unlock() }
        if existsLocked(id.path) { throw ResourceError.alreadyExists(id.name) }
        dirs.insert(id.path)
        return ResourceItem(id: id, isDirectory: true)
    }

    func delete(_ id: ResourceID, recursive: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        if failDeleteOnce.contains(id.name) && !failedDeletes.contains(id.name) {
            failedDeletes.insert(id.name)
            throw ResourceError.permissionDenied("delete \(id.name)")
        }
        if !recursive && !childrenLocked(id.path).isEmpty { throw ResourceError.unsupported("Deleting a non-empty folder") }
        let prefix = id.path + "/"
        files = files.filter { $0.key != id.path && !$0.key.hasPrefix(prefix) }
        dirs = dirs.filter { $0 != id.path && !$0.hasPrefix(prefix) }
    }

    func deleteIfUnchanged(_ id: ResourceID, from expected: ResourceItem) async throws -> Bool {
        if refuseDeleteNames.contains(id.name) { return false }
        let now = try await stat(id)
        guard now.isSameVersion(as: expected) else { return false }
        try await delete(id, recursive: false)
        return true
    }

    func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        try Task.checkCancellation()
        try onMove?(id, destination)
        if let moveError { throw moveError }
        if failMoveContaining.contains(where: { id.path.contains($0) }) { throw ResourceError.connectionFailed("move \(id.path)") }
        if let needle = moveDelayContaining, id.path.contains(needle) {
            try await Task.sleep(nanoseconds: UInt64(moveDelay * 1e9))
        }
        lock.lock()
        guard existsLocked(id.path) else { lock.unlock(); throw ResourceError.notFound(id.path) }
        if existsLocked(destination.path) { lock.unlock(); throw ResourceError.alreadyExists(destination.name) }
        if let needle = partialMoveContaining, id.path.contains(needle), dirs.contains(id.path) {
            dirs.insert(destination.path)
            if let first = treeFilesLocked(id.path).first, let f = files[first] {
                let rel = first.dropFirst(id.path.count)
                files[destination.path + rel] = f
            }
            lock.unlock()
            throw ResourceError.connectionFailed("move \(id.path) stopped partway")
        }
        let prefix = id.path + "/"
        var nf: [String: (data: Data, rev: Int)] = [:]
        for (k, v) in files {
            if k == id.path { nf[destination.path] = v } else if k.hasPrefix(prefix) { nf[destination.path + "/" + k.dropFirst(prefix.count)] = v } else { nf[k] = v }
        }
        files = nf
        dirs = Set(dirs.map { $0 == id.path ? destination.path : ($0.hasPrefix(prefix) ? destination.path + "/" + $0.dropFirst(prefix.count) : $0) })
        lock.unlock()
        try afterMove?(id, destination)
        return try await stat(destination)
    }

    func copy(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        try Task.checkCancellation()
        lock.lock()
        guard existsLocked(id.path) else { lock.unlock(); throw ResourceError.notFound(id.path) }
        if existsLocked(destination.path) { lock.unlock(); throw ResourceError.alreadyExists(destination.name) }
        let isDir = dirs.contains(id.path)
        let tree = treeFilesLocked(id.path)
        let subdirs = dirs.filter { $0.hasPrefix(id.path + "/") }
        if isDir { dirs.insert(destination.path) }
        lock.unlock()
        var copied = 0
        for path in tree {
            if copyDelay > 0 { try await Task.sleep(nanoseconds: UInt64(copyDelay * 1e9)) }
            try Task.checkCancellation()
            if let limit = copyFailsAfter, copied >= limit { throw ResourceError.connectionFailed("copy \(id.path) stopped partway") }
            lock.lock()
            if let f = files[path] { writeLocked(destination.path + path.dropFirst(id.path.count), f.data) }
            lock.unlock()
            copied += 1
        }
        lock.lock()
        for d in subdirs { dirs.insert(destination.path + d.dropFirst(id.path.count)) }
        lock.unlock()
        return try await stat(destination)
    }
}

final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0
    var open: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
    var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }
    func release() { lock.lock(); isOpen = true; lock.unlock() }
    func pass() async {
        lock.lock(); arrivals += 1; lock.unlock()
        while !open { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

@MainActor
final class BehaviorRegressionLocalTests: FileOpsTestCase {
    override func setUp() async throws {
        try await super.setUp()
        queue.hooks = FileOperationHookRegistry()
        queue.announcesStateChanges = false
    }

    func settle() async {
        let end = Date().addingTimeInterval(30)
        while (queue.operations.contains(where: \.isActive) || queue.undoWorkInFlight > 0 || !queue.fallible.chain.isEmpty), Date() < end {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testRetryAfterDestinationEditAsksInsteadOfOverwritingCopy() async throws {
        let src = try dir("src/docs")
        let dst = try dir("dst")
        try file("a.txt", in: src, "a")
        let locked = try file("locked.txt", in: src, "secret")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let resolver = ScriptedResolver([ConflictDecision(.keepBoth)])
        let op = await run(.copy(sources: [src], destination: dst), resolver: resolver)
        XCTAssertTrue(op.canRetry)
        let landed = dst.appendingPathComponent("docs")
        try file("a.txt", in: landed, "user edit")
        chmod(locked.path, 0o644)
        let retried = try XCTUnwrap(op.retry())
        await settle()
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertEqual(read(landed.appendingPathComponent("a.txt")), "user edit")
        XCTAssertEqual(read(landed.appendingPathComponent("a 2.txt")), "a")
        XCTAssertEqual(read(landed.appendingPathComponent("locked.txt")), "secret")
        XCTAssertEqual(resolver.asked.count, 1)
    }

    func testRetryAfterDestinationEditAsksInsteadOfOverwritingMove() async throws {
        queue.forcesCopyMoves = true
        let src = try dir("src/docs")
        let dst = try dir("dst")
        try file("a.txt", in: src, "a")
        let locked = try file("locked.txt", in: src, "secret")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let resolver = ScriptedResolver([ConflictDecision(.keepBoth)])
        let op = await run(.move(sources: [src], destination: dst), resolver: resolver)
        XCTAssertTrue(op.canRetry)
        XCTAssertEqual(read(src.appendingPathComponent("a.txt")), "a")
        let landed = dst.appendingPathComponent("docs")
        try file("a.txt", in: landed, "user edit")
        chmod(locked.path, 0o644)
        let retried = try XCTUnwrap(op.retry())
        await settle()
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertEqual(read(landed.appendingPathComponent("a.txt")), "user edit")
        XCTAssertEqual(read(landed.appendingPathComponent("a 2.txt")), "a")
        XCTAssertEqual(read(landed.appendingPathComponent("locked.txt")), "secret")
        XCTAssertFalse(exists(src))
        XCTAssertEqual(resolver.asked.count, 1)
    }

    func editDuringCleanup(_ src: URL) {
        let once = OnceFlag()
        queue.afterCopyProbe = { _ in
            guard once.fire() else { return }
            try? "after!".write(to: src.appendingPathComponent("edited.txt"), atomically: false, encoding: .utf8)
            try? "late".write(to: src.appendingPathComponent("late.txt"), atomically: false, encoding: .utf8)
        }
    }

    func testCrossVolumeMoveWithChangedChildUndoRestoresMovedChildren() async throws {
        queue.forcesCopyMoves = true
        let src = try dir("src/docs")
        let dst = try dir("dst")
        try file("same.txt", in: src, "same")
        try file("edited.txt", in: src, "before")
        editDuringCleanup(src)
        let op = await run(.move(sources: [src], destination: dst))
        let landed = dst.appendingPathComponent("docs")
        XCTAssertFalse(exists(src.appendingPathComponent("same.txt")))
        XCTAssertEqual(read(src.appendingPathComponent("edited.txt")), "after!")
        XCTAssertEqual(read(src.appendingPathComponent("late.txt")), "late")
        XCTAssertEqual(read(landed.appendingPathComponent("same.txt")), "same")
        XCTAssertEqual(read(landed.appendingPathComponent("edited.txt")), "before")
        XCTAssertEqual(op.errors.count, 2, "\(op.errors)")
        XCTAssertTrue(op.canRetry)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        await settle()
        XCTAssertEqual(read(src.appendingPathComponent("same.txt")), "same")
        XCTAssertEqual(read(src.appendingPathComponent("edited.txt")), "after!")
        XCTAssertEqual(read(src.appendingPathComponent("late.txt")), "late")
        XCTAssertFalse(exists(landed))
        XCTAssertEqual(read(trashDir.appendingPathComponent("docs/edited.txt")), "before")
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        await settle()
        XCTAssertEqual(read(landed.appendingPathComponent("same.txt")), "same")
        XCTAssertEqual(read(landed.appendingPathComponent("edited.txt")), "before")
        XCTAssertFalse(exists(src.appendingPathComponent("same.txt")))
        XCTAssertEqual(read(src.appendingPathComponent("edited.txt")), "after!")
    }

    func testCrossVolumeMoveReplaceWithChangedChildUndoRestoresBothSides() async throws {
        queue.forcesCopyMoves = true
        let src = try dir("src/docs")
        let landed = try dir("dst/docs")
        try file("same.txt", in: src, "same")
        try file("edited.txt", in: src, "before")
        try file("keep.txt", in: landed, "old")
        editDuringCleanup(src)
        let op = await run(.move(sources: [src], destination: landed.deletingLastPathComponent()), resolver: ScriptedResolver([ConflictDecision(.replace)]))
        XCTAssertNil(op.undoUnavailableReason)
        XCTAssertEqual(read(landed.appendingPathComponent("same.txt")), "same")
        XCTAssertFalse(exists(landed.appendingPathComponent("keep.txt")))
        XCTAssertFalse(exists(src.appendingPathComponent("same.txt")))
        XCTAssertEqual(read(src.appendingPathComponent("edited.txt")), "after!")
        undo.undo()
        await settle()
        XCTAssertEqual(read(src.appendingPathComponent("same.txt")), "same")
        XCTAssertEqual(read(src.appendingPathComponent("edited.txt")), "after!")
        XCTAssertEqual(read(landed.appendingPathComponent("keep.txt")), "old")
        XCTAssertFalse(exists(landed.appendingPathComponent("same.txt")))
        let trashed = (try FileManager.default.contentsOfDirectory(atPath: trashDir.path)).map { trashDir.appendingPathComponent($0) }
        XCTAssertTrue(trashed.contains { read($0.appendingPathComponent("edited.txt")) == "before" }, "\(trashed)")
        undo.redo()
        await settle()
        XCTAssertEqual(read(landed.appendingPathComponent("same.txt")), "same")
        XCTAssertFalse(exists(landed.appendingPathComponent("keep.txt")))
        XCTAssertFalse(exists(src.appendingPathComponent("same.txt")))
        let again = (try FileManager.default.contentsOfDirectory(atPath: trashDir.path)).map { trashDir.appendingPathComponent($0) }
        XCTAssertTrue(again.contains { read($0.appendingPathComponent("keep.txt")) == "old" }, "\(again)")
    }

    func testCrossVolumeMoveRetryFinishesChangedChildWithoutAsking() async throws {
        queue.forcesCopyMoves = true
        let src = try dir("src/docs")
        let dst = try dir("dst")
        try file("same.txt", in: src, "same")
        try file("edited.txt", in: src, "before")
        editDuringCleanup(src)
        let resolver = ScriptedResolver([])
        let op = await run(.move(sources: [src], destination: dst), resolver: resolver)
        XCTAssertTrue(op.canRetry)
        let retried = try XCTUnwrap(op.retry())
        await settle()
        let landed = dst.appendingPathComponent("docs")
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertTrue(resolver.asked.isEmpty)
        XCTAssertEqual(read(landed.appendingPathComponent("edited.txt")), "after!")
        XCTAssertEqual(read(landed.appendingPathComponent("late.txt")), "late")
        XCTAssertEqual(read(landed.appendingPathComponent("same.txt")), "same")
        XCTAssertFalse(exists(src))
    }

    func testFailedRedoStaysRedoableAndRetries() throws {
        let shared = FileOperationQueue.shared
        let saved = shared.undoManager
        shared.undoManager = undo
        shared.announcesStateChanges = false
        defer { shared.undoManager = saved }
        let d = try dir("r")
        let original = try file("old.txt", in: d, "mine")
        let renamed = try FileActions.rename(original, to: "new.txt")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        undo.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(read(original), "mine")
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        try file("new.txt", in: d, "blocker")
        let before = shared.operations.count
        undo.redo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let reported = Array(shared.operations.dropFirst(before))
        XCTAssertEqual(reported.first?.title, "Redo Rename")
        XCTAssertEqual(read(original), "mine")
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(undo.redoActionName, "Rename")
        for op in reported { shared.remove(op) }
        try FileManager.default.removeItem(at: renamed)
        undo.redo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(read(renamed), "mine")
        XCTAssertFalse(exists(original))
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    func replaceForJournal() async throws -> URL {
        let src = try dir("src")
        let dst = try dir("dst")
        try file("f.txt", in: src, "replacement")
        try file("f.txt", in: dst, "original")
        await run(.copy(sources: [src.appendingPathComponent("f.txt")], destination: dst), resolver: ScriptedResolver([ConflictDecision(.replace)]))
        return dst.appendingPathComponent("f.txt")
    }

    func testFailedAsyncRedoStaysRedoableAndRetries() async throws {
        let target = try await replaceForJournal()
        undo.undo()
        await settle()
        XCTAssertEqual(read(target), "original")
        let parked = root.appendingPathComponent("parked.txt")
        let trashed = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil).first { read($0) == "replacement" })
        try FileManager.default.moveItem(at: trashed, to: parked)
        let before = queue.operations.count
        undo.redo()
        await settle()
        XCTAssertEqual(queue.operations.dropFirst(before).first?.title, "Redo Copy")
        XCTAssertEqual(read(target), "original")
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        try FileManager.default.moveItem(at: parked, to: trashed)
        undo.redo()
        await settle()
        XCTAssertEqual(read(target), "replacement")
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    func testImmediateUndoRedoOverlapIsSerialized() async throws {
        var pendingUndo: ((Bool) -> Void)?
        var undoCalls = 0
        var redoCalls = 0
        queue.registerFallible(name: "Step", undo: { done in
            undoCalls += 1
            pendingUndo = done
        }, redo: { done in
            redoCalls += 1
            done(true)
        })
        undo.undo()
        undo.redo()
        XCTAssertEqual(undoCalls, 1)
        XCTAssertEqual(redoCalls, 0)
        pendingUndo?(true)
        XCTAssertEqual(redoCalls, 1)
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        XCTAssertEqual(undoCalls, 2)
        pendingUndo?(true)
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
    }

    func testFailedPendingUndoCancelsQueuedRedoAndStaysUndoable() async throws {
        var pendingUndo: ((Bool) -> Void)?
        var undoCalls = 0
        var redoCalls = 0
        queue.registerFallible(name: "Step", undo: { done in
            undoCalls += 1
            pendingUndo = done
        }, redo: { done in
            redoCalls += 1
            done(true)
        })
        undo.undo()
        undo.redo()
        pendingUndo?(false)
        await settle()
        XCTAssertEqual(redoCalls, 0)
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        XCTAssertEqual(undo.undoActionName, "Step")
        undo.undo()
        XCTAssertEqual(undoCalls, 2)
        pendingUndo?(true)
        XCTAssertTrue(undo.canRedo)
    }

    func testImmediateJournalUndoRedoEndsRedone() async throws {
        let target = try await replaceForJournal()
        undo.undo()
        undo.redo()
        await settle()
        XCTAssertEqual(read(target), "replacement")
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        await settle()
        XCTAssertEqual(read(target), "original")
    }

    func testBlockedJournalRestoreCountsAsBackgroundMutation() async throws {
        let target = try await replaceForJournal()
        let gate = OpenGate()
        let hook = TestHook(id: "slow-undo")
        hook.beforeBehavior = { snap in
            if snap.origin == .undo { await gate.pass() }
            return .allow
        }
        queue.hooks.register(hook, owner: "tester")
        XCTAssertEqual(queue.backgroundMutationCount, 0)
        undo.undo()
        await waitUntil { gate.arrived > 0 }
        XCTAssertGreaterThan(queue.backgroundMutationCount, 0)
        XCTAssertEqual(read(target), "replacement")
        gate.release()
        await settle()
        XCTAssertEqual(queue.backgroundMutationCount, 0)
        XCTAssertEqual(read(target), "original")
    }

    func testHookedRenameAndItsUndoCountAsBackgroundMutation() async throws {
        let shared = FileOperationQueue.shared
        let saved = shared.undoManager
        shared.undoManager = undo
        shared.announcesStateChanges = false
        defer { shared.undoManager = saved }
        let registry = FileOperationHookRegistry()
        let userGate = OpenGate()
        let undoGate = OpenGate()
        let hook = TestHook(id: "slow")
        hook.beforeBehavior = { snap in
            await (snap.origin == .undo ? undoGate : userGate).pass()
            return .allow
        }
        registry.register(hook, owner: "tester")
        let d = try dir("r")
        let original = try file("old.txt", in: d, "mine")
        let baseline = shared.backgroundMutationCount
        let rename = Task { try await FileActions.renameAsync(original, to: "new.txt", registry: registry) }
        await waitUntil { userGate.arrived > 0 }
        XCTAssertEqual(shared.backgroundMutationCount, baseline + 1)
        userGate.release()
        let renamed = try await rename.value
        XCTAssertEqual(shared.backgroundMutationCount, baseline)
        undo.undo()
        await waitUntil { undoGate.arrived > 0 }
        XCTAssertEqual(shared.backgroundMutationCount, baseline + 1)
        XCTAssertEqual(read(renamed), "mine")
        undoGate.release()
        await waitUntil { shared.backgroundMutationCount == baseline }
        XCTAssertEqual(shared.backgroundMutationCount, baseline)
        XCTAssertEqual(read(original), "mine")
    }

    func testRecentlyTrashedPutBackCountsAsBackgroundMutation() async throws {
        let src = try dir("src")
        let a = try file("a.txt", in: src, "a")
        await run(.trash(items: [a]))
        var seen: [Int] = []
        let sub = queue.$backgroundMutationCount.sink { seen.append($0) }
        defer { sub.cancel() }
        let model = RecentlyTrashedModel(service: service, activity: queue)
        model.reload()
        let report = await model.putBack(model.entries)
        XCTAssertEqual(report.restored.count, 1)
        XCTAssertEqual(read(a), "a")
        XCTAssertTrue(seen.contains(1), "\(seen)")
        XCTAssertEqual(queue.backgroundMutationCount, 0)
    }
}

@MainActor
final class BehaviorRegressionRemoteTests: FileOpsTestCase {
    var registry: ResourceProviderRegistry!
    var sa: StrictResourceProvider!
    var sb: StrictResourceProvider!
    var mem: MemoryResourceProvider!
    var engine: CrossProviderTransfer!

    override func setUp() async throws {
        try await super.setUp()
        registry = ResourceProviderRegistry()
        sa = StrictResourceProvider("strict-a")
        sb = StrictResourceProvider("strict-b")
        mem = MemoryResourceProvider("mem-src")
        try registry.register(sa, owner: "test")
        try registry.register(sb, owner: "test")
        try registry.register(mem, owner: "test")
        engine = CrossProviderTransfer(registry: registry)
        let transfers = ResourceTransferProviderRegistry()
        transfers.register(engine, owner: "test")
        queue.transferProviders = transfers
        queue.hooks = FileOperationHookRegistry()
        queue.announcesStateChanges = false
        StagingArea.root = root.appendingPathComponent("staging")
    }

    func leftovers(_ p: StrictResourceProvider) -> [String] {
        p.allPaths.filter { $0.contains("bftmp") || $0.contains("bfbak") }
    }

    func testRemoteMoveCleanupFailureIsRetryableWithoutRecopying() async throws {
        sa.seed("/docs/one.txt", "1")
        sa.seed("/docs/two.txt", "2")
        sa.seed("/docs/three.txt", "3")
        let source = sa!
        sb.onUpload = { id in
            if id.name == "two.txt" { source.seed("/docs/one.txt", "rewritten") }
        }
        sa.failDeleteOnce = ["two.txt"]
        sa.refuseDeleteNames = ["three.txt"]
        let resolver = ScriptedResolver([])
        queue.conflictResolver = resolver
        let op = queue.enqueueTransfer(ResourceTransferRequest(mode: .move, sources: [sa.rid("/docs")], into: sb.root))
        await waitIdle()
        XCTAssertTrue(op.canRetry)
        XCTAssertTrue(op.errors.contains { $0.message.contains("changed") }, "\(op.errors)")
        XCTAssertEqual(sa.text("/docs/one.txt"), "rewritten")
        XCTAssertEqual(sa.text("/docs/two.txt"), "2")
        XCTAssertEqual(sa.text("/docs/three.txt"), "3")
        XCTAssertEqual(sb.text("/docs/one.txt"), "1")
        sb.onUpload = nil
        sb.seed("/docs/user.txt", "mine")
        sa.refuseDeleteNames = []
        let retried = try XCTUnwrap(op.retry())
        await waitIdle()
        XCTAssertEqual(retried.state, .finished)
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertTrue(resolver.asked.isEmpty)
        XCTAssertEqual(sb.text("/docs/one.txt"), "rewritten")
        XCTAssertEqual(sb.text("/docs/two.txt"), "2")
        XCTAssertEqual(sb.text("/docs/three.txt"), "3")
        XCTAssertEqual(sb.text("/docs/user.txt"), "mine")
        XCTAssertEqual(sb.uploads("one.txt"), 2)
        XCTAssertEqual(sb.uploads("two.txt"), 1)
        XCTAssertEqual(sb.uploads("three.txt"), 1)
        XCTAssertFalse(sa.hasDir("/docs"))
        XCTAssertNil(sa.text("/docs/two.txt"))
    }

    func testChangedAtDeleteTimeKeepsSourceAndIsRetryable() async throws {
        sa.seed("/f.txt", "payload")
        sa.refuseDeleteNames = ["f.txt"]
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [sa.rid("/f.txt")], into: sb.root), progress: { _ in })
        guard case .failed(let err) = report.results[0] else { return XCTFail("expected failure, got \(report.results)") }
        XCTAssertTrue(err.message.contains("changed"), err.message)
        XCTAssertEqual(sa.text("/f.txt"), "payload")
        XCTAssertEqual(sb.text("/f.txt"), "payload")
        XCTAssertFalse(FileOperationQueue.outcome(from: report).completed.contains(0))
    }

    func testSafeMoveUnavailableIsAnItemErrorWithoutFallback() async throws {
        sa.seed("/x/f.txt", "payload")
        sa.moveError = .remote(code: "SafeMoveUnavailable", message: "can’t delete safely")
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [sa.rid("/x/f.txt")], into: sa.rid("/y")), progress: { _ in })
        guard case .failed(let err) = report.results[0] else { return XCTFail("expected failure, got \(report.results)") }
        XCTAssertTrue(err.message.contains("can’t delete safely"), err.message)
        XCTAssertEqual(sa.text("/x/f.txt"), "payload")
        XCTAssertNil(sa.text("/y/f.txt"))
        XCTAssertEqual(sa.uploads("f.txt"), 0)
    }

    func testSameServerCopyReplacePartialCopyKeepsOriginal() async throws {
        sa.seed("/x/docs/1.txt", "one")
        sa.seed("/x/docs/2.txt", "two")
        sa.seed("/x/docs/3.txt", "three")
        sa.seed("/y/docs/keep.txt", "old")
        sa.copyFailsAfter = 1
        let report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [sa.rid("/x/docs")], into: sa.rid("/y")), resolver: ScriptedResolver([ConflictDecision(.replace)]), progress: { _ in })
        XCTAssertEqual(report.errors.count, 1, "\(report.errors)")
        XCTAssertEqual(sa.text("/y/docs/keep.txt"), "old")
        XCTAssertNil(sa.text("/y/docs/1.txt"))
        XCTAssertEqual(leftovers(sa), [])
        XCTAssertEqual(sa.text("/x/docs/2.txt"), "two")
    }

    func testStagedSwapFailureCleansPartialTargetAndRestoresOriginal() async throws {
        mem.seed("/docs/a.txt", "a")
        mem.seed("/docs/b.txt", "b")
        sb.seed("/docs/keep.txt", "old")
        sb.partialMoveContaining = "bftmp"
        let report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [ResourceID(providerID: mem.providerID, path: "/docs")], into: sb.root), resolver: ScriptedResolver([ConflictDecision(.replace)]), progress: { _ in })
        XCTAssertEqual(report.errors.count, 1, "\(report.errors)")
        XCTAssertEqual(sb.text("/docs/keep.txt"), "old")
        XCTAssertNil(sb.text("/docs/a.txt"))
        XCTAssertEqual(leftovers(sb), [])
    }

    func testFailedRestoreReportsBackupPath() async throws {
        mem.seed("/docs/a.txt", "a")
        sb.seed("/docs/keep.txt", "old")
        sb.failMoveContaining = ["bftmp", "bfbak"]
        let report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [ResourceID(providerID: mem.providerID, path: "/docs")], into: sb.root), resolver: ScriptedResolver([ConflictDecision(.replace)]), progress: { _ in })
        let backups = sb.allPaths.filter { $0.contains("bfbak") && $0.hasSuffix("keep.txt") }
        XCTAssertEqual(backups.count, 1, "\(sb.allPaths)")
        let backupDir = try XCTUnwrap(backups.first).replacingOccurrences(of: "/keep.txt", with: "")
        XCTAssertEqual(sb.text(backupDir + "/keep.txt"), "old")
        guard case .failed(let err) = report.results[0] else { return XCTFail("expected failure, got \(report.results)") }
        XCTAssertTrue(err.message.contains(backupDir), err.message)
        XCTAssertFalse(sb.allPaths.contains { $0.contains("bftmp") }, "\(sb.allPaths)")
    }

    func testCancelledSameServerReplaceKeepsOriginal() async throws {
        for i in 0..<4 { sa.seed("/x/docs/f\(i).txt", "\(i)") }
        sa.seed("/y/docs/keep.txt", "old")
        sa.copyDelay = 0.1
        let flag = CancelFlag()
        let request = ResourceTransferRequest(mode: .copy, sources: [sa.rid("/x/docs")], into: sa.rid("/y"))
        let engine = self.engine!
        let task = Task { await engine.run(request, resolver: ScriptedResolver([ConflictDecision(.replace)]), control: ResourceTransferControl(isCancelled: { flag.value }), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 250_000_000)
        flag.value = true
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.aborted, "Cancelled")
        XCTAssertEqual(sa.text("/y/docs/keep.txt"), "old")
        XCTAssertNil(sa.text("/y/docs/f0.txt"))
        XCTAssertEqual(leftovers(sa), [])
    }

    func testCancellationDuringSwapStillFinishesConsistently() async throws {
        mem.seed("/docs/x.txt", "x")
        sb.seed("/docs/keep.txt", "old")
        sb.moveDelayContaining = "bftmp"
        sb.moveDelay = 0.3
        let flag = CancelFlag()
        let request = ResourceTransferRequest(mode: .copy, sources: [ResourceID(providerID: mem.providerID, path: "/docs")], into: sb.root)
        let engine = self.engine!
        let task = Task { await engine.run(request, resolver: ScriptedResolver([ConflictDecision(.replace)]), control: ResourceTransferControl(isCancelled: { flag.value }), progress: { _ in }) }
        let end = Date().addingTimeInterval(5)
        while !sb.allPaths.contains(where: { $0.contains("bfbak") }), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        flag.value = true
        task.cancel()
        _ = await task.value
        XCTAssertEqual(sb.text("/docs/x.txt"), "x")
        XCTAssertNil(sb.text("/docs/keep.txt"))
        XCTAssertEqual(leftovers(sb), [])
    }
}
