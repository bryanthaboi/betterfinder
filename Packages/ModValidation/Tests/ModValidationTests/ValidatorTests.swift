import XCTest
import ModKit
@testable import ModValidation

final class ValidatorTests: XCTestCase {
    func testEveryModKitExamplePassesValidate() async throws {
        let ids = ModExamples.ids
        XCTAssertEqual(ids.count, 5)
        for id in ids {
            let dir = try XCTUnwrap(ModExamples.example(id)).directory
            let r = await Support.run(.directory(dir))
            XCTAssertTrue(r.receipt.staticOK, "\(id): \(r.receipt.diagnostics)")
            XCTAssertEqual(Support.codes(r), ["BF9002"], id)
            XCTAssertEqual(r.receipt[.dryRun], .notRun, id)
            XCTAssertFalse(r.receipt.ok, id)
            XCTAssertEqual(r.manifest?.id.hasPrefix("alice."), true, id)
        }
    }

    func testExamplesAsArchivesMatchDirectoryTreeHash() async throws {
        for id in ModExamples.ids {
            let dir = try XCTUnwrap(ModExamples.example(id)).directory
            let direct = await Support.run(.directory(dir))
            let zipped = await Support.run(.archiveData(Support.archive(of: dir), name: "\(id).bfmod"))
            XCTAssertEqual(direct.receipt.treeHash, zipped.receipt.treeHash, id)
            XCTAssertEqual(Support.codes(zipped), ["BF9002"], id)
            XCTAssertNotNil(zipped.archiveSHA256)
        }
    }

    func testScaffoldMatrixPassesValidate() async {
        for template in ScaffoldTemplate.allCases {
            for language in ScaffoldLanguage.allCases {
                let dir = Support.scaffold(template, language, id: "bob.matrix-\(template.rawValue)-\(language.rawValue)")
                let r = await Support.run(.directory(dir))
                XCTAssertTrue(r.receipt.staticOK, "\(template) \(language): \(r.receipt.diagnostics)")
                XCTAssertEqual(Support.codes(r), ["BF9002"], "\(template) \(language): \(r.receipt.diagnostics)")
                let expectedRuntime = template.isDataOnly ? "data/1" : ModScaffold.runtime(language)
                XCTAssertEqual(r.manifest?.runtime.rawValue, expectedRuntime, "\(template) \(language)")
            }
        }
    }

    func testScaffoldedModsRoundTripThroughPackage() async {
        for template in ScaffoldTemplate.allCases {
            for language in ScaffoldLanguage.allCases {
                let dir = Support.scaffold(template, language, id: "bob.pack-\(template.rawValue)-\(language.rawValue)")
                let direct = await Support.run(.directory(dir))
                let archive = Support.archive(of: dir)
                let zipped = await Support.run(.archiveData(archive, name: "x.bfmod"))
                XCTAssertEqual(direct.receipt.treeHash, zipped.receipt.treeHash, "\(template) \(language)")
                XCTAssertTrue(zipped.receipt.staticOK, "\(template) \(language): \(zipped.receipt.diagnostics)")
            }
        }
    }

    func testReceiptIsDeterministic() async {
        let dir = Support.scaffold(.column, .ts)
        let a = await Support.run(.directory(dir))
        let b = await Support.run(.directory(dir))
        XCTAssertEqual(a.receipt, b.receipt)
        XCTAssertEqual(ModReportRenderer.json(a), ModReportRenderer.json(b))
        XCTAssertEqual(ModReportRenderer.text(a), ModReportRenderer.text(b))
        let other = Support.scaffold(.column, .ts)
        let c = await Support.run(.directory(other))
        XCTAssertEqual(a.receipt, c.receipt)
    }

    func testReceiptCarriesToolchainVersions() async throws {
        let ts = await Support.run(.directory(Support.scaffold(.command, .ts)))
        XCTAssertTrue(ts.receipt.toolchain.hasPrefix("modkit/1.0.0 bfscript/1 typescript/5.9.3+sha256:"), ts.receipt.toolchain)
        XCTAssertEqual(ts.receipt.validator, ModKitVersion.validator)
        XCTAssertEqual(ts.receipt.api, ModKitVersion.api)
        XCTAssertEqual(ts.receipt.treeHash.count, 64)
        let bf = await Support.run(.directory(Support.scaffold(.command, .bfscript)))
        XCTAssertEqual(bf.receipt.toolchain, ModKitVersion.toolchain)
    }

    func testDryRunnerPassMakesReceiptOK() async {
        let calls = CallCounter()
        let dir = Support.scaffold(.command, .bfscript)
        let r = await Support.run(.directory(dir), dry: StubDryRunner(diagnostics: [], calls: calls))
        XCTAssertTrue(r.receipt.ok, "\(r.receipt.diagnostics)")
        XCTAssertEqual(r.receipt[.dryRun], .pass)
        XCTAssertEqual(calls.count, 1)
    }

