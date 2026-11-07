import XCTest
@testable import Updates

final class SkipVersionTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var prefs: UpdatePreferences!

    override func setUp() {
        (defaults, suite) = makeDefaults()
        prefs = UpdatePreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func release(_ tag: String) -> UpdateRelease {
        UpdateRelease(tag: "v\(tag)", version: SemanticVersion(tag)!, name: tag, notes: "", pageURL: nil, publishedAt: nil, zipAsset: nil, dmgAsset: nil)
    }

    func checker(current: String) -> UpdateChecker {
        UpdateChecker(configuration: UpdateCheckerConfiguration(currentVersion: current), preferences: prefs)
    }

    func testSkippedVersionSuppressedWhenAutomatic() {
        prefs.skippedVersion = SemanticVersion("0.1.5")
        let result = checker(current: "0.1.1").evaluate(release("0.1.5"), userInitiated: false)
        XCTAssertEqual(result, .skipped(release("0.1.5")))
    }

    func testUserInitiatedIgnoresSkip() {
        prefs.skippedVersion = SemanticVersion("0.1.5")
        let result = checker(current: "0.1.1").evaluate(release("0.1.5"), userInitiated: true)
        XCTAssertEqual(result, .updateAvailable(release("0.1.5")))
    }

    func testNewerThanSkippedStillOffered() {
        prefs.skippedVersion = SemanticVersion("0.1.5")
        let result = checker(current: "0.1.1").evaluate(release("0.1.6"), userInitiated: false)
        XCTAssertEqual(result, .updateAvailable(release("0.1.6")))
    }

    func testUpToDateAndDowngradeNeverOffered() {
        XCTAssertEqual(checker(current: "0.1.5").evaluate(release("0.1.5"), userInitiated: true), .upToDate(latest: SemanticVersion("0.1.5")!))
        XCTAssertEqual(checker(current: "0.1.9").evaluate(release("0.1.5"), userInitiated: true), .upToDate(latest: SemanticVersion("0.1.5")!))
    }

    func testClearingSkip() {
        prefs.skippedVersion = SemanticVersion("0.1.5")
        XCTAssertTrue(prefs.isSkipped(SemanticVersion("0.1.5")!))
        XCTAssertTrue(prefs.isSkipped(SemanticVersion("0.1.4")!))
        XCTAssertFalse(prefs.isSkipped(SemanticVersion("0.1.6")!))
        prefs.skippedVersion = nil
        XCTAssertFalse(prefs.isSkipped(SemanticVersion("0.1.5")!))
    }

    func testDailyDueLogic() {
        let now = Date()
        XCTAssertTrue(prefs.isDue(now: now))
        prefs.lastChecked = now.addingTimeInterval(-3600)
        XCTAssertFalse(prefs.isDue(now: now))
        prefs.lastChecked = now.addingTimeInterval(-25 * 3600)
        XCTAssertTrue(prefs.isDue(now: now))
        prefs.automaticallyChecks = false
        XCTAssertFalse(prefs.isDue(now: now))
    }

    func testDefaultsWhenUnset() {
        XCTAssertTrue(prefs.automaticallyChecks)
        XCTAssertTrue(prefs.crashReportsEnabled)
        XCTAssertNil(prefs.lastChecked)
        XCTAssertNil(prefs.skippedVersion)
    }
}
