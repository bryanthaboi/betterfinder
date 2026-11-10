import XCTest
@testable import FSCore

final class HomeNameDisplayTests: XCTestCase {
    private let home = "/Users/casey"

    private func display(_ style: HomeNameStyle, custom: String = "") -> HomeNameDisplay {
        HomeNameDisplay(style: style, custom: custom, homePath: home)
    }

    func testRealNameChangesNothing() {
        let d = display(.real)
        XCTAssertFalse(d.isActive)
        XCTAssertNil(d.replacementName)
        XCTAssertEqual(d.name("casey", forPath: home), "casey")
        XCTAssertEqual(d.path(home), home)
        XCTAssertEqual(d.path(home + "/Documents/a.txt"), home + "/Documents/a.txt")
        XCTAssertEqual(d.accessibilityName("casey", forPath: home), "casey")
    }

    func testTildeReplacesHomeAndPathsUnderIt() {
        let d = display(.tilde)
        XCTAssertEqual(d.name("casey", forPath: home), "~")
        XCTAssertEqual(d.name("casey", forPath: home + "/"), "~")
        XCTAssertEqual(d.path(home), "~")
        XCTAssertEqual(d.path(home + "/Documents/a.txt"), "~/Documents/a.txt")
        XCTAssertEqual(d.name("Documents", forPath: home + "/Documents"), "Documents")
    }

    func testCustomReplacesTheHomeComponentOnly() {
        let d = display(.custom, custom: "me")
        XCTAssertEqual(d.name("casey", forPath: home), "me")
        XCTAssertEqual(d.path(home), "/Users/me")
        XCTAssertEqual(d.path(home + "/Music/casey/track.mp3"), "/Users/me/Music/casey/track.mp3")
        XCTAssertEqual(d.name("casey", forPath: home + "/Music/casey"), "casey")
    }

    func testCustomIsSanitizedAndFallsBackToTilde() {
        XCTAssertEqual(display(.custom, custom: "  ").replacementName, "~")
        XCTAssertEqual(display(.custom, custom: "").path(home + "/x"), "~/x")
        XCTAssertEqual(display(.custom, custom: "a/b").replacementName, "ab")
    }

    func testRedactedUsesFixedPlaceholderAndNeutralAccessibilityName() {
        let d = display(.redacted)
        XCTAssertTrue(d.isRedacted)
        XCTAssertEqual(d.name("casey", forPath: home), HomeNameDisplay.redactedPlaceholder)
        XCTAssertEqual(d.path(home + "/Desktop"), "/Users/" + HomeNameDisplay.redactedPlaceholder + "/Desktop")
        XCTAssertEqual(d.accessibilityName("casey", forPath: home), HomeNameDisplay.redactedAccessibilityName)
        XCTAssertFalse(d.path(home + "/Desktop").contains("casey"))
        XCTAssertEqual(d.accessibilityName("Desktop", forPath: home + "/Desktop"), "Desktop")
    }

    func testOtherUsersAreNotAffected() {
        for style in HomeNameStyle.allCases {
            let d = display(style, custom: "me")
            XCTAssertEqual(d.name("robin", forPath: "/Users/robin"), "robin")
            XCTAssertEqual(d.path("/Users/robin/Documents"), "/Users/robin/Documents")
            XCTAssertEqual(d.name("caseyb", forPath: "/Users/caseyb"), "caseyb")
            XCTAssertEqual(d.path("/Users/caseyb/Documents"), "/Users/caseyb/Documents")
            XCTAssertEqual(d.name("Users", forPath: "/Users"), "Users")
            XCTAssertFalse(d.contains("/Users/caseyb"))
        }
    }

    func testVolumeThatContainsTheSameNameIsNotAffected() {
        for style in HomeNameStyle.allCases {
            let d = display(style, custom: "me")
            XCTAssertEqual(d.name("casey", forPath: "/Volumes/casey"), "casey")
            XCTAssertEqual(d.path("/Volumes/casey/Projects"), "/Volumes/casey/Projects")
            XCTAssertEqual(d.path("/Volumes/Backup/Users/casey/Documents"), "/Volumes/Backup/Users/casey/Documents")
            XCTAssertEqual(d.name("casey", forPath: "/Volumes/Backup/Users/casey"), "casey")
            XCTAssertFalse(d.isHome("/Volumes/Backup/Users/casey"))
        }
    }

    func testHomeOnAnotherVolumeKeepsItsParent() {
        let d = HomeNameDisplay(style: .custom, custom: "me", homePath: "/Volumes/Data/Homes/casey/")
        XCTAssertEqual(d.homePath, "/Volumes/Data/Homes/casey")
        XCTAssertEqual(d.path("/Volumes/Data/Homes/casey/x"), "/Volumes/Data/Homes/me/x")
        XCTAssertEqual(d.realName, "casey")
    }

    func testCurrentReadsDefaults() {
        let suite = "HomeNameDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HomeNameDisplay.current(defaults: defaults).style, .real)
        defaults.set("custom", forKey: HomeNameDisplay.styleKey)
        defaults.set("me", forKey: HomeNameDisplay.customKey)
        let d = HomeNameDisplay.current(defaults: defaults)
        XCTAssertEqual(d.style, .custom)
        XCTAssertEqual(d.replacementName, "me")
        XCTAssertEqual(d.homePath, DemoEnvironment.home.standardizedFileURL.path)
        defaults.set("nonsense", forKey: HomeNameDisplay.styleKey)
        XCTAssertEqual(HomeNameDisplay.current(defaults: defaults).style, .real)
    }
}
