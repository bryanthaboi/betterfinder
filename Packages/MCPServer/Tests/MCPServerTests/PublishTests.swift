import Foundation
import ModKit
import ModValidation
import XCTest
@testable import MCPServer

final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String: [String]]()
    func set(_ key: String, _ value: [String]) { lock.withLock { values[key] = value } }
    func get(_ key: String) -> [String] { lock.withLock { values[key] ?? [] } }
}

func merged(_ base: JSONValue, _ extra: [String: JSONValue]) -> JSONValue { base.merging(extra) }

final class PublishTests: XCTestCase {
    let repoArgs: JSONValue = obj(["workspace": "alice.demo".j, "owner": "alice".j, "name": "demo".j, "visibility": "private".j])

    func ghReady(_ h: Harness) {
        h.runner.handler = { inv in
            if inv.executable == "gh", inv.arguments == ["api", "user", "--jq", ".login"] { return result("alice\n") }
            return result("")
        }
    }

    func testCreateRepoNeedsDryRunThenConfirm() async throws {
        let h = await Harness()
        ghReady(h)
        _ = await h.scaffold()

        let dry = await h.call("github_create_repo", repoArgs)
        XCTAssertTrue(dry.ok, dry.errorMessage)
        h.assertConforms("github_create_repo", dry)
        let token = dry.string("confirmationToken")
        XCTAssertTrue(ModPatterns.matches(token, "^[0-9a-f]{48}$"), token)
        XCTAssertEqual(dry.string("pending"), token)
        XCTAssertEqual(dry.data["review"]?["owner"]?.stringValue, "alice")
        XCTAssertEqual(dry.data["review"]?["visibility"]?.stringValue, "private")
        XCTAssertEqual(dry.data["review"]?["signedInAs"]?.stringValue, "alice")
        XCTAssertNil(dry.data["repoURL"])
        XCTAssertTrue(dry.content.contains { $0["text"]?.stringValue?.contains("NOT DONE YET") == true })
        XCTAssertEqual(h.runner.argv(), [["gh", "api", "user", "--jq", ".login"]])

        let done = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": token.j]))
        XCTAssertTrue(done.ok, done.errorMessage)
        h.assertConforms("github_create_repo", done)
        XCTAssertEqual(done.string("repoURL"), "https://github.com/alice/demo")
        XCTAssertTrue(h.runner.argv().contains(["gh", "repo", "create", "alice/demo", "--private", "--description", "Demo - a betterfinder mod"]), "\(h.runner.argv())")
        XCTAssertEqual(h.runner.argv().filter { $0.starts(with: ["gh", "repo", "create"]) }.count, 1)

        let replay = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": token.j]))
        XCTAssertEqual(replay.errorCode, "consent_invalid")
        XCTAssertEqual(h.runner.argv().filter { $0.starts(with: ["gh", "repo", "create"]) }.count, 1)
    }

    func testPublicVisibilityFlag() async throws {
        let h = await Harness()
        ghReady(h)
        _ = await h.scaffold()
        let args = merged(repoArgs, ["visibility": "public".j])
        let dry = await h.call("github_create_repo", args)
        _ = await h.call("github_create_repo", merged(args, ["confirm": true, "confirmationToken": dry.string("confirmationToken").j]))
        XCTAssertTrue(h.runner.argv().contains(["gh", "repo", "create", "alice/demo", "--public", "--description", "Demo - a betterfinder mod"]))
    }

    func testConfirmWithoutTokenIsRejected() async throws {
        let h = await Harness()
        ghReady(h)
        _ = await h.scaffold()
        let none = await h.call("github_create_repo", merged(repoArgs, ["confirm": true]))
        XCTAssertTrue(none.isError)
        XCTAssertEqual(none.errorCode, "consent_required")
        let forged = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": String(repeating: "a", count: 48).j]))
        XCTAssertEqual(forged.errorCode, "consent_invalid")
        let malformed = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": "yes".j]))
        XCTAssertEqual(malformed.errorCode, "invalid_arguments")
        XCTAssertFalse(h.runner.argv().contains { $0.starts(with: ["gh", "repo", "create"]) })
    }

