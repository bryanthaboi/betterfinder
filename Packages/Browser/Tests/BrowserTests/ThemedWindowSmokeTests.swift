import AppKit
import XCTest
import Theming
@testable import Browser

@MainActor
final class ThemedWindowSmokeTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var out: [T] = []
        for v in view.subviews {
            if let t = v as? T { out.append(t) }
            out += descendants(of: v, as: type)
        }
        return out
    }

    func testRetroThemedWindowShowsRowsAndChrome() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-theme-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for i in 0..<7 { FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i).txt").path, contents: Data("x".utf8)) }
        let manager = ThemeManager.shared
        let previous = manager.current.id
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            MainActor.assumeIsolated { manager.select(previous) }
        }
        manager.select("platinum")
        XCTAssertEqual(manager.current.id, "platinum")

        let wc = BrowserWindowController(location: .folder(dir))
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: true)
        wc.showWindow(nil)
        defer { wc.close() }
        let pane = wc.activePane
        wc.setViewMode(.list)
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 8 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        XCTAssertTrue(spin { list.outline.numberOfRows == 8 }, "rows: \(list.outline.numberOfRows)")
        window.displayIfNeeded()
        XCTAssertNotNil(list.outline.rowView(atRow: 0, makeIfNecessary: false), "row 0 not realized")
        XCTAssertTrue(pane.statusBar.text.contains("8 items"), pane.statusBar.text)

        let chrome = try XCTUnwrap(ThemedWindowChrome.chrome(for: window))
        XCTAssertTrue(chrome.isDrawingCustomChrome)
        let titlebar = try XCTUnwrap(chrome.titlebarView)
        XCTAssertFalse(descendants(of: titlebar, as: WindowCaptionButton.self).isEmpty)
        XCTAssertTrue(titlebar.subviews.contains { String(describing: type(of: $0)) == "TitlebarBackgroundView" })

        manager.select("modern")
        XCTAssertFalse(chrome.isDrawingCustomChrome)
        XCTAssertEqual(list.outline.numberOfRows, 8)
        manager.select("platinum")
        XCTAssertTrue(chrome.isDrawingCustomChrome)
        XCTAssertEqual(list.outline.numberOfRows, 8)
        XCTAssertEqual(list.outline.rowHeight, max(16, CGFloat(manager.current.metrics.rowHeight)))
    }

    func testWindowControllerValidatesMenusAndToolbar() throws {
        _ = NSApplication.shared
        let wc = BrowserWindowController(location: .computer)
        defer { wc.close() }
        XCTAssertTrue(wc.responds(to: #selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:))))
        XCTAssertTrue(wc.responds(to: #selector(NSToolbarItemValidation.validateToolbarItem(_:))))
        let back = NSMenuItem(title: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "")
        back.target = wc
        let up = NSMenuItem(title: "Up", action: #selector(BrowserWindowController.goUp(_:)), keyEquivalent: "")
        up.target = wc
        let menu = NSMenu()
        menu.addItem(back)
        menu.addItem(up)
        menu.update()
        XCTAssertFalse(back.isEnabled)
        XCTAssertFalse(up.isEnabled)
    }
}
