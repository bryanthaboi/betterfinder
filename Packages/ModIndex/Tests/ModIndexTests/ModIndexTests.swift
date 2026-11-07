import XCTest
import Foundation
import CryptoKit
import ModKit
@testable import ModIndex

final class MockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) throws -> (Int, Data, [String: String]) = { _ in throw URLError(.notConnectedToInternet) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data, headers) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ModIndexTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var directory: URL!
    var session: URLSession!
    var keys: [TrustedIndexKey] { [TrustedIndexKey(publicKey: key.publicKey.rawRepresentation, validFrom: now.addingTimeInterval(-1000), validUntil: now.addingTimeInterval(1000))] }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
    func listing() throws -> ModIndexListing { try ModIndexListing.decode(XCTUnwrap(ModExamples.indexListingExample)).get() }
    func feed(serial: UInt64 = 2, offset: TimeInterval = -10, expiry: TimeInterval = 100) throws -> Data {
        try IndexFeed(generatedAt: now.addingTimeInterval(offset), expiresAt: now.addingTimeInterval(expiry), serial: serial,
                      apiVersions: ["1.0.0"], mods: [try IndexEntry(listing: listing())]).encoded()
    }
    func client() -> ModIndexClient {
        let date = now
        return ModIndexClient(trustedKeys: keys, stateDirectory: directory.appendingPathComponent("state"), cacheDirectory: directory, session: session, now: { date })
    }
    func serve(_ data: Data) throws {
        let sig = try key.signature(for: data)
        MockProtocol.handler = { request in request.url!.path.hasSuffix(".sig") ? (200, sig, [:]) : (200, data, ["ETag": "v2"]) }
    }
    func testSignatureAndDeterminism() throws {
        let data = try feed()
        XCTAssertEqual(data, try feed())
        XCTAssertEqual(try IndexVerifier.verify(data, signature: key.signature(for: data), keys: keys, now: now).serial, 2)
    }
    func testTamperAndWrongKey() throws {
        let data = try feed(), sig = try key.signature(for: data)
        XCTAssertThrowsError(try IndexVerifier.verify(data + Data([32]), signature: sig, keys: keys, now: now))
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try IndexVerifier.verify(data, signature: other.signature(for: data), keys: keys, now: now))
    }
    func testExpiredAndKeyWindow() throws {
        let data = try feed(expiry: -1)
        XCTAssertThrowsError(try IndexVerifier.verify(data, signature: key.signature(for: data), keys: keys, now: now))
        XCTAssertThrowsError(try IndexVerifier.verify(data, signature: key.signature(for: data), keys: keys, now: now.addingTimeInterval(2000), allowExpired: true))
    }
    func testRotation() throws {
        let data = try feed(), next = Curve25519.Signing.PrivateKey()
        let rotated = keys + [TrustedIndexKey(publicKey: next.publicKey.rawRepresentation, validFrom: now.addingTimeInterval(-1), validUntil: now.addingTimeInterval(100))]
        XCTAssertNoThrow(try IndexVerifier.verify(data, signature: next.signature(for: data), keys: rotated, now: now))
    }
    func testETag304() async throws {
        try serve(feed())
        let c = client()
        let first = try await c.fetch()
        XCTAssertEqual(first.listings.count, 1)
        MockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "v2")
            return (304, Data(), [:])
        }
        let second = try await c.fetch()
        XCTAssertFalse(second.isOffline)
    }
    func testOfflineAndPersistedRollback() async throws {
        try serve(feed())
        _ = try await client().fetch()
        MockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = try await client().fetch()
        XCTAssertTrue(offline.isOffline)
        try serve(feed(serial: 1, offset: -20))
        do { _ = try await client().fetch(); XCTFail("rollback accepted") }
        catch ModIndexError.rollback {} catch { XCTFail("\(error)") }
    }
    func testExpiredOfflineCannotInstall() async throws {
        try serve(feed())
        _ = try await client().fetch()
        MockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let date = now.addingTimeInterval(200)
        let c = ModIndexClient(trustedKeys: keys, stateDirectory: directory.appendingPathComponent("state"), cacheDirectory: directory, session: session, now: { date })
        let snapshot = try await c.fetch()
        XCTAssertTrue(snapshot.isExpired)
        XCTAssertFalse(snapshot.canInstall)
        do { _ = try await c.verifiedListing(id: "alice.image-dimensions"); XCTFail("expired install") } catch {}
    }
    func testRollbackAfterCacheEviction() async throws {
        try serve(feed())
        _ = try await client().fetch()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            try FileManager.default.removeItem(at: file)
        }
        try serve(feed(serial: 1, offset: -20))
        do { _ = try await client().fetch(); XCTFail("evicted rollback accepted") }
        catch ModIndexError.rollback {} catch { XCTFail("\(error)") }
    }
    func testArtifactDigestAndLimit() async throws {
        var m = try listing()
        m.release.bytes = 3
        MockProtocol.handler = { _ in (200, Data("bad".utf8), [:]) }
        do { _ = try await ModArtifactDownloader(session: session).download(m, directory: directory); XCTFail("hash accepted") }
        catch ModIndexError.digestMismatch {} catch { XCTFail("\(error)") }
        MockProtocol.handler = { _ in (200, Data("huge".utf8), [:]) }
        do { _ = try await ModArtifactDownloader(session: session).download(m, directory: directory); XCTFail("limit accepted") }
        catch ModIndexError.sizeLimit {} catch { XCTFail("\(error)") }
        m.release.sha256 = ModKit.SHA256.hex("bad")
        MockProtocol.handler = { _ in (200, Data("bad".utf8), [:]) }
        let file = try await ModArtifactDownloader(session: session).download(m, directory: directory)
        XCTAssertEqual(try Data(contentsOf: file), Data("bad".utf8))
    }
}
