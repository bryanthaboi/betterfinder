import XCTest
@testable import Settings

@MainActor
final class SettingsTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        let name = "SettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRegisteredDefaultsUseExistingKeys() {
        let d = freshDefaults()
        SettingsDefaults.register(in: d)
        XCTAssertEqual(d.object(forKey: "calculateFolderSizes") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "foldersFirst") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "showHiddenFiles") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "returnOpens") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "verifyCopies") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "trashViaFinder") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "hasCompletedOnboarding") as? Bool, false)
    }

    func testNewWindowLocationResolution() throws {
        let d = freshDefaults()
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(NewWindowLocation.resolve(defaults: d), home)
        d.set("desktop", forKey: SettingsKey.newWindowLocation)
        XCTAssertEqual(NewWindowLocation.resolve(defaults: d), home.appendingPathComponent("Desktop", isDirectory: true))
        let tmp = FileManager.default.temporaryDirectory
        d.set("custom", forKey: SettingsKey.newWindowLocation)
        d.set(tmp.path, forKey: SettingsKey.newWindowCustomPath)
        XCTAssertEqual(NewWindowLocation.resolve(defaults: d).standardizedFileURL.path, tmp.standardizedFileURL.path)
        d.set("/definitely/not/here", forKey: SettingsKey.newWindowCustomPath)
        XCTAssertEqual(NewWindowLocation.resolve(defaults: d), home)
    }

    func testNoOpSizeIndexController() {
        let c = NoOpSizeIndexController()
        XCTAssertFalse(c.isIndexingPaused)
        c.setIndexingPaused(true)
        XCTAssertTrue(c.isIndexingPaused)
        c.rebuildIndex()
    }

    func testSettingsWindowControllerBuildsAllTabs() {
        let c = SettingsWindowController()
        XCTAssertNotNil(c.window)
        XCTAssertEqual(SettingsWindowController.Tab.allCases.count, 5)
    }
}
