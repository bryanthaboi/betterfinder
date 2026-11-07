import XCTest
@testable import Updates

final class SemanticVersionTests: XCTestCase {
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testParsesPlainAndPrefixed() {
        XCTAssertEqual(v("1.2.3").numbers, [1, 2, 3])
        XCTAssertEqual(v("v0.1.42").numbers, [0, 1, 42])
        XCTAssertEqual(v("V2").numbers, [2])
        XCTAssertEqual(v(" 1.0 ").numbers, [1, 0])
    }

    func testRejectsGarbage() {
        for bad in ["", "v", "a.b.c", "1..2", "1.2.x", "-1.0", "1.2.3-", "1.2.3-a..b", "١.٢"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testNumericOrderingIsNotLexical() {
        XCTAssertLessThan(v("0.1.9"), v("0.1.10"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertGreaterThan(v("1.0.0"), v("0.99.99"))
    }

    func testMissingComponentsAreZero() {
        XCTAssertEqual(v("1.0"), v("1.0.0"))
        XCTAssertEqual(v("1"), v("1.0.0.0"))
        XCTAssertEqual(v("1.0").hashValue, v("1.0.0").hashValue)
        XCTAssertLessThan(v("1.0"), v("1.0.1"))
    }

    func testPrereleaseSortsBeforeRelease() {
        XCTAssertLessThan(v("1.0.0-beta"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-beta"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.11"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertTrue(v("1.0.0-rc.1").isPrerelease)
    }

    func testBuildMetadataIgnored() {
        XCTAssertEqual(v("1.2.3+45"), v("1.2.3"))
    }

    func testDescription() {
        XCTAssertEqual(v("v1.2.3-rc.1+9").description, "1.2.3-rc.1")
    }
}
