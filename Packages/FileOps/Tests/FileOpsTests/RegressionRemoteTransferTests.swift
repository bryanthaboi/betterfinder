import FSCore
import XCTest
@testable import FileOps

@MainActor
final class RegressionRemoteTransferTests: FileOpsTestCase {
    var registry: ResourceProviderRegistry!
    var a: MemoryResourceProvider!
    var b: MemoryResourceProvider!
    var engine: CrossProviderTransfer!

    override func setUp() async throws {
        try await super.setUp()
        registry = ResourceProviderRegistry()
        a = MemoryResourceProvider("mem-a")
        b = MemoryResourceProvider("mem-b")
        try registry.register(a, owner: "test")
        try registry.register(b, owner: "test")
        engine = CrossProviderTransfer(registry: registry)
        StagingArea.root = root.appendingPathComponent("staging")
    }

    func rid(_ p: MemoryResourceProvider, _ path: String) -> ResourceID { ResourceID(providerID: p.providerID, path: path) }

    func move(_ sources: [ResourceID], into dest: ResourceID, _ decisions: [ConflictDecision] = []) async -> ResourceTransferReport {
        await engine.run(ResourceTransferRequest(mode: .move, sources: sources, into: dest), resolver: ScriptedResolver(decisions), progress: { _ in })
    }

    func testSkippedRemoteChildSurvivesMove() async throws {
        a.seed("/docs/precious.txt", "new precious")
        a.seed("/docs/other.txt", "other")
        b.seed("/docs/precious.txt", "old")
        let report = await move([rid(a, "/docs")], into: b.root, [ConflictDecision(.merge), ConflictDecision(.skip)])
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(b.data("/docs/precious.txt"), Data("old".utf8))
        XCTAssertEqual(b.data("/docs/other.txt"), Data("other".utf8))
        XCTAssertEqual(a.data("/docs/precious.txt"), Data("new precious".utf8))
        XCTAssertNil(a.data("/docs/other.txt"))
        XCTAssertTrue(a.hasDir("/docs"))
        XCTAssertFalse(report.deletedSources.contains(rid(a, "/docs")))
    }

    func testNestedFailureKeepsFailedSourceAndIsRetryable() async throws {
        a.seed("/docs/ok.txt", "ok")
        a.seed("/docs/sub/bad.txt", "bad")
        a.seed("/docs/sub/fine.txt", "fine")
        b.failUploadNames = ["bad.txt"]
        let report = await move([rid(a, "/docs")], into: b.root)
        XCTAssertEqual(report.errors.count, 1)
        guard case .failed = report.results[0] else { return XCTFail("expected a failed result, got \(report.results)") }
        XCTAssertEqual(a.data("/docs/sub/bad.txt"), Data("bad".utf8))
        XCTAssertTrue(a.hasDir("/docs/sub"))
        XCTAssertTrue(a.hasDir("/docs"))
        XCTAssertNil(a.data("/docs/ok.txt"))
        XCTAssertNil(a.data("/docs/sub/fine.txt"))
        XCTAssertEqual(b.data("/docs/ok.txt"), Data("ok".utf8))
        XCTAssertEqual(b.data("/docs/sub/fine.txt"), Data("fine".utf8))
        XCTAssertTrue(a.deletes.allSatisfy { !$0.hasSuffix("/docs") && !$0.hasSuffix("/sub") })
        let outcome = FileOperationQueue.outcome(from: report)
        XCTAssertFalse(outcome.completed.contains(0))
    }

    func testNestedRemoteVerificationActuallyReadsBack() async throws {
        a.seed("/docs/f.txt", "important bytes")
        a.seed("/docs/deep/g.txt", "more bytes")
        b.corruptUploads = true
        let report = await move([rid(a, "/docs")], into: b.root)
        XCTAssertEqual(report.errors.count, 2)
        XCTAssertTrue(report.errors.allSatisfy { $0.message.contains("read back") }, "\(report.errors)")
        XCTAssertEqual(report.verifiedFiles, 0)
        XCTAssertEqual(a.data("/docs/f.txt"), Data("important bytes".utf8))
        XCTAssertEqual(a.data("/docs/deep/g.txt"), Data("more bytes".utf8))
        XCTAssertTrue(a.deletes.isEmpty)
    }

