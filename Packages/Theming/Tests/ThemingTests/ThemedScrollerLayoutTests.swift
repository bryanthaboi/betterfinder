import AppKit
import XCTest
@testable import Theming

@MainActor
final class ThemedScrollerLayoutTests: XCTestCase {
    func testKnobRectMatchesThemedLayout() throws {
        _ = NSApplication.shared
        let mgr = ThemeManager(userThemesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let theme = try XCTUnwrap(mgr.theme(withID: "classic-windows"))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        sv.hasVerticalScroller = true
        sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 3000))
        ThemedScroller.apply(theme, to: sv)
        let scroller = try XCTUnwrap(sv.verticalScroller as? ThemedScroller)
        scroller.doubleValue = 0.5
        let knob = try XCTUnwrap(scroller.currentLayout.knob)
        XCTAssertEqual(scroller.rect(for: .knob), knob)
        XCTAssertEqual(scroller.rect(for: .knob).width, scroller.bounds.width)
    }
}
