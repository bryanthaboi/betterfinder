import AppKit
import SwiftUI
import XCTest
import FSCore
import Theming
@testable import Browser

@MainActor
final class RegressionChromeTests: XCTestCase {
    private var savedStore: UserDefaults!
    private var suite = ""
    private var previousTheme = ""
    private var previousDensity: Density?
    private var previousPost: ((String, NSView) -> Void)!
    private var previousDelay: TimeInterval = 0
    private var previousInfoAnnounce: ((String) -> Void)!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suite = "bf-chrome-tests-\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suite)!
        previousTheme = ThemeManager.shared.current.id
        previousDensity = ThemeManager.shared.density
        previousPost = StatusAnnouncements.post
        previousDelay = SizeSummaryDriver.announcementDelay
        previousInfoAnnounce = InfoModel.announce
        InlineWarning.resetLastMessage()
    }

    override func tearDown() async throws {
        InlineWarning.dismiss()
        BrowserDefaults.store.removePersistentDomain(forName: suite)
        BrowserDefaults.store = savedStore
        StatusAnnouncements.post = previousPost
        SizeSummaryDriver.announcementDelay = previousDelay
        InfoModel.announce = previousInfoAnnounce
        ThemeManager.shared.density = previousDensity
        ThemeManager.shared.select(previousTheme)
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-chrome-\(UUID().uuidString)").resolvingSymlinksInPath()
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

    private func color(_ c: NSColor?) -> String { c?.usingColorSpace(.sRGB)?.hexString ?? "nil" }

    private final class MeasureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        private(set) var calls = 0
        func begin() { lock.lock(); calls += 1; active += 1; peak = max(peak, active); lock.unlock() }
        func end() { lock.lock(); active -= 1; lock.unlock() }
    }

    private func fakeMeasure(_ log: MeasureLog, result: @escaping @Sendable (URL) -> SizeResult) -> SizeSummaryDriver.Measure {
        { url in
            AsyncStream { cont in
                Task {
                    log.begin()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    cont.yield(result(url))
                    log.end()
                    cont.finish()
                }
            }
        }
    }

    private func run(_ driver: SizeSummaryDriver, dir: URL, selection: [FileItem], output: StatusBarSegmentOutput, sizesEnabled: Bool = false) {
        let model = FolderModel(location: .folder(dir))
        let sizes = SizeCoordinator()
        sizes.enabled = sizesEnabled
        driver.update(StatusBarContext(location: .folder(dir), providedLocation: nil, model: model, selection: selection, sizes: sizes), output: output)
    }

    func testMultiSelectionMeasuresEveryFolderWithBoundedConcurrency() throws {
        let dir = try tempDir()
        var items: [FileItem] = []
        for i in 0..<250 {
            let u = dir.appendingPathComponent("d\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
            items.append(try XCTUnwrap(DirectoryLister.item(for: u)))
        }
        let log = MeasureLog()
        let driver = SizeSummaryDriver()
        driver.measure = fakeMeasure(log) { _ in SizeResult(allocatedBytes: 4096, logicalBytes: 10, itemCount: 1, isComplete: true) }
        let output = StatusBarSegmentOutput()
        run(driver, dir: dir, selection: items, output: output)
        XCTAssertTrue(output.isBusy)
        XCTAssertTrue(output.text.contains("0 of 250 folders measured"), output.text)
        XCTAssertTrue(spin { !output.isBusy }, output.text)
        XCTAssertEqual(log.calls, 250)
        XCTAssertLessThanOrEqual(log.peak, SizeSummaryDriver.maxConcurrentFolders)
        XCTAssertEqual(output.text, "250 selected — \(SizeFormatter.string(250 * 4096)) on disk (250 folders)")
    }

    func testMixedSelectionUsesOneUnitAndLabelsIt() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("a.txt")
        try Data(repeating: 1, count: 10).write(to: file)
        let folder = dir.appendingPathComponent("F", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fileItem = try XCTUnwrap(DirectoryLister.item(for: file))
        let folderItem = try XCTUnwrap(DirectoryLister.item(for: folder))
        let allocated = try XCTUnwrap(fileItem.allocatedSize)
        XCTAssertNotEqual(allocated, 10)

        let log = MeasureLog()
        let driver = SizeSummaryDriver()
        driver.measure = fakeMeasure(log) { _ in SizeResult(allocatedBytes: 8192, logicalBytes: 100, itemCount: 2, isComplete: true) }
        let output = StatusBarSegmentOutput()
        BrowserDefaults.statusAlternateSize = false
        run(driver, dir: dir, selection: [fileItem, folderItem], output: output)
        XCTAssertTrue(spin { !output.isBusy })
        XCTAssertEqual(output.text, "2 selected — \(SizeFormatter.string(allocated + 8192)) on disk (1 file, 1 folder)")

        BrowserDefaults.statusAlternateSize = true
        run(driver, dir: dir, selection: [fileItem, folderItem], output: output)
        XCTAssertTrue(spin { !output.isBusy && output.text.contains("logical") }, output.text)
        XCTAssertEqual(output.text, "2 selected — \(SizeFormatter.string(110)) logical (1 file, 1 folder)")
    }

    func testPartialFolderMarksAggregateAsAtLeast() throws {
        let dir = try tempDir()
        var items: [FileItem] = []
        for name in ["ok", "denied"] {
            let u = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
            items.append(try XCTUnwrap(DirectoryLister.item(for: u)))
        }
        let driver = SizeSummaryDriver()
        driver.measure = fakeMeasure(MeasureLog()) { url in
            var r = SizeResult(allocatedBytes: 4096, logicalBytes: 1, itemCount: 1, isComplete: url.lastPathComponent == "ok")
            r.isPartial = url.lastPathComponent != "ok"
            return r
        }
        let output = StatusBarSegmentOutput()
        run(driver, dir: dir, selection: items, output: output)
        XCTAssertTrue(spin { !output.isBusy })
        XCTAssertTrue(output.text.contains("at least \(SizeFormatter.string(8192)) on disk"), output.text)
        XCTAssertTrue(output.text.contains("some items unreadable"), output.text)
    }

    func testSizeCompletionAnnouncesOnceAfterVisibleCalculation() throws {
        let dir = try tempDir()
        let folder = dir.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let item = try XCTUnwrap(DirectoryLister.item(for: folder))
        var announced: [String] = []
        StatusAnnouncements.post = { message, _ in announced.append(message) }
        SizeSummaryDriver.announcementDelay = 0
        let driver = SizeSummaryDriver()
        driver.measure = { _ in
            AsyncStream { cont in
                cont.yield(SizeResult(allocatedBytes: 4096, logicalBytes: 1, itemCount: 1, isComplete: false))
                cont.yield(SizeResult(allocatedBytes: 8192, logicalBytes: 2, itemCount: 2, isComplete: true))
                cont.finish()
            }
        }
        let view = StatusSegmentView(accessibilityLabel: "Status", help: nil)
        let output = StatusBarSegmentOutput()
        output.onChange = { view.apply(output) }
        run(driver, dir: dir, selection: [item], output: output)
        XCTAssertTrue(spin { !output.isBusy })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(announced, ["Projects, \(SizeFormatter.string(8192)) on disk, calculation complete"])
        XCTAssertNil(output.announcement)

        let quiet = SizeSummaryDriver()
        quiet.measure = driver.measure
        SizeSummaryDriver.announcementDelay = 60
        let output2 = StatusBarSegmentOutput()
        output2.onChange = { view.apply(output2) }
        run(quiet, dir: dir, selection: [item], output: output2)
        XCTAssertTrue(spin { !output2.isBusy })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(announced.count, 1)
    }

    func testSearchNoticeIsShownInStatus() throws {
        let dir = try tempDir()
        let model = FolderModel(location: .search(scope: dir, query: "x"))
        model.searchNotice = "First 5,000 results — narrow your search"
        let driver = SizeSummaryDriver()
        let output = StatusBarSegmentOutput()
        driver.update(StatusBarContext(location: .search(scope: dir, query: "x"), providedLocation: nil, model: model, selection: [], sizes: SizeCoordinator()), output: output)
        XCTAssertTrue(output.text.hasSuffix("· First 5,000 results — narrow your search"), output.text)
        XCTAssertEqual(output.toolTip, model.searchNotice)
    }

    func testSegmentSpinnerLivesInsideSegmentAndCollapsesWhenIdle() throws {
        let view = StatusSegmentView(accessibilityLabel: "Status", help: nil)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        let output = StatusBarSegmentOutput()
        output.set(text: "calculating")
        output.setBusy(true)
        view.apply(output)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.spinner.isHidden)
        func aligned(_ v: NSView) -> NSRect { v.superview!.convert(v.alignmentRect(forFrame: v.frame), to: view) }
        let spin = aligned(view.spinner)
        XCTAssertGreaterThanOrEqual(spin.minX, 0)
        XCTAssertEqual(aligned(view.label).minX - spin.maxX, Spacing.xxs, accuracy: 0.5)

        output.setBusy(false)
        view.apply(output)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.spinner.isHidden)
        XCTAssertEqual(aligned(view.label).minX, 0, accuracy: 0.5)
    }

    func testStatusLabelsUseStatusBarFont() throws {
        ThemeManager.shared.select("platinum")
        let bar = StatusBarView(registries: BrowserRegistries())
        bar.applyTheme(ThemeManager.shared.current)
        let label = try XCTUnwrap(descendants(of: bar, as: ClickableLabel.self).first)
        XCTAssertEqual(label.font, ThemeManager.shared.current.statusBarFont)
    }

    func testDefaultStatusTextBaselineSitsNearSpecifiedOffset() throws {
        ThemeManager.shared.select("modern")
        let dir = try tempDir()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.statusBar.text.contains("1 item") })
        pane.view.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(descendants(of: pane.statusBar, as: ClickableLabel.self).first)
        XCTAssertEqual(label.font?.pointSize, 11)
        let frame = label.convert(label.bounds, to: pane.statusBar)
        let top = pane.statusBar.isFlipped ? frame.minY : pane.statusBar.bounds.maxY - frame.maxY
        XCTAssertEqual(top + label.firstBaselineOffsetFromTop, 18, accuracy: 1.5)
    }

    func testActionableStatusSegmentIsKeyboardAndButtonAccessible() throws {
        let label = ClickableLabel(labelWithString: "3 items")
        XCTAssertEqual(label.accessibilityRole(), .staticText)
        XCTAssertFalse(label.acceptsFirstResponder)
        XCTAssertFalse(label.accessibilityPerformPress())

        var clicks = 0
        label.onClick = { clicks += 1 }
        XCTAssertEqual(label.accessibilityRole(), .button)
        XCTAssertTrue(label.acceptsFirstResponder)
        XCTAssertEqual(label.focusRingType, .exterior)
        XCTAssertTrue(label.accessibilityPerformPress())
        for (chars, code) in [(" ", UInt16(49)), ("\r", UInt16(36))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            label.keyDown(with: event)
        }
        XCTAssertEqual(clicks, 3)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(label)
        XCTAssertTrue(window.makeFirstResponder(label))
        XCTAssertTrue(window.firstResponder === label)
    }

    private func pathBar(width: CGFloat) -> (PathBarView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        bar.translatesAutoresizingMaskIntoConstraints = true
        window.contentView?.addSubview(bar)
        return (bar, window)
    }

    private func crumbs(_ bar: PathBarView) -> [CrumbButton] { descendants(of: bar, as: CrumbButton.self) }

    func testHiddenScopeControlDoesNotReserveWidth() throws {
        ThemeManager.shared.select("modern")
        let dir = try tempDir()
        let (bar, window) = pathBar(width: 600)
        _ = window
        bar.update(location: .folder(dir))
        bar.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(descendants(of: bar, as: NSTextField.self).first { $0.accessibilityLabel() == "Path" })
        XCTAssertEqual(field.frame.maxX, 600 - Spacing.s, accuracy: 0.5)

        bar.update(location: .search(scope: dir, query: "q"))
        bar.layoutSubtreeIfNeeded()
        let scope = try XCTUnwrap(descendants(of: bar, as: NSSegmentedControl.self).first)
        XCTAssertFalse(scope.isHidden)
        XCTAssertEqual(field.frame.maxX, scope.alignmentRect(forFrame: scope.frame).minX - Spacing.xs, accuracy: 0.5)
    }

    func testDeepPathCollapsesLeadingAncestorsIntoMenu() throws {
        ThemeManager.shared.select("modern")
        var deep = try tempDir()
        for i in 0..<12 { deep = deep.appendingPathComponent("level-number-\(i)", isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let (bar, window) = pathBar(width: 320)
        _ = window
        bar.update(location: .folder(deep))
        bar.layoutSubtreeIfNeeded()
        let shown = crumbs(bar)
        let more = try XCTUnwrap(shown.first { $0.isCollapsedAncestors })
        XCTAssertEqual(more.accessibilityLabel(), "Enclosing folders")
        XCTAssertEqual(shown.last?.title, "level-number-11")
        XCTAssertFalse(bar.collapsedAncestors.isEmpty)
        XCTAssertFalse(bar.collapsedAncestors.contains(deep))
        XCTAssertEqual(bar.collapsedAncestorsMenu().items.count, bar.collapsedAncestors.count)
        let stack = try XCTUnwrap(shown.last?.superview)
        XCTAssertLessThanOrEqual(stack.frame.maxX, 320 - Spacing.s + 0.5)

        bar.setFrameSize(NSSize(width: 4000, height: 32))
        bar.layoutSubtreeIfNeeded()
        XCTAssertNil(crumbs(bar).first { $0.isCollapsedAncestors })
        XCTAssertTrue(bar.collapsedAncestors.isEmpty)
    }

    func testVisibleTailKeepsCurrentFolder() {
        XCTAssertEqual(PathBarView.visibleTail(minimumWidths: [40, 40, 40], available: 1000, separatorUnit: 16, ellipsis: 24), 3)
        XCTAssertEqual(PathBarView.visibleTail(minimumWidths: [40, 40, 40, 200], available: 10, separatorUnit: 16, ellipsis: 24), 1)
        let exact: CGFloat = 192
        XCTAssertEqual(PathBarView.visibleTail(minimumWidths: [40, 40, 40, 40], available: exact, separatorUnit: 16, ellipsis: 24), 3)
        XCTAssertEqual(PathBarView.visibleTail(minimumWidths: [40, 40, 40, 40], available: exact - 1, separatorUnit: 16, ellipsis: 24), 2)
    }

    func testPathBarUsesDedicatedFontAndColors() throws {
        ThemeManager.shared.select("platinum")
        let theme = ThemeManager.shared.current
        let dir = try tempDir()
        let (bar, window) = pathBar(width: 2000)
        _ = window
        bar.update(location: .folder(dir))
        bar.layoutSubtreeIfNeeded()
        let all = crumbs(bar)
        XCTAssertGreaterThan(all.count, 1)
        for c in all { XCTAssertEqual(c.font, theme.pathBarFont) }
        let last = try XCTUnwrap(all.last)
        let ancestor = try XCTUnwrap(all.first)
        XCTAssertEqual(color(last.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), color(Theme.color(theme.pathBar.highlight)))
        XCTAssertEqual(color(ancestor.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), color(Theme.color(theme.pathBar.text)))
        let sep = try XCTUnwrap(descendants(of: bar, as: NSImageView.self).first { $0.superview is NSStackView })
        XCTAssertEqual(color(sep.contentTintColor), color(Theme.color(theme.pathBar.separator)))
        XCTAssertLessThanOrEqual(last.intrinsicContentSize.height, theme.layout.pathBarHeight)
        XCTAssertGreaterThanOrEqual(last.intrinsicContentSize.height, ThemeLayout.lineHeight(theme.pathBarFont))
    }

    func testLowContrastHighlightFallsBackToText() {
        var theme = ThemeManager.shared.current
        theme.pathBar.background = "#FFFFFF"
        theme.pathBar.highlight = "#FFFF66"
        theme.colors.text = "#000000"
        XCTAssertEqual(color(PathBarView.crumbColors(for: theme).current), "#000000")
    }

    func testProvidedLocationDoesNotEditStaleLocalPath() throws {
        let dir = try tempDir()
        let (bar, window) = pathBar(width: 600)
        _ = window
        bar.update(location: .folder(dir))
        bar.showProvided(title: "docs", symbolName: "server.rack", path: "sftp://host/home/me/docs")
        bar.beginEditing()
        XCTAssertFalse(bar.isEditing)
        XCTAssertEqual(InlineWarning.lastMessage, PathBarView.providedEditingMessage)
        XCTAssertEqual(bar.accessibilityCustomActions()?.map(\.name), ["Copy server path"])
        XCTAssertEqual(bar.accessibilityValue() as? String, "sftp://host/home/me/docs")
        let crumb = try XCTUnwrap(crumbs(bar).last)
        XCTAssertEqual(bar.ancestorsMenu(for: crumb).items.map(\.title), ["Copy Server Path"])

        bar.update(location: .folder(dir))
        bar.beginEditing()
        XCTAssertTrue(bar.isEditing)
        XCTAssertEqual(bar.accessibilityCustomActions()?.map(\.name), ["Edit path"])
    }

    func testFailedPathCompletionShowsVisibleWarning() throws {
        let (bar, window) = pathBar(width: 600)
        _ = window
        bar.update(location: .computer)
        bar.beginEditing(text: "/definitely-missing-\(UUID().uuidString)/x")
        _ = bar.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(InlineWarning.lastMessage, PathBarView.noCompletionMessage)
        XCTAssertTrue(bar.isEditing)
    }

    func testSidebarCustomSelectionColorsFontAndGap() throws {
        ThemeManager.shared.select("system7")
        let theme = ThemeManager.shared.current
        XCTAssertTrue(SidebarViewController.usesCustomSelection(theme))
        let row = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        row.theme = theme
        let cell = SidebarCellView()
        cell.textField?.font = theme.sidebarFont
        cell.normalTextColor = Theme.color(theme.colors.sidebarText)
        cell.selectedTextColor = Theme.color(theme.colors.sidebarSelectionText)
        cell.normalIconColor = Theme.color(theme.colors.sidebarIcon)
        cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        row.addSubview(cell)
        XCTAssertEqual(color(cell.textField?.textColor), "#000000")
        row.isSelected = true
        XCTAssertEqual(row.interiorBackgroundStyle, .normal)
        XCTAssertEqual(color(cell.textField?.textColor), "#FFFFFF")
        XCTAssertEqual(color(cell.imageView?.contentTintColor), "#FFFFFF")
        row.isSelected = false
        XCTAssertEqual(color(cell.textField?.textColor), "#000000")
        XCTAssertEqual(row.selectionRect(), row.bounds.insetBy(dx: Spacing.xxs, dy: 0))

        ThemeManager.shared.select("modern")
        XCTAssertFalse(SidebarViewController.usesCustomSelection(ThemeManager.shared.current))
        let modernRow = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        modernRow.theme = ThemeManager.shared.current
        XCTAssertEqual(modernRow.selectionRect(), modernRow.bounds.insetBy(dx: Spacing.xs, dy: 2))
    }

    func testSidebarLiveCellsUseSidebarFontIconColorAndCompactGap() throws {
        ThemeManager.shared.select("classic-windows")
        let theme = ThemeManager.shared.current
        let dir = try tempDir()
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 600), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(of: wc.sidebarController.view, as: SidebarOutlineView.self).first)
        var checked = 0
        for row in 0..<outline.numberOfRows {
            guard let box = outline.item(atRow: row) as? EntryBox, box.entry.symbol != nil,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else { continue }
            XCTAssertEqual(cell.textField?.font, theme.sidebarFont)
            XCTAssertEqual(cell.iconTextGap, Spacing.xxs)
            if !outline.isRowSelected(row) {
                XCTAssertEqual(color(cell.imageView?.contentTintColor), color(Theme.color(theme.colors.sidebarIcon)))
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertGreaterThanOrEqual(outline.rowHeight, ThemeLayout.lineHeight(theme.sidebarFont))
    }

    func testLargeFontsGrowSidebarPathAndStatusGeometry() {
        var theme = ThemeManager.builtIns.first { $0.id == "classic-windows" }!
        theme.fonts.sidebar = Theme.FontSpec(family: "system", size: 36)
        theme.fonts.statusBar = Theme.FontSpec(family: "system", size: 36)
        theme.pathBar.font = Theme.FontSpec(family: "system", size: 36)
        let lay = theme.layout
        XCTAssertGreaterThanOrEqual(SidebarViewController.rowHeight(for: theme), ThemeLayout.lineHeight(theme.sidebarFont))
        let crumb = PathBarView.metrics(for: theme).height
        XCTAssertGreaterThanOrEqual(crumb, ThemeLayout.lineHeight(theme.pathBarFont))
        XCTAssertLessThanOrEqual(crumb, lay.pathBarHeight)
        XCTAssertGreaterThanOrEqual(lay.statusBarHeight, ThemeLayout.lineHeight(theme.statusBarFont))

        let stock = ThemeManager.builtIns.first { $0.id == "classic-windows" }!
        XCTAssertEqual(SidebarViewController.rowHeight(for: stock), stock.layout.sidebarRowHeight)
    }

    func testNonEjectableSidebarRowsDoNotReserveEjectSpace() {
        let cell = SidebarCellView()
        cell.textField?.stringValue = String(repeating: "Very long favorite name ", count: 10)
        cell.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        cell.setEjectVisible(false)
        cell.layoutSubtreeIfNeeded()
        let tf = cell.textField!
        XCTAssertEqual(tf.alignmentRect(forFrame: tf.frame).maxX, 200, accuracy: 0.5)
        cell.setEjectVisible(true)
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(tf.alignmentRect(forFrame: tf.frame).maxX, 200 - Spacing.hitTarget - Spacing.xxs + 0.5)
    }

    func testSidebarHeadingContrastForBuiltIns() {
        let luna = ThemeManager.builtIns.first { $0.id == "luna" }!
        XCTAssertEqual(SidebarViewController.headingColor(for: luna).alphaComponent, 1)
        let platinum = ThemeManager.builtIns.first { $0.id == "platinum" }!
        XCTAssertEqual(SidebarViewController.headingColor(for: platinum).alphaComponent, 0.6, accuracy: 0.01)
        for theme in ThemeManager.builtIns {
            let bgToken = theme.colors.sidebarBg.lowercased() == "system:clear" ? "system:windowBackground" : theme.colors.sidebarBg
            guard let bg = Theme.color(bgToken).usingColorSpace(.sRGB), let fg = SidebarViewController.headingColor(for: theme).usingColorSpace(.sRGB) else { continue }
            let composite = SidebarViewController.composite(fg, alpha: fg.alphaComponent, over: bg)
            XCTAssertGreaterThanOrEqual(NSColor.contrastRatio(composite, bg), 4.5, theme.id)
        }
    }

    private func makeWindowWithPanels(_ regs: BrowserRegistries) throws -> BrowserWindowController {
        let dir = try tempDir()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data())
        let wc = BrowserWindowController(location: .folder(dir), registries: regs)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    func testSlideOutPanelHasOpaqueThemedSurface() throws {
        ThemeManager.shared.select("system7")
        let regs = BrowserRegistries()
        let wc = try makeWindowWithPanels(regs)
        defer { wc.close() }
        regs.panels.register(PanelSpec(id: "s", title: "Slide", edge: .left, presentation: .slideOut, defaultOpen: true, content: .ui(.stack(id: "r", [.label(id: "l", "hello")]))), owner: "tester")
        let inst = try XCTUnwrap(wc.panelHost?.instances["tester/s"])
        let root = try XCTUnwrap(inst.vc.view as? ThemedPanelRoot)
        XCTAssertTrue(root.isOpaque)
        XCTAssertEqual(color(root.fill), color(Theme.color(ThemeManager.shared.current.colors.windowBg)))
        let title = try XCTUnwrap(descendants(of: root, as: NSTextField.self).first { $0.stringValue == "Slide" })
        XCTAssertEqual(color(title.textColor), color(ThemeManager.shared.current.textColor))
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        root.draw(NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(rep.colorAt(x: 5, y: 5)?.alphaComponent, 1)

        ThemeManager.shared.select("high-contrast")
        XCTAssertEqual(color(root.fill), color(Theme.color(ThemeManager.shared.current.colors.windowBg)))
    }

    func testSlideOutResizeHandleIsAdjustableByAccessibilityAndKeyboard() throws {
        let regs = BrowserRegistries()
        let wc = try makeWindowWithPanels(regs)
        defer { wc.close() }
        regs.panels.register(PanelSpec(id: "s", title: "Notes", edge: .left, presentation: .slideOut, defaultSize: 240, minSize: 200, maxSize: 260, defaultOpen: true, content: .ui(.stack(id: "r", [.label(id: "l", "hi")]))), owner: "tester")
        let overlay = try XCTUnwrap(wc.panelHost?.instances["tester/s"]?.overlay)
        let handle = overlay.handle
        XCTAssertEqual(handle.accessibilityLabel(), "Resize Notes panel")
        XCTAssertEqual(handle.accessibilityOrientation(), .vertical)
        XCTAssertEqual((handle.accessibilityValue() as? NSNumber)?.doubleValue, 240)
        XCTAssertEqual((handle.accessibilityMinValue() as? NSNumber)?.doubleValue, 200)
        XCTAssertEqual((handle.accessibilityMaxValue() as? NSNumber)?.doubleValue, 260)
        XCTAssertTrue(handle.accessibilityPerformIncrement())
        XCTAssertEqual(overlay.sizeConstraint.constant, 256)
        XCTAssertTrue(handle.accessibilityPerformIncrement())
        XCTAssertEqual(overlay.sizeConstraint.constant, 260)
        XCTAssertEqual(PanelStateStore.size("tester/s", default: 0), 260)
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        handle.keyDown(with: left)
        XCTAssertEqual(overlay.sizeConstraint.constant, 244)
        for _ in 0..<10 { XCTAssertTrue(handle.accessibilityPerformDecrement()) }
        XCTAssertEqual(overlay.sizeConstraint.constant, 200)
        XCTAssertTrue(handle.acceptsFirstResponder)
        XCTAssertEqual(handle.focusRingType, .exterior)
        XCTAssertEqual(handle.accessibilityValueDescription(), "200 points")
    }

    func testExplicitPanelOpenFocusesPanelAndCloseRestoresInvoker() throws {
        let regs = BrowserRegistries()
        let wc = try makeWindowWithPanels(regs)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        regs.panels.register(PanelSpec(id: "s", title: "Edit", edge: .left, presentation: .slideOut, content: .ui(.stack(id: "r", [.textField(id: "t", value: "x", accessibilityLabel: "Note")]))), owner: "tester")
        let host = try XCTUnwrap(wc.panelHost)
        let inst = try XCTUnwrap(host.instances["tester/s"])
        let invoker = NSTextField(string: "invoker")
        window.contentView?.addSubview(invoker)
        XCTAssertTrue(window.makeFirstResponder(invoker))

        host.toggle("tester/s")
        XCTAssertTrue(host.isOpen("tester/s"))
        XCTAssertTrue(PanelHostController.focusIsInside(inst.vc.view), String(describing: window.firstResponder))

        host.toggle("tester/s")
        XCTAssertFalse(host.isOpen("tester/s"))
        XCTAssertFalse(PanelHostController.focusIsInside(inst.vc.view))
        let fr = window.firstResponder
        XCTAssertTrue(fr === invoker || ((fr as? NSTextView)?.delegate as? NSTextField) === invoker, String(describing: fr))
    }

    func testUnloadingFocusedPanelMovesFocusToBrowser() throws {
        let regs = BrowserRegistries()
        let wc = try makeWindowWithPanels(regs)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        regs.panels.register(PanelSpec(id: "s", title: "Edit", edge: .left, presentation: .slideOut, content: .ui(.stack(id: "r", [.textField(id: "t", value: "x", accessibilityLabel: "Note")]))), owner: "tester")
        let host = try XCTUnwrap(wc.panelHost)
        let panelView = try XCTUnwrap(host.instances["tester/s"]?.vc.view)
        host.open("tester/s", focus: true, animated: false)
        XCTAssertTrue(PanelHostController.focusIsInside(panelView))
        regs.panels.removeAll(owner: "tester")
        XCTAssertNil(host.instances["tester/s"])
        XCTAssertFalse(PanelHostController.focusIsInside(panelView))
        XCTAssertNotNil(window.firstResponder as? NSView)
    }

    func testBackgroundPanelOpenDoesNotStealFocus() throws {
        let regs = BrowserRegistries()
        let wc = try makeWindowWithPanels(regs)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        let invoker = NSTextField(string: "keep")
        window.contentView?.addSubview(invoker)
        XCTAssertTrue(window.makeFirstResponder(invoker))
        regs.panels.register(PanelSpec(id: "s", title: "Bg", edge: .left, presentation: .slideOut, defaultOpen: true, content: .ui(.stack(id: "r", [.textField(id: "t", value: "x", accessibilityLabel: "Note")]))), owner: "tester")
        wc.setPanel("tester/s", open: true, animated: false)
        let fr = window.firstResponder
        XCTAssertTrue(fr === invoker || ((fr as? NSTextView)?.delegate as? NSTextField) === invoker)
    }

    func testInfoTagsWrapInsteadOfOverflowing() throws {
        let tags = ["Customer deliverable", "Needs review", "Archive 2026", "Quarterly finance", "Red", "Very long tag name for testing"]
        let single = NSHostingView(rootView: FlowTags(tags: ["Red"], onRemove: { _ in }).frame(width: 320))
        let many = NSHostingView(rootView: FlowTags(tags: tags, onRemove: { _ in }).frame(width: 320))
        XCTAssertLessThanOrEqual(many.fittingSize.width, 320.5)
        XCTAssertGreaterThan(many.fittingSize.height, single.fittingSize.height * 2)
    }

    func testInfoBodyScrollsAndPanelKeepsUsableHeight() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("info.txt")
        try Data("x".utf8).write(to: file)
        let c = InfoPanelController(url: file)
        defer { c.close() }
        let content = try XCTUnwrap(c.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(of: content, as: NSScrollView.self).isEmpty)
        XCTAssertGreaterThan(c.window?.contentRect(forFrameRect: c.window!.frame).height ?? 0, 200)
        XCTAssertEqual(c.window?.contentRect(forFrameRect: c.window!.frame).width ?? 0, Spacing.infoPanelWidth, accuracy: 1)
    }

    func testInfoSizeAnnouncesCompletionOnce() throws {
        let dir = try tempDir()
        let model = InfoModel(url: dir)
        var said: [String] = []
        InfoModel.announce = { said.append($0) }
        var progress = false
        var announced = false
        model.applySize(SizeResult(allocatedBytes: 4096, logicalBytes: 1, itemCount: 1, isComplete: false), name: "Projects", sawProgress: &progress, announced: &announced)
        XCTAssertTrue(model.sizeText.hasSuffix("…"))
        model.applySize(SizeResult(allocatedBytes: 8192, logicalBytes: 2, itemCount: 2, isComplete: true), name: "Projects", sawProgress: &progress, announced: &announced)
        model.applySize(SizeResult(allocatedBytes: 8192, logicalBytes: 2, itemCount: 2, isComplete: true), name: "Projects", sawProgress: &progress, announced: &announced)
        XCTAssertEqual(said, ["Projects, \(SizeFormatter.string(8192)) on disk, calculation complete"])

        var p2 = false, a2 = false
        model.applySize(SizeResult(allocatedBytes: 8192, logicalBytes: 2, itemCount: 2, isComplete: true), name: "Cached", sawProgress: &p2, announced: &a2)
        XCTAssertEqual(said.count, 1)
        var partial = SizeResult(allocatedBytes: 4096, logicalBytes: 1, itemCount: 1, isComplete: false)
        partial.isPartial = true
        var p3 = true, a3 = false
        model.applySize(partial, name: "Locked", sawProgress: &p3, announced: &a3)
        XCTAssertTrue(model.sizeText.contains("some items unreadable"), model.sizeText)
        XCTAssertTrue(said.last?.contains("some items unreadable") ?? false)
    }
}