    func testStaleAndChangedConsentAreRejected() async throws {
        let h = await Harness()
        ghReady(h)
        _ = await h.scaffold()
        let dry = await h.call("github_create_repo", repoArgs)
        h.clock.advance(601)
        let expired = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": dry.string("confirmationToken").j]))
        XCTAssertEqual(expired.errorCode, "consent_expired")

        let dry2 = await h.call("github_create_repo", repoArgs)
        let changed = await h.call("github_create_repo", merged(repoArgs, ["name": "other".j, "confirm": true, "confirmationToken": dry2.string("confirmationToken").j]))
        XCTAssertEqual(changed.errorCode, "consent_mismatch")
        let afterMismatch = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": dry2.string("confirmationToken").j]))
        XCTAssertEqual(afterMismatch.errorCode, "consent_invalid")

        let dry3 = await h.call("github_create_repo", repoArgs)
        let visibility = await h.call("github_create_repo", merged(repoArgs, ["visibility": "public".j, "confirm": true, "confirmationToken": dry3.string("confirmationToken").j]))
        XCTAssertEqual(visibility.errorCode, "consent_mismatch")
        XCTAssertFalse(h.runner.argv().contains { $0.starts(with: ["gh", "repo", "create"]) })
    }

    func testConfirmFalseWithTokenStaysDryRun() async throws {
        let h = await Harness()
        ghReady(h)
        _ = await h.scaffold()
        let dry = await h.call("github_create_repo", repoArgs)
        let again = await h.call("github_create_repo", merged(repoArgs, ["confirm": false, "confirmationToken": dry.string("confirmationToken").j]))
        XCTAssertTrue(again.ok)
        XCTAssertNotEqual(again.string("confirmationToken"), dry.string("confirmationToken"))
        XCTAssertNil(again.data["repoURL"])
        XCTAssertFalse(h.runner.argv().contains { $0.starts(with: ["gh", "repo", "create"]) })
    }

    func testTokenCannotCrossTools() async throws {
        let h = await Harness()
        ghReady(h)
        let (revision, _, archive) = await h.packaged()
        let dry = await h.call("github_create_repo", repoArgs)
        let token = dry.string("confirmationToken")
        let release = await h.call("github_publish_release", obj([
            "workspace": "alice.demo".j, "revision": revision.j, "repoURL": "https://github.com/alice/demo".j, "tag": "v0.1.0".j,
            "archive": (archive["id"] ?? .null), "confirm": true, "confirmationToken": token.j,
        ]))
        XCTAssertEqual(release.errorCode, "consent_mismatch")
        XCTAssertFalse(h.runner.argv().contains { $0.first == "git" })
    }

    func testGhUnavailableIsReportedAndNoTokenIssued() async throws {
        let h = await Harness()
        h.runner.handler = { inv in throw CommandRunnerError.notFound(inv.executable) }
        _ = await h.scaffold()
        let dry = await h.call("github_create_repo", repoArgs)
        XCTAssertTrue(dry.isError)
        XCTAssertEqual(dry.errorCode, "gh_unavailable")
        XCTAssertTrue(dry.errorMessage.contains("never downloads"))
        XCTAssertEqual(h.server.ledger.outstanding, 0)
    }

