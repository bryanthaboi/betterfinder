import Security
import XCTest
@testable import Updates

final class VerifierTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws { tmp = try makeTempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testRequirementString() {
        XCTAssertEqual(
            UpdateRequirement.requirementString(),
            #"anchor apple generic and identifier "com.bryanthaboi.betterfinder" and certificate leaf[subject.OU] = "2239U5J89G""#
        )
    }

    func testRequirementEscapesQuotes() {
        let s = UpdateRequirement.requirementString(bundleIdentifier: #"a"b"#, teamIdentifier: #"c\d"#)
        XCTAssertEqual(s, #"anchor apple generic and identifier "a\"b" and certificate leaf[subject.OU] = "c\\d""#)
    }

    func testRequirementCompilesWithSecurityFramework() {
        var req: SecRequirement?
        let status = SecRequirementCreateWithString(UpdateRequirement.requirementString() as CFString, [], &req)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(req)
    }

    func verifier(current: String = "0.1.1") -> UpdateVerifier {
        UpdateVerifier(currentVersion: SemanticVersion(current))
    }

    func testIdentityAcceptsMatchingNewerApp() throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.2")
        let info = try verifier().verifyIdentity(appURL: app)
        XCTAssertEqual(info.bundleIdentifier, "com.bryanthaboi.betterfinder")
        XCTAssertEqual(info.version, SemanticVersion("0.1.2"))
    }

    func testIdentityRejectsWrongBundleID() throws {
        let app = tmp.appendingPathComponent("evil.app")
        try makeFakeApp(at: app, bundleID: "com.evil.app", version: "9.9.9")
        XCTAssertThrowsError(try verifier().verifyIdentity(appURL: app)) {
            guard case UpdateError.verificationFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    func testIdentityRejectsSameOrOlderVersion() throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.1")
        XCTAssertThrowsError(try verifier(current: "0.1.1").verifyIdentity(appURL: app))
        XCTAssertThrowsError(try verifier(current: "0.1.5").verifyIdentity(appURL: app))
    }

    func testIdentityRejectsNonBundle() {
        XCTAssertThrowsError(try verifier().verifyIdentity(appURL: tmp.appendingPathComponent("missing.app")))
    }

    func testUnsignedAppFailsSignature() throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.2")
        XCTAssertThrowsError(try verifier().verifySignature(appURL: app)) {
            guard case UpdateError.verificationFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAdHocSignedAppFailsRequirement() throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.2")
        let sign = UpdateVerifier.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try XCTSkipIf(sign.status != 0, "codesign unavailable: \(sign.output)")
        XCTAssertThrowsError(try verifier().verifySignature(appURL: app))
    }

    func testFullVerifyRejectsBeforeNotarizationWhenIdentityBad() throws {
        let app = tmp.appendingPathComponent("evil.app")
        try makeFakeApp(at: app, bundleID: "com.evil.app", version: "9.9.9")
        XCTAssertThrowsError(try verifier().verify(appURL: app, release: nil, checkNotarization: false))
    }

    func testNotarizationRejectsUnsignedApp() throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.2")
        XCTAssertThrowsError(try verifier().verifyNotarization(appURL: app))
    }
}
