import AppKit
import XCTest
import FSCore
import Theming
@testable import Browser

@MainActor
final class BehaviorRegressionVisualTests: XCTestCase {
    private var savedStore: UserDefaults!
    private var suite = ""
    private var previousTheme = ""
    private var previousDensity: Density?

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suite = "bf-r2-visual-\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suite)!
        previousTheme = ThemeManager.shared.current.id
        previousDensity = ThemeManager.shared.density
    }

    override func tearDown() async throws {
        ThemeAccessibility.increaseContrastOverride = nil
        for original in ThemeManager.builtIns where ThemeManager.shared.theme(withID: original.id) != original {
            ThemeManager.shared.applyLive(original)
        }
        ThemeManager.shared.density = previousDensity
        ThemeManager.shared.select(previousTheme)
        BrowserDefaults.store.removePersistentDomain(forName: suite)
        BrowserDefaults.store = savedStore
        try await super.tearDown()
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-r2-visual-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var out: [T] = []
        for v in view.subviews {
            if let t = v as? T { out.append(t) }
            out += descendants(of: v, as: type)
        }
        return out
    }

    private func builtIn(_ id: String) throws -> Theme {
        try XCTUnwrap(ThemeManager.builtIns.first { $0.id == id })
    }

    private func openList() throws -> (BrowserWindowController, BrowserPaneController, ListViewController) {
        let dir = try tempDir()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        wc.setViewMode(.list)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 1 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        return (wc, pane, list)
    }

    private func assertLiveHeader(_ list: ListViewController, pane: BrowserPaneController, height: CGFloat, fontSize: CGFloat, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        pane.view.layoutSubtreeIfNeeded()
        guard let header = list.outline.headerView else { return XCTFail("no header \(message)", file: file, line: line) }
        XCTAssertEqual(header.frame.height, height, message, file: file, line: line)
        XCTAssertEqual(header.superview?.frame.height, height, "clip \(message)", file: file, line: line)
        let visible = list.outline.tableColumns.filter { !$0.isHidden }
        XCTAssertFalse(visible.isEmpty, message, file: file, line: line)
        for col in visible {
            XCTAssertEqual(col.headerCell.font?.pointSize, fontSize, "\(col.identifier.rawValue) \(message)", file: file, line: line)
        }
    }

    func testLiveListHeaderKeepsBuiltInHeightsAtEveryDensity() throws {
        ThemeManager.shared.density = nil
        ThemeManager.shared.select("modern")
        let (wc, pane, list) = try openList()
        defer { wc.close() }
        for theme in ThemeManager.builtIns {
            ThemeManager.shared.select(theme.id)
            for density in Density.allCases {
                ThemeManager.shared.density = density
                let expected = theme.header.height > 0 ? CGFloat(theme.header.height) : Spacing.listHeaderHeight
                let size = theme.header.style == .native ? 11 : theme.headerFont.pointSize
                assertLiveHeader(list, pane: pane, height: expected, fontSize: size, "\(theme.id) \(density)")
            }
        }
    }

    func testLiveListHeaderGrowsForLargeHeaderFontsAtEveryDensity() throws {
        ThemeManager.shared.density = nil
        ThemeManager.shared.select("modern")
        let (wc, pane, list) = try openList()
        defer { wc.close() }
        for id in ["classic-windows", "modern"] {
            let stock = try builtIn(id)
            for size in [24.0, 36.0] {
                var theme = stock
                theme.header.font = Theme.FontSpec(family: "system", size: size)
                ThemeManager.shared.applyLive(theme)
                XCTAssertEqual(ThemeManager.shared.current, theme)
                let font = NSFont.systemFont(ofSize: CGFloat(size))
                let base = minimum(stock)
                let expected = ThemeLayout.fittedHeight(base, font: font, verticalPadding: ThemeLayout.headerTextPadding)
                XCTAssertGreaterThan(expected, base)
                XCTAssertGreaterThanOrEqual(expected, ThemeLayout.lineHeight(font) + ThemeLayout.headerTextPadding)
                for density in Density.allCases {
                    ThemeManager.shared.density = density
                    if stock.header.height > 0 {
                        XCTAssertEqual(theme.layout(density: density).headerHeight, expected, "\(id) \(size) \(density)")
                    }
                    assertLiveHeader(list, pane: pane, height: expected, fontSize: CGFloat(size), "\(id) \(size) \(density)")
                }
            }
            ThemeManager.shared.applyLive(stock)
            ThemeManager.shared.density = nil
            assertLiveHeader(list, pane: pane, height: minimum(stock), fontSize: stock.header.style == .native ? 11 : stock.headerFont.pointSize, "\(id) restored")
        }
    }

    private func minimum(_ theme: Theme) -> CGFloat {
        theme.header.height > 0 ? CGFloat(theme.header.height) : Spacing.listHeaderHeight
    }

    private func render(_ view: NSView) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func close(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.08 && abs(a.greenComponent - b.greenComponent) < 0.08
            && abs(a.blueComponent - b.blueComponent) < 0.08 && abs(a.alphaComponent - b.alphaComponent) < 0.08
    }

    private struct SelectionSample {
        let edge: NSColor?
        let center: NSColor?
        let outline: NSColor
        let fill: NSColor
        let customDrawn: Bool
        let textColor: NSColor?
    }

    private func sampleSelectedSidebarRow(_ wc: BrowserWindowController, contrast: Bool) throws -> SelectionSample {
        ThemeAccessibility.increaseContrastOverride = contrast
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(of: wc.sidebarController.view, as: SidebarOutlineView.self).first)
        let rowIndex = try XCTUnwrap((0..<outline.numberOfRows).first { outline.item(atRow: $0) is EntryBox })
        outline.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        let row = try XCTUnwrap(outline.rowView(atRow: rowIndex, makeIfNecessary: true) as? SidebarRowView)
        row.isSelected = true
        outline.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.isSelected)
        let theme = row.theme
        let sel = row.selectionRect()
        let rep = render(row)
        let x = Int(sel.maxX - 10)
        var outlineColor = NSColor.clear
        var fill = NSColor.clear
        row.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = Theme.color(theme.colors.sidebarSelection).usingColorSpace(.sRGB) ?? .clear
            let text = Theme.color(theme.colors.sidebarSelectionText).usingColorSpace(.sRGB) ?? .clear
            outlineColor = NSColor.contrastRatio(text, fill) >= NSColor.glyphContrastMinimum ? text : ThemeAccessibility.contrastOutlineColor(against: fill)
        }
        let cell = (0..<outline.numberOfColumns).compactMap { outline.view(atColumn: $0, row: rowIndex, makeIfNecessary: false) as? SidebarCellView }.first
        return SelectionSample(
            edge: rep.colorAt(x: x, y: Int(sel.minY)),
            center: rep.colorAt(x: x, y: Int(sel.midY)),
            outline: outlineColor,
            fill: fill,
            customDrawn: row.usesCustomSelection && row.interiorBackgroundStyle == .normal,
            textColor: cell?.textField?.textColor
        )
    }

    func testLiveSidebarSelectionOutlinesOnlyWithIncreaseContrast() throws {
        let dir = try tempDir()
        for id in ["system7", "modern"] {
            ThemeManager.shared.density = nil
            ThemeManager.shared.select(id)
            let theme = ThemeManager.shared.current
            let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
            defer { wc.close() }
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 600), display: false)
            wc.window?.contentView?.layoutSubtreeIfNeeded()

            let off = try sampleSelectedSidebarRow(wc, contrast: false)
            XCTAssertFalse(close(off.edge, off.outline), "\(id) outline without Increase Contrast")
            XCTAssertEqual(off.customDrawn, SidebarViewController.usesCustomSelection(theme), id)
            if off.customDrawn {
                XCTAssertTrue(close(off.edge, off.fill), "\(id) plain edge is fill")
            }

            let on = try sampleSelectedSidebarRow(wc, contrast: true)
            XCTAssertTrue(on.customDrawn, id)
            XCTAssertTrue(close(on.edge, on.outline), "\(id) edge \(String(describing: on.edge)) outline \(on.outline)")
            XCTAssertTrue(close(on.center, on.fill), "\(id) center \(String(describing: on.center)) fill \(on.fill)")
            XCTAssertFalse(close(on.edge, on.center), id)
            if let text = on.textColor {
                XCTAssertGreaterThanOrEqual(NSColor.contrastRatio(text, on.fill), NSColor.textContrastMinimum, id)
            }

            let again = try sampleSelectedSidebarRow(wc, contrast: false)
            XCTAssertFalse(close(again.edge, again.outline), "\(id) outline removed again")
        }
    }
}
