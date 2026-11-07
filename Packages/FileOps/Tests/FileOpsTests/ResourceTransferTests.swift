import FSCore
import XCTest
@testable import FileOps

final class MemoryResourceProvider: ResourceProvider, @unchecked Sendable {
    let providerID: String
    let displayName: String
    var capabilities: ResourceCapabilities
    let root: ResourceID
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var dirs: Set<String> = ["/"]
    var corruptUploads = false
    var lieAboutSize = false
    var downloadDelay: TimeInterval = 0
    var failUploadNames: Set<String> = []
    var failMoveSources: Set<String> = []
    var failMoveContaining: String?
    var onUpload: ((ResourceID) -> Void)?
    private(set) var deletes: [String] = []
    private(set) var serverMoves = 0

    init(_ id: String, capabilities: ResourceCapabilities = [.read, .write, .rename, .delete, .makeDirectory]) {
        providerID = id
        displayName = id
        self.capabilities = capabilities
        root = ResourceID(providerID: id, path: "/")
    }

    func seed(_ path: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        let id = ResourceID(providerID: providerID, path: path)
        files[id.path] = Data(text.utf8)
        var p = id.lexicalParent
        while let d = p { dirs.insert(d.path); p = d.lexicalParent }
    }

    func data(_ path: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[ResourceID.normalize(path)] }
    func hasDir(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return dirs.contains(ResourceID.normalize(path)) }
    var allPaths: [String] { lock.lock(); defer { lock.unlock() }; return (Array(files.keys) + Array(dirs)).sorted() }

    func item(_ path: String) -> ResourceItem? {
        let id = ResourceID(providerID: providerID, path: path)
        if dirs.contains(id.path) { return ResourceItem(id: id, isDirectory: true) }
        guard let d = files[id.path] else { return nil }
        return ResourceItem(id: id, isDirectory: false, size: lieAboutSize ? Int64(d.count + 1) : Int64(d.count))
    }

    func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        lock.lock()
        let prefix = directory.isRoot ? "/" : directory.path + "/"
        let names = Set((Array(files.keys) + Array(dirs)).filter { $0 != directory.path && $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") })
        let items = names.sorted().compactMap(item)
        lock.unlock()
        return AsyncThrowingStream { c in
            c.yield(items)
            c.finish()
        }
    }

    func stat(_ id: ResourceID) async throws -> ResourceItem {
        lock.lock(); defer { lock.unlock() }
        guard let i = item(id.path) else { throw ResourceError.notFound(id.path) }
        return i
    }

    func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        if downloadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(downloadDelay * 1e9)) }
        try Task.checkCancellation()
        lock.lock()
        guard let d = files[id.path] else { lock.unlock(); throw ResourceError.notFound(id.path) }
        lock.unlock()
        try d.write(to: localFile)
        progress(Int64(d.count))
        return try await stat(id)
    }

    func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        var d = try Data(contentsOf: localFile)
        if failUploadNames.contains(id.name) { throw ResourceError.permissionDenied(id.name) }
        onUpload?(id)
        lock.lock()
        if files[id.path] != nil && !options.overwrite { lock.unlock(); throw ResourceError.alreadyExists(id.name) }
        if corruptUploads, !d.isEmpty { d[0] ^= 0xFF }
        files[id.path] = d
        lock.unlock()
        progress(Int64(d.count))
        return try await stat(id)
    }

    func makeDirectory(_ id: ResourceID) async throws -> ResourceItem {
        lock.lock(); defer { lock.unlock() }
        if dirs.contains(id.path) || files[id.path] != nil { throw ResourceError.alreadyExists(id.name) }
        dirs.insert(id.path)
        return ResourceItem(id: id, isDirectory: true)
    }

    func delete(_ id: ResourceID, recursive: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        deletes.append(id.path)
        let prefix = id.path + "/"
        files = files.filter { $0.key != id.path && !$0.key.hasPrefix(prefix) }
        dirs = dirs.filter { $0 != id.path && !$0.hasPrefix(prefix) }
    }

    func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        if failMoveSources.contains(id.path) { throw ResourceError.connectionFailed("move \(id.path)") }
        if let needle = failMoveContaining, id.path.contains(needle) { throw ResourceError.connectionFailed("move \(id.path)") }
        lock.lock()
        serverMoves += 1
        let prefix = id.path + "/"
        var nf: [String: Data] = [:]
        for (k, v) in files {
            if k == id.path { nf[destination.path] = v } else if k.hasPrefix(prefix) { nf[destination.path + "/" + k.dropFirst(prefix.count)] = v } else { nf[k] = v }
        }
        files = nf
        dirs = Set(dirs.map { $0 == id.path ? destination.path : ($0.hasPrefix(prefix) ? destination.path + "/" + $0.dropFirst(prefix.count) : $0) })
        lock.unlock()
        return try await stat(destination)
    }
}

