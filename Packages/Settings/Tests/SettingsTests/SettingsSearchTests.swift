import XCTest
@testable import Settings

@MainActor
final class SettingsSearchTests: XCTestCase {
    func testEveryGeneralSectionHasSearchableRows() {
        for section in GeneralSection.allCases {
            XCTAssertTrue(SettingsSearchIndex.general.contains { $0.generalSection == section }, section.title)
        }
    }

    func testEntryIDsAreUnique() {
        let ids = SettingsSearchIndex.entries(extraPanes: [("weather", "Weather")]).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testMatchingIsTokenizedAndCaseInsensitive() {
        let hidden = SettingsSearchIndex.entry("hiddenFiles")!
        XCTAssertTrue(hidden.matches("HIDDEN"))
        XCTAssertTrue(hidden.matches("dotfiles listing"))
        XCTAssertFalse(hidden.matches("hidden visor"))
        XCTAssertTrue(hidden.matches("   "))
    }

    func testKeywordsFindRowsAndOtherTabs() {
        let hits = SettingsSearchIndex.entries(extraPanes: [("weather", "Weather")])
        XCTAssertEqual(hits.filter { $0.matches("iterm") }.map(\.id), ["terminal"])
        XCTAssertTrue(hits.filter { $0.matches("checksum") }.contains { $0.paneID == SettingsPaneID.advanced })
        XCTAssertTrue(hits.filter { $0.matches("weather") }.contains { $0.paneID == "weather" })
        XCTAssertTrue(hits.filter { $0.matches("full disk") }.contains { $0.paneID == SettingsPaneID.permissions })
    }

    func testAllPanesShareTheWidestSize() {
        XCTAssertEqual(SettingsWindowController.paneSize(fitting: []), SettingsWindowController.minimumPaneSize)
        let size = SettingsWindowController.paneSize(fitting: [CGSize(width: 600, height: 420), CGSize(width: 900, height: 500), CGSize(width: 700, height: 700)])
        XCTAssertEqual(size, CGSize(width: 900, height: 700))
    }
}