    func testGhNotLoggedIn() async throws {
        let h = await Harness()
        h.runner.handler = { _ in CommandResult(status: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login") }
        _ = await h.scaffold()
        let dry = await h.call("github_create_repo", repoArgs)
        XCTAssertEqual(dry.errorCode, "gh_not_authenticated")
        XCTAssertEqual(h.server.ledger.outstanding, 0)
    }

    func testCredentialsAreNeverEchoed() async throws {
        let h = await Harness()
        h.runner.handler = { inv in
            if inv.arguments == ["api", "user", "--jq", ".login"] { return result("alice\n") }
            if inv.arguments.starts(with: ["repo", "create"]) {
                return CommandResult(status: 1, stdout: "", stderr: "HTTP 401 Bad credentials ghp_abcdefghijklmnopqrstuvwxyz0123456789 and https://alice:secretpass1234@github.com/x Authorization: Bearer abcdef0123456789")
            }
            return result("")
        }
        _ = await h.scaffold()
        let dry = await h.call("github_create_repo", repoArgs)
        let failed = await h.call("github_create_repo", merged(repoArgs, ["confirm": true, "confirmationToken": dry.string("confirmationToken").j]))
        XCTAssertEqual(failed.errorCode, "gh_failed")
        let text = failed.errorMessage
        XCTAssertFalse(text.contains("ghp_abc"), text)
        XCTAssertFalse(text.contains("secretpass"), text)
        XCTAssertFalse(text.contains("abcdef0123456789"), text)
        XCTAssertTrue(text.contains("***"))
    }

    func testInvalidRepoArgumentsNeverReachGh() async throws {
        let h = await Harness()
        ghReady(h)
        _ = await h.scaffold()
        for (owner, name) in [("-evil", "demo"), ("alice", "--web"), ("alice", ".."), ("alice/x", "demo"), ("alice", "a b")] {
            let r = await h.call("github_create_repo", merged(repoArgs, ["owner": owner.j, "name": name.j]))
            XCTAssertFalse(r.ok, "\(owner)/\(name)")
        }
        XCTAssertTrue(h.runner.calls.isEmpty)
    }

    func releaseHandler(_ h: Harness, archiveBytes: @escaping @Sendable () -> Int, archiveData: @escaping @Sendable () -> Data, capture: Captured) {
        h.runner.handler = { inv in
            let a = inv.arguments
            if inv.executable == "gh" {
                if a == ["api", "user", "--jq", ".login"] { return result("alice\n") }
                if a.starts(with: ["release", "create"]) { return result("https://github.com/alice/demo/releases/tag/v0.1.0\n") }
                if a.starts(with: ["release", "view"]) {
                    let size = archiveBytes()
                    return result("{\"url\":\"https://github.com/alice/demo/releases/tag/v0.1.0\",\"isDraft\":false,\"assets\":[{\"name\":\"alice.demo-0.1.0.bfmod\",\"size\":\(size),\"url\":\"https://github.com/alice/demo/releases/download/v0.1.0/alice.demo-0.1.0.bfmod\"}]}")
                }
                if a.starts(with: ["release", "download"]) {
                    let dir = URL(fileURLWithPath: a[a.firstIndex(of: "--dir")! + 1])
                    try archiveData().write(to: dir.appendingPathComponent(a[a.firstIndex(of: "--pattern")! + 1]))
                    return result("")
                }
                if a.first == "api", a.dropFirst().first?.hasPrefix("repos/") == true { return result(String(repeating: "c", count: 40) + "\n") }
                if a.starts(with: ["repo", "clone"]) { return result("") }
                if a.starts(with: ["pr", "create"]) { return result("https://github.com/bryanthaboi/betterfinder-mod-index/pull/12\n") }
            } else if inv.executable == "git" {
                if a.contains("add"), let cwd = inv.workingDirectory, a.contains("--all") {
                    let en = FileManager.default.enumerator(atPath: cwd.path)
                    var files = [String]()
                    while let f = en?.nextObject() as? String {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent(f).path, isDirectory: &isDir), !isDir.boolValue { files.append(f) }
                    }
                    capture.set("staged", files.sorted())
                }
                if a.contains("rev-parse") { return result(String(repeating: "b", count: 40) + "\n") }
            }
            return result("")
        }
    }

    func testPublishReleaseRunsExactGhAndGitCommands() async throws {
        let h = await Harness()
        let (revision, _, archive) = await h.packaged()
        let archivePath = try XCTUnwrap(archive["path"]?.stringValue)
        let bytes = try XCTUnwrap(archive["bytes"]?.intValue)
        let capture = Captured()
        releaseHandler(h, archiveBytes: { bytes }, archiveData: { Data() }, capture: capture)
        let args: JSONValue = obj([
            "workspace": "alice.demo".j, "revision": revision.j, "repoURL": "https://github.com/alice/demo".j, "tag": "v0.1.0".j, "archive": archive["id"] ?? .null,
        ])
        let dry = await h.call("github_publish_release", args)
        XCTAssertTrue(dry.ok, dry.errorMessage)
        h.assertConforms("github_publish_release", dry)
        XCTAssertNotNil(dry.data["review"]?["sourceInventory"]?.arrayValue)
        XCTAssertEqual(dry.data["review"]?["archive"]?["sha256"], archive["sha256"])
        XCTAssertTrue(h.runner.argv().allSatisfy { $0 == ["gh", "api", "user", "--jq", ".login"] }, "dry run must be read only: \(h.runner.argv())")

        let before = h.runner.calls.count
        let done = await h.call("github_publish_release", merged(args, ["confirm": true, "confirmationToken": dry.string("confirmationToken").j]))
        XCTAssertTrue(done.ok, done.errorMessage)
        h.assertConforms("github_publish_release", done)
        XCTAssertEqual(done.string("releaseURL"), "https://github.com/alice/demo/releases/tag/v0.1.0")
        XCTAssertEqual(done.string("commit"), String(repeating: "b", count: 40))
        XCTAssertEqual(done.string("assetURL"), "https://github.com/alice/demo/releases/download/v0.1.0/alice.demo-0.1.0.bfmod")
        XCTAssertEqual(done.string("sha256"), archive["sha256"]?.stringValue)

        let git = ["git", "-c", "core.hooksPath=/dev/null"]
        let credential = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]
        let tail = Array(h.runner.argv().dropFirst(before))
        let expected: [[String]] = [
            ["gh", "api", "user", "--jq", ".login"],
            git + ["init", "--initial-branch", "main"],
            git + ["add", "--all"],
            git + ["-c", "commit.gpgsign=false", "commit", "--message", "Release v0.1.0"],
            git + ["remote", "add", "origin", "https://github.com/alice/demo.git"],
            git + credential + ["push", "--set-upstream", "origin", "main"],
            git + ["tag", "--annotate", "v0.1.0", "--message", "Demo 0.1.0"],
            git + credential + ["push", "origin", "v0.1.0"],
            git + ["rev-parse", "HEAD"],
            ["gh", "release", "create", "v0.1.0", archivePath, "--repo", "alice/demo", "--title", "Demo 0.1.0", "--notes",
             "betterfinder mod alice.demo 0.1.0\n\nSHA-256 of the archive: \(archive["sha256"]?.stringValue ?? "")", "--verify-tag"],
            ["gh", "release", "view", "v0.1.0", "--repo", "alice/demo", "--json", "url,isDraft,assets"],
        ]
        XCTAssertEqual(tail, expected)
        let staged = capture.get("staged")
        XCTAssertTrue(staged.contains("manifest.json"))
        XCTAssertTrue(staged.contains("scripts/main.bfscript.json"))
        XCTAssertFalse(staged.contains { $0.hasSuffix(".bfmod") || $0.contains(".artifacts") || $0.hasSuffix(".png") }, "\(staged)")
        XCTAssertTrue(h.runner.calls.dropFirst(before).dropFirst().allSatisfy { $0.workingDirectory != nil || $0.executable == "gh" })
        let sourceDir = try XCTUnwrap(h.runner.calls[before + 1].workingDirectory)
        XCTAssertFalse(sourceDir.path.hasPrefix(h.workspaces.root.appendingPathComponent("alice.demo").path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDir.path), "staging must be cleaned up")
    }

