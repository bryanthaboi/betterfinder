import FSCore
import XCTest
@testable import FileOps

@MainActor
final class RecoveryRegressionLocalTests: FileOpsTestCase {
    func testRetryAfterSameSizeDestinationEditWithPreservedMtime() async throws {
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
        let target = landed.appendingPathComponent("a.txt")
        let before = try XCTUnwrap(FS.lstatInfo(target.path))
        try FileManager.default.removeItem(at: target)
        try file("a.txt", in: landed, "b")
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, target.path, &times, 0), 0)
        let after = try XCTUnwrap(FS.lstatInfo(target.path))
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertNotEqual(before.st_ino, after.st_ino)
        chmod(locked.path, 0o644)
        let retried = try XCTUnwrap(op.retry())
        await waitIdle()
        XCTAssertTrue(retried.errors.isEmpty, "\(retried.errors)")
        XCTAssertEqual(read(landed.appendingPathComponent("a.txt")), "b")
        XCTAssertEqual(read(landed.appendingPathComponent("a 2.txt")), "a")
        XCTAssertEqual(read(landed.appendingPathComponent("locked.txt")), "secret")
        XCTAssertEqual(resolver.asked.count, 1)
    }

}

@MainActor
final class RecoveryRegressionRemoteTests: FileOpsTestCase {
    var provider: StrictResourceProvider!
    var engine: CrossProviderTransfer!

    override func setUp() async throws {
        try await super.setUp()
        provider = StrictResourceProvider("r3")
        let registry = ResourceProviderRegistry()
        try registry.register(provider, owner: "test")
        engine = CrossProviderTransfer(registry: registry)
        provider.seed("/in/file", "AAAA")
        provider.seed("/out/file", "OLD!")
    }

    func runReplacement(_ mode: ResourceTransferRequest.Mode = .copy, control: ResourceTransferControl = ResourceTransferControl()) async -> ResourceTransferReport {
        await engine.run(ResourceTransferRequest(mode: mode, sources: [provider.rid("/in/file")], into: provider.rid("/out")), resolver: ScriptedResolver([ConflictDecision(.replace)]), control: control, progress: { _ in })
    }

    func assertRetained(_ marker: String, text: String, report: ResourceTransferReport, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try XCTUnwrap(provider.allPaths.first { $0.contains(marker) && provider.text($0) == text }, file: file, line: line)
        XCTAssertTrue(report.errors.contains { $0.message.contains(path) }, "\(report.errors)", file: file, line: line)
    }

    func testHashlessCancelledMovePreservesRecreatedSourceAndStaging() async throws {
        provider.suppliesHashes = false
        let flag = CancelFlag()
        let p = provider!
        p.onMove = { source, target in
            if source.path == "/in/file", target.path.contains("bftmp") { flag.value = true }
        }
        let report = await runReplacement(.move, control: ResourceTransferControl(isCancelled: {
            if flag.value { p.seed("/in/file", "BBBB") }
            return flag.value
        }))
        XCTAssertEqual(p.text("/in/file"), "BBBB")
        XCTAssertEqual(p.text("/out/file"), "OLD!")
        XCTAssertTrue(report.committed.isEmpty)
        try assertRetained("bftmp", text: "AAAA", report: report)
    }

    func testHashlessOccupiedBackupRestorePreservesOriginal() async throws {
        provider.suppliesHashes = false
        let p = provider!
        p.afterMove = { source, target in
            if source.path == "/out/file", target.path.contains("bfbak") {
                p.seed("/out/file", "EVIL")
                throw ResourceError.connectionFailed("backup response lost")
            }
        }
        let report = await runReplacement()
        XCTAssertTrue(report.committed.isEmpty)
        XCTAssertEqual(p.text("/out/file"), "EVIL")
        try assertRetained("bfbak", text: "OLD!", report: report)
    }

    func testOccupiedSwapTargetPreservesAllVersions() async throws {
        for hashes in [true, false] {
            provider.suppliesHashes = hashes
            let p = provider!
            p.seed("/out/file", "OLD!")
            p.onMove = { source, target in
                if source.path.contains("bftmp"), target.path == "/out/file" { p.seed(target.path, "EVIL") }
            }
            let report = await runReplacement()
            XCTAssertTrue(report.committed.isEmpty)
            XCTAssertEqual(p.text("/out/file"), "EVIL")
            try assertRetained("bfbak", text: "OLD!", report: report)
            try assertRetained("bftmp", text: "AAAA", report: report)
            for path in p.allPaths where path.contains("bfbak") || path.contains("bftmp") { try await p.delete(p.rid(path), recursive: true) }
        }
    }

    func testOccupiedDirectorySubsetPreservesAllVersions() async throws {
        let p = provider!
        try await p.delete(p.rid("/in/file"), recursive: false)
        try await p.delete(p.rid("/out/file"), recursive: false)
        p.seed("/in/file/a", "AAAA")
        p.seed("/in/file/b", "BBBB")
        p.seed("/out/file/old", "OLD!")
        p.onMove = { source, target in
            if source.path.contains("bftmp"), target.path == "/out/file" { p.seed(target.path + "/a", "EVIL") }
        }
        let report = await runReplacement()
        XCTAssertTrue(report.committed.isEmpty)
        XCTAssertEqual(p.text("/out/file/a"), "EVIL")
        let backup = try XCTUnwrap(p.allPaths.first { $0.contains("bfbak") && $0.hasSuffix("/old") })
        let staged = try XCTUnwrap(p.allPaths.first { $0.contains("bftmp") && $0.hasSuffix("/a") })
        XCTAssertEqual(p.text(backup), "OLD!")
        XCTAssertEqual(p.text(staged), "AAAA")
        XCTAssertEqual(p.text(String(staged.dropLast()) + "b"), "BBBB")
        XCTAssertTrue(report.errors.contains { $0.message.contains("bfbak") && $0.message.contains("bftmp") })
    }
}
