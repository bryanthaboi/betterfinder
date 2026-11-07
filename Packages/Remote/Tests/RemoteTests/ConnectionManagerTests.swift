import FSCore
import XCTest
@testable import Remote

final class ConnectionManagerTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        MockS3Protocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-mgr-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        MockS3Protocol.reset()
        super.tearDown()
    }

    func testAddPersistsWithoutSecretsAndRemoveCleansUp() async throws {
        let server = MockS3Server()
        server.buckets["b"] = [:]
        server.secrets["AK"] = "SK"
        MockS3Protocol.install(server, hosts: ["m.mock.test"])
        let store = RemoteServerStore(url: dir.appendingPathComponent("servers.json"))
        let creds = InMemoryCredentialStore()
        let registry = ResourceProviderRegistry()
        let mgr = RemoteConnectionManager(store: store, credentials: creds, registry: registry, toolchain: SSHToolchain(supportDirectory: dir), sessionConfiguration: { MockS3Protocol.configuration() })
        let def = RemoteServer(name: "Media", kind: .s3(S3Configuration(endpoint: "https://m.mock.test", bucket: "b")))
        let saved = try await mgr.add(def, secret: try AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK").encoded())
        XCTAssertEqual(mgr.state(of: saved), .connected)
        XCTAssertNotNil(registry.provider(for: saved.providerID))
        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(json.contains("m.mock.test"))
        XCTAssertFalse(json.contains("SK"))
        XCTAssertEqual(RemoteServerStore(url: store.url).load().map(\.id), [saved.id])
        try mgr.remove(saved)
        XCTAssertNil(registry.provider(for: saved.providerID))
        XCTAssertNil(try creds.secret(for: saved.credentialScope))
        XCTAssertTrue(RemoteServerStore(url: store.url).load().isEmpty)
    }

    func testFailedAddDoesNotSaveOrKeepCredentials() async throws {
        let server = MockS3Server()
        server.buckets["b"] = [:]
        server.secrets["AK"] = "SK"
        MockS3Protocol.install(server, hosts: ["m.mock.test"])
        let store = RemoteServerStore(url: dir.appendingPathComponent("servers.json"))
        let creds = InMemoryCredentialStore()
        let registry = ResourceProviderRegistry()
        let mgr = RemoteConnectionManager(store: store, credentials: creds, registry: registry, toolchain: SSHToolchain(supportDirectory: dir), retry: .none, sessionConfiguration: { MockS3Protocol.configuration() })
        let def = RemoteServer(kind: .s3(S3Configuration(endpoint: "https://m.mock.test", bucket: "b")))
        do {
            _ = try await mgr.add(def, secret: try AWSCredentials(accessKeyID: "AK", secretAccessKey: "wrong").encoded())
            XCTFail("expected failure")
        } catch ResourceError.authenticationFailed {}
        XCTAssertTrue(mgr.servers.isEmpty)
        XCTAssertNil(registry.provider(for: def.providerID))
        XCTAssertNil(try creds.secret(for: def.credentialScope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testSFTPServerAddResolvesHomeAndPinsPath() async throws {
        let fx = try SFTPFixture()
        defer { fx.cleanup() }
        let mgr = RemoteConnectionManager(store: RemoteServerStore(url: dir.appendingPathComponent("servers.json")), credentials: InMemoryCredentialStore(), registry: ResourceProviderRegistry(), toolchain: fx.toolchain())
        let saved = try await mgr.add(RemoteServer(kind: .sftp(SFTPConfiguration(host: "fake.example", username: "tester"))))
        guard case .sftp(let c) = saved.kind else { return XCTFail() }
        XCTAssertEqual(c.path, "/home/tester")
        XCTAssertEqual(try mgr.provider(for: saved).root.path, "/home/tester")
        XCTAssertEqual(saved.name, "tester@fake.example")
    }
}
