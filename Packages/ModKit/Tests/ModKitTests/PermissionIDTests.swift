import XCTest
@testable import ModKit

final class PermissionIDTests: XCTestCase {
    func legacyID(_ p: ModPermission) -> String {
        "\(p.kind.rawValue):" + String(SHA256.hex(p.modKitJSON()).prefix(12))
    }

    func testMatchesModHostAlgorithmForEveryExamplePermission() {
        var seen = 0
        for ex in ModExamples.all {
            guard case .success(let m) = ModManifest.decode(ex.package.data("manifest.json")!) else { return XCTFail(ex.id) }
            for p in m.permissions {
                XCTAssertEqual(ModPermissionID.make(p), legacyID(p))
                XCTAssertTrue(ModPermissionID.isWellFormed(ModPermissionID.make(p)))
                XCTAssertEqual(ModPermissionID.kind(of: ModPermissionID.make(p)), p.kind)
                seen += 1
            }
        }
        XCTAssertGreaterThan(seen, 3)
    }

    func testFixtureIsStable() {
        let p = ModPermission(kind: .fsRead, reason: "Read selected image headers", scope: .selection, recursive: false)
        XCTAssertEqual(String(decoding: ModPermissionID.canonicalJSON(p), as: UTF8.self),
                       #"{"kind":"fs.read","reason":"Read selected image headers","recursive":false,"scope":"selection"}"#)
        XCTAssertEqual(ModPermissionID.make(p), "fs.read:" + String(SHA256.hex(#"{"kind":"fs.read","reason":"Read selected image headers","recursive":false,"scope":"selection"}"#).prefix(12)))
        XCTAssertEqual(p.permissionID, ModPermissionID.make(p))
        XCTAssertEqual(ModPermissionID.from(kind: "ui", canonicalJSON: Data(#"{"kind":"ui","surfaces":["column"]}"#.utf8)).count, "ui:".count + 12)
    }

    func testCanonicalJSONAgreesWithJSONValueCanonicalForm() throws {
        let p = ModPermission(kind: .ui, surfaces: [.column, .toolbar])
        let viaValue = try JSONValue.parse(ModPermissionID.canonicalJSON(p)).canonicalData()
        XCTAssertEqual(viaValue, ModPermissionID.canonicalJSON(p))
    }

    func testDistinctPermissionsHaveDistinctIDs() {
        let a = ModPermission(kind: .ui, surfaces: [.column])
        let b = ModPermission(kind: .ui, surfaces: [.toolbar])
        XCTAssertNotEqual(ModPermissionID.make(a), ModPermissionID.make(b))
        XCTAssertFalse(ModPermissionID.isWellFormed("ui"))
        XCTAssertFalse(ModPermissionID.isWellFormed("ui:ABCDEF012345"))
        XCTAssertNil(ModPermissionID.kind(of: "bogus:abcdef012345"))
    }
}
