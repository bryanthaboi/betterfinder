import AppKit
import XCTest
import FSCore
@testable import Browser

@MainActor
final class ColumnWindowSizeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BrowserDefaults.viewMode = .list
        addTeardownBlock { BrowserDefaults.viewMode = .list }
    }

    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-colsize-\(UUID().uuidString)").resolvingSymlinksInPath()
        let fm = FileManager.default
        for name in ["Alpha", "Beta/Inner/Deep/Deeper", "Gamma"] {
            try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for i in 0..<5 { fm.createFile(atPath: dir.appendingPathComponent("file-\(i).txt").path, contents: Data("x".utf8)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSwitchingViewModesKeepsWindowHeight() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 600), display: true)
        window.orderFront(nil)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 8 })
        spin(0.2)
        XCTAssertEqual(window.frame.height, 600, accuracy: 1)

        for mode in [BrowserViewMode.column, .list, .icon, .column] {
            wc.setViewMode(mode)
            window.contentView?.layoutSubtreeIfNeeded()
            spin(0.3)
            XCTAssertEqual(window.frame.height, 600, accuracy: 1, "\(mode)")
            XCTAssertEqual(window.frame.width, 1000, accuracy: 1, "\(mode)")

            var frame = window.frame
            frame.size.height = 650
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            spin(0.2)
            XCTAssertEqual(window.frame.height, 650, accuracy: 1, "resize \(mode)")

            frame = window.frame
            frame.size.height = 600
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            spin(0.2)
            XCTAssertEqual(window.frame.height, 600, accuracy: 1, "restore \(mode)")
        }
        wc.close()
    }

    func testColumnViewFillsWindowHeight() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 600), display: true)
        window.orderFront(nil)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 8 })
        wc.setViewMode(.column)
        window.contentView?.layoutSubtreeIfNeeded()
        spin(0.3)
        let content = try XCTUnwrap(pane.content as? ColumnViewController)
        let host = content.view
        XCTAssertGreaterThan(host.bounds.height, 400)
        XCTAssertEqual(window.frame.height, 600, accuracy: 1)

        let column = try XCTUnwrap(pane.content as? ColumnViewController)
        var current = dir
        for name in ["Beta", "Inner", "Deep", "Deeper"] {
            let next = current.appendingPathComponent(name)
            pane.content.select([next], scroll: true)
            column.moveRight()
            XCTAssertTrue(spin { pane.location.url?.pathKey == next.pathKey })
            current = next
        }
        window.contentView?.layoutSubtreeIfNeeded()
        spin(0.3)
        let hscroll = try XCTUnwrap(host as? NSScrollView)
        hscroll.scrollerStyle = .legacy
        hscroll.autohidesScrollers = false
        hscroll.tile()
        window.contentView?.layoutSubtreeIfNeeded()
        let doc = try XCTUnwrap(hscroll.documentView)
        let clip = hscroll.contentView
        XCTAssertEqual(doc.frame.height, clip.bounds.height, accuracy: 1)
        XCTAssertGreaterThan(doc.frame.width, clip.bounds.width)
        XCTAssertGreaterThan(clip.bounds.height, 400)
        let columnScrolls = doc.subviews.flatMap { $0.subviews.compactMap { $0 as? NSScrollView } }
        XCTAssertGreaterThanOrEqual(columnScrolls.count, 4)
        for s in columnScrolls { XCTAssertEqual(s.frame.height, clip.bounds.height, accuracy: 1) }
        XCTAssertEqual(window.frame.height, 600, accuracy: 1)
        XCTAssertEqual(window.frame.width, 1000, accuracy: 1)
        wc.close()
    }
}
