import FSCore
import XCTest
@testable import Remote

final class RegressionS3MoveTests: XCTestCase {
    final class Script: @unchecked Sendable {
        var copies = 0
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
        let config = S3Configuration(endpoint: "https://s3.mock.test", region: "us-east-1", bucket: "photos")
        try store.setSecret(try AWSCredentials(accessKeyID: "AKTEST", secretAccessKey: "secret-test").encoded(), for: config.credentialScope)
        let client = S3Client(configuration: config, credentialStore: store, sessionConfiguration: MockS3Protocol.configuration(), retry: RetryPolicy(maxAttempts: 2, initialDelay: 0.01))
        p = S3Provider(providerID: "s3-photos", client: client)
        server.put("photos", "src/", Data())
        server.put("photos", "src/a.txt", Data("aaaa".utf8))
        server.put("photos", "src/sub/b.txt", Data("bbbb".utf8))
    }

    override func tearDown() {
        MockS3Protocol.reset()
        super.tearDown()
    }

    static func object(_ text: String) -> MockS3Server.Object {
        let d = Data(text.utf8)
        return MockS3Server.Object(data: d, etag: FileDigest.md5Hex(d), modified: Date(), meta: [:], contentType: "application/octet-stream")
    }

    static func isCopy(_ headers: [String: String]) -> Bool { headers.keys.contains { $0.lowercased() == "x-amz-copy-source" } }

    func afterCopies(_ n: Int, _ change: @escaping (inout [String: MockS3Server.Object]) -> Void) {
        let s = Script()
        server.onRequest = { _, _, headers, buckets in
            if Self.isCopy(headers) { s.copies += 1; return }
            guard s.copies == n, !s.fired else { return }
            s.fired = true
            change(&buckets["photos"]!)
        }
    }

    var src: ResourceID { p.root.appending("src") }
    var dst: ResourceID { p.root.appending("dst") }
    func text(_ key: String) -> String? { server.object("photos", key).map { String(decoding: $0.data, as: UTF8.self) } }
    var deletes: [String] { server.requests().filter { $0.method == "DELETE" && !$0.path.contains(".bfcheck-") }.map(\.path) }
    var unconditionalDeletes: [String] { server.requests().filter { r in r.method == "DELETE" && !r.headers.keys.contains { $0.lowercased() == "if-match" } }.map(\.path) }

    func testCleanFolderMoveDeletesOnlyTheCopiedManifest() async throws {
        _ = try await p.move(src, to: dst)
        XCTAssertEqual(server.keys("photos"), ["dst/", "dst/a.txt", "dst/sub/b.txt"])
        XCTAssertEqual(Set(deletes), ["/photos/src/", "/photos/src/a.txt", "/photos/src/sub/b.txt"])
        XCTAssertEqual(unconditionalDeletes.filter { !$0.contains(".bfcheck-") }, [])
        let copies = server.requests().filter { Self.isCopy($0.headers) }
        XCTAssertEqual(copies.count, 3)
        XCTAssertTrue(copies.allSatisfy { r in r.headers.keys.contains { $0.lowercased() == "x-amz-copy-source-if-match" } })
    }

    func testObjectAddedAfterCopyIsNeverDeleted() async throws {
        afterCopies(3) { $0["src/new.txt"] = Self.object("late") }
        do {
            _ = try await p.move(src, to: dst)
            XCTFail("expected the move to report the leftover")
        } catch ResourceError.verificationFailed(let message) {
            XCTAssertTrue(message.contains("new.txt"), message)
        }
        XCTAssertEqual(text("src/new.txt"), "late")
        XCTAssertNil(server.object("photos", "src/a.txt"))
        XCTAssertNil(server.object("photos", "src/sub/b.txt"))
        XCTAssertEqual(text("dst/a.txt"), "aaaa")
        XCTAssertEqual(text("dst/sub/b.txt"), "bbbb")
        XCTAssertFalse(deletes.contains("/photos/src/new.txt"))
    }

    func testObjectReplacedAfterCopyKeepsTheNewerSource() async throws {
        afterCopies(3) { $0["src/a.txt"] = Self.object("AAAA") }
        do {
            _ = try await p.move(src, to: dst)
            XCTFail("expected the move to report the changed source")
        } catch ResourceError.verificationFailed(let message) {
            XCTAssertTrue(message.contains("a.txt"), message)
        }
        XCTAssertEqual(text("src/a.txt"), "AAAA")
        XCTAssertEqual(text("dst/a.txt"), "aaaa")
        XCTAssertNil(server.object("photos", "src/sub/b.txt"))
        XCTAssertFalse(unconditionalDeletes.contains("/photos/src/a.txt"))
    }

    func testObjectReplacedBeforeItsCopyFailsWithoutDeletingAnything() async throws {
        let s = Script()
        server.onRequest = { _, _, headers, buckets in
            guard Self.isCopy(headers), !s.fired else { return }
            s.fired = true
            buckets["photos"]!["src/sub/b.txt"] = Self.object("BBBB")
        }
        do {
            _ = try await p.move(src, to: dst)
            XCTFail("expected a precondition failure")
        } catch ResourceError.remote(let code, _) {
            XCTAssertEqual(code, "PreconditionFailed")
        }
        XCTAssertTrue(deletes.isEmpty, "\(deletes)")
        XCTAssertEqual(text("src/a.txt"), "aaaa")
        XCTAssertEqual(text("src/sub/b.txt"), "BBBB")
    }

    func testBadDestinationCopyIsCaughtBeforeAnyDelete() async throws {
        afterCopies(3) { $0["dst/a.txt"] = Self.object("aa") }
        do {
            _ = try await p.move(src, to: dst)
            XCTFail("expected verification to fail")
        } catch ResourceError.verificationFailed {}
        XCTAssertTrue(deletes.isEmpty, "\(deletes)")
        XCTAssertEqual(text("src/a.txt"), "aaaa")
        XCTAssertEqual(text("src/sub/b.txt"), "bbbb")
    }

    func testSingleFileReplacedAfterCopyIsKept() async throws {
        server.put("photos", "f.txt", Data("1234".utf8))
        afterCopies(1) { $0["f.txt"] = Self.object("abcd") }
        do {
            _ = try await p.move(p.root.appending("f.txt"), to: p.root.appending("g.txt"))
            XCTFail("expected the changed source to be kept")
        } catch ResourceError.verificationFailed {}
        XCTAssertEqual(text("f.txt"), "abcd")
        XCTAssertEqual(text("g.txt"), "1234")
        XCTAssertFalse(unconditionalDeletes.contains("/photos/f.txt"))
    }

    func testSingleFileMoveStillWorks() async throws {
        server.put("photos", "f.txt", Data("1234".utf8))
        let moved = try await p.move(p.root.appending("f.txt"), to: p.root.appending("g.txt"))
        XCTAssertEqual(moved.size, 4)
        XCTAssertNil(server.object("photos", "f.txt"))
        XCTAssertEqual(text("g.txt"), "1234")
    }
}
