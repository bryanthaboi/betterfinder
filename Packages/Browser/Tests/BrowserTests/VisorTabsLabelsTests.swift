import AppKit
import XCTest
import FSCore
import FileOps
import Integration
import Theming
@testable import Browser

@MainActor
final class PointDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: NSPoint
    init(_ pasteboard: NSPasteboard, at location: NSPoint) {
        self.pasteboard = pasteboard
        self.location = location
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
final class VisorTabsLabelsTests: XCTestCase {
    private var savedStore: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suite = "VisorTabsLabelsTests.\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suite)!
        BrowserDefaults.viewMode = .list
    }

    override func tearDown() async throws {
        BrowserDefaults.store.removePersistentDomain(forName: suite)
        BrowserDefaults.store = savedStore
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func makeTree(files: [String] = ["a.txt", "b.txt"], folders: [String] = ["Sub", "Other"]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-visor-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in folders { try FileManager.default.createDirectory(at: dir.appendingPathComponent(f), withIntermediateDirectories: true) }
        for f in files { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data("x".utf8)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testPathFormatsOnALocalVolume() {
        let volume = PathFormat.Volume(root: "/", name: "Macintosh HD", remote: nil)
        let path = "/Users/me/My Files/report (final).txt"
        func make(_ f: PathFormat, directory: Bool = false, _ p: String = path) -> String? { f.string(path: p, isDirectory: directory, volume: volume) }
        XCTAssertEqual(make(.posix), path)
        XCTAssertEqual(make(.url), "file:///Users/me/My%20Files/report%20(final).txt")
        XCTAssertEqual(make(.windows), "\\Users\\me\\My Files\\report (final).txt")
        XCTAssertNil(make(.unc))
        XCTAssertEqual(make(.hfs), "Macintosh HD:Users:me:My Files:report (final).txt")
        XCTAssertEqual(make(.hfs, directory: true, "/Users/me/a:b"), "Macintosh HD:Users:me:a/b:")
        XCTAssertEqual(make(.terminal), "/Users/me/My\\ Files/report\\ \\(final\\).txt")
        XCTAssertEqual(PathFormat.shellEscaped("/tmp/it's $HOME"), "/tmp/it\\'s\\ \\$HOME")
        XCTAssertEqual(PathFormat.shellEscaped("/tmp/naïve"), "/tmp/naïve")
    }

    func testPathFormatsOnANetworkVolume() throws {
        let volume = PathFormat.Volume(root: "/Volumes/Share", name: "Share", remote: URL(string: "smb://bryan@nas.local/Share"))
        let path = "/Volumes/Share/Projects/plan.md"
        XCTAssertEqual(PathFormat.unc.string(path: path, isDirectory: false, volume: volume), "\\\\nas.local\\Share\\Projects\\plan.md")
        XCTAssertEqual(PathFormat.windows.string(path: path, isDirectory: false, volume: volume), "\\\\nas.local\\Share\\Projects\\plan.md")
        XCTAssertEqual(PathFormat.url.string(path: path, isDirectory: false, volume: volume), "smb://nas.local/Share/Projects/plan.md")
        XCTAssertEqual(PathFormat.url.string(path: "/Volumes/Share/Projects", isDirectory: true, volume: volume), "smb://nas.local/Share/Projects/")
        XCTAssertEqual(PathFormat.hfs.string(path: path, isDirectory: false, volume: volume), "Share:Projects:plan.md")
        XCTAssertEqual(PathFormat.components(of: "/Volumes/Share", under: "/Volumes/Share"), [])
    }

    func testCopyPathFormatsAreOfferedForLocalSelections() throws {
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(pane.canCopyPath(as: .posix))
        XCTAssertTrue(pane.canCopyPath(as: .terminal))
        XCTAssertTrue(pane.canCopyPath(as: .hfs))
        XCTAssertFalse(pane.canCopyPath(as: .unc))
        let submenu = try XCTUnwrap(CopyPathMenu.submenuItem(target: pane).submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["POSIX Path", "URL", "Windows Path", "UNC Path", "HFS Path", "Terminal Path"])
        let unc = try XCTUnwrap(submenu.items.first { $0.title == "UNC Path" })
        XCTAssertFalse(pane.validateMenuItem(unc))
        XCTAssertTrue(pane.validateMenuItem(try XCTUnwrap(submenu.items.first { $0.title == "URL" })))
        XCTAssertTrue(ContextMenuBuilder.builtInMenu(for: pane).items.contains { $0.title == "Copy Path As" })
        let ids = wc.registries.commands.paletteEntries(query: "copy path as", context: BrowserContext(controller: wc)).map(\.title)
        XCTAssertTrue(ids.contains("Copy Path as Terminal Path"))
    }

    func testLabelColorComesFromTheLastColoredTag() {
        let colors = NSWorkspace.shared.fileLabelColors
        XCTAssertNil(TagColors.labelColor(for: []))
        XCTAssertNil(TagColors.labelColor(for: [.init(name: "Work", colorIndex: 0)]))
        XCTAssertEqual(TagColors.labelColor(for: [.init(name: "A", colorIndex: 6), .init(name: "B", colorIndex: 2)]), colors[2])
        XCTAssertEqual(TagColors.labelColor(for: [.init(name: "A", colorIndex: 6), .init(name: "Plain", colorIndex: 0)]), colors[6])
        XCTAssertEqual(DirectoryLister.UserTag(raw: "Important\n6"), .init(name: "Important", colorIndex: 6))
        XCTAssertEqual(DirectoryLister.UserTag(raw: "Loose"), .init(name: "Loose", colorIndex: 0))
    }

    func testColoredLabelsTintRowsOnlyWhenEnabled() throws {
        let dir = try makeTree()
        let tagged = dir.appendingPathComponent("a.txt")
        let red = try XCTUnwrap(TagColors.systemTags.first { TagColors.color(for: $0) == NSWorkspace.shared.fileLabelColors[6] } ?? TagColors.systemTags.first)
        try (tagged as NSURL).setResourceValue([red], forKey: .tagNamesKey)
        XCTAssertEqual(DirectoryLister.userTags(tagged).map(\.name), [red])
        XCTAssertNil(TagColors.labelColor(for: tagged))

        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        window.orderFront(nil)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 4 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        window.contentView?.layoutSubtreeIfNeeded()
        func label(_ name: String) -> NSColor? {
            guard let row = (0..<list.outline.numberOfRows).first(where: { (list.outline.item(atRow: $0) as? FileNode)?.item.name == name }) else { return nil }
            return (list.outline.rowView(atRow: row, makeIfNecessary: true) as? ThemedRowView)?.labelColor
        }
        XCTAssertNil(label("a.txt"))

        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.coloredLabels)
        XCTAssertNotNil(TagColors.labelColor(for: tagged))
        XCTAssertTrue(spin { label("a.txt") != nil })
        XCTAssertNil(label("b.txt"))

        wc.setViewMode(.icon)
        let icons = try XCTUnwrap(pane.content as? IconViewController)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(spin {
            icons.collection.visibleItems().compactMap { $0 as? IconItem }.contains { $0.representedURL?.lastPathComponent == "a.txt" && $0.tagColor != nil }
        })
        XCTAssertFalse(icons.collection.visibleItems().compactMap { $0 as? IconItem }.contains { $0.representedURL?.lastPathComponent == "b.txt" && $0.tagColor != nil })

        wc.setViewMode(.list)
        BrowserDefaults.store.set(false, forKey: BrowserDefaults.Key.coloredLabels)
        let again = try XCTUnwrap(pane.content as? ListViewController)
        XCTAssertTrue(spin {
            guard let row = (0..<again.outline.numberOfRows).first(where: { (again.outline.item(atRow: $0) as? FileNode)?.item.name == "a.txt" }) else { return false }
            return (again.outline.rowView(atRow: row, makeIfNecessary: true) as? ThemedRowView)?.labelColor == nil
        })
    }

    func testColumnWidthFitsTheLongestName() throws {
        let theme = ThemeManager.shared.current
        func item(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/tmp/bf-fit/\(name)"), name: name, isDirectory: false) }
        let short = ColumnViewController.fittedWidth(for: [item("a")], theme: theme)
        let medium = ColumnViewController.fittedWidth(for: [item("a"), item("a reasonably long file name.txt")], theme: theme)
        let huge = ColumnViewController.fittedWidth(for: [item(String(repeating: "w", count: 400))], theme: theme)
        XCTAssertEqual(ColumnViewController.fittedWidth(for: [], theme: theme), ColumnViewController.columnWidth)
        XCTAssertEqual(short, ColumnViewController.fittedWidthRange.lowerBound)
        XCTAssertGreaterThan(medium, short)
        XCTAssertEqual(huge, ColumnViewController.fittedWidthRange.upperBound)
        XCTAssertEqual(ColumnViewController.fittedWidth(for: [item("a reasonably long file name.txt")], theme: theme, scrollerWidth: 15), medium + 15)
        let many = (0..<500).map { item("f\($0)") } + [item("the one long name that should still decide the width.txt")]
        XCTAssertEqual(ColumnViewController.fittedWidth(for: many, theme: theme), ColumnViewController.fittedWidth(for: [many.last!], theme: theme))

        let long = "a file whose name is long enough to need a wider column.txt"
        let dir = try makeTree(files: [long], folders: [])
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        window.orderFront(nil)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 1 })
        wc.setViewMode(.column)
        let columns = try XCTUnwrap(pane.content as? ColumnViewController)
        XCTAssertTrue(spin { (columns.columnWidths().first ?? 0) > ColumnViewController.columnWidth })
        BrowserDefaults.store.set(false, forKey: BrowserDefaults.Key.columnAutoWidth)
        XCTAssertTrue(spin { columns.columnWidths().first == ColumnViewController.columnWidth })
        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.columnAutoWidth)
        XCTAssertTrue(spin { (columns.columnWidths().first ?? 0) > ColumnViewController.columnWidth })
    }

    func testSidebarIconsCanBeColored() throws {
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        wc.window?.orderFront(nil)
        let sidebar = wc.sidebarController
        sidebar.loadViewIfNeeded()
        let title = try XCTUnwrap(sidebar.entryTitles(inSection: "Favorites").last)
        XCTAssertEqual(sidebar.iconIsTinted(forEntryTitled: title), true)
        XCTAssertEqual(sidebar.iconIsTinted(forEntryTitled: "Recents"), true)
        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.colorSidebarIcons)
        XCTAssertTrue(spin { sidebar.iconIsTinted(forEntryTitled: title) == false })
        XCTAssertEqual(sidebar.iconIsTinted(forEntryTitled: "Recents"), true)
        BrowserDefaults.store.set(false, forKey: BrowserDefaults.Key.colorSidebarIcons)
        XCTAssertTrue(spin { sidebar.iconIsTinted(forEntryTitled: title) == true })
    }

    func testDualPaneGetsASecondSidebarWhenEnabled() throws {
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 700), display: true)
        window.orderFront(nil)
        wc.toggleDualPane(nil)
        XCTAssertNil(wc.secondSidebar)
        XCTAssertTrue(wc.boundPane(for: wc.sidebarController) === wc.activePane)

        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.dualPaneSidebars)
        XCTAssertTrue(spin { wc.secondSidebar != nil })
        let second = try XCTUnwrap(wc.secondSidebar)
        XCTAssertTrue(wc.boundPane(for: wc.sidebarController) === wc.panes[0])
        XCTAssertTrue(wc.boundPane(for: second) === wc.panes[1])
        window.contentView?.layoutSubtreeIfNeeded()
        spin(0.2)
        let widths = wc.sidebarWidths
        XCTAssertEqual(try XCTUnwrap(widths.second), widths.first, accuracy: 2)

        let sub = dir.appendingPathComponent("Sub")
        second.onSelect?(.folder(sub))
        XCTAssertTrue(wc.activePane === wc.panes[1])
        XCTAssertTrue(wc.panes[1].location.isSame(as: .folder(sub)))
        XCTAssertTrue(wc.panes[0].location.isSame(as: .folder(dir)))
        wc.sidebarController.onSelect?(.folder(dir.appendingPathComponent("Other")))
        XCTAssertTrue(wc.activePane === wc.panes[0])
        XCTAssertTrue(wc.panes[1].location.isSame(as: .folder(sub)))

        wc.toggleDualPane(nil)
        XCTAssertNil(wc.secondSidebar)
        wc.toggleDualPane(nil)
        XCTAssertNotNil(wc.secondSidebar)
        BrowserDefaults.store.set(false, forKey: BrowserDefaults.Key.dualPaneSidebars)
        XCTAssertTrue(spin { wc.secondSidebar == nil })
    }

    func testNewShortcutsAreBuiltIn() throws {
        XCTAssertTrue(BrowserWindow.shortcuts.contains { $0.keyCode == 41 && $0.mods == [.command, .shift] && $0.action == #selector(BrowserWindowController.toggleFoldersFirst(_:)) })
        let registry = KeyBindingRegistry()
        registry.menuProvider = { nil }
        XCTAssertNotNil(registry.builtInChords[KeyChord(key: ";", command: true, shift: true)])
        XCTAssertNotNil(registry.builtInChords[KeyChord(key: "tab", option: true)])

        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir), registries: BrowserRegistries())
        defer { wc.close() }
        wc.window?.orderFront(nil)
        XCTAssertFalse(BrowserDefaults.sort.foldersFirst)
        wc.toggleFoldersFirst(nil)
        XCTAssertTrue(BrowserDefaults.sort.foldersFirst)
        let item = NSMenuItem(title: "Keep Folders on Top", action: #selector(BrowserWindowController.toggleFoldersFirst(_:)), keyEquivalent: "")
        XCTAssertTrue(wc.validateUserInterfaceItem(item))
        XCTAssertEqual(item.state, .on)

        XCTAssertFalse(wc.activePane.handleKeyDown(key(48, "\t", .option)))
        wc.toggleDualPane(nil)
        let before = wc.activePane
        XCTAssertTrue(wc.activePane.handleKeyDown(key(48, "\t", .option)))
        XCTAssertFalse(wc.activePane === before)
        XCTAssertTrue(wc.activePane.handleKeyDown(key(48, "\t")))
        XCTAssertTrue(wc.activePane === before)
    }

    func testTabBarTargets() {
        let frames = [NSRect(x: 10, y: 400, width: 290, height: 24), NSRect(x: 304, y: 400, width: 290, height: 24), NSRect(x: 598, y: 400, width: 292, height: 24)]
        typealias T = TabBarLayout
        XCTAssertNil(T.target(at: NSPoint(x: 100, y: 300), frames: frames, foldersOnly: false))
        XCTAssertNil(T.target(at: NSPoint(x: 100, y: 412), frames: [], foldersOnly: true))
        XCTAssertEqual(T.target(at: NSPoint(x: 150, y: 412), frames: frames, foldersOnly: false), .tab(0))
        XCTAssertEqual(T.target(at: NSPoint(x: 700, y: 412), frames: frames, foldersOnly: false), .tab(2))
        XCTAssertNil(T.target(at: NSPoint(x: 302, y: 412), frames: frames, foldersOnly: false))
        XCTAssertEqual(T.target(at: NSPoint(x: 150, y: 412), frames: frames, foldersOnly: true), .tab(0))
        XCTAssertEqual(T.target(at: NSPoint(x: 300, y: 412), frames: frames, foldersOnly: true), .gap(1))
        XCTAssertEqual(T.target(at: NSPoint(x: 600, y: 412), frames: frames, foldersOnly: true), .gap(2))
        XCTAssertEqual(T.target(at: NSPoint(x: 12, y: 412), frames: frames, foldersOnly: true), .gap(0))
        XCTAssertEqual(T.target(at: NSPoint(x: 2, y: 412), frames: frames, foldersOnly: true), .gap(0))
        XCTAssertEqual(T.target(at: NSPoint(x: 885, y: 412), frames: frames, foldersOnly: true), .gap(3))
        XCTAssertEqual(T.target(at: NSPoint(x: 899, y: 412), frames: frames, foldersOnly: true), .gap(3))
        XCTAssertEqual(T.target(at: NSPoint(x: 12, y: 412), frames: frames, foldersOnly: false), .tab(0))
        XCTAssertEqual(T.gapX(1, frames: frames), 302)

        let reversed = Array(frames.reversed())
        XCTAssertEqual(T.target(at: NSPoint(x: 700, y: 412), frames: reversed, foldersOnly: false), .tab(0))
        XCTAssertEqual(T.target(at: NSPoint(x: 899, y: 412), frames: reversed, foldersOnly: true), .gap(0))
        XCTAssertEqual(T.target(at: NSPoint(x: 2, y: 412), frames: reversed, foldersOnly: true), .gap(3))
        XCTAssertEqual(T.gapX(0, frames: reversed), 890)
    }

    func testTabsTakeDropsAndDoubleClicks() throws {
        let dir = try makeTree()
        let sub = dir.appendingPathComponent("Sub")
        let other = dir.appendingPathComponent("Other")
        let manager = BrowserWindowManager(registries: BrowserRegistries())
        defer { for c in manager.controllers { c.close() } }
        let first = manager.openWindow(at: .folder(dir))
        let second = manager.openTab(at: .folder(sub), nextTo: first)
        let window = try XCTUnwrap(second.window)
        XCTAssertTrue(spin { TabBarLayout.tabs(in: window).count == 2 })
        let tabs = TabBarLayout.tabs(in: window)
        XCTAssertTrue(tabs[0].window === first.window)
        XCTAssertTrue(tabs[1].window === second.window)

        let pb = NSPasteboard(name: NSPasteboard.Name("bf-tabdrop-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let file = dir.appendingPathComponent("a.txt")
        pb.writeObjects([file as NSURL])
        let onSecond = PointDraggingInfo(pb, at: NSPoint(x: tabs[1].frame.midX, y: tabs[1].frame.midY))
        let drop = try XCTUnwrap(second.tabDrop(for: onSecond))
        XCTAssertEqual(drop.target, .tab(1))
        XCTAssertEqual(drop.destination?.pathKey, sub.pathKey)
        XCTAssertEqual(drop.operation, .move)
        XCTAssertEqual(second.draggingUpdated(onSecond), .move)
        XCTAssertNotNil(second.tabDropHighlight?.superview)
        second.draggingExited(onSecond)
        XCTAssertNil(second.tabDropHighlight)
        XCTAssertNil(second.tabDrop(for: PointDraggingInfo(pb, at: NSPoint(x: tabs[0].frame.midX, y: tabs[0].frame.midY))))
        XCTAssertNil(second.tabDrop(for: PointDraggingInfo(pb, at: NSPoint(x: tabs[1].frame.midX, y: 20))))
        XCTAssertEqual(second.draggingUpdated(PointDraggingInfo(pb, at: NSPoint(x: tabs[1].frame.midX, y: 20))), [])

        pb.clearContents()
        pb.writeObjects([other as NSURL])
        let gap = PointDraggingInfo(pb, at: NSPoint(x: TabBarLayout.gapX(1, frames: tabs.map(\.frame)), y: tabs[0].frame.midY))
        let folderDrop = try XCTUnwrap(second.tabDrop(for: gap))
        XCTAssertEqual(folderDrop.target, .gap(1))
        XCTAssertEqual(folderDrop.folders.map(\.pathKey), [other.pathKey])
        XCTAssertTrue(second.performDragOperation(gap))
        XCTAssertEqual(manager.controllers.count, 3)
        let opened = try XCTUnwrap(manager.controllers.last)
        XCTAssertTrue(opened.location.isSame(as: .folder(other)))
        XCTAssertTrue(spin { (first.window?.tabbedWindows ?? []).count == 3 })
        let order = try XCTUnwrap(first.window?.tabbedWindows)
        XCTAssertTrue(order[0] === first.window)
        XCTAssertTrue(order[1] === opened.window)
        XCTAssertTrue(order[2] === second.window)

        XCTAssertFalse(first.isDualPane)
        let key = try XCTUnwrap(first.window?.tabGroup?.selectedWindow)
        let host = try XCTUnwrap(key.windowController as? BrowserWindowController)
        XCTAssertTrue(spin { TabBarLayout.tabs(in: key).count == 3 })
        let now = TabBarLayout.tabs(in: key)
        XCTAssertTrue(host.handleTabDoubleClick(at: NSPoint(x: now[0].frame.midX, y: now[0].frame.midY)))
        XCTAssertTrue(first.isDualPane)
        XCTAssertFalse(host.handleTabDoubleClick(at: NSPoint(x: now[0].frame.midX, y: 20)))
    }

    private func makeVisor(_ manager: BrowserWindowManager, dir: URL) -> VisorController {
        let hotKey = GlobalHotKey(defaults: BrowserDefaults.store, id: 77, comboDefaultsKey: "test.visorCombo", enabledDefaultsKey: "test.visorEnabled", defaultCombo: .visorDefault)
        let visor = VisorController(manager: manager, hotKey: hotKey)
        visor.animationDuration = 0
        visor.initialLocation = { .folder(dir) }
        visor.screenProvider = { VisorController.Screen(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: NSRect(x: 0, y: 70, width: 1600, height: 900)) }
        visor.activate = {}
        visor.frontmostApplication = { nil }
        visor.reduceMotion = { false }
        return visor
    }

    func testVisorLayout() {
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let visible = NSRect(x: 0, y: 70, width: 1600, height: 900)
        XCTAssertEqual(VisorLayout.frame(screenFrame: screen, visibleFrame: visible, storedHeight: nil, aboveDock: false), NSRect(x: 0, y: 70, width: 1600, height: 405))
        XCTAssertEqual(VisorLayout.frame(screenFrame: screen, visibleFrame: visible, storedHeight: 500, aboveDock: true), NSRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(VisorLayout.frame(screenFrame: screen, visibleFrame: visible, storedHeight: 5000, aboveDock: true).height, 970)
        XCTAssertEqual(VisorLayout.frame(screenFrame: screen, visibleFrame: visible, storedHeight: 10, aboveDock: false).height, VisorLayout.minHeight)
        let side = NSRect(x: 80, y: 0, width: 1520, height: 970)
        XCTAssertEqual(VisorLayout.frame(screenFrame: screen, visibleFrame: side, storedHeight: 300, aboveDock: false), NSRect(x: 80, y: 0, width: 1520, height: 300))
        XCTAssertEqual(VisorLayout.hiddenFrame(for: NSRect(x: 0, y: 70, width: 1600, height: 405), screenFrame: screen), NSRect(x: 0, y: -405, width: 1600, height: 405))
        XCTAssertEqual(VisorLayout.level(aboveDock: false), .normal)
        XCTAssertGreaterThan(VisorLayout.level(aboveDock: true).rawValue, Int(CGWindowLevelForKey(.dockWindow)))
        XCTAssertTrue(VisorLayout.collectionBehavior(allSpaces: true).contains(.canJoinAllSpaces))
        XCTAssertFalse(VisorLayout.collectionBehavior(allSpaces: false).contains(.canJoinAllSpaces))
    }

    func testVisorShowsDocksHidesAndKeepsItsTabs() throws {
        let dir = try makeTree()
        let sub = dir.appendingPathComponent("Sub")
        let manager = BrowserWindowManager(registries: BrowserRegistries())
        defer { for c in manager.controllers { c.close() } }
        let visor = makeVisor(manager, dir: dir)
        let shown = NSRect(x: 0, y: 70, width: 1600, height: 405)

        XCTAssertFalse(visor.isShown)
        visor.toggle()
        XCTAssertTrue(visor.isShown)
        XCTAssertEqual(manager.controllers.count, 1)
        let wc = try XCTUnwrap(manager.controllers.first)
        XCTAssertTrue(wc.isVisor)
        XCTAssertTrue(wc.location.isSame(as: .folder(dir)))
        let window = try XCTUnwrap(wc.window)
        XCTAssertEqual(window.frame, shown)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(window.tabbingIdentifier, VisorLayout.tabbingIdentifier)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(window.level, .normal)
        XCTAssertNotNil(wc.visorPinButton)

        XCTAssertTrue(manager.isEmpty)
        XCTAssertNil(manager.activeController)
        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.openFoldersInTabs)
        let normal = manager.open(at: .folder(sub))
        XCTAssertFalse(normal.isVisor)
        XCTAssertFalse(window.tabbedWindows?.contains { $0 === normal.window } ?? false)
        XCTAssertTrue(manager.activeController === normal)
        XCTAssertNotEqual(normal.window?.tabbingIdentifier, VisorLayout.tabbingIdentifier)

        let tab = manager.openTab(at: .folder(sub), nextTo: wc)
        XCTAssertTrue(tab.isVisor)
        XCTAssertTrue(spin { (window.tabbedWindows ?? []).count == 2 })
        XCTAssertEqual(visor.controllers.count, 2)

        visor.hide()
        XCTAssertFalse(visor.isShown)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(tab.window?.isVisible ?? true)
        XCTAssertEqual(manager.controllers.count, 3)

        visor.show()
        XCTAssertTrue(visor.isShown)
        XCTAssertTrue(spin { (window.tabbedWindows ?? []).count == 2 })
        XCTAssertTrue(window.tabbedWindows?[0] === window)
        XCTAssertTrue(window.tabbedWindows?[1] === tab.window)
        XCTAssertEqual(window.tabGroup?.selectedWindow?.frame, shown)
        XCTAssertTrue(window.tabGroup?.selectedWindow === tab.window)

        tab.close()
        XCTAssertTrue(spin { visor.controllers.count == 1 })
        XCTAssertTrue(visor.isShown)
        wc.close()
        XCTAssertTrue(spin { visor.controllers.isEmpty })
        XCTAssertFalse(visor.isShown)
        visor.show()
        XCTAssertEqual(visor.controllers.count, 1)
        XCTAssertTrue(visor.isShown)
    }

    func testVisorHeightPinAndSettings() throws {
        let dir = try makeTree()
        let manager = BrowserWindowManager(registries: BrowserRegistries())
        defer { for c in manager.controllers { c.close() } }
        let visor = makeVisor(manager, dir: dir)
        visor.install()
        defer { visor.uninstall() }
        visor.show()
        let wc = try XCTUnwrap(visor.controllers.first)
        let window = try XCTUnwrap(wc.window)

        XCTAssertEqual(wc.windowWillResize(window, to: NSSize(width: 900, height: 600)), NSSize(width: 1600, height: 600))
        XCTAssertEqual(wc.windowWillResize(window, to: NSSize(width: 900, height: 50)).height, VisorLayout.minHeight)
        XCTAssertEqual(wc.windowWillResize(window, to: NSSize(width: 900, height: 5000)).height, 900)
        window.setFrame(NSRect(x: 0, y: 200, width: 1600, height: 520), display: true)
        wc.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        XCTAssertEqual(VisorSettings.height, 520)
        XCTAssertEqual(window.frame, NSRect(x: 0, y: 70, width: 1600, height: 520))

        BrowserDefaults.store.set(true, forKey: VisorSettings.aboveDockKey)
        XCTAssertTrue(spin { window.frame == NSRect(x: 0, y: 0, width: 1600, height: 520) })
        XCTAssertEqual(window.level, VisorLayout.level(aboveDock: true))
        let other = manager.openWindow(at: .folder(dir))
        let otherWindow = try XCTUnwrap(other.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindow)
        XCTAssertTrue(spin { visor.raisedWindows.contains { $0 === otherWindow } })
        XCTAssertGreaterThan(otherWindow.level.rawValue, window.level.rawValue)
        BrowserDefaults.store.set(false, forKey: VisorSettings.aboveDockKey)
        XCTAssertTrue(spin { window.level == .normal && otherWindow.level == .normal })
        XCTAssertTrue(visor.raisedWindows.isEmpty)
        BrowserDefaults.store.set(false, forKey: VisorSettings.allSpacesKey)
        XCTAssertTrue(spin { !window.collectionBehavior.contains(.canJoinAllSpaces) })

        XCTAssertFalse(visor.isPinned)
        wc.toggleVisorPin(nil)
        XCTAssertTrue(visor.isPinned)
        XCTAssertEqual(wc.visorPinButton?.accessibilityValue() as? String, "on")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        spin(0.1)
        XCTAssertTrue(visor.isShown)
        visor.togglePinned()
        XCTAssertEqual(wc.visorPinButton?.accessibilityValue() as? String, "off")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(spin { !visor.isShown })
        XCTAssertFalse(window.isVisible)

        let entries = wc.registries.commands.paletteEntries(query: "visor", context: BrowserContext(controller: wc)).map(\.title)
        XCTAssertTrue(entries.contains("Toggle Visor"))
        XCTAssertTrue(entries.contains("Keep Visor Open"))
    }
}