    func testFileAboveReadBackLimitIsStillVerified() async throws {
        engine.readBackVerificationLimit = 4
        a.seed("/big.bin", "larger than the limit")
        b.corruptUploads = true
        let report = await move([rid(a, "/big.bin")], into: b.root)
        XCTAssertEqual(report.committed, [])
        XCTAssertEqual(report.verifiedFiles, 0)
        XCTAssertEqual(a.data("/big.bin"), Data("larger than the limit".utf8))
        XCTAssertTrue(a.deletes.isEmpty)
    }

    func testChildAddedDuringMoveIsKept() async throws {
        a.seed("/docs/one.txt", "1")
        let source = a!
        b.onUpload = { id in
            if id.name == "one.txt" { source.seed("/docs/late.txt", "late") }
        }
        let report = await move([rid(a, "/docs")], into: b.root)
        XCTAssertEqual(b.data("/docs/one.txt"), Data("1".utf8))
        XCTAssertNil(a.data("/docs/one.txt"))
        XCTAssertEqual(a.data("/docs/late.txt"), Data("late".utf8))
        XCTAssertTrue(a.hasDir("/docs"))
        XCTAssertTrue(report.errors.contains { $0.message.contains("added") }, "\(report.errors)")
    }

    func testChildChangedDuringMoveIsKept() async throws {
        a.seed("/docs/one.txt", "1")
        a.seed("/docs/two.txt", "2")
        let source = a!
        b.onUpload = { id in
            if id.name == "two.txt" { source.seed("/docs/one.txt", "rewritten after copy") }
        }
        let report = await move([rid(a, "/docs")], into: b.root)
        XCTAssertEqual(a.data("/docs/one.txt"), Data("rewritten after copy".utf8))
        XCTAssertNil(a.data("/docs/two.txt"))
        XCTAssertTrue(report.errors.contains { $0.message.contains("changed") }, "\(report.errors)")
    }

    func testRemoteFolderReplaceKeepsOriginalWhenChildFails() async throws {
        a.seed("/docs/x.txt", "x")
        a.seed("/docs/bad.txt", "bad")
        b.seed("/docs/keep.txt", "old")
        b.failUploadNames = ["bad.txt"]
        let report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/docs")], into: b.root), resolver: ScriptedResolver([ConflictDecision(.replace)]), progress: { _ in })
        XCTAssertFalse(report.errors.isEmpty)
        XCTAssertTrue(report.errors.contains { $0.message.contains("wasn’t replaced") }, "\(report.errors)")
        XCTAssertEqual(b.data("/docs/keep.txt"), Data("old".utf8))
        XCTAssertFalse(b.allPaths.contains { $0.contains("bftmp") || $0.contains("bfbak") }, "\(b.allPaths)")
    }

