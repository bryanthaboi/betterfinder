import AppKit
import XCTest
import FSCore
import Theming
@testable import Browser

@MainActor
final class RegressionContentTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-r1-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func builtIn(_ id: String) throws -> Theme {
        try XCTUnwrap(ThemeManager.builtIns.first { $0.id == id })
    }

    private func selectTheme(_ id: String) {
        let manager = ThemeManager.shared
        let previous = manager.current.id
        let previousDensity = manager.density
        addTeardownBlock {
            await MainActor.run {
                manager.density = previousDensity
                manager.select(previous)
            }
        }
        manager.select(id)
    }

    private static func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? c
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func makeSelectedCell(rowSelected: Bool, emphasized: Bool, normal: NSColor) -> (ThemedRowView, FileCellView) {
        let row = ThemedRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        let cell = FileCellView(identifier: .init("name"), showsIcon: false)
        cell.frame = row.bounds
        row.addSubview(cell)
        cell.normalTextColor = normal
        row.isEmphasized = emphasized
        row.isSelected = rowSelected
        return (row, cell)
    }

    func testInactiveSelectionTextStaysReadableInRetroAndHighContrast() throws {
        _ = NSApplication.shared
        for id in ["system7", "high-contrast"] {
            selectTheme(id)
            let theme = ThemeManager.shared.current
            XCTAssertEqual(theme.id, id)
            for emphasized in [true, false] {
                let (_, cell) = makeSelectedCell(rowSelected: true, emphasized: emphasized, normal: theme.textColor)
                let text = try XCTUnwrap(cell.textField?.textColor)
                let background = ListRenderer.selectionColor(theme, emphasized: emphasized)
                XCTAssertEqual(text, ListRenderer.selectionTextColor(theme, emphasized: emphasized), "\(id) emphasized=\(emphasized)")
                XCTAssertGreaterThanOrEqual(Self.contrast(text, background), 4.5, "\(id) emphasized=\(emphasized)")
            }
            let (row, cell) = makeSelectedCell(rowSelected: true, emphasized: true, normal: theme.textColor)
            row.isEmphasized = false
            XCTAssertEqual(cell.textField?.textColor, ListRenderer.selectionTextColor(theme, emphasized: false))
            row.isSelected = false
            XCTAssertEqual(cell.textField?.textColor, theme.textColor)
        }
    }

    func testTagCellsRecolorWhenRowSelectionChanges() throws {
        _ = NSApplication.shared
        selectTheme("system7")
        let theme = ThemeManager.shared.current
        let (row, cell) = makeSelectedCell(rowSelected: false, emphasized: false, normal: theme.secondaryTextColor)
        cell.attributedText = { color in TagColors.attributed(["Work"], font: theme.listFont, textColor: color) }
        cell.refreshTextColor()
        func tagColor() -> NSColor? {
            let s = cell.textField?.attributedStringValue ?? NSAttributedString()
            return s.attribute(.foregroundColor, at: s.length - 1, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(tagColor(), theme.secondaryTextColor)
        row.isSelected = true
        XCTAssertEqual(tagColor(), ListRenderer.selectionTextColor(theme, emphasized: false))
    }

    func testListRowsInInactiveWindowUseInactiveSelectionText() throws {
        _ = NSApplication.shared
        selectTheme("system7")
        let dir = try tempDir("inactive")
        for n in ["a.txt", "b.txt"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        wc.setViewMode(.list)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 2 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        pane.view.layoutSubtreeIfNeeded()
        list.outline.selectRowIndexes([0], byExtendingSelection: false)
        list.outline.layoutSubtreeIfNeeded()
        let rowView = try XCTUnwrap(list.outline.rowView(atRow: 0, makeIfNecessary: true))
        let cell = try XCTUnwrap(list.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileCellView)
        let theme = ThemeManager.shared.current
        XCTAssertTrue(rowView.isSelected)
        let expected = ListRenderer.selectionTextColor(theme, emphasized: rowView.isEmphasized)
        XCTAssertEqual(cell.textField?.textColor, expected)
        XCTAssertGreaterThanOrEqual(Self.contrast(expected, ListRenderer.selectionColor(theme, emphasized: rowView.isEmphasized)), 4.5)
    }

    func testColumnPreviewScrollsInShortWindowAndStaysSquareInTallOne() {
        _ = NSApplication.shared
        let preview = PreviewColumnView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let item = FileItem(url: URL(fileURLWithPath: "/tmp/example.txt"), name: "example.txt", isDirectory: false, logicalSize: 10,
                            dateModified: Date(), dateCreated: Date(), dateAdded: Date(), contentTypeIdentifier: "public.plain-text", tagNames: ["Red", "Blue"])
        preview.show(item, sizes: nil)
        preview.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(preview.previewFrame.height, PreviewColumnView.minimumPreviewHeight - 0.5)
        XCTAssertGreaterThan(preview.contentHeight, preview.scroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(preview.infoFrameInContent.maxY, preview.contentHeight)

        preview.setFrameSize(NSSize(width: 300, height: 900))
        preview.layoutSubtreeIfNeeded()
        XCTAssertEqual(preview.previewFrame.height, preview.previewFrame.width, accuracy: 0.5)
        XCTAssertLessThanOrEqual(preview.contentHeight, preview.scroll.contentView.bounds.height + 0.5)
    }

    func testIconLabelsUseIconLabelTokens() throws {
        _ = NSApplication.shared
        let aqua = try builtIn("aqua")
        let item = IconItem()
        item.loadView()
        item.view.frame = NSRect(x: 0, y: 0, width: 112, height: 120)
        item.textField?.stringValue = "Report.pdf"
        item.applyTheme(aqua)
        item.isSelected = true
        item.view.layoutSubtreeIfNeeded()
        item.layoutLabelBackground()
        XCTAssertEqual(item.labelShape, .pill)
        XCTAssertGreaterThan(item.labelBackground.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(item.textField?.font, aqua.iconLabelFont)
        XCTAssertLessThan(item.labelBackgroundFrame.width, item.textField?.frame.width ?? 0)

        let platinum = try builtIn("platinum")
        item.applyTheme(platinum)
        XCTAssertEqual(item.labelBackground.layer?.cornerRadius, 0)
        let bg = try XCTUnwrap(item.labelBackground.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        XCTAssertLessThan(Self.luminance(bg), 0.01)
        XCTAssertEqual(item.textField?.textColor, Theme.color(platinum.iconLabels.selectionText))

        let hc = try builtIn("high-contrast")
        item.applyTheme(hc)
        XCTAssertEqual(item.textField?.maximumNumberOfLines, hc.iconLabels.maxLines)
        XCTAssertEqual(item.textField?.font, hc.iconLabelFont)
        item.isSelected = false
        XCTAssertEqual(item.textField?.textColor, Theme.color(hc.iconLabels.text))
    }

    func testIconGridReservesRoomForLabelLines() throws {
        _ = NSApplication.shared
        selectTheme("high-contrast")
        let theme = ThemeManager.shared.current
        let dir = try tempDir("icons")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        wc.setViewMode(.icon)
        let icons = try XCTUnwrap(wc.activePane.content as? IconViewController)
        _ = icons.view
        let s = icons.iconSize
        let line = ThemeLayout.lineHeight(theme.iconLabelFont)
        XCTAssertGreaterThanOrEqual(icons.itemSize.height, s + Spacing.xs * 3 + line * CGFloat(theme.iconLabels.maxLines))
    }

    func testIncreaseContrastOutlinesIconHighlights() throws {
        _ = NSApplication.shared
        let modern = try builtIn("modern")
        let item = IconItem()
        item.loadView()
        addTeardownBlock { await MainActor.run { IconItem.increaseContrastOverride = nil } }
        IconItem.increaseContrastOverride = false
        item.applyTheme(modern)
        item.isSelected = true
        XCTAssertEqual(item.highlight.layer?.borderWidth, 0)
        IconItem.increaseContrastOverride = true
        item.applyTheme(modern)
        XCTAssertEqual(item.highlight.layer?.borderWidth, 2)
        XCTAssertNotNil(item.highlight.layer?.borderColor)
        item.isSelected = false
        XCTAssertEqual(item.highlight.layer?.borderWidth, 0)
        item.isDropTarget = true
        XCTAssertEqual(item.highlight.layer?.borderWidth, 2)
    }

    func testRowsGrowForLargeFontsButBuiltInsKeepTheirHeights() throws {
        for theme in ThemeManager.builtIns {
            XCTAssertEqual(ListViewController.fittedRowHeight(theme), max(16, theme.layout(density: nil).rowHeight), theme.id)
        }
        var big = try builtIn("classic-windows")
        big.fonts.list = Theme.FontSpec(family: "system", size: 36)
        let fitted = ListViewController.fittedRowHeight(big)
        XCTAssertGreaterThanOrEqual(fitted, ThemeLayout.lineHeight(big.listFont))
        XCTAssertGreaterThan(fitted, CGFloat(big.metrics.rowHeight))
        var mid = try builtIn("modern")
        mid.fonts.list = Theme.FontSpec(family: "system", size: 24)
        XCTAssertGreaterThanOrEqual(ListViewController.fittedRowHeight(mid), ThemeLayout.lineHeight(mid.listFont))
    }

    func testContributedColumnCellExposesAccessibilityValue() throws {
        _ = NSApplication.shared
        let regs = BrowserRegistries()
        let dir = try tempDir("axcol")
        for n in ["a.txt", "bbbb.txt"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        BrowserDefaults.viewMode = .list
        let wc = BrowserWindowController(location: .folder(dir), registries: regs)
        defer { wc.close() }
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let pane = wc.activePane
        let list = try XCTUnwrap(pane.content as? ListViewController)
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 2 })
        let token = regs.columns.register(ColumnSpec(id: "len", title: "Length", width: 80, provider: NameLengthColumnProvider()), owner: "axtester")
        defer { token.cancel() }
        let qid = "axtester/len"
        let item = try XCTUnwrap(pane.model.items.first { $0.name == "bbbb.txt" })
        XCTAssertTrue(spin { list.columnStore.cachedValue(column: qid, for: item) != nil })
        let value = try XCTUnwrap(list.columnStore.cachedValue(column: qid, for: item))
        list.outline.reloadData()
        list.outline.layoutSubtreeIfNeeded()
        let col = list.outline.column(withIdentifier: .init(ColumnRegistry.tableIdentifier(for: qid)))
        XCTAssertGreaterThanOrEqual(col, 0)
        let row = (0..<list.outline.numberOfRows).first { (list.outline.item(atRow: $0) as? FileNode)?.item.name == "bbbb.txt" }
        let cell = try XCTUnwrap(list.outline.view(atColumn: col, row: try XCTUnwrap(row), makeIfNecessary: true) as? FileCellView)
        XCTAssertEqual(cell.textField?.accessibilityValue() as? String, value.accessibilityDescription ?? value.displayText)
    }

    private func imageItem(_ url: URL, modified: Date = Date(timeIntervalSinceReferenceDate: 1000), size: Int64 = 10) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: false, logicalSize: size, dateModified: modified, contentTypeIdentifier: "public.png")
    }

    func testDimensionsFailureIsRetriedAndNeverStuckPending() throws {
        let attempts = AttemptCounter()
        let cache = DimensionsCache(limit: 10, failureLimit: 10, failureTTL: 0, reader: { _ in
            attempts.next() == 1 ? nil : CGSize(width: 4, height: 3)
        })
        var updates = 0
        cache.addListener(self) { _ in updates += 1 }
        let it = imageItem(URL(fileURLWithPath: "/tmp/bf-dim-\(UUID().uuidString).png"))
        XCTAssertNil(cache.dimensions(for: it))
        XCTAssertTrue(cache.isPending(it))
        XCTAssertTrue(spin { updates == 1 })
        XCTAssertFalse(cache.isPending(it))
        XCTAssertEqual(cache.inFlightCount, 0)
        XCTAssertNil(cache.dimensions(for: it))
        XCTAssertTrue(spin { updates == 2 })
        XCTAssertEqual(cache.dimensions(for: it), CGSize(width: 4, height: 3))
        XCTAssertEqual(cache.inFlightCount, 0)
    }

    func testDimensionsNegativeResultsExpireAndStayBounded() throws {
        let cache = DimensionsCache(limit: 10, failureLimit: 4, failureTTL: 60, reader: { _ in nil })
        var updates = 0
        cache.addListener(self) { _ in updates += 1 }
        let it = imageItem(URL(fileURLWithPath: "/tmp/bf-neg-\(UUID().uuidString).png"))
        _ = cache.dimensions(for: it)
        XCTAssertTrue(spin { updates == 1 })
        _ = cache.dimensions(for: it)
        XCTAssertFalse(cache.isPending(it))
        XCTAssertEqual(cache.inFlightCount, 0)
        for i in 0..<20 { _ = cache.dimensions(for: imageItem(URL(fileURLWithPath: "/tmp/bf-neg-\(i).png"))) }
        XCTAssertTrue(spin { updates == 21 })
        XCTAssertLessThanOrEqual(cache.failureCount, 4)
    }

    func testReplacedImageAtSamePathIsReread() throws {
        let sizes = SizeBox()
        sizes.value = CGSize(width: 10, height: 10)
        let cache = DimensionsCache(limit: 10, reader: { _ in sizes.value })
        var updates = 0
        cache.addListener(self) { _ in updates += 1 }
        let url = URL(fileURLWithPath: "/tmp/bf-rep-\(UUID().uuidString).png")
        let first = imageItem(url, modified: Date(timeIntervalSinceReferenceDate: 1))
        _ = cache.dimensions(for: first)
        XCTAssertTrue(spin { updates == 1 })
        XCTAssertEqual(cache.dimensions(for: first), CGSize(width: 10, height: 10))
        sizes.value = CGSize(width: 20, height: 30)
        let replaced = imageItem(url, modified: Date(timeIntervalSinceReferenceDate: 2))
        XCTAssertNil(cache.dimensions(for: replaced))
        XCTAssertTrue(spin { updates == 2 })
        XCTAssertEqual(cache.dimensions(for: replaced), CGSize(width: 20, height: 30))
    }

    func testDimensionsCacheStaysBoundedAcrossManyFolders() throws {
        let cache = DimensionsCache(limit: 50, reader: { _ in CGSize(width: 1, height: 1) })
        var updates = 0
        cache.addListener(self) { _ in updates += 1 }
        for folder in 0..<20 {
            for i in 0..<25 { _ = cache.dimensions(for: imageItem(URL(fileURLWithPath: "/tmp/f\(folder)/img\(i).png"))) }
        }
        XCTAssertTrue(spin { updates == 500 })
        XCTAssertLessThanOrEqual(cache.count, 50)
        XCTAssertEqual(cache.inFlightCount, 0)
        cache.purge()
        XCTAssertEqual(cache.count, 0)
    }

    private func runWalk(_ dir: URL, query: String, configure: (MetadataSearch) -> Void) -> (paths: [String], completeness: MetadataSearch.Completeness?) {
        let search = MetadataSearch(kind: .name(query, scope: dir))
        search.forcesWalk = true
        configure(search)
        var paths: [String] = []
        var result: MetadataSearch.Completeness?
        search.onPaths = { paths += $0 }
        search.onFinish = { result = $0 }
        search.start()
        _ = spin { result != nil }
        search.stop()
        return (paths, result)
    }

    func testWalkSearchReportsResultCap() throws {
        let dir = try tempDir("cap")
        for i in 0..<8 { FileManager.default.createFile(atPath: dir.appendingPathComponent("match-\(i).txt").path, contents: Data()) }
        let capped = runWalk(dir, query: "match") { $0.resultLimit = 3 }
        let c = try XCTUnwrap(capped.completeness)
        XCTAssertEqual(capped.paths.count, 3)
        XCTAssertTrue(c.hitResultLimit)
        XCTAssertEqual(c.notice(resultLimit: 3), "Showing the first 3 matches — narrow your search")

        let full = runWalk(dir, query: "match") { $0.resultLimit = 100 }
        XCTAssertEqual(full.paths.count, 8)
        XCTAssertEqual(full.completeness?.isComplete, true)
        XCTAssertNil(full.completeness?.notice(resultLimit: 100))
    }

    func testWalkSearchReportsDeniedFoldersAndVisitLimit() throws {
        let dir = try tempDir("denied")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("match-inside.txt").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("match-outside.txt").path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let r = runWalk(dir, query: "match") { _ in }
        let c = try XCTUnwrap(r.completeness)
        XCTAssertEqual(r.paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["match-outside.txt"])
        XCTAssertEqual(c.skippedDirectories, 1)
        XCTAssertFalse(c.isComplete)
        XCTAssertEqual(c.notice(resultLimit: 5000), "Partial results — 1 folder couldn’t be searched")

        let many = try tempDir("visits")
        for i in 0..<6 { FileManager.default.createFile(atPath: many.appendingPathComponent("x-\(i).txt").path, contents: Data()) }
        let v = runWalk(many, query: "x") { $0.visitLimit = 2 }
        XCTAssertEqual(v.completeness?.hitVisitLimit, true)
        XCTAssertNotNil(v.completeness?.notice(resultLimit: 5000))
    }

    func testFolderModelPublishesSearchNotice() throws {
        let dir = try tempDir("model")
        for i in 0..<5 { FileManager.default.createFile(atPath: dir.appendingPathComponent("hit-\(i).txt").path, contents: Data()) }
        let previous = FolderModel.makeSearch
        addTeardownBlock { await MainActor.run { FolderModel.makeSearch = previous } }
        FolderModel.makeSearch = { kind in
            let s = MetadataSearch(kind: kind)
            s.forcesWalk = true
            s.resultLimit = 2
            return s
        }
        let model = FolderModel(location: .search(scope: dir, query: "hit"))
        var loadingChanges = 0
        model.onLoadingChange = { loadingChanges += 1 }
        model.start()
        XCTAssertTrue(spin { !model.isLoading && loadingChanges >= 2 })
        XCTAssertEqual(model.searchNotice, "Showing the first 2 matches — narrow your search")

        FolderModel.makeSearch = { kind in
            let s = MetadataSearch(kind: kind)
            s.forcesWalk = true
            return s
        }
        model.load()
        XCTAssertNil(model.searchNotice)
        XCTAssertTrue(spin { !model.isLoading })
        XCTAssertNil(model.searchNotice)
        model.stop()
    }
}

private struct NameLengthColumnProvider: ColumnProvider {
    func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue] {
        var out: [URL: ColumnValue] = [:]
        for i in items { out[i.url] = .number(Double(i.name.count)) }
        return out
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}

private final class SizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = CGSize.zero
    var value: CGSize {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
