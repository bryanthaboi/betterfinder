import AppKit
import XCTest
import FSCore
import Theming
@testable import Browser

@MainActor
final class DensityLayoutTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testDensityAndThemeMetricsDriveLiveLayout() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-density-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        let previousTheme = ThemeManager.shared.current.id
        let previousDensity = ThemeManager.shared.density
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            await MainActor.run {
                ThemeManager.shared.density = previousDensity
                ThemeManager.shared.select(previousTheme)
            }
        }
        ThemeManager.shared.density = nil
        ThemeManager.shared.select("modern")
        let wc = BrowserWindowController(location: .folder(dir))
        wc.setViewMode(.list)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 1 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.outline.rowHeight, 28)
        XCTAssertEqual(list.outline.intercellSpacing, NSSize.zero)
        XCTAssertEqual(pane.pathBar.frame.height, 32)
        XCTAssertEqual(pane.statusBar.frame.height, 28)

        ThemeManager.shared.density = .comfortable
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.outline.rowHeight, 32)
        ThemeManager.shared.density = .compact
        XCTAssertEqual(list.outline.rowHeight, 24)

        ThemeManager.shared.density = nil
        ThemeManager.shared.select("platinum")
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.outline.rowHeight, 18)
        XCTAssertEqual(pane.pathBar.frame.height, 24)
        XCTAssertEqual(pane.statusBar.frame.height, 20)
        ThemeManager.shared.density = .regular
        XCTAssertEqual(list.outline.rowHeight, 22)
        wc.close()
    }
}
