import FSCore
import XCTest
@testable import Remote

final class S3ProviderTests: XCTestCase {
    var server: MockS3Server!
    var store: InMemoryCredentialStore!
    var tmp: URL!

    override func setUp() {
        super.setUp()
        MockS3Protocol.reset()
        server = MockS3Server()
        server.buckets["photos"] = [:]
        server.secrets["AKTEST"] = "secret-test"
        MockS3Protocol.install(server, hosts: ["s3.mock.test"])
        store = InMemoryCredentialStore()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bf-s3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        MockS3Protocol.reset()
        super.tearDown()
    }

    func makeProvider(bucket: String = "photos", endpoint: String = "https://s3.mock.test", prefix: String = "", access: String = "AKTEST", secret: String = "secret-test", retry: RetryPolicy = RetryPolicy(maxAttempts: 3, initialDelay: 0.01)) throws -> S3Provider {
        let config = S3Configuration(endpoint: endpoint, region: "us-east-1", bucket: bucket, prefix: prefix)
        try store.setSecret(try AWSCredentials(accessKeyID: access, secretAccessKey: secret).encoded(), for: config.credentialScope)
        let client = S3Client(configuration: config, credentialStore: store, sessionConfiguration: MockS3Protocol.configuration(), retry: retry)
        return S3Provider(providerID: "s3-\(bucket)", client: client)
    }

