import FSCore
import XCTest
@testable import Remote

final class BehaviorRegressionS3MoveTests: XCTestCase {
    final class Flag: @unchecked Sendable {
        var fired = false
    }

    var server: MockS3Server!
    var store: InMemoryCredentialStore!
    var p: S3Provider!

    override func setUpWithError() throws {
        MockS3Protocol.reset()
        server = MockS3Server()
        server.buckets["photos"] = [:]
        server.secrets["AKTEST"] = "secret-test"
        MockS3Protocol.install(server, hosts: ["s3.mock.test"])
        store = InMemoryCredentialStore()
        p = try makeProvider()
    }

    override func tearDown() {
        MockS3Protocol.reset()
        super.tearDown()
    }

    func makeProvider() throws -> S3Provider {
        let config = S3Configuration(endpoint: "https://s3.mock.test", region: "us-east-1", bucket: "photos")
        try store.setSecret(try AWSCredentials(accessKeyID: "AKTEST", secretAccessKey: "secret-test").encoded(), for: config.credentialScope)
        let client = S3Client(configuration: config, credentialStore: store, sessionConfiguration: MockS3Protocol.configuration(), retry: RetryPolicy(maxAttempts: 2, initialDelay: 0.01))
        return S3Provider(providerID: "s3-photos", client: client)
    }

    static func object(_ text: String) -> MockS3Server.Object {
        let d = Data(text.utf8)
        return MockS3Server.Object(data: d, etag: FileDigest.md5Hex(d), modified: Date(), meta: [:], contentType: "application/octet-stream")
    }

    func text(_ key: String) -> String? { server.object("photos", key).map { String(decoding: $0.data, as: UTF8.self) } }
    var f: ResourceID { p.root.appending("f.txt") }
    var g: ResourceID { p.root.appending("g.txt") }
    var sourceDeletes: [MockS3Server.Logged] { server.requests().filter { $0.method == "DELETE" && !$0.path.contains(".bfcheck-") } }
    var probes: [MockS3Server.Logged] { server.requests().filter { $0.method == "PUT" && $0.path.contains(".bfcheck-") } }
    static func header(_ r: MockS3Server.Logged?, _ name: String) -> String? { r?.headers.first { $0.key.lowercased() == name.lowercased() }?.value }

    func changeAtDelete(_ key: String, to text: String) {
        let flag = Flag()
        server.beforeDelete = { k, objects in
            guard k == key, !flag.fired else { return }
            flag.fired = true
            objects[key] = Self.object(text)
        }
    }

    func testFileChangedAtDeleteDispatchSurvivesTheMove() async throws {
        server.put("photos", "f.txt", Data("old!".utf8))
        changeAtDelete("f.txt", to: "NEW!")
        do {
            _ = try await p.move(f, to: g)
            XCTFail("the move must not succeed after deleting a newer source")
        } catch ResourceError.verificationFailed(let message) {
            XCTAssertTrue(message.contains("f.txt"), message)
        }
        XCTAssertEqual(text("f.txt"), "NEW!")
        XCTAssertEqual(text("g.txt"), "old!")
        XCTAssertEqual(Self.header(sourceDeletes.last, "If-Match"), "\"\(FileDigest.md5Hex(Data("old!".utf8)))\"")
    }

    func testFolderChildChangedAtDeleteDispatchIsKeptAndReported() async throws {
        server.put("photos", "src/", Data())
        server.put("photos", "src/a.txt", Data("aaaa".utf8))
        server.put("photos", "src/sub/b.txt", Data("bbbb".utf8))
        changeAtDelete("src/a.txt", to: "AAAA")
        do {
            _ = try await p.move(p.root.appending("src"), to: p.root.appending("dst"))
            XCTFail("expected the changed child to be reported")
        } catch ResourceError.verificationFailed(let message) {
            XCTAssertTrue(message.contains("a.txt"), message)
        }
        XCTAssertEqual(text("src/a.txt"), "AAAA")
        XCTAssertEqual(text("dst/a.txt"), "aaaa")
        XCTAssertEqual(text("dst/sub/b.txt"), "bbbb")
        XCTAssertNil(server.object("photos", "src/sub/b.txt"))
        XCTAssertTrue(sourceDeletes.allSatisfy { Self.header($0, "If-Match") != nil }, "\(sourceDeletes.map(\.path))")
    }

    func testEndpointRejectingConditionalDeleteKeepsTheSource() async throws {
        for (status, code) in [(501, "NotImplemented"), (400, "InvalidArgument")] {
            server.buckets["photos"] = [:]
            server.log = []
            p = try makeProvider()
            server.conditionalDelete = .reject(status, code)
            server.put("photos", "f.txt", Data("1234".utf8))
            do {
                _ = try await p.move(f, to: g)
                XCTFail("expected the move to refuse for \(status)")
            } catch ResourceError.remote(let c, let message) {
                XCTAssertEqual(c, "SafeMoveUnavailable")
                XCTAssertTrue(message.contains("f.txt"), message)
            }
            XCTAssertEqual(text("f.txt"), "1234", "\(status)")
            XCTAssertNil(server.object("photos", "g.txt"), "\(status)")
            XCTAssertTrue(sourceDeletes.isEmpty, "\(status) \(sourceDeletes.map(\.path))")
            XCTAssertEqual(server.keys("photos"), ["f.txt"], "\(status)")
        }
    }