    func testRemoteFolderMoveReplaceCommitsAndCleansUp() async throws {
        a.seed("/docs/x.txt", "x")
        b.seed("/docs/keep.txt", "old")
        let report = await move([rid(a, "/docs")], into: b.root, [ConflictDecision(.replace)])
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.committed, [rid(b, "/docs")])
        XCTAssertEqual(b.data("/docs/x.txt"), Data("x".utf8))
        XCTAssertNil(b.data("/docs/keep.txt"))
        XCTAssertFalse(b.allPaths.contains { $0.contains("bftmp") || $0.contains("bfbak") }, "\(b.allPaths)")
        XCTAssertNil(a.data("/docs/x.txt"))
        XCTAssertFalse(a.hasDir("/docs"))
    }

    func testRemoteReplaceWithFailedStagingNeverDeletesSource() async throws {
        a.seed("/docs/x.txt", "x")
        a.seed("/docs/bad.txt", "bad")
        b.seed("/docs/keep.txt", "old")
        b.failUploadNames = ["bad.txt"]
        _ = await move([rid(a, "/docs")], into: b.root, [ConflictDecision(.replace)])
        XCTAssertEqual(a.data("/docs/x.txt"), Data("x".utf8))
        XCTAssertEqual(a.data("/docs/bad.txt"), Data("bad".utf8))
        XCTAssertEqual(b.data("/docs/keep.txt"), Data("old".utf8))
    }

    func testSameServerReplaceRestoresOriginalOnFailure() async throws {
        a.seed("/x/f.txt", "new")
        a.seed("/y/f.txt", "old")
        a.failMoveSources = ["/x/f.txt"]
        let report = await move([rid(a, "/x/f.txt")], into: rid(a, "/y"), [ConflictDecision(.replace)])
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(a.data("/y/f.txt"), Data("old".utf8))
        XCTAssertEqual(a.data("/x/f.txt"), Data("new".utf8))
        XCTAssertFalse(a.allPaths.contains { $0.contains("bfbak") }, "\(a.allPaths)")
    }

    func testSameServerReplaceSucceedsWithoutPreDelete() async throws {
        a.seed("/x/f.txt", "new")
        a.seed("/y/f.txt", "old")
        let report = await move([rid(a, "/x/f.txt")], into: rid(a, "/y"), [ConflictDecision(.replace)])
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(a.data("/y/f.txt"), Data("new".utf8))
        XCTAssertNil(a.data("/x/f.txt"))
        XCTAssertFalse(a.allPaths.contains { $0.contains("bfbak") }, "\(a.allPaths)")
    }

    func testStagedReplaceCommitFailureRestoresOriginal() async throws {
        a.seed("/docs/x.txt", "x")
        b.seed("/docs/keep.txt", "old")
        b.failMoveContaining = "bftmp"
        let report = await move([rid(a, "/docs")], into: b.root, [ConflictDecision(.replace)])
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(b.data("/docs/keep.txt"), Data("old".utf8))
        XCTAssertNil(b.data("/docs/x.txt"))
        XCTAssertFalse(b.allPaths.contains { $0.contains("bftmp") || $0.contains("bfbak") }, "\(b.allPaths)")
        XCTAssertEqual(a.data("/docs/x.txt"), Data("x".utf8))
    }

    func testCancelledFolderMoveKeepsEverySource() async throws {
        for i in 0..<5 { a.seed("/docs/f\(i).txt", "\(i)") }
        a.downloadDelay = 0.15
        let flag = CancelFlag()
        let request = ResourceTransferRequest(mode: .move, sources: [rid(a, "/docs")], into: b.root)
        let task = Task { await engine.run(request, control: ResourceTransferControl(isCancelled: { flag.value }), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 350_000_000)
        flag.value = true
        let report = await task.value
        XCTAssertEqual(report.aborted, "Cancelled")
        for i in 0..<5 { XCTAssertEqual(a.data("/docs/f\(i).txt"), Data("\(i)".utf8)) }
        XCTAssertTrue(a.deletes.isEmpty)
    }

    func testFolderReplaceFailsClosedWithoutRename() async throws {
        let c = MemoryResourceProvider("mem-c", capabilities: [.read, .write, .delete, .makeDirectory])
        try registry.register(c, owner: "test")
        a.seed("/docs/x.txt", "x")
        c.seed("/docs/keep.txt", "old")
        let report = await engine.run(ResourceTransferRequest(mode: .copy, sources: [rid(a, "/docs")], into: c.root), resolver: ScriptedResolver([ConflictDecision(.replace)]), progress: { _ in })
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(c.data("/docs/keep.txt"), Data("old".utf8))
        XCTAssertNil(c.data("/docs/x.txt"))
    }
}