final class SandboxLocalProvider: ResourceProvider, @unchecked Sendable {
    let base = LocalResourceProvider()
    let trashDir: URL
    var providerID: String { base.providerID }
    var displayName: String { base.displayName }
    var capabilities: ResourceCapabilities { base.capabilities }
    var root: ResourceID { base.root }
    private(set) var trashed: [ResourceID] = []

    init(trashDir: URL) { self.trashDir = trashDir }

    func list(_ d: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> { base.list(d, options: options) }
    func stat(_ id: ResourceID) async throws -> ResourceItem { try await base.stat(id) }
    func download(_ id: ResourceID, to f: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem { try await base.download(id, to: f, progress: progress) }
    func upload(from f: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem { try await base.upload(from: f, to: id, options: options, progress: progress) }
    func makeDirectory(_ id: ResourceID) async throws -> ResourceItem { try await base.makeDirectory(id) }
    func delete(_ id: ResourceID, recursive: Bool) async throws { try await base.delete(id, recursive: recursive) }
    func move(_ id: ResourceID, to d: ResourceID) async throws -> ResourceItem { try await base.move(id, to: d) }
    func trash(_ id: ResourceID) async throws {
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: id.fileURL!, to: trashDir.appendingPathComponent(UUID().uuidString + "-" + id.name))
        trashed.append(id)
    }
}

@MainActor
final class ResourceTransferTests: FileOpsTestCase {
    var registry: ResourceProviderRegistry!
    var local: SandboxLocalProvider!
    var a: MemoryResourceProvider!
    var b: MemoryResourceProvider!
    var engine: CrossProviderTransfer!
    var staging: URL!

    override func setUp() async throws {
        try await super.setUp()
        registry = ResourceProviderRegistry()
        local = SandboxLocalProvider(trashDir: root.appendingPathComponent("LocalTrash"))
        a = MemoryResourceProvider("mem-a", capabilities: [.read, .write, .rename, .delete, .makeDirectory])
        b = MemoryResourceProvider("mem-b")
        try registry.register(local, owner: "test")
        try registry.register(a, owner: "test")
        try registry.register(b, owner: "test")
        engine = CrossProviderTransfer(registry: registry)
        let transfers = ResourceTransferProviderRegistry()
        transfers.register(engine, owner: "test")
        queue.transferProviders = transfers
        queue.hooks = FileOperationHookRegistry()
        staging = root.appendingPathComponent("staging")
        StagingArea.root = staging
    }

    func rid(_ p: MemoryResourceProvider, _ path: String) -> ResourceID { ResourceID(providerID: p.providerID, path: path) }

    func stagingIsEmpty() -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        return items.allSatisfy { ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).isEmpty }
    }

