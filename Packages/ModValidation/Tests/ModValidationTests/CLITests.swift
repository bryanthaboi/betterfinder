import CryptoKit
import XCTest
import ModKit
@testable import ModValidation

final class CLITests: XCTestCase {
    func testValidateExitCodes() async throws {
        let good = Support.scaffold(.command, .ts)
        let r = await Support.cli(["validate", good.path])
        XCTAssertEqual(r.code, 0, r.out + r.err)
        XCTAssertTrue(r.out.hasPrefix("INCOMPLETE alice.test-mod 0.1.0"), r.out)
        let strict = await Support.cli(["validate", good.path, "--strict"])
        XCTAssertEqual(strict.code, 1)

        let bad = Support.scaffold(.command, .ts, overrides: ["scripts/main.ts": "export const countSelection: number = 'x';"])
        let b = await Support.cli(["validate", bad.path])
        XCTAssertEqual(b.code, 1, b.out)
        XCTAssertTrue(b.out.contains("scripts/main.ts:1:14: error BF8001: TS2322"), b.out)
        XCTAssertTrue(b.out.hasPrefix("FAIL"))
    }

    func testValidateJSONIsMachineReadableAndDecodesAsReceipt() async throws {
        let dir = Support.scaffold(.column, .bfscript)
        let r = await Support.cli(["validate", dir.path, "--json"])
        XCTAssertEqual(r.code, 0)
        let data = Data(r.out.utf8)
        let receipt = try JSONDecoder().decode(PreflightReceipt.self, from: data)
        XCTAssertTrue(receipt.staticOK)
        XCTAssertEqual(receipt[.dryRun], .notRun)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["staticOK"] as? Bool, true)
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual((obj["mod"] as? [String: Any])?["id"] as? String, "alice.test-mod")
    }

    func testValidateHostVersionFlag() async {
        let dir = Support.scaffold(.command, .bfscript)
        let ok = await Support.cli(["validate", dir.path, "--host-version", "1.4.0"])
        XCTAssertEqual(ok.code, 0)
        let old = await Support.cli(["validate", dir.path, "--host-version=2.0.0"])
        XCTAssertEqual(old.code, 1)
        XCTAssertTrue(old.out.contains("BF6002"), old.out)
        let invalid = await Support.cli(["validate", dir.path, "--host-version", "banana"])
        XCTAssertEqual(invalid.code, 2)
    }

    func testValidateOnArchiveAndMissingPath() async throws {
        let dir = Support.scaffold(.command, .bfscript)
        let file = Support.tempDir().deletingLastPathComponent().appendingPathComponent("a.bfmod")
        try Support.archive(of: dir).write(to: file)
        let r = await Support.cli(["validate", file.path, "--json"])
        XCTAssertEqual(r.code, 0, r.out)
        XCTAssertTrue(r.out.contains("archiveSHA256"))
        let none = await Support.cli(["validate", "/definitely/not/here"])
        XCTAssertEqual(none.code, 2)
    }

    func testUsageErrors() async {
        for args in [[], ["bogus"], ["validate"], ["validate", "a", "b"], ["validate", "x", "--nope"], ["scaffold"], ["scaffold", "alice.x", "--language", "rust"],
                     ["scaffold", "alice.x", "--template", "nope"], ["scaffold", "BAD ID"], ["package", "x"], ["docs"], ["index-entry", "x"], ["validate", "x", "--host-version"]] {
            let r = await Support.cli(args)
            XCTAssertEqual(r.code, 2, "\(args): \(r.out)\(r.err)")
            XCTAssertFalse(r.err.isEmpty, "\(args)")
        }
        let help = await Support.cli(["help"])
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.out.contains("scaffold <id>"))
    }

    func testScaffoldCommandWritesValidModAndRefusesNonEmptyDir() async throws {
        let out = Support.tempDir("made")
        let r = await Support.cli(["scaffold", "carol.hello", "--language", "ts", "--template", "panel", "--out", out.path])
        XCTAssertEqual(r.code, 0, r.out + r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("scripts/main.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("betterfinder.d.ts").path))
        let validate = await Support.cli(["validate", out.path])
        XCTAssertEqual(validate.code, 0, validate.out)
        let again = await Support.cli(["scaffold", "carol.hello", "--out", out.path])
        XCTAssertEqual(again.code, 1)
        XCTAssertTrue(again.err.contains("not empty"))
    }

    func testScaffoldDataOnlyTemplateNotes() async {
        let out = Support.tempDir("themed")
        let r = await Support.cli(["scaffold", "carol.skin", "--language", "ts", "--template", "theme", "--out", out.path])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("data-only"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("scripts").path))
    }

    func testPackageWritesArchiveAndReceipt() async throws {
        let dir = Support.scaffold(.column, .ts)
        let out = Support.tempDir("dist").appendingPathComponent("test.bfmod")
        let r = await Support.cli(["package", dir.path, "--out", out.path])
        XCTAssertEqual(r.code, 0, r.out + r.err)
        let archive = try Data(contentsOf: out)
        XCTAssertTrue(r.out.contains(ModValidator.sha256(archive)))
        let receiptData = try Data(contentsOf: URL(fileURLWithPath: out.path + ".receipt.json"))
        let receipt = try JSONDecoder().decode(PreflightReceipt.self, from: receiptData)
        XCTAssertTrue(receipt.staticOK)
        let direct = await Support.run(.directory(dir))
        XCTAssertEqual(receipt.treeHash, direct.receipt.treeHash)
        let reread = await Support.cli(["validate", out.path])
        XCTAssertEqual(reread.code, 0)
        let again = Support.tempDir("dist2").appendingPathComponent("test.bfmod")
        _ = await Support.cli(["package", dir.path, "--out", again.path])
        XCTAssertEqual(try Data(contentsOf: again), archive)
        let pkg = ModPackage(files: ZipReader.extract(archive, limits: ZipLimits(catalog: .v1)).files)
        XCTAssertNil(pkg.data("betterfinder.d.ts"))
        XCTAssertNil(pkg.data("tsconfig.json"))
        XCTAssertNil(pkg.data(".gitignore"))
    }

    func testPackageRefusesInvalidModAndBadOutputName() async {
        let bad = Support.scaffold(.command, .ts, overrides: ["scripts/main.ts": "export const x: number = 'a';"])
        let out = Support.tempDir("dist").appendingPathComponent("bad.bfmod")
        let r = await Support.cli(["package", bad.path, "--out", out.path])
        XCTAssertEqual(r.code, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        let good = Support.scaffold(.command, .bfscript)
        let name = await Support.cli(["package", good.path, "--out", out.path.replacingOccurrences(of: ".bfmod", with: ".zip")])
        XCTAssertEqual(name.code, 2)
    }

    func testDocsCommandGeneratesExpectedFiles() async throws {
        let out = Support.tempDir("wiki")
        let r = await Support.cli(["docs", "--out", out.path])
        XCTAssertEqual(r.code, 0, r.err)
        for name in ModDocsGenerator.pageNames {
            let text = try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.isEmpty, name)
        }
        let api = try String(contentsOf: out.appendingPathComponent("Reference-API.md"), encoding: .utf8)
        XCTAssertEqual(api, ModCatalog.markdownReference())
        XCTAssertTrue(api.contains("process.archive.create"))
        let manifest = try String(contentsOf: out.appendingPathComponent("Reference-Manifest.md"), encoding: .utf8)
        for field in ["manifestVersion", "permissions", "contributes", "runtime", "dependencies", "conflicts"] {
            XCTAssertTrue(manifest.contains("`\(field)`"), field)
        }
        XCTAssertTrue(manifest.contains("`jsc-ir/1`"))
        let diag = try String(contentsOf: out.appendingPathComponent("Reference-Diagnostics.md"), encoding: .utf8)
        for code in ModDiagnosticCode.allCases { XCTAssertTrue(diag.contains("`\(code.rawValue)`"), code.rawValue) }
        XCTAssertTrue(diag.contains("TS2322"))
        let ts = try String(contentsOf: out.appendingPathComponent("Getting-Started-TypeScript.md"), encoding: .utf8)
        XCTAssertTrue(ts.contains("betterfinder-mod scaffold alice.my-mod --language ts"))
        let again = Support.tempDir("wiki2")
        _ = await Support.cli(["docs", "--out", again.path])
        for name in ModDocsGenerator.pageNames {
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(name)), try Data(contentsOf: again.appendingPathComponent(name)), name)
        }
    }

    func testDtsCommand() async throws {
        let r = await Support.cli(["dts"])
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, ModCatalogAdapter.declarations())
        let out = Support.tempDir("types").appendingPathComponent("betterfinder.d.ts")
        let w = await Support.cli(["dts", "--out", out.path])
        XCTAssertEqual(w.code, 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), r.out)
    }

    func testVersionCommand() async throws {
        let r = await Support.cli(["version"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("typescript typescript/5.9.3+sha256:"), r.out)
        let j = await Support.cli(["version", "--json"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(j.out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["api"] as? String, ModKitVersion.api)
        XCTAssertEqual(obj["catalogDigest"] as? String, ModCatalog.v1.digest)
    }

    func testIndexEntryCommand() async throws {
        let dir = Support.scaffold(.column, .bfscript, id: "alice.image-dims")
        let out = Support.tempDir("idx").appendingPathComponent("listing.json")
        let r = await Support.cli([
            "index-entry", dir.path, "--repo", "https://github.com/alice/betterfinder-image-dims.git",
            "--release-url", "https://github.com/alice/betterfinder-image-dims/releases/download/v0.1.0/alice.image-dims.bfmod",
            "--commit", "0123456789abcdef0123456789abcdef01234567", "--summary", "Adds a Dimensions column.", "--tags", "images, column", "--out", out.path,
        ])
        XCTAssertEqual(r.code, 0, r.out + r.err)
        let data = try Data(contentsOf: out)
        guard case .success(let listing) = ModIndexListing.decode(data) else { return XCTFail("listing does not decode: \(String(decoding: data, as: UTF8.self))") }
        XCTAssertEqual(listing.id, "alice.image-dims")
        XCTAssertEqual(listing.repo, "https://github.com/alice/betterfinder-image-dims")
        XCTAssertEqual(listing.release.tag, "v0.1.0")
        XCTAssertEqual(listing.release.commit, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(listing.release.sha256.count, 64)
        XCTAssertEqual(listing.categories, [.UI])
        XCTAssertEqual(listing.tags, ["images", "column"])
        let validated = await Support.run(.directory(dir))
        let manifest = try XCTUnwrap(validated.manifest)
        XCTAssertEqual(listing.consistency(with: manifest), [])
        XCTAssertTrue(r.err.contains("signature is a placeholder"))
        let archive = Support.archive(of: dir)
        XCTAssertEqual(listing.release.sha256, ModValidator.sha256(archive))
        XCTAssertEqual(listing.release.bytes, archive.count)
    }

    func testIndexEntryRejectsBadRepoAndInvalidMod() async {
        let dir = Support.scaffold(.command, .bfscript)
        let bad = await Support.cli(["index-entry", dir.path, "--repo", "https://gitlab.com/a/b", "--release-url", "https://github.com/a/b/releases/download/v1/x.bfmod"])
        XCTAssertEqual(bad.code, 2)
        let broken = Support.scaffold(.command, .ts, overrides: ["scripts/main.ts": "export const x: number = 'a';"])
        let r = await Support.cli(["index-entry", broken.path, "--repo", "https://github.com/a/b", "--release-url", "https://github.com/a/b/releases/download/v1/x.bfmod"])
        XCTAssertEqual(r.code, 1)
    }

    func testSignedListingValidatesAgainstArchiveAndAuthorKey() async throws {
        let dir = Support.scaffold(.column, .bfscript, id: "alice.image-dims")
        let work = Support.tempDir("signed")
        let archive = work.appendingPathComponent("image-dims.bfmod")
        let pkg = await Support.cli(["package", dir.path, "--out", archive.path])
        XCTAssertEqual(pkg.code, 0, pkg.out + pkg.err)
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = work.appendingPathComponent("author.key")
        try key.rawRepresentation.write(to: keyFile)
        let listingDir = work.appendingPathComponent("index/mods/alice.image-dims", isDirectory: true)
        try FileManager.default.createDirectory(at: listingDir, withIntermediateDirectories: true)
        let entry = await Support.cli([
            "index-entry", archive.path, "--repo", "https://github.com/alice/image-dims",
            "--release-url", "https://github.com/alice/image-dims/releases/download/v0.1.0/image-dims.bfmod",
            "--commit", String(repeating: "a", count: 40), "--key-id", "alice:1", "--author-key", keyFile.path, "--out", listingDir.path,
        ])
        XCTAssertEqual(entry.code, 0, entry.out + entry.err)
        XCTAssertFalse(entry.err.contains("placeholder; sign"), entry.err)
        let listingFile = listingDir.appendingPathComponent("listing.json")
        let authors = work.appendingPathComponent("index/authors", isDirectory: true)
        try FileManager.default.createDirectory(at: authors, withIntermediateDirectories: true)
        let authorFile = ModAuthorFile(author: "alice", keys: [ModAuthorKey(keyId: "alice:1", publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                                                            validFrom: Date(timeIntervalSinceNow: -60), validUntil: Date(timeIntervalSinceNow: 3600))])
        try authorFile.canonicalData.write(to: authors.appendingPathComponent("alice.json"))

        let ok = await Support.cli(["validate", archive.path, "--listing", listingFile.path])
        XCTAssertEqual(ok.code, 0, ok.out + ok.err)
        XCTAssertTrue(ok.err.contains("signature by alice:1 verified"), ok.err)

        let stranger = work.appendingPathComponent("stranger.json")
        try ModAuthorFile(author: "alice", keys: [ModAuthorKey(keyId: "alice:1", publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                                                               validFrom: Date(timeIntervalSinceNow: -60), validUntil: Date(timeIntervalSinceNow: 3600))]).canonicalData.write(to: stranger)
        let forged = await Support.cli(["validate", archive.path, "--listing", listingFile.path, "--authors", stranger.path])
        XCTAssertEqual(forged.code, 1)
        XCTAssertTrue(forged.out.contains("BF7011"), forged.out)

        var tampered = try ModIndexListing.decode(Data(contentsOf: listingFile)).get()
        tampered.release.bytes += 1
        let tamperedFile = work.appendingPathComponent("tampered.json")
        try tampered.modKitJSON(pretty: true).write(to: tamperedFile)
        let mismatch = await Support.cli(["validate", archive.path, "--listing", tamperedFile.path, "--authors", authors.path, "--json"])
        XCTAssertEqual(mismatch.code, 1)
        XCTAssertTrue(mismatch.out.contains("BF7013"), mismatch.out)

        let folder = await Support.cli(["validate", dir.path, "--listing", listingFile.path])
        XCTAssertEqual(folder.code, 2)
    }

    func testArgumentParserForms() throws {
        let p = try ParsedArgs.parse(["a", "--out=x y", "--json", "--n", "5", "--", "--literal"], values: ["--out", "--n"], flags: ["--json"])
        XCTAssertEqual(p.positionals, ["a", "--literal"])
        XCTAssertEqual(p.options["--out"], "x y")
        XCTAssertEqual(p.options["--n"], "5")
        XCTAssertTrue(p.flags.contains("--json"))
        XCTAssertThrowsError(try ParsedArgs.parse(["--json=1"], values: [], flags: ["--json"]))
    }

    func testExtensionCommandsAreDispatchedBeforeBuiltins() async {
        let c = Capture()
        let code = await ModCLI.run(arguments: ["custom", "--flag"], io: c.io, extensions: ["custom": { args, io, _, _ in io.out("ran \(args.joined(separator: ","))\n"); return 7 }])
        XCTAssertEqual(code, 7)
        XCTAssertEqual(c.out, "ran --flag\n")
        let plain = await Support.cli(["custom"])
        XCTAssertEqual(plain.code, 2)
        XCTAssertTrue(ModCLI.usage.contains("mcp [--stdio | --http]"))
    }
}
