import XCTest
@testable import Settings

@MainActor
final class BrowsingSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "BrowsingSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testNewSettingsKeepTodaysBehaviorByDefault() {
        let d = freshDefaults()
        SettingsDefaults.register(in: d)
        XCTAssertEqual(d.object(forKey: "openFoldersInTabs") as? Bool, false)
        XCTAssertEqual(d.string(forKey: "terminalAppPath"), "")
        XCTAssertNil(d.string(forKey: "terminalBundleID"))
        XCTAssertEqual(d.string(forKey: "homeFolderNameStyle"), "real")
        XCTAssertEqual(d.string(forKey: "homeFolderNameCustom"), "")
    }

    func testTerminalChoiceStoreAndReset() {
        let d = freshDefaults()
        TerminalChoice.store(path: "/Applications/Ghostty.app", bundleID: "com.mitchellh.ghostty", in: d)
        XCTAssertEqual(d.string(forKey: SettingsKey.terminalAppPath), "/Applications/Ghostty.app")
        XCTAssertEqual(d.string(forKey: SettingsKey.terminalBundleID), "com.mitchellh.ghostty")
        TerminalChoice.store(path: "/Applications/Custom.app", bundleID: nil, in: d)
        XCTAssertEqual(d.string(forKey: SettingsKey.terminalAppPath), "/Applications/Custom.app")
        XCTAssertNil(d.string(forKey: SettingsKey.terminalBundleID))
        TerminalChoice.store(path: TerminalChoice.systemPath, bundleID: TerminalChoice.systemBundleID, in: d)
        XCTAssertEqual(d.string(forKey: SettingsKey.terminalAppPath), "")
        XCTAssertNil(d.string(forKey: SettingsKey.terminalBundleID))
    }

    func testInstalledTerminalsAndDisplayName() {
        let found = TerminalChoice.installed { $0 == "com.googlecode.iterm2" ? URL(fileURLWithPath: "/Applications/iTerm.app") : nil }
        XCTAssertEqual(found.map(\.name), ["iTerm"])
        XCTAssertEqual(found.first?.path, "/Applications/iTerm.app")
        XCTAssertEqual(TerminalChoice.displayName(path: ""), "Terminal")
        XCTAssertEqual(TerminalChoice.displayName(path: "/definitely/not/here.app"), "Terminal")
    }
}