    func testResourceIDsAndURIsRoundTrip() {
        let id = ResourceID(providerID: "remote.s3.x", path: "a//b/./c/../d e")
        XCTAssertEqual(id.path, "/a/b/d e")
        XCTAssertEqual(ResourceID(uri: id.uri), id)
        XCTAssertFalse(id.uri.isFileURL)
        XCTAssertNil(id.fileURL)
        XCTAssertEqual(ResourceID.local(URL(fileURLWithPath: "/tmp/x")).fileURL?.path, "/tmp/x")
        let item = OperationItem(source: id.uri, destination: URL(fileURLWithPath: "/tmp/y"))
        XCTAssertEqual(item.sourceResource, id)
        XCTAssertEqual(item.destinationResource, ResourceID.local(URL(fileURLWithPath: "/tmp/y")))
        XCTAssertTrue(item.isRemote)
        XCTAssertFalse(OperationItem(source: URL(fileURLWithPath: "/a"), destination: nil).isRemote)
    }

    func testLocalToRemoteAndBackCopyVerifiesContent() async throws {
        let src = try dir("src")
        try file("hello.txt", in: src, "hello remote")
        let toRemote = await engine.run(ResourceTransferRequest(mode: .copy, sources: [.local(src.appendingPathComponent("hello.txt"))], into: a.root), progress: { _ in })
        XCTAssertEqual(toRemote.committed, [rid(a, "/hello.txt")])
        XCTAssertEqual(a.data("/hello.txt"), Data("hello remote".utf8))
        XCTAssertEqual(toRemote.verifiedFiles, 1)
        let back = try dir("back")
        let toLocal = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/hello.txt")], into: .local(back)), progress: { _ in })
        XCTAssertTrue(toLocal.errors.isEmpty, "\(toLocal.errors)")
        XCTAssertEqual(read(back.appendingPathComponent("hello.txt")), "hello remote")
        XCTAssertTrue(stagingIsEmpty())
    }

