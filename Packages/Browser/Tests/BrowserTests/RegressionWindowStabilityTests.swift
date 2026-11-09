import AppKit
import XCTest
import Theming
@testable import Browser

@MainActor
final class RegressionWindowStabilityTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeFolder(files: Int, folders: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-stab-\(UUID().uuidString)").resolvingSymlinksInPath()
        for i in 0..<folders { try FileManager.default.createDirectory(at: dir.appendingPathComponent(String(format: "dir%02d", i)), withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<files { FileManager.default.createFile(atPath: dir.appendingPathComponent(String(format: "file%02d.txt", i)).path, contents: Data("x".utf8)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func preserveSettings() {
        let manager = ThemeManager.shared
        let theme = manager.current.id
        let sort = BrowserDefaults.sort
        addTeardownBlock {
            MainActor.assumeIsolated {
                BrowserDefaults.sort = sort
                manager.select(theme)
            }
        }
    }

    private func openList(_ dir: URL, size: NSSize = NSSize(width: 900, height: 600)) throws -> (BrowserWindowController, ListViewController) {
        let wc = BrowserWindowController(location: .folder(dir))
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: size), display: true)
        wc.showWindow(nil)
        wc.setViewMode(.list)
        let list = try XCTUnwrap(wc.activePane.content as? ListViewController)
        return (wc, list)
    }

    private func visibleRowCount(_ list: ListViewController) -> Int {
        list.outline.enclosingScrollView?.window?.displayIfNeeded()
        let clip = list.outline.enclosingScrollView!.contentView.bounds
        return list.outline.rows(in: clip).length
    }

    func testReversingNameSortKeepsRowsVisible() throws {
        preserveSettings()
        BrowserDefaults.sort = SortSpec(key: .name, ascending: true, foldersFirst: false)
        for (files, folders) in [(6, 3), (60, 5)] {
            let dir = try makeFolder(files: files, folders: folders)
            let (wc, list) = try openList(dir)
            defer { wc.close() }
            let total = files + folders
            XCTAssertTrue(spin { list.outline.numberOfRows == total })
            for ascending in [false, true, false] {
                list.outline.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: ascending)]
                let expectedFirst = ascending ? wc.activePane.model.items.map(\.name).min() : wc.activePane.model.items.map(\.name).max()
                XCTAssertTrue(spin { wc.activePane.model.items.first?.name == expectedFirst }, "order not applied for ascending=\(ascending)")
                pump()
                XCTAssertEqual(list.outline.numberOfRows, total)
                XCTAssertGreaterThan(visibleRowCount(list), 0, "no visible rows after sort ascending=\(ascending) total=\(total)")
                let clip = list.outline.enclosingScrollView!.contentView.bounds
                XCTAssertLessThanOrEqual(clip.minY, max(0, list.outline.frame.maxY - clip.height) + 1, "scrolled past content")
            }
        }
    }

    func testOverflowMenuFormsDoNotCrash() throws {
        let dir = try makeFolder(files: 3, folders: 1)
        let (wc, _) = try openList(dir)
        defer { wc.close() }
        let toolbar = try XCTUnwrap(wc.window?.toolbar)
        for id in [NSToolbarItem.Identifier("nav"), NSToolbarItem.Identifier("viewMode")] {
            let item = try XCTUnwrap(wc.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false))
            let form = try XCTUnwrap(item.menuFormRepresentation, "\(id.rawValue) has no overflow menu form")
            for entry in form.submenu?.items ?? [] {
                guard let action = entry.action else { continue }
                NSApp.sendAction(action, to: entry.target, from: entry)
            }
            if let action = item.view.flatMap({ ($0 as? NSControl)?.action }) {
                NSApp.sendAction(action, to: wc, from: NSMenuItem())
            }
        }
        XCTAssertEqual(wc.activePane.viewMode, .icon)
    }

    func testClassicWindowsListShowsSortHeader() throws {
        preserveSettings()
        let dir = try makeFolder(files: 4, folders: 1)
        ThemeManager.shared.select("modern")
        let (wc, list) = try openList(dir)
        defer { wc.close() }
        XCTAssertTrue(spin { list.outline.numberOfRows == 5 })
        for id in ["classic-windows", "modern", "classic-windows"] {
            ThemeManager.shared.select(id)
            pump()
            list.view.window?.displayIfNeeded()
            let header = try XCTUnwrap(list.outline.headerView, "\(id): no header view")
            XCTAssertGreaterThan(header.frame.height, 0, "\(id): zero-height header")
            XCTAssertNotNil(header.window, "\(id): header not in window")
            XCTAssertFalse(header.isHiddenOrHasHiddenAncestor, "\(id): header hidden")
            XCTAssertGreaterThan(header.visibleRect.height, 0, "\(id): header clipped away")
            XCTAssertTrue(header.superview is NSClipView, "\(id): header superview \(String(describing: header.superview))")
            let nameRect = header.headerRect(ofColumn: list.outline.column(withIdentifier: NSUserInterfaceItemIdentifier(SortKey.name.rawValue)))
            if id == "classic-windows" { XCTAssertGreaterThan(darkPixelCount(in: header, rect: nameRect), 8, "\(id): name column title not drawn") }
        }
    }

    private func darkPixelCount(in view: NSView, rect: NSRect) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / view.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        let r = rect.intersection(view.bounds).insetBy(dx: 2, dy: 2)
        guard !r.isEmpty else { return 0 }
        var count = 0
        for y in Int(r.minY * sy)..<Int(r.maxY * sy) {
            for x in Int(r.minX * sx)..<Int(r.maxX * sx) {
                guard let c = rep.colorAt(x: x, y: view.isFlipped ? y : rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent < 0.6 { count += 1 }
            }
        }
        return count
    }

    func testThemeCyclingResizeAndDualPaneStayStable() throws {
        preserveSettings()
        let dir = try makeFolder(files: 30, folders: 4)
        let (wc, list) = try openList(dir)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(spin { list.outline.numberOfRows == 34 })
        let ids = ThemeManager.shared.available.map(\.id)
        XCTAssertGreaterThan(ids.count, 3)
        let sizes = [NSSize(width: 900, height: 600), NSSize(width: 420, height: 140), NSSize(width: 711, height: 129), NSSize(width: 300, height: 100), NSSize(width: 1200, height: 800)]
        for round in 0..<2 {
            for (i, id) in ids.enumerated() {
                ThemeManager.shared.select(id)
                window.setContentSize(sizes[(i + round) % sizes.count])
                window.displayIfNeeded()
                pump(0.05)
                if i % 3 == 0 { wc.toggleDualPane(nil); pump(0.05); window.displayIfNeeded() }
            }
        }
        pump(0.5)
        window.displayIfNeeded()
    }

    func testCustomChromeCentersToolbarBelowTitleStrip() throws {
        preserveSettings()
        let dir = try makeFolder(files: 3, folders: 1)
        ThemeManager.shared.select("classic-windows")
        let (wc, _) = try openList(dir)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        for id in ["classic-windows", "luna", "modern", "classic-windows"] {
            ThemeManager.shared.select(id)
            pump(1.3)
            window.displayIfNeeded()
            let chrome = try XCTUnwrap(ThemedWindowChrome.chrome(for: window))
            let tv = try XCTUnwrap(chrome.titlebarView)
            let bar = try XCTUnwrap(tv.subviews.first { String(describing: type(of: $0)).contains("NSToolbarView") })
            var platters: [NSRect] = []
            func visit(_ v: NSView, _ depth: Int) {
                for c in v.subviews {
                    if String(describing: type(of: c)) == "NSToolbarPlatterView" { platters.append(c.convert(c.bounds, to: tv)) }
                    if depth < 3 { visit(c, depth + 1) }
                }
            }
            visit(bar, 0)
            guard let top = platters.map({ tv.bounds.height - $0.maxY }).min(), let bottom = platters.map(\.minY).min() else { continue }
            let strip = chrome.isDrawingCustomChrome ? chrome.titleStripHeight : 0
            let above = top - strip
            XCTAssertGreaterThanOrEqual(above, 8, "\(id): no padding above toolbar buttons")
            XCTAssertEqual(above, bottom, accuracy: 1, "\(id): toolbar buttons not centered (above \(above), below \(bottom))")
            if chrome.isDrawingCustomChrome, let up = platters.first {
                let center = NSPoint(x: up.midX, y: up.midY)
                let hit = tv.hitTest(tv.superview.map { tv.convert(center, to: $0) } ?? center)
                XCTAssertTrue(hit.map { $0.isDescendant(of: bar) } ?? false, "\(id): toolbar button not clickable at its drawn position")
            }
        }
    }
}
