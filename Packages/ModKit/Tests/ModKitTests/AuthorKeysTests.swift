import CryptoKit
import XCTest
@testable import ModKit

final class AuthorKeysTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()

    func authorFile(keyId: String = "alice:2026", from: String = "2026-01-01T00:00:00Z", until: String = "2027-01-01T00:00:00Z") -> Data {
        Data("""
        {"author":"alice","keys":[{"keyId":"\(keyId)","publicKey":"\(key.publicKey.rawRepresentation.base64EncodedString())","validFrom":"\(from)","validUntil":"\(until)"}]}
        """.utf8)
    }

    func listing(signature: String? = nil, keyId: String = "alice:2026") throws -> ModIndexListing {
        var l = ModIndexListing(
            id: "alice.thing", title: "Thing", author: "alice", version: SemVer(1, 0, 0),
            api: SemVerRange.parse(">=1.0.0 <2.0.0")!, app: SemVerRange.parse(">=1.0.0 <2.0.0")!, categories: [.UI],
            repo: "https://github.com/alice/thing",
            release: ModIndexRelease(tag: "v1.0.0", commit: String(repeating: "a", count: 40), assetURL: "https://example.com/a.bfmod", bytes: 3,
                                     sha256: SHA256.hex(Data("abc".utf8)), keyId: keyId, signature: String(repeating: "A", count: 86) + "=="),
            permissions: []
        )
        l.release.signature = try signature ?? ModAuthorKeys.sign(payload: l.signedPayload, privateKey: key.rawRepresentation)
        return l
    }

    let now = ModAuthorKeys.date("2026-06-01T00:00:00Z")!

    func testDecodeAndVerify() throws {
        let file = try ModAuthorFile.decode(authorFile()).get()
        XCTAssertEqual(file.keys.first?.keyId, "alice:2026")
        XCTAssertEqual(ModAuthorKeys.verifyRelease(try listing(), authors: [file], at: now), [])
        XCTAssertEqual(ModAuthorKeys.verifyArtifact(Data("abc".utf8), listing: try listing()), [])
        assertDiag(ModAuthorKeys.verifyArtifact(Data("abcd".utf8), listing: try listing()), .artifactMismatch, pointer: "/release/bytes")
        let round = try ModAuthorFile.decode(file.canonicalData).get()
        XCTAssertEqual(round, file)
    }

    func testRejectsTamperedUnknownAndExpired() throws {
        let file = try ModAuthorFile.decode(authorFile()).get()
        var tampered = try listing()
        tampered.version = SemVer(1, 0, 1)
        assertDiag(ModAuthorKeys.verifyRelease(tampered, authors: [file], at: now), .releaseSignatureInvalid)
        assertDiag(ModAuthorKeys.verifyRelease(try listing(keyId: "alice:other"), authors: [file], at: now), .untrustedAuthorKey, pointer: "/release/keyId")
        assertDiag(ModAuthorKeys.verifyRelease(try listing(), authors: [], at: now), .untrustedAuthorKey, pointer: "/author")
        assertDiag(ModAuthorKeys.verifyRelease(try listing(), authors: [file], at: ModAuthorKeys.date("2028-01-01T00:00:00Z")!), .untrustedAuthorKey)
        let other = Curve25519.Signing.PrivateKey()
        var forged = try listing()
        forged.release.signature = try ModAuthorKeys.sign(payload: forged.signedPayload, privateKey: other.rawRepresentation)
        assertDiag(ModAuthorKeys.verifyRelease(forged, authors: [file], at: now), .releaseSignatureInvalid)
    }

    func testAuthorFileShape() {
        if case .success = ModAuthorFile.decode(authorFile(keyId: "mallory:1")) { XCTFail("keyId must be namespaced by author") }
        if case .success = ModAuthorFile.decode(authorFile(from: "2027-01-01T00:00:00Z", until: "2026-01-01T00:00:00Z")) { XCTFail("window must be ordered") }
        if case .success = ModAuthorFile.decode(Data(#"{"author":"alice","keys":[],"x":1}"#.utf8)) { XCTFail("closed object") }
    }

    func testColumnHandlerReadingSizeKeepsSelectionGrant() throws {
        let json = """
        {"manifestVersion":1,"id":"alice.heat","name":"Heat","author":"alice","version":"1.0.0","api":">=1.0.0 <2.0.0","app":">=1.0.0 <2.0.0",
         "runtime":"jsc-ir/1","entry":"scripts/main.bfscript.json","license":"MIT",
         "permissions":[{"kind":"ui.selection","level":"metadata","reason":"sizes"},{"kind":"ui","surfaces":["column"]}],
         "contributes":{"columns":[{"id":"heat","title":"Heat","valueType":"string","handler":"heat"}]},
         "hooks":[{"name":"column.values","handler":"heat","version":1}],"settings":[],"dependencies":[],"conflicts":[]}
        """
        let manifest = try ModManifest.decode(Data(json.utf8)).get()
        let diags = ModGrants.check(manifest: manifest, catalog: .v1, analysis: ScriptAnalysis(callsKnown: true))
        XCTAssertFalse(diags.contains { $0.code == .unusedGrant }, "\(diags.map(\.message))")
        var noItems = manifest
        noItems.hooks = []
        noItems.contributes.columns = []
        XCTAssertTrue(ModGrants.check(manifest: noItems, catalog: .v1, analysis: ScriptAnalysis(callsKnown: true)).contains { $0.code == .unusedGrant && $0.pointer == "/permissions/0" })
    }
}
