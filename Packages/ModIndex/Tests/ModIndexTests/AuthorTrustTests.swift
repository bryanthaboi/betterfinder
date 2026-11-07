import XCTest
import Foundation
import CryptoKit
import ModKit
@testable import ModIndex

final class AuthorTrustTests: XCTestCase {
    let index = Curve25519.Signing.PrivateKey()
    let author = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func signedListing(signer: Curve25519.Signing.PrivateKey? = nil) throws -> ModIndexListing {
        var l = try ModIndexListing.decode(XCTUnwrap(ModExamples.indexListingExample)).get()
        l.release.keyId = l.author.lowercased() + ":1"
        l.release.signature = try ModAuthorKeys.sign(payload: l.signedPayload, privateKey: (signer ?? author).rawRepresentation)
        return l
    }

    func authorFile(_ l: ModIndexListing) -> ModAuthorFile {
        ModAuthorFile(author: l.author, keys: [ModAuthorKey(keyId: l.release.keyId, publicKey: author.publicKey.rawRepresentation.base64EncodedString(),
                                                            validFrom: now.addingTimeInterval(-100), validUntil: now.addingTimeInterval(100))])
    }

    func testFeedCarriesSignedAuthorKeys() throws {
        let l = try signedListing()
        let data = try IndexFeed(generatedAt: now.addingTimeInterval(-10), expiresAt: now.addingTimeInterval(100), serial: 1, apiVersions: ["1.0.0"],
                                 mods: [IndexEntry(listing: l)], authors: [authorFile(l)]).encoded()
        let keys = [TrustedIndexKey(publicKey: index.publicKey.rawRepresentation, validFrom: now.addingTimeInterval(-1000), validUntil: now.addingTimeInterval(1000))]
        let feed = try IndexVerifier.verify(data, signature: index.signature(for: data), keys: keys, now: now)
        XCTAssertEqual(feed.authors, [authorFile(l)])
        let verified = try ModVerifiedRelease(listing: feed.mods[0].listing, author: XCTUnwrap(feed.author(l.author)))
        XCTAssertEqual(verified.listing.id, l.id)
        XCTAssertThrowsError(try ModVerifiedRelease(listing: signedListing(signer: Curve25519.Signing.PrivateKey()), author: authorFile(l)))
        var unsigned = l
        unsigned.release.signature = String(repeating: "A", count: 86) + "=="
        XCTAssertThrowsError(try ModVerifiedRelease(listing: unsigned, author: authorFile(l)))
        let legacy = try IndexFeed.decoder().decode(IndexFeed.self, from: IndexFeed(generatedAt: now, expiresAt: now.addingTimeInterval(1), serial: 1, apiVersions: [], mods: []).encoded())
        XCTAssertEqual(legacy.authors, [])
    }
}