    func testPublishReleaseRejectsMismatchedArchiveAndRevision() async throws {
        let h = await Harness()
        ghReady(h)
        let (revision, _, archive) = await h.packaged()
        let other = await h.packaged(id: "alice.other")
        let args: JSONValue = obj([
            "workspace": "alice.demo".j, "revision": revision.j, "repoURL": "https://github.com/alice/demo".j, "tag": "v0.1.0".j, "archive": other.archive["id"] ?? .null,
        ])
        let wrongArchive = await h.call("github_publish_release", args)
        XCTAssertEqual(wrongArchive.errorCode, "archive_mismatch")
        let unknown = await h.call("github_publish_release", merged(args, ["archive": "art-forged".j]))
        XCTAssertEqual(unknown.errorCode, "archive_mismatch")

        let edit = await h.call("mod_files_write", obj(["workspace": "alice.demo".j, "expected": revision.j, "changes": [obj(["path": "EXTRA.md", "text": "x".j])].j]))
        XCTAssertTrue(edit.ok)
        let stale = await h.call("github_publish_release", merged(args, ["archive": archive["id"] ?? .null]))
        XCTAssertEqual(stale.errorCode, "stale_revision")

        let path = try XCTUnwrap(archive["path"]?.stringValue)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))
        let tampered = await h.call("github_publish_release", merged(args, ["revision": edit.string("revision").j, "archive": archive["id"] ?? .null]))
        XCTAssertTrue(["archive_changed", "archive_mismatch"].contains(tampered.errorCode ?? ""), tampered.errorCode ?? "")
        XCTAssertFalse(h.runner.argv().contains { $0.first == "git" })
    }

    func testPublishRejectsBadURLsAndTags() async throws {
        let h = await Harness()
        ghReady(h)
        let (revision, _, archive) = await h.packaged()
        let base: JSONValue = obj(["workspace": "alice.demo".j, "revision": revision.j, "repoURL": "https://github.com/alice/demo".j, "tag": "v0.1.0".j, "archive": archive["id"] ?? .null])
        for url in ["http://github.com/alice/demo", "https://evil.example/alice/demo", "https://github.com/alice/demo/extra", "https://github.com/-x/demo", "https://github.com/alice/.."] {
            let r = await h.call("github_publish_release", merged(base, ["repoURL": url.j]))
            XCTAssertFalse(r.ok, url)
        }
        for tag in ["-v1", "--force", "a b", "../x", ""] {
            let r = await h.call("github_publish_release", merged(base, ["tag": tag.j]))
            XCTAssertEqual(r.errorCode, "invalid_arguments", tag)
        }
        XCTAssertFalse(h.runner.argv().contains { $0.first == "git" })
    }

    func indexEntryFixture(_ h: Harness) async throws -> (revision: String, archive: JSONValue, data: Data) {
        let (revision, _, archive) = await h.packaged()
        let path = try XCTUnwrap(archive["path"]?.stringValue)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        releaseHandler(h, archiveBytes: { data.count }, archiveData: { data }, capture: Captured())
        return (revision, archive, data)
    }

    let signedExtras: [String: JSONValue] = ["keyId": "alice:ed25519:2026".j, "signature": (String(repeating: "B", count: 86) + "==").j]

    func testIndexEntryVerifiesReleaseAndBuildsListing() async throws {
        let h = await Harness()
        let (_, archive, data) = try await indexEntryFixture(h)
        let args: JSONValue = obj([
            "workspace": "alice.demo".j, "releaseURL": "https://github.com/alice/demo/releases/download/v0.1.0/alice.demo-0.1.0.bfmod".j,
            "summary": "A demo".j, "categories": strs(["WORKFLOW"]),
        ])
        let unsigned = await h.call("mod_index_entry", args)
        XCTAssertTrue(unsigned.ok, unsigned.errorMessage)
        h.assertConforms("mod_index_entry", unsigned)
        XCTAssertFalse(unsigned.data["warnings"]?.arrayValue?.isEmpty ?? true)
        XCTAssertTrue(h.runner.argv().contains(["gh", "release", "download", "v0.1.0", "--repo", "alice/demo", "--pattern", "alice.demo-0.1.0.bfmod", "--dir", h.runner.calls.first { $0.arguments.starts(with: ["release", "download"]) }!.arguments[8], "--clobber"]))
        XCTAssertTrue(h.runner.argv().contains(["gh", "api", "repos/alice/demo/commits/v0.1.0", "--jq", ".sha"]))

        let signed = await h.call("mod_index_entry", merged(args, signedExtras))
        XCTAssertTrue(signed.ok, signed.errorMessage)
        XCTAssertEqual(signed.data["warnings"], strs([]))
        let file = try XCTUnwrap(signed.data["files"]?[0])
        XCTAssertEqual(file["path"]?.stringValue, "mods/alice.demo/listing.json")
        let listing = try JSONValue.parse(try XCTUnwrap(file["text"]?.stringValue))
        XCTAssertEqual(listing["id"]?.stringValue, "alice.demo")
        XCTAssertEqual(listing["repo"]?.stringValue, "https://github.com/alice/demo")
        XCTAssertEqual(listing["release"]?["tag"]?.stringValue, "v0.1.0")
        XCTAssertEqual(listing["release"]?["commit"]?.stringValue, String(repeating: "c", count: 40))
        XCTAssertEqual(listing["release"]?["sha256"]?.stringValue, archive["sha256"]?.stringValue)
        XCTAssertEqual(listing["release"]?["bytes"]?.intValue, data.count)
        XCTAssertEqual(listing["release"]?["keyId"]?.stringValue, "alice:ed25519:2026")
        let decoded = ModIndexListing.decode(Data((file["text"]?.stringValue ?? "").utf8))
        if case .failure(let d) = decoded { XCTFail("\(d)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.workspaces.root.appendingPathComponent(".index/alice.demo/mods/alice.demo/listing.json").path))
    }

    func testIndexEntryRejectsReleaseThatIsNotTheWorkspace() async throws {
        let h = await Harness()
        let (revision, _, _) = try await indexEntryFixture(h)
        let other = await h.packaged(id: "alice.other")
        let otherData = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(other.archive["path"]?.stringValue)))
        releaseHandler(h, archiveBytes: { otherData.count }, archiveData: { otherData }, capture: Captured())
        let edit = await h.call("mod_files_write", obj(["workspace": "alice.demo".j, "expected": revision.j, "changes": [obj(["path": "EXTRA.md", "text": "x".j])].j]))
        XCTAssertTrue(edit.ok)
        let r = await h.call("mod_index_entry", obj([
            "workspace": "alice.demo".j, "releaseURL": "https://github.com/alice/demo/releases/tag/v0.1.0".j, "summary": "x".j, "categories": strs(["UI"]),
        ]))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(["release_mismatch", "release_invalid"].contains(r.errorCode ?? ""), r.errorCode ?? "")
        for bad in ["https://github.com/alice/demo", "https://github.com/alice/demo/releases/download/v1/x.exe", "https://github.com/alice/demo/releases/download/-v1/x.bfmod", "https://example.com/alice/demo/releases/tag/v1"] {
            let b = await h.call("mod_index_entry", obj(["workspace": "alice.demo".j, "releaseURL": bad.j, "summary": "x".j, "categories": strs(["UI"])]))
            XCTAssertFalse(b.ok, bad)
        }
    }

    func testIndexPullRequestDryRunThenExactForkBranchPR() async throws {
        let h = await Harness()
        _ = try await indexEntryFixture(h)
        let entry = await h.call("mod_index_entry", obj([
            "workspace": "alice.demo".j, "releaseURL": "https://github.com/alice/demo/releases/tag/v0.1.0".j,
            "summary": "A demo".j, "categories": strs(["WORKFLOW"]), "keyId": signedExtras["keyId"]!, "signature": signedExtras["signature"]!,
        ]))
        XCTAssertTrue(entry.ok, entry.errorMessage)
        let revision = entry.string("revision")
        let pr: JSONValue = obj(["workspace": "alice.demo".j, "revision": revision.j, "title": "Add alice.demo 0.1.0".j, "body": "Please review".j])

        let before = h.runner.calls.count
        let dry = await h.call("mod_index_pr", pr)
        XCTAssertTrue(dry.ok, dry.errorMessage)
        h.assertConforms("mod_index_pr", dry)
        let review = try XCTUnwrap(dry.data["review"])
        XCTAssertEqual(review["destination"]?.stringValue, "bryanthaboi/betterfinder-mod-index")
        XCTAssertEqual(review["head"]?.stringValue, "alice:add-alice.demo-0.1.0")
        XCTAssertEqual(review["title"]?.stringValue, "Add alice.demo 0.1.0")
        XCTAssertEqual(review["diff"]?[0]?["path"]?.stringValue, "mods/alice.demo/listing.json")
        XCTAssertEqual(review["diff"]?[0]?["text"]?.stringValue, entry.data["files"]?[0]?["text"]?.stringValue)
        let body = try XCTUnwrap(review["body"]?.stringValue)
        for fragment in ["mod, version, folder: alice.demo 0.1.0", "source repo and license: https://github.com/alice/demo", "permission rationale:", "Please review", "no screenshots included"] {
            XCTAssertTrue(body.contains(fragment), fragment)
        }
        XCTAssertEqual(Array(h.runner.argv().dropFirst(before)), [["gh", "api", "user", "--jq", ".login"]])

        let wrongRevision = await h.call("mod_index_pr", merged(pr, ["revision": String(repeating: "1", count: 64).j]))
        XCTAssertEqual(wrongRevision.errorCode, "no_index_entry")

        let mark = h.runner.calls.count
        let done = await h.call("mod_index_pr", merged(pr, ["confirm": true, "confirmationToken": dry.string("confirmationToken").j]))
        XCTAssertTrue(done.ok, done.errorMessage)
        h.assertConforms("mod_index_pr", done)
        XCTAssertEqual(done.string("prURL"), "https://github.com/bryanthaboi/betterfinder-mod-index/pull/12")
        XCTAssertEqual(done.string("head"), "alice:add-alice.demo-0.1.0")

        let calls = Array(h.runner.calls.dropFirst(mark))
        let git = ["git", "-c", "core.hooksPath=/dev/null"]
        let credential = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]
        let clone = try XCTUnwrap(calls[2].arguments.dropFirst(3).first)
        let expected: [[String]] = [
            ["gh", "api", "user", "--jq", ".login"],
            ["gh", "repo", "fork", "bryanthaboi/betterfinder-mod-index", "--clone=false", "--remote=false"],
            ["gh", "repo", "clone", "alice/betterfinder-mod-index", clone, "--", "--depth", "1", "--no-tags"],
            git + ["remote", "add", "upstream", "https://github.com/bryanthaboi/betterfinder-mod-index.git"],
            git + credential + ["fetch", "--depth", "1", "upstream", "main"],
            git + ["checkout", "-b", "add-alice.demo-0.1.0", "FETCH_HEAD"],
            git + ["add", "--", "mods/alice.demo/listing.json"],
            git + ["-c", "commit.gpgsign=false", "commit", "--message", "Add alice.demo 0.1.0"],
            git + credential + ["push", "--set-upstream", "origin", "add-alice.demo-0.1.0"],
            ["gh", "pr", "create", "--repo", "bryanthaboi/betterfinder-mod-index", "--head", "alice:add-alice.demo-0.1.0", "--base", "main", "--title", "Add alice.demo 0.1.0", "--body", body],
        ]
        XCTAssertEqual(calls.map { [$0.executable] + $0.arguments }, expected)
        XCTAssertFalse(calls.contains { $0.arguments.contains("upstream") && $0.arguments.contains("push") })
    }

    func testIndexPullRequestSurfacesPlaceholderSignatureWarning() async throws {
        let h = await Harness()
        _ = try await indexEntryFixture(h)
        let entry = await h.call("mod_index_entry", obj([
            "workspace": "alice.demo".j, "releaseURL": "https://github.com/alice/demo/releases/tag/v0.1.0".j, "summary": "A demo".j, "categories": strs(["UI"]),
        ]))
        let dry = await h.call("mod_index_pr", obj(["workspace": "alice.demo".j, "revision": entry.string("revision").j, "title": "t".j, "body": "".j]))
        XCTAssertTrue(dry.ok, dry.errorMessage)
        XCTAssertFalse(dry.data["review"]?["warnings"]?.arrayValue?.isEmpty ?? true)
        XCTAssertTrue(dry.data["review"]?["body"]?.stringValue?.contains("NOT SIGNED YET") == true)
        let multiline = await h.call("mod_index_pr", obj(["workspace": "alice.demo".j, "revision": entry.string("revision").j, "title": "a\nb".j, "body": "".j]))
        XCTAssertEqual(multiline.errorCode, "invalid_arguments")
    }

    func testConsentLedgerUnits() throws {
        let clock = FakeClock()
        let ledger = ConsentLedger(ttl: 10, clock: { clock.now })
        let a = ledger.issue(tool: "t", digest: "d")
        XCTAssertThrowsError(try ledger.consume(token: nil, tool: "t", digest: "d")) { XCTAssertEqual(($0 as? ToolError)?.code, "consent_required") }
        XCTAssertThrowsError(try ledger.consume(token: a.token, tool: "other", digest: "d")) { XCTAssertEqual(($0 as? ToolError)?.code, "consent_mismatch") }
        XCTAssertThrowsError(try ledger.consume(token: a.token, tool: "t", digest: "d")) { XCTAssertEqual(($0 as? ToolError)?.code, "consent_invalid") }
        let b = ledger.issue(tool: "t", digest: "d")
        XCTAssertNoThrow(try ledger.consume(token: b.token, tool: "t", digest: "d"))
        let c = ledger.issue(tool: "t", digest: "d")
        clock.advance(11)
        XCTAssertThrowsError(try ledger.consume(token: c.token, tool: "t", digest: "d")) { XCTAssertEqual(($0 as? ToolError)?.code, "consent_expired") }
        var tokens = Set<String>()
        for _ in 0..<200 { tokens.insert(ledger.issue(tool: "t", digest: "d").token) }
        XCTAssertEqual(tokens.count, 200)
        XCTAssertLessThanOrEqual(ledger.outstanding, 64)
    }
}