    func testEndpointIgnoringConditionalDeleteIsDetectedBeforeAnything() async throws {
        server.conditionalDelete = .ignore
        server.put("photos", "f.txt", Data("1234".utf8))
        do {
            _ = try await p.move(f, to: g)
            XCTFail("an endpoint that ignores If-Match must not be trusted with the source")
        } catch ResourceError.remote(let code, _) {
            XCTAssertEqual(code, "SafeMoveUnavailable")
        }
        XCTAssertEqual(text("f.txt"), "1234")
        XCTAssertTrue(sourceDeletes.isEmpty, "\(sourceDeletes.map(\.path))")
        XCTAssertEqual(server.keys("photos"), ["f.txt"])
        XCTAssertEqual(probes.count, 1)
    }

    func testRejectionAtDeleteTimeKeepsSourceAndCopy() async throws {
        server.put("photos", "f.txt", Data("1234".utf8))
        server.conditionalDeleteByKey["f.txt"] = .reject(501, "NotImplemented")
        do {
            _ = try await p.move(f, to: g)
            XCTFail("expected the refusal to surface")
        } catch ResourceError.remote(let code, let message) {
            XCTAssertEqual(code, "SafeMoveUnavailable")
            XCTAssertTrue(message.contains("kept"), message)
        }
        XCTAssertEqual(text("f.txt"), "1234")
        XCTAssertEqual(text("g.txt"), "1234")
        server.conditionalDeleteByKey = [:]
        server.put("photos", "h.txt", Data("h".utf8))
        do {
            _ = try await p.move(p.root.appending("h.txt"), to: p.root.appending("i.txt"))
            XCTFail("a refused conditional delete should stop later moves before copying")
        } catch ResourceError.remote(let code, _) {
            XCTAssertEqual(code, "SafeMoveUnavailable")
        }
        XCTAssertEqual(text("h.txt"), "h")
        XCTAssertNil(server.object("photos", "i.txt"))
    }

    func testDeleteIfUnchangedKeepsAnObjectChangedAtDeleteDispatch() async throws {
        server.put("photos", "f.txt", Data("old!".utf8))
        let expected = try await p.stat(f)
        changeAtDelete("f.txt", to: "NEW!")
        let deleted = try await p.deleteIfUnchanged(f, from: expected)
        XCTAssertFalse(deleted)
        XCTAssertEqual(text("f.txt"), "NEW!")
    }

    func testDeleteIfUnchangedDeletesOnlyTheExpectedVersion() async throws {
        server.put("photos", "f.txt", Data("1234".utf8))
        let expected = try await p.stat(f)
        var noTag = expected
        noTag.etag = nil
        let withoutTag = try await p.deleteIfUnchanged(f, from: noTag)
        XCTAssertFalse(withoutTag)
        XCTAssertEqual(text("f.txt"), "1234")
        let deleted = try await p.deleteIfUnchanged(f, from: expected)
        XCTAssertTrue(deleted)
        XCTAssertNil(server.object("photos", "f.txt"))
        XCTAssertEqual(Self.header(sourceDeletes.last, "If-Match"), "\"\(FileDigest.md5Hex(Data("1234".utf8)))\"")
        XCTAssertEqual(server.keys("photos"), [])
    }

    func testDeleteIfUnchangedRefusesOnAnEndpointThatCannotEnforceIt() async throws {
        for mode in [MockS3Server.ConditionalDelete.ignore, .reject(501, "NotImplemented")] {
            server.buckets["photos"] = [:]
            server.log = []
            p = try makeProvider()
            server.conditionalDelete = mode
            server.put("photos", "f.txt", Data("1234".utf8))
            let expected = try await p.stat(f)
            do {
                _ = try await p.deleteIfUnchanged(f, from: expected)
                XCTFail("expected the delete to be refused for \(mode)")
            } catch ResourceError.remote(let code, let message) {
                XCTAssertEqual(code, "SafeMoveUnavailable")
                XCTAssertTrue(message.contains("f.txt"), message)
            }
            XCTAssertEqual(text("f.txt"), "1234", "\(mode)")
            XCTAssertEqual(server.keys("photos"), ["f.txt"], "\(mode)")
        }
    }

