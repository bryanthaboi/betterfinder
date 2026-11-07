import XCTest
@testable import Updates

final class ReleaseParsingTests: XCTestCase {
    func testParsesFixture() throws {
        let release = try UpdateRelease.parse(fixtureData("release"))
        XCTAssertEqual(release.tag, "v0.1.42")
        XCTAssertEqual(release.version, SemanticVersion("0.1.42"))
        XCTAssertEqual(release.name, "betterfinder 0.1.42")
        XCTAssertTrue(release.notes.contains("Faster **folder sizes**"))
        XCTAssertEqual(release.pageURL?.absoluteString, "https://github.com/bryanthaboi/betterfinder/releases/tag/v0.1.42")
        XCTAssertNotNil(release.publishedAt)
    }

    func testPicksMacOSZipAndDmg() throws {
        let release = try UpdateRelease.parse(fixtureData("release"))
        XCTAssertEqual(release.zipAsset?.name, "betterfinder-0.1.42-macos.zip")
        XCTAssertEqual(release.zipAsset?.size, 7_000_000)
        XCTAssertEqual(release.zipAsset?.apiURL?.absoluteString, "https://api.github.com/repos/bryanthaboi/betterfinder/releases/assets/9002")
        XCTAssertEqual(release.zipAsset?.sha256, "abcdef0123456789")
        XCTAssertEqual(release.dmgAsset?.name, "betterfinder-0.1.42.dmg")
    }

    func testRejectsDraftsAndBadTags() {
        XCTAssertThrowsError(try UpdateRelease.parse(Data(#"{"tag_name":"v1.0.0","draft":true}"#.utf8)))
        XCTAssertThrowsError(try UpdateRelease.parse(Data(#"{"tag_name":"nightly"}"#.utf8)))
        XCTAssertThrowsError(try UpdateRelease.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try UpdateRelease.parse(Data("not json".utf8)))
    }

    func testMissingOptionalFields() throws {
        let release = try UpdateRelease.parse(Data(#"{"tag_name":"v1.2.3"}"#.utf8))
        XCTAssertEqual(release.name, "v1.2.3")
        XCTAssertEqual(release.notes, "")
        XCTAssertNil(release.zipAsset)
        XCTAssertNil(release.dmgAsset)
    }

    func testFallsBackToAnyZip() throws {
        let json = #"{"tag_name":"v1.0.0","assets":[{"name":"app.zip","size":1,"browser_download_url":"https://example.com/app.zip"}]}"#
        let release = try UpdateRelease.parse(Data(json.utf8))
        XCTAssertEqual(release.zipAsset?.name, "app.zip")
        XCTAssertNil(release.zipAsset?.sha256)
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownBlocks.parse("# Title\n\nSome text\nmore text\n\n- one\n  - nested\n1. first\n\n```\ncode line\n```\n---\n")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Some text more text"),
            .bullet(indent: 0, text: "one"),
            .bullet(indent: 1, text: "nested"),
            .numbered(number: "1", text: "first"),
            .code("code line"),
            .rule,
        ])
    }

    func testMarkdownUnclosedFenceAndInline() {
        XCTAssertEqual(MarkdownBlocks.parse("```\nabc"), [.code("abc")])
        XCTAssertEqual(String(MarkdownBlocks.inline("a **b** c").characters), "a b c")
    }
}
