import AppKit
import XCTest
@testable import Theming

@MainActor
final class RegressionCellCopyTests: XCTestCase {
    private func uniqueTheme() -> Theme {
        var t = Theme.modernDefault
        t.name = "copy-test-" + UUID().uuidString
        t.colors.accent = "#" + UUID().uuidString
        return t
    }

    func testThemedCellsRetainThemeAcrossCopies() {
        for _ in 0..<300 {
            autoreleasepool {
                let t = uniqueTheme()
                let header = ThemedHeaderCell(textCell: "Name")
                header.themeOverride = t
                let button = ThemedButtonCell(textCell: "B")
                button.themeOverride = t
                let segmented = ThemedSegmentedCell()
                segmented.themeOverride = t
                let copies: [NSCell] = [header.copy() as! NSCell, header.copy() as! NSCell, button.copy() as! NSCell, segmented.copy() as! NSCell]
                XCTAssertEqual((copies[0] as? ThemedHeaderCell)?.themeOverride?.name, t.name)
                XCTAssertEqual((copies[2] as? ThemedButtonCell)?.themeOverride?.name, t.name)
                XCTAssertEqual((copies[3] as? ThemedSegmentedCell)?.themeOverride?.name, t.name)
                (copies[1] as? ThemedHeaderCell)?.themeOverride = uniqueTheme()
                XCTAssertEqual(header.themeOverride?.name, t.name)
            }
        }
    }
}