    func testDryRunnerFailureAndIncompleteBlock() async {
        let calls = CallCounter()
        let dir = Support.scaffold(.command, .bfscript)
        let failing = StubDryRunner(diagnostics: [ModDiagnostic(.internalMismatch, message: "hook crashed")], calls: calls)
        let r = await Support.run(.directory(dir), dry: failing)
        XCTAssertFalse(r.receipt.ok)
        XCTAssertEqual(r.receipt[.dryRun], .fail)
        let warned = await Support.run(.directory(dir), dry: StubDryRunner(diagnostics: [ModDiagnostic(.unusedHook, message: "w")], calls: calls))
        XCTAssertTrue(warned.receipt.ok)
        let incomplete = await Support.run(.directory(dir), dry: StubDryRunner(diagnostics: [ModDiagnostic(.checkNotRun, message: "no host")], calls: calls))
        XCTAssertFalse(incomplete.receipt.ok)
        XCTAssertEqual(incomplete.receipt[.dryRun], .notRun)
    }

    func testDryRunSkippedWhenStaticChecksFail() async {
        let calls = CallCounter()
        let dir = Support.scaffold(.command, .bfscript, overrides: ["scripts/main.bfscript.json": "{\"format\": 1, \"functions\": {}}"])
        let r = await Support.run(.directory(dir), dry: StubDryRunner(diagnostics: [], calls: calls))
        XCTAssertFalse(r.receipt.ok)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(r.receipt[.dryRun], .notRun)
    }

    func testDryRunnerReceivesCompiledScript() async {
        struct Probe: DryRunning {
            let box: Box
            final class Box: @unchecked Sendable { var compiled: CompiledMod? }
            func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] { box.compiled = compiled; return [] }
        }
        for language in ScaffoldLanguage.allCases {
            let box = Probe.Box()
            let dir = Support.scaffold(.column, language)
            _ = await Support.run(.directory(dir), dry: Probe(box: box))
            let c = box.compiled
            XCTAssertEqual(c?.manifest.id, "alice.test-mod")
            XCTAssertFalse(c?.script?.executionSource.isEmpty ?? true, "\(language)")
            XCTAssertEqual(c?.script?.moduleSource != nil, language != .bfscript)
            XCTAssertEqual(c?.analysis?.catalogCalls, ["media.imageDimensions"])
        }
    }

    func testIncompatibleHostVersionIsAnError() async {
        let dir = Support.scaffold(.command, .bfscript)
        let r = await Support.run(.directory(dir), host: HostInfo(app: SemVer(3, 0, 0), api: SemVer(1, 0, 0)))
        XCTAssertTrue(Support.hasCode(r, .appIncompatible))
        XCTAssertFalse(r.receipt.staticOK)
    }

    func testManifestDiagnosticsGetLineAndColumn() async {
        let dir = Support.scaffold(.command, .bfscript)
        Support.manifest(dir) { $0["license"] = "" }
        let r = await Support.run(.directory(dir))
        let d = r.receipt.diagnostics.first { $0.pointer == "/license" }
        XCTAssertNotNil(d?.line)
        XCTAssertNotNil(d?.column)
        XCTAssertEqual(d?.file, "manifest.json")
    }

    func testMissingManifestAndEmptyDirectory() async {
        let dir = Support.tempDir()
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .missingManifest))
        XCTAssertFalse(r.receipt.ok)
        XCTAssertEqual(r.receipt[.schema], .fail)
    }

    func testSymlinkExecutableAndForbiddenFilesInDirectory() async throws {
        let dir = Support.scaffold(.command, .bfscript)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("run.sh"))
        try Data("data".utf8).write(to: dir.appendingPathComponent("tool.dat"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("tool.dat").path)
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .forbiddenFileType, containing: "link.json"))
        XCTAssertTrue(Support.hasCode(r, .forbiddenFileType, containing: "run.sh"))
        XCTAssertTrue(Support.hasCode(r, .forbiddenFileType, containing: "tool.dat"))
        XCTAssertEqual(r.receipt[.paths], .fail)
        XCTAssertFalse(r.receipt.staticOK)
    }

    func testEditorFilesAndVCSAreExcludedFromDirectoryValidation() async throws {
        let dir = Support.scaffold(.column, .ts)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref".utf8).write(to: dir.appendingPathComponent(".git/HEAD"))
        let r = await Support.run(.directory(dir))
        XCTAssertEqual(Support.codes(r), ["BF9002"])
        XCTAssertNil(r.package?.data("betterfinder.d.ts"))
        XCTAssertNil(r.package?.data(".git/HEAD"))
    }

    func testBFScriptErrorsStillReportThroughSharedValidator() async {
        let dir = Support.scaffold(.column, .bfscript, overrides: [
            "scripts/main.bfscript.json": "{\"format\":1,\"functions\":{\"columnValues\":{\"signature\":\"column.values@1\",\"body\":[{\"return\":\"nope\"}]}}}"
        ])
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .typeMismatch))
        XCTAssertEqual(r.receipt[.types], .fail)
    }
}