    func testCapabilityIsProbedOncePerClientAndCleanedUp() async throws {
        server.put("photos", "a.txt", Data("a".utf8))
        server.put("photos", "b.txt", Data("b".utf8))
        _ = try await p.move(p.root.appending("a.txt"), to: p.root.appending("a2.txt"))
        _ = try await p.move(p.root.appending("b.txt"), to: p.root.appending("b2.txt"))
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(server.keys("photos"), ["a2.txt", "b2.txt"])
        XCTAssertEqual(Self.header(sourceDeletes.first { $0.path == "/photos/a.txt" }, "If-Match"), "\"\(FileDigest.md5Hex(Data("a".utf8)))\"")
    }
}

final class BehaviorRegressionSFTPReplaceTests: XCTestCase {
    var fx: SFTPFixture!
    var local: URL!

    override func setUpWithError() throws {
        fx = try SFTPFixture()
        try Data("original contents".utf8).write(to: fx.home.appendingPathComponent("doc.txt"))
        local = fx.dir.appendingPathComponent("replacement.txt")
        try Data("replacement".utf8).write(to: local)
    }

    override func tearDown() {
        fx?.cleanup()
        super.tearDown()
    }

    var remoteText: String? { try? String(contentsOf: fx.home.appendingPathComponent("doc.txt"), encoding: .utf8) }
    var leftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: fx.home.path)) ?? []).filter { $0.hasPrefix(".bfpart-") || $0.hasPrefix(".bfold-") } }
    var mark: URL { fx.dir.appendingPathComponent("pause") }

    func replace() async throws -> ResourceItem {
        let p = fx.provider()
        let root = try await p.resolveRoot()
        return try await p.upload(from: local, to: root.appending("doc.txt"), options: .init(overwrite: true), progress: { _ in })
    }

    func pause(on command: String, after earlier: String) {
        fx.env["FAKE_SFTP_PAUSE_CMD"] = command
        fx.env["FAKE_SFTP_PAUSE_AFTER"] = earlier
        fx.env["FAKE_SFTP_PAUSE_MARK"] = mark.path
    }

    func cancelAtPause() async throws -> Result<ResourceItem, Error> {
        let task = Task { try await self.replace() }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: mark.path) {
            guard Date() < deadline else {
                task.cancel()
                XCTFail("the fixture never paused: \(fx.logLines)")
                return await task.result
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        try Data().write(to: URL(fileURLWithPath: mark.path + ".go"))
        return await task.result
    }

    func testStagedSizeMismatchNeverTouchesTheOriginal() async throws {
        for legacy in ["0", "1"] {
            try Data("original contents".utf8).write(to: fx.home.appendingPathComponent("doc.txt"))
            try? FileManager.default.removeItem(at: fx.log)
            fx.env["FAKE_SFTP_LEGACY_RENAME"] = legacy
            fx.env["FAKE_SFTP_SHORT_PUT"] = "1"
            do {
                _ = try await replace()
                XCTFail("expected the short upload to be caught, legacy=\(legacy)")
            } catch ResourceError.verificationFailed(let message) {
                XCTAssertTrue(message.contains("doc.txt"), message)
            }
            XCTAssertEqual(remoteText, "original contents", "legacy=\(legacy)")
            XCTAssertTrue(leftovers.isEmpty, "legacy=\(legacy) \(leftovers)")
            XCTAssertFalse(fx.logLines.contains { $0.hasPrefix("CMD rename") }, "legacy=\(legacy) \(fx.logLines)")
        }
    }

    func testCancelAfterUploadBeforeCommitKeepsTheOriginal() async throws {
        pause(on: "^ls ", after: "^CMD put ")
        let result = try await cancelAtPause()
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(remoteText, "original contents")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testCancelAfterLegacyCommitRestoresTheOriginal() async throws {
        fx.env["FAKE_SFTP_LEGACY_RENAME"] = "1"
        pause(on: "^-?(ls|rm) ", after: "^CMD rename [^ ]*doc\\.txt [^ ]*bfold")
        let result = try await cancelAtPause()
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(remoteText, "original contents", "\(fx.logLines)")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testFailedRestoreAfterCancelReportsTheBackup() async throws {
        fx.env["FAKE_SFTP_LEGACY_RENAME"] = "1"
        fx.env["FAKE_SFTP_FAIL_CMD"] = "^rename [^ ]*doc\\.txt [^ ]*bfpart"
        pause(on: "^-?(ls|rm) ", after: "^CMD rename [^ ]*doc\\.txt [^ ]*bfold")
        let result = try await cancelAtPause()
        do {
            _ = try result.get()
            XCTFail("expected a failure naming the backup")
        } catch ResourceError.remote(let code, let message) {
            XCTAssertEqual(code, "ReplaceIncomplete")
            XCTAssertTrue(message.contains(".bfold-"), message)
        }
        let kept = try XCTUnwrap(leftovers.first { $0.hasPrefix(".bfold-") }, "\(fx.logLines)")
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(kept), encoding: .utf8), "original contents")
    }
}