    func file(_ name: String, size: Int) throws -> URL {
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let u = tmp.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    func testConfigurationURLsAndScopes() throws {
        let aws = S3Configuration(region: "eu-west-1", bucket: "my-bucket")
        XCTAssertEqual(try aws.baseURL().absoluteString, "https://my-bucket.s3.eu-west-1.amazonaws.com")
        XCTAssertEqual(aws.credentialScope.host, "my-bucket.s3.eu-west-1.amazonaws.com")
        let r2 = S3Configuration(endpoint: "https://acct.r2.cloudflarestorage.com", region: "auto", bucket: "b")
        XCTAssertEqual(try r2.baseURL().absoluteString, "https://acct.r2.cloudflarestorage.com/b")
        let minio = S3Configuration(endpoint: "http://127.0.0.1:9000", bucket: "local")
        XCTAssertEqual(try minio.baseURL().absoluteString, "http://127.0.0.1:9000/local")
        XCTAssertEqual(minio.credentialScope.host, "127.0.0.1:9000")
        XCTAssertThrowsError(try S3Configuration(endpoint: "http://storage.example.com", bucket: "b").baseURL())
        XCTAssertNoThrow(try S3Configuration(endpoint: "http://storage.example.com", bucket: "b", allowInsecureHTTP: true).baseURL())
        XCTAssertThrowsError(try S3Configuration(endpoint: "https://u:p@host", bucket: "b").validate())
        XCTAssertThrowsError(try S3Configuration(bucket: "bad/bucket").validate())
    }

    func testListPaginatesAndMapsPrefixesToFolders() async throws {
        for i in 0..<7 { server.put("photos", "file\(i).jpg", Data("x\(i)".utf8)) }
        server.put("photos", "albums/a.jpg", Data("a".utf8))
        server.put("photos", "albums/b/c.jpg", Data("c".utf8))
        server.put("photos", "empty/", Data())
        server.put("photos", ".hidden", Data("h".utf8))
        let p = try makeProvider()
        var pages = 0
        var items: [ResourceItem] = []
        for try await page in p.list(p.root, options: ResourceListOptions(showHidden: false, pageSize: 3)) {
            pages += 1
            items += page
        }
        XCTAssertGreaterThanOrEqual(pages, 3)
        XCTAssertEqual(Set(items.filter(\.isDirectory).map(\.name)), ["albums", "empty"])
        XCTAssertEqual(items.filter { !$0.isDirectory }.count, 7)
        XCTAssertFalse(items.contains { $0.name == ".hidden" })
        let tokens = server.requests().filter { $0.query["continuation-token"] != nil }
        XCTAssertFalse(tokens.isEmpty)
        let albums = try await p.listAll(ResourceID(providerID: p.providerID, path: "/albums"))
        XCTAssertEqual(albums.map(\.name).sorted(), ["a.jpg", "b"])
        XCTAssertEqual(albums.first { $0.name == "b" }?.isDirectory, true)
        XCTAssertEqual(albums.first { $0.name == "a.jpg" }?.size, 1)
        let empty = try await p.listAll(ResourceID(providerID: p.providerID, path: "/empty"))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(server.signatureFailures, 0)
    }

    func testRootPrefixScopesAllKeys() async throws {
        server.put("photos", "team/x.txt", Data("x".utf8))
        server.put("photos", "other/y.txt", Data("y".utf8))
        let p = try makeProvider(prefix: "team")
        let items = try await p.listAll(p.root)
        XCTAssertEqual(items.map(\.name), ["x.txt"])
        let f = try file("up.txt", size: 10)
        _ = try await p.upload(from: f, to: p.root.appending("up.txt"), options: .init(), progress: { _ in })
        XCTAssertNotNil(server.object("photos", "team/up.txt"))
    }

    func testStatDistinguishesFilesFoldersAndMissing() async throws {
        server.put("photos", "dir/inner.txt", Data("abc".utf8))
        server.put("photos", "a.txt", Data("hello".utf8), meta: ["x-amz-meta-sha256": FileDigest.sha256Hex(Data("hello".utf8))])
        let p = try makeProvider()
        let a = try await p.stat(p.root.appending("a.txt"))
        XCTAssertFalse(a.isDirectory)
        XCTAssertEqual(a.size, 5)
        XCTAssertEqual(a.etag, FileDigest.md5Hex(Data("hello".utf8)))
        XCTAssertEqual(a.checksumSHA256, FileDigest.sha256Hex(Data("hello".utf8)))
        let d = try await p.stat(p.root.appending("dir"))
        XCTAssertTrue(d.isDirectory)
        do {
            _ = try await p.stat(p.root.appending("nope"))
            XCTFail("expected notFound")
        } catch ResourceError.notFound {}
    }

    func testRangedReadAndChunkedDownload() async throws {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        server.put("photos", "blob.bin", payload)
        let p = try makeProvider()
        let slice = try await p.read(p.root.appending("blob.bin"), range: 10..<20)
        XCTAssertEqual(slice, payload.subdata(in: 10..<20))
        p.client.downloadChunkSize = 128
        let before = server.requests().count
        let dest = tmp.appendingPathComponent("dl.bin")
        let progress = ProgressLog()
        _ = try await p.download(p.root.appending("blob.bin"), to: dest, progress: progress.add)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertEqual(progress.values.last, 1000)
        XCTAssertGreaterThanOrEqual(progress.values.count, 8)
        let ranged = server.requests().dropFirst(before).filter { $0.method == "GET" && $0.headers["Range"] != nil }
        XCTAssertTrue(ranged.allSatisfy { $0.headers["If-Match"] != nil })
    }

    func testSinglePutSendsContentMD5AndChecksumMetadata() async throws {
        let p = try makeProvider()
        let f = try file("small.bin", size: 4096)
        let item = try await p.upload(from: f, to: p.root.appending("small.bin"), options: .init(contentType: "application/octet-stream"), progress: { _ in })
        let digest = try FileDigest.compute(f)
        XCTAssertEqual(item.size, 4096)
        XCTAssertEqual(item.checksumSHA256, digest.sha256)
        XCTAssertEqual(item.etag, digest.md5)
        let put = server.requests().first { $0.method == "PUT" }!
        XCTAssertNotNil(put.headers["Content-MD5"])
        XCTAssertEqual(put.headers["x-amz-meta-sha256"], digest.sha256)
        do {
            _ = try await p.upload(from: f, to: p.root.appending("small.bin"), options: .init(overwrite: false), progress: { _ in })
            XCTFail("expected conflict")
        } catch ResourceError.alreadyExists {}
    }

    func testMultipartUploadAboveThreshold() async throws {
        let p = try makeProvider()
        p.client.multipartThreshold = 64 * 1024
        p.client.partSize = 50 * 1024
        let f = try file("big.bin", size: 180 * 1024)
        let progress = ProgressLog()
        let item = try await p.upload(from: f, to: p.root.appending("big.bin"), options: .init(), progress: progress.add)
        let stored = server.object("photos", "big.bin")!
        XCTAssertEqual(stored.data, try Data(contentsOf: f))
        XCTAssertTrue(stored.etag.hasSuffix("-4"))
        XCTAssertEqual(item.checksumSHA256, try FileDigest.compute(f).sha256)
        XCTAssertEqual(server.requests().filter { $0.query["partNumber"] != nil }.count, 4)
        XCTAssertEqual(progress.values.last, Int64(180 * 1024))
        XCTAssertEqual(server.completed.count, 1)
        XCTAssertTrue(server.aborted.isEmpty)
    }

    func testCancelledMultipartUploadIsAborted() async throws {
        let p = try makeProvider()
        p.client.multipartThreshold = 32 * 1024
        p.client.partSize = 32 * 1024
        server.partDelay = 0.15
        let f = try file("cancel.bin", size: 32 * 1024 * 8)
        let task = Task { try await p.upload(from: f, to: p.root.appending("cancel.bin"), options: .init(), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {}
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.aborted.count, 1)
        XCTAssertTrue(server.completed.isEmpty)
        XCTAssertNil(server.object("photos", "cancel.bin"))
        XCTAssertLessThan(server.requests().filter { $0.query["partNumber"] != nil }.count, 8)
    }

    func testTransientFailuresAreRetried() async throws {
        server.put("photos", "a.txt", Data("a".utf8))
        server.failNext = [503, 500]
        let p = try makeProvider()
        let items = try await p.listAll(p.root)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
        XCTAssertEqual(server.requests().count, 3)
        server.failNext = [503, 503, 503]
        do {
            _ = try await p.listAll(p.root)
            XCTFail("expected failure after retries")
        } catch let e as ResourceError {
            XCTAssertTrue(e.isTransient)
        }
    }

    func testDeleteRecursiveCopyAndRename() async throws {
        server.put("photos", "d/a.txt", Data("a".utf8))
        server.put("photos", "d/sub/b.txt", Data("b".utf8))
        server.put("photos", "d/", Data())
        server.put("photos", "keep.txt", Data("k".utf8))
        let p = try makeProvider()
        _ = try await p.copy(p.root.appending("keep.txt"), to: p.root.appending("copy.txt"))
        XCTAssertEqual(server.object("photos", "copy.txt")?.data, Data("k".utf8))
        _ = try await p.move(p.root.appending("copy.txt"), to: p.root.appending("moved.txt"))
        XCTAssertNil(server.object("photos", "copy.txt"))
        XCTAssertNotNil(server.object("photos", "moved.txt"))
        _ = try await p.makeDirectory(p.root.appending("newdir"))
        XCTAssertNotNil(server.object("photos", "newdir/"))
        try await p.delete(p.root.appending("d"), recursive: true)
        XCTAssertEqual(server.keys("photos"), ["keep.txt", "moved.txt", "newdir/"])
        XCTAssertFalse(p.capabilities.canTrash)
        XCTAssertFalse(p.capabilities.canWatch)
    }

    func testBadSecretSurfacesAuthenticationFailure() async throws {
        let p = try makeProvider(secret: "wrong")
        do {
            _ = try await p.listAll(p.root)
            XCTFail("expected auth failure")
        } catch ResourceError.authenticationFailed {}
    }

    func testMissingCredentialsNeverSendsRequest() async throws {
        let config = S3Configuration(endpoint: "https://s3.mock.test", bucket: "photos")
        let client = S3Client(configuration: config, credentialStore: InMemoryCredentialStore(), sessionConfiguration: MockS3Protocol.configuration())
        let p = S3Provider(providerID: "s3-none", client: client)
        do {
            _ = try await p.listAll(p.root)
            XCTFail("expected missing credentials")
        } catch ResourceError.credentialsMissing {}
        XCTAssertTrue(server.requests().isEmpty)
    }
}

final class CredentialIsolationTests: XCTestCase {
    override func tearDown() {
        MockS3Protocol.reset()
        super.tearDown()
    }

    func testEachHostOnlyReceivesItsOwnAccessKey() async throws {
        let a = MockS3Server()
        a.buckets["alpha"] = [:]
        a.secrets["AK-ALPHA"] = "sa"
        a.put("alpha", "a.txt", Data("a".utf8))
        let b = MockS3Server()
        b.buckets["beta"] = [:]
        b.secrets["AK-BETA"] = "sb"
        b.put("beta", "b.txt", Data("b".utf8))
        MockS3Protocol.install(a, hosts: ["a.mock.test"])
        MockS3Protocol.install(b, hosts: ["b.mock.test"])
        let store = InMemoryCredentialStore()
        let ca = S3Configuration(endpoint: "https://a.mock.test", bucket: "alpha")
        let cb = S3Configuration(endpoint: "https://b.mock.test", bucket: "beta")
        try store.setSecret(try AWSCredentials(accessKeyID: "AK-ALPHA", secretAccessKey: "sa").encoded(), for: ca.credentialScope)
        try store.setSecret(try AWSCredentials(accessKeyID: "AK-BETA", secretAccessKey: "sb").encoded(), for: cb.credentialScope)
        let pa = S3Provider(providerID: "a", client: S3Client(configuration: ca, credentialStore: store, sessionConfiguration: MockS3Protocol.configuration()))
        let pb = S3Provider(providerID: "b", client: S3Client(configuration: cb, credentialStore: store, sessionConfiguration: MockS3Protocol.configuration()))
        _ = try await pa.listAll(pa.root)
        _ = try await pb.listAll(pb.root)
        _ = try await pa.read(pa.root.appending("a.txt"), range: nil)
        _ = try await pb.read(pb.root.appending("b.txt"), range: nil)
        XCTAssertFalse(a.requests().isEmpty)
        XCTAssertFalse(b.requests().isEmpty)
        XCTAssertTrue(a.requests().allSatisfy { $0.accessKey == "AK-ALPHA" && $0.host == "a.mock.test" })
        XCTAssertTrue(b.requests().allSatisfy { $0.accessKey == "AK-BETA" && $0.host == "b.mock.test" })
        XCTAssertFalse(a.requests().contains { ($0.headers["Authorization"] ?? "").contains("AK-BETA") })
        XCTAssertFalse(b.requests().contains { ($0.headers["Authorization"] ?? "").contains("AK-ALPHA") })
        XCTAssertTrue(store.reads.allSatisfy { $0 == ca.credentialScope || $0 == cb.credentialScope })
    }

    func testRedirectToAnotherHostIsRefused() async throws {
        let a = MockS3Server()
        a.buckets["alpha"] = [:]
        a.secrets["AK-ALPHA"] = "sa"
        a.redirectTo = "https://evil.mock.test/alpha/"
        let evil = MockS3Server()
        evil.buckets["alpha"] = [:]
        evil.verifySignatures = false
        MockS3Protocol.install(a, hosts: ["a.mock.test"])
        MockS3Protocol.install(evil, hosts: ["evil.mock.test"])
        let store = InMemoryCredentialStore()
        let ca = S3Configuration(endpoint: "https://a.mock.test", bucket: "alpha")
        try store.setSecret(try AWSCredentials(accessKeyID: "AK-ALPHA", secretAccessKey: "sa").encoded(), for: ca.credentialScope)
        let pa = S3Provider(providerID: "a", client: S3Client(configuration: ca, credentialStore: store, sessionConfiguration: MockS3Protocol.configuration(), retry: .none))
        do {
            _ = try await pa.listAll(pa.root)
            XCTFail("expected redirect refusal")
        } catch let e as ResourceError {
            if case .remote(let code, _) = e { XCTAssertEqual(code, "PermanentRedirect") } else { XCTFail("unexpected \(e)") }
        }
        XCTAssertTrue(evil.requests().isEmpty)
    }

    func testBoundCredentialsRefuseOtherHosts() throws {
        let store = InMemoryCredentialStore()
        let scope = CredentialScope(kind: .s3, host: "A.example.com", resource: "b")
        try store.setSecret(try AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK").encoded(), for: scope)
        let bound = BoundCredentials(scope: scope, store: store)
        XCTAssertEqual(try bound.awsCredentials(forRequestHost: "a.example.com").accessKeyID, "AK")
        XCTAssertThrowsError(try bound.awsCredentials(forRequestHost: "a.example.com.evil.test"))
        XCTAssertThrowsError(try bound.awsCredentials(forRequestHost: "b.example.com"))
        XCTAssertNil(try store.secret(for: CredentialScope(kind: .s3, host: "a.example.com", resource: "other")))
        XCTAssertNil(try store.secret(for: CredentialScope(kind: .sftp, host: "a.example.com", resource: "b")))
    }

    func testKeychainRoundTripWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["BF_KEYCHAIN_TESTS"] == "1" else { throw XCTSkip("set BF_KEYCHAIN_TESTS=1 to touch the login keychain") }
        let k = KeychainCredentialStore(service: "com.bryanthaboi.betterfinder.remote.tests")
        let scope = CredentialScope(kind: .s3, host: "test.invalid", resource: UUID().uuidString)
        try k.setSecret(Data("one".utf8), for: scope)
        try k.setSecret(Data("two".utf8), for: scope)
        XCTAssertEqual(try k.secret(for: scope), Data("two".utf8))
        try k.removeSecret(for: scope)
        XCTAssertNil(try k.secret(for: scope))
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    var values: [Int64] { lock.lock(); defer { lock.unlock() }; return storage }
    var add: @Sendable (Int64) -> Void { { [self] v in lock.lock(); storage.append(v); lock.unlock() } }
}