    func testRemoteToRemoteMoveDeletesSourceOnlyAfterVerification() async throws {
        a.seed("/docs/one.txt", "1")
        a.seed("/docs/sub/two.txt", "22")
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [rid(a, "/docs")], into: b.root), progress: { _ in })
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(b.data("/docs/one.txt"), Data("1".utf8))
        XCTAssertEqual(b.data("/docs/sub/two.txt"), Data("22".utf8))
        XCTAssertFalse(a.hasDir("/docs"))
        XCTAssertNil(a.data("/docs/one.txt"))
        XCTAssertEqual(report.verifiedFiles, 2)
        XCTAssertEqual(report.deletedSources, [rid(a, "/docs/one.txt"), rid(a, "/docs/sub/two.txt"), rid(a, "/docs/sub"), rid(a, "/docs")])
        XCTAssertTrue(stagingIsEmpty())
    }

    func testCorruptDestinationKeepsSource() async throws {
        a.seed("/precious.bin", "do not lose me")
        b.corruptUploads = true
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [rid(a, "/precious.bin")], into: b.root), progress: { _ in })
        XCTAssertEqual(report.committed, [])
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(report.errors[0].message.contains("Verification failed"), report.errors[0].message)
        XCTAssertEqual(a.data("/precious.bin"), Data("do not lose me".utf8))
        XCTAssertTrue(a.deletes.isEmpty)
    }

    func testShortDownloadIsCaughtBeforeUpload() async throws {
        a.seed("/f.txt", "abc")
        a.lieAboutSize = true
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [rid(a, "/f.txt")], into: b.root), progress: { _ in })
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertNil(b.data("/f.txt"))
        XCTAssertNotNil(a.data("/f.txt"))
    }

    func testMoveFromLocalTrashesSourceNotDeletes() async throws {
        let src = try dir("src")
        try file("a.txt", in: src, "aaa")
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [.local(src)], into: a.root), progress: { _ in })
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(a.data("/src/a.txt"), Data("aaa".utf8))
        XCTAssertFalse(exists(src))
        XCTAssertEqual(local.trashed, [.local(src)])
    }

    func testSameProviderMoveUsesServerRename() async throws {
        a.seed("/x/file.txt", "f")
        _ = try await a.makeDirectory(rid(a, "/y"))
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [rid(a, "/x/file.txt")], into: rid(a, "/y")), progress: { _ in })
        XCTAssertEqual(report.committed, [rid(a, "/y/file.txt")])
        XCTAssertEqual(a.serverMoves, 1)
        XCTAssertNil(a.data("/x/file.txt"))
    }

    func testConflictChoices() async throws {
        a.seed("/n.txt", "new")
        b.seed("/n.txt", "old")
        var report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/n.txt")], into: b.root), resolver: ScriptedResolver([ConflictDecision(.keepBoth)]), progress: { _ in })
        XCTAssertEqual(report.committed, [rid(b, "/n 2.txt")])
        XCTAssertEqual(b.data("/n.txt"), Data("old".utf8))
        report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/n.txt")], into: b.root), resolver: ScriptedResolver([ConflictDecision(.skip)]), progress: { _ in })
        XCTAssertEqual(report.results, [.skipped])
        report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/n.txt")], into: b.root), resolver: ScriptedResolver([ConflictDecision(.replace)]), progress: { _ in })
        XCTAssertEqual(b.data("/n.txt"), Data("new".utf8))
        a.seed("/m.txt", "m")
        b.seed("/m.txt", "m-old")
        report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/n.txt"), rid(a, "/m.txt")], into: b.root), resolver: ScriptedResolver([ConflictDecision(.stop)]), progress: { _ in })
        XCTAssertEqual(report.aborted, "Stopped")
        XCTAssertEqual(b.data("/m.txt"), Data("m-old".utf8))
        let resolver = ScriptedResolver([ConflictDecision(.keepBoth, applyToAll: true)])
        report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/n.txt"), rid(a, "/m.txt")], into: b.root), resolver: resolver, progress: { _ in })
        XCTAssertEqual(resolver.asked.count, 1)
        XCTAssertEqual(report.committed.count, 2)
    }

    func testMoveRefusedWhenSourceCannotDelete() async throws {
        let ro = MemoryResourceProvider("ro", capabilities: [.read])
        try registry.register(ro, owner: "test")
        ro.seed("/a.txt", "a")
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [rid(ro, "/a.txt")], into: b.root), progress: { _ in })
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertNil(b.data("/a.txt"))
        let toRO = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(b, "/missing")], into: ro.root), progress: { _ in })
        XCTAssertEqual(toRO.errors.count, 1)
    }

    func testCancellationStopsAndCleansStaging() async throws {
        for i in 0..<5 { a.seed("/f\(i).txt", "\(i)") }
        a.downloadDelay = 0.2
        let control = CancelFlag()
        let task = Task { await engine.run(ResourceTransferRequest(mode: .move, sources: (0..<5).map { rid(a, "/f\($0).txt") }, into: b.root), control: ResourceTransferControl(isCancelled: { control.value }), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 300_000_000)
        control.value = true
        let report = await task.value
        XCTAssertEqual(report.aborted, "Cancelled")
        XCTAssertLessThan(report.committed.count, 5)
        for i in 0..<5 where b.data("/f\(i).txt") == nil { XCTAssertNotNil(a.data("/f\(i).txt")) }
        XCTAssertTrue(stagingIsEmpty())
    }

    func testQueueRunsTransferWithHooksAndNoUndo() async throws {
        let hook = TestHook(id: "watch")
        queue.hooks.register(hook, owner: "tester")
        a.seed("/r.txt", "remote")
        let dest = try dir("dest")
        let op = queue.enqueue(.copy(sources: [rid(a, "/r.txt").uri], destination: dest))
        XCTAssertTrue(op.isResourceTransfer)
        await waitIdle()
        await queue.hooks.waitForAfterHooks()
        XCTAssertEqual(op.state, .finished)
        XCTAssertEqual(read(dest.appendingPathComponent("r.txt")), "remote")
        XCTAssertEqual(op.resultingResources, [.local(dest.appendingPathComponent("r.txt"))])
        XCTAssertNotNil(op.undoUnavailableReason)
        XCTAssertFalse(undo.canUndo)
        let before = try XCTUnwrap(hook.befores.first)
        XCTAssertEqual(before.kind, .copy)
        XCTAssertEqual(before.items.first?.sourceResource, rid(a, "/r.txt"))
        XCTAssertEqual(before.items.first?.destinationResource, .local(dest.appendingPathComponent("r.txt")))
        let after = try XCTUnwrap(hook.afters.first)
        XCTAssertEqual(after.1.committed.count, 1)
        XCTAssertTrue(op.title.contains("dest"))
    }

    func testQueueHookDenialBlocksRemoteTransfer() async throws {
        let hook = TestHook(id: "deny")
        hook.beforeBehavior = { s in s.items.contains(where: \.isRemote) ? .deny("no remote") : .allow }
        queue.hooks.register(hook, owner: "tester")
        a.seed("/r.txt", "remote")
        let op = queue.enqueueTransfer(ResourceTransferRequest(mode: .move, sources: [rid(a, "/r.txt")], into: b.root))
        await waitIdle()
        XCTAssertEqual(op.hookDenial?.reason, "no remote")
        XCTAssertNotNil(a.data("/r.txt"))
        XCTAssertNil(b.data("/r.txt"))
    }

    func testQueueCancelAndRetryKeepTransferSemantics() async throws {
        for i in 0..<4 { a.seed("/c\(i).txt", "\(i)") }
        a.downloadDelay = 0.2
        let op = queue.enqueueTransfer(ResourceTransferRequest(mode: .copy, sources: (0..<4).map { rid(a, "/c\($0).txt") }, into: b.root))
        try await Task.sleep(nanoseconds: 300_000_000)
        op.cancel()
        await waitIdle()
        XCTAssertEqual(op.state, .cancelled)
        XCTAssertTrue(op.canRetry)
        a.downloadDelay = 0
        let retried = try XCTUnwrap(op.retry())
        XCTAssertTrue(retried.isResourceTransfer)
        await waitIdle()
        XCTAssertEqual(retried.state, .finished)
        for i in 0..<4 { XCTAssertEqual(b.data("/c\(i).txt"), Data("\(i)".utf8)) }
    }

    func testResourceActionsRunHooksAndRespectCapabilities() async throws {
        let hooks = FileOperationHookRegistry()
        let hook = TestHook(id: "h")
        hook.beforeBehavior = { s in s.kind == .delete ? .deny("keep it") : .allow }
        hooks.register(hook, owner: "tester")
        a.seed("/d/old.txt", "o")
        let renamed = try await ResourceActions.rename(rid(a, "/d/old.txt"), to: "new.txt", registry: registry, hooks: hooks)
        XCTAssertEqual(renamed, rid(a, "/d/new.txt"))
        XCTAssertNotNil(a.data("/d/new.txt"))
        do {
            try await ResourceActions.delete([renamed], registry: registry, hooks: hooks)
            XCTFail("expected denial")
        } catch is HookDeniedError {}
        XCTAssertNotNil(a.data("/d/new.txt"))
        do {
            try await ResourceActions.trash([renamed], registry: registry, hooks: hooks)
            XCTFail("expected unsupported")
        } catch ResourceError.unsupported(let m) {
            XCTAssertTrue(m.contains("doesn’t have a Trash"))
        }
        let made = try await ResourceActions.makeDirectory(in: rid(a, "/d"), registry: registry, hooks: hooks)
        XCTAssertEqual(made.name, "untitled folder")
        let made2 = try await ResourceActions.makeDirectory(in: rid(a, "/d"), registry: registry, hooks: hooks)
        XCTAssertEqual(made2.name, "untitled folder 2")
        XCTAssertEqual(hook.befores.map(\.kind), [.rename, .delete, .newFolder, .newFolder])
        XCTAssertEqual(hook.befores[0].items[0].destinationResource, rid(a, "/d/new.txt"))
        XCTAssertNotNil(ResourceActions.undoUnavailableReason(for: rid(a, "/"), registry: registry))
        XCTAssertNil(ResourceActions.undoUnavailableReason(for: .local(root), registry: registry))
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
