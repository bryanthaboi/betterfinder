import FileOps
import FSCore
import XCTest
@testable import Remote

final class CrossProviderTests: XCTestCase {
    var server: MockS3Server!
    var fx: SFTPFixture!
    var registry: ResourceProviderRegistry!
    var s3: S3Provider!
    var sftp: SFTPProvider!
    var local: URL!
    var stagingRoot: URL!

    override func setUp() async throws {
        MockS3Protocol.reset()
        server = MockS3Server()
        server.buckets["bucket"] = [:]
        server.secrets["AK"] = "SK"
        MockS3Protocol.install(server, hosts: ["s3.mock.test"])
        let creds = InMemoryCredentialStore()
        let config = S3Configuration(endpoint: "https://s3.mock.test", bucket: "bucket")
        try creds.setSecret(try AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK").encoded(), for: config.credentialScope)
        let client = S3Client(configuration: config, credentialStore: creds, sessionConfiguration: MockS3Protocol.configuration())
        client.multipartThreshold = 48 * 1024
        client.partSize = 32 * 1024
        s3 = S3Provider(providerID: "remote.s3.test", client: client)
        fx = try SFTPFixture()
        sftp = fx.provider()
        _ = try await sftp.resolveRoot()
        registry = ResourceProviderRegistry()
        try registry.register(LocalResourceProvider(), owner: "t")
        try registry.register(s3, owner: "t")
        try registry.register(sftp, owner: "t")
        local = fx.dir.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        stagingRoot = fx.dir.appendingPathComponent("staging")
        StagingArea.root = stagingRoot
    }

    override func tearDown() async throws {
        fx.cleanup()
        MockS3Protocol.reset()
    }

    func stagingEmpty() -> Bool {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.allSatisfy { ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).isEmpty }
    }

    func testLocalToS3ToSFTPToLocalRoundTrip() async throws {
        let engine = CrossProviderTransfer(registry: registry)
        let big = Data((0..<(150 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try big.write(to: local.appendingPathComponent("big.bin"))
        try Data("tiny".utf8).write(to: local.appendingPathComponent("tiny.txt"))
        let up = await engine.run(ResourceTransferRequest(mode: .copy, sources: [.local(local.appendingPathComponent("big.bin")), .local(local.appendingPathComponent("tiny.txt"))], into: s3.root), progress: { _ in })
        XCTAssertTrue(up.errors.isEmpty, "\(up.errors)")
        XCTAssertEqual(server.object("bucket", "big.bin")?.data, big)
        XCTAssertTrue(server.object("bucket", "big.bin")!.etag.hasSuffix("-5"))
        XCTAssertEqual(server.object("bucket", "big.bin")?.meta["x-amz-meta-sha256"], FileDigest.sha256Hex(big))

        let toSFTP = await engine.run(ResourceTransferRequest(mode: .move, sources: [s3.root.appending("big.bin")], into: sftp.root), progress: { _ in })
        XCTAssertTrue(toSFTP.errors.isEmpty, "\(toSFTP.errors)")
        XCTAssertEqual(try Data(contentsOf: fx.home.appendingPathComponent("big.bin")), big)
        XCTAssertNil(server.object("bucket", "big.bin"))
        XCTAssertEqual(toSFTP.deletedSources, [s3.root.appending("big.bin")])

        let back = local.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let down = await engine.run(ResourceTransferRequest(mode: .copy, sources: [sftp.root.appending("big.bin")], into: .local(back)), progress: { _ in })
        XCTAssertTrue(down.errors.isEmpty, "\(down.errors)")
        XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("big.bin")), big)
        XCTAssertTrue(stagingEmpty())
        XCTAssertFalse(stagingRoot.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Documents"))
    }

    func testSFTPFolderMoveToS3VerifiesEveryFileBeforeDeleting() async throws {
        let tree = fx.home.appendingPathComponent("tree/sub")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: fx.home.appendingPathComponent("tree/a.txt"))
        try Data("bb".utf8).write(to: tree.appendingPathComponent("b.txt"))
        let engine = CrossProviderTransfer(registry: registry)
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [sftp.root.appending("tree")], into: s3.root), progress: { _ in })
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.verifiedFiles, 2)
        XCTAssertEqual(server.object("bucket", "tree/a.txt")?.data, Data("a".utf8))
        XCTAssertEqual(server.object("bucket", "tree/sub/b.txt")?.data, Data("bb".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("tree").path))
    }

    func testFailedS3UploadNeverDeletesSFTPSource() async throws {
        try Data("keep".utf8).write(to: fx.home.appendingPathComponent("keep.txt"))
        server.failNext = [500, 500, 500, 500]
        let engine = CrossProviderTransfer(registry: registry)
        let report = await engine.run(ResourceTransferRequest(mode: .move, sources: [sftp.root.appending("keep.txt")], into: s3.root), progress: { _ in })
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(fx.logLines.contains { $0.hasPrefix("CMD rm") })
        XCTAssertTrue(stagingEmpty())
    }
}
