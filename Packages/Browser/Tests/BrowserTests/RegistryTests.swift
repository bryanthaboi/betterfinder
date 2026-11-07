import AppKit
import XCTest
import FSCore
import FileOps
import Theming
@testable import Browser

@MainActor
class RegistryTestCase: XCTestCase {
    var savedStore: UserDefaults!
    var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suiteName = "bf-registry-tests-\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        BrowserDefaults.store = savedStore
        try await super.tearDown()
    }

    func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func makeTree(files: [String] = (0..<8).map { "file-\($0).txt" }) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-reg-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for f in files { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data("x".utf8)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func makeWindow(_ dir: URL, registries: BrowserRegistries) -> BrowserWindowController {
        let wc = BrowserWindowController(location: .folder(dir), registries: registries)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    func toolbarIDs(_ wc: BrowserWindowController) -> [String] {
        wc.window?.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
    }
}

struct EchoColumnProvider: ColumnProvider {
    func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue] {
        var out: [URL: ColumnValue] = [:]
        for i in items { out[i.url] = .number(Double(i.name.count)) }
        return out
    }
}

final class ProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [Int] = []
    private var _cancelled = 0
    private var _started = 0
    var batches: [Int] { lock.lock(); defer { lock.unlock() }; return _batches }
    var cancelled: Int { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var started: Int { lock.lock(); defer { lock.unlock() }; return _started }
    func began(_ n: Int) { lock.lock(); _batches.append(n); _started += 1; lock.unlock() }
    func wasCancelled() { lock.lock(); _cancelled += 1; lock.unlock() }
}

struct SlowColumnProvider: ColumnProvider {
    let log: ProviderLog
    let delay: UInt64

    func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue] {
        log.began(items.count)
        do {
            try await Task.sleep(nanoseconds: delay)
        } catch {
            log.wasCancelled()
            throw error
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.url, ColumnValue.string("v")) })
    }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

struct StubLocationProvider: LocationProvider {
    let providerID: String
    var capabilities: LocationCapabilities { [.list, .read] }

    func list(_ location: ProvidedLocation, context: LocationContext) async throws -> [ProvidedItem] {
        if location.id == "/" {
            return [
                ProvidedItem(id: "docs", name: "docs", isContainer: true, child: ProvidedLocation(providerID: providerID, id: "/docs", title: "docs")),
                ProvidedItem(id: "readme", name: "readme.md", size: 12),
            ]
        }
        return [ProvidedItem(id: "a", name: "a.txt", size: 1)]
    }

    func parent(of location: ProvidedLocation) -> ProvidedLocation? {
        location.id == "/" ? nil : ProvidedLocation(providerID: providerID, id: "/", title: "remote")
    }
}

final class RegistryCoreTests: RegistryTestCase {
    func testBatchRegisterIsTransactionalAndTokensRemove() {
        let reg = ToolbarRegistry()
        var changes = 0
        reg.addObserver(self) { changes += 1 }
        let good = ToolbarItemSpec(id: "a", title: "A", action: { _ in })
        let dup = ToolbarItemSpec(id: "b", title: "B", action: { _ in })
        XCTAssertThrowsError(try reg.registerBatch([good, dup, dup], owner: "o"))
        XCTAssertTrue(reg.entries.isEmpty)
        XCTAssertEqual(changes, 0)
        let token = try? reg.registerBatch([good, dup], owner: "o")
        XCTAssertEqual(reg.entries.count, 2)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(reg.entries.map(\.qualifiedID).sorted(), ["o/a", "o/b"])
        token?.cancel()
        XCTAssertTrue(reg.entries.isEmpty)
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(token?.isActive ?? true)
    }

    func testReplaceAllExchangesOwnerRegistrationsAtomically() throws {
        let reg = ToolbarRegistry()
        _ = try reg.registerBatch([ToolbarItemSpec(id: "a", title: "A", action: { _ in }), ToolbarItemSpec(id: "b", title: "B", action: { _ in })], owner: "o")
        _ = reg.register(ToolbarItemSpec(id: "keep", title: "Keep", action: { _ in }), owner: "other")
        var changes = 0
        reg.addObserver(self) { changes += 1 }
        XCTAssertThrowsError(try reg.replaceAll([ToolbarItemSpec(id: "", title: "Bad", action: { _ in })], owner: "o"))
        XCTAssertEqual(reg.entries(owner: "o").count, 2)
        _ = try reg.replaceAll([ToolbarItemSpec(id: "c", title: "C", action: { _ in })], owner: "o")
        XCTAssertEqual(reg.entries(owner: "o").map(\.qualifiedID), ["o/c"])
        XCTAssertEqual(reg.entries(owner: "other").count, 1)
        XCTAssertEqual(changes, 1)
        reg.removeAll(owner: "o")
        XCTAssertEqual(reg.entries.map(\.qualifiedID), ["other/keep"])
    }

    func testOwnersCannotCollideAndIdsCannotEmbedSlash() {
        let reg = CommandRegistry()
        _ = reg.register(CommandSpec(id: "x", title: "X", handler: { _ in }), owner: "a")
        _ = reg.register(CommandSpec(id: "x", title: "X", handler: { _ in }), owner: "b")
        XCTAssertEqual(Set(reg.entries.map(\.qualifiedID)), ["a/x", "b/x"])
        let token = reg.register(CommandSpec(id: "a/x", title: "Spoof", handler: { _ in }), owner: "b")
        XCTAssertFalse(token.isActive && reg.entry("a/x")?.owner == "b")
        XCTAssertEqual(reg.entry("a/x")?.owner, "a")
    }

    func testHiddenAndOrderPersistAcrossInstances() throws {
        let reg = ToolbarRegistry()
        _ = try reg.registerBatch([
            ToolbarItemSpec(id: "a", title: "A", action: { _ in }),
            ToolbarItemSpec(id: "b", title: "B", action: { _ in }),
            ToolbarItemSpec(id: "c", title: "C", action: { _ in }),
        ], owner: "o")
        XCTAssertEqual(reg.visibleEntries.map(\.qualifiedID), ["o/a", "o/b", "o/c"])
        reg.setHidden("o/b", true)
        reg.move("o/c", toIndex: 0)
        let fresh = ToolbarRegistry()
        _ = try fresh.registerBatch([
            ToolbarItemSpec(id: "a", title: "A", action: { _ in }),
            ToolbarItemSpec(id: "b", title: "B", action: { _ in }),
            ToolbarItemSpec(id: "c", title: "C", action: { _ in }),
        ], owner: "o")
        XCTAssertEqual(fresh.visibleEntries.map(\.qualifiedID), ["o/c", "o/a"])
        XCTAssertTrue(fresh.isHidden("o/b"))
        fresh.setHidden("o/b", false)
        XCTAssertEqual(fresh.visibleEntries.map(\.qualifiedID), ["o/c", "o/a", "o/b"])
        fresh.resetPreferences()
        XCTAssertEqual(fresh.visibleEntries.map(\.qualifiedID), ["o/a", "o/b", "o/c"])
    }

    func testHiddenByDefaultColumnNeedsExplicitShow() {
        let reg = ColumnRegistry()
        _ = reg.register(ColumnSpec(id: "c", title: "C", defaultVisible: false, provider: EchoColumnProvider()), owner: "o")
        XCTAssertTrue(reg.isHidden("o/c"))
        reg.setHidden("o/c", false)
        XCTAssertFalse(reg.isHidden("o/c"))
    }
}

final class RegistryLiveWindowTests: RegistryTestCase {
    func testToolbarItemsAppearDisappearAndDogfoodDualPane() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let ids = toolbarIDs(wc)
        XCTAssertTrue(ids.contains("dualPane"))
        let viewIndex = try XCTUnwrap(ids.firstIndex(of: "viewMode"))
        XCTAssertEqual(ids.firstIndex(of: "dualPane"), viewIndex + 1)

        var ran = 0
        let token = regs.toolbar.register(ToolbarItemSpec(id: "hello", title: "Hello", symbolName: "star", action: { _ in ran += 1 }), owner: "tester")
        let id = "bf.contrib.tester/hello"
        XCTAssertTrue(toolbarIDs(wc).contains(id))
        XCTAssertLessThan(try XCTUnwrap(toolbarIDs(wc).firstIndex(of: id)), try XCTUnwrap(toolbarIDs(wc).firstIndex(of: "search")))
        let item = try XCTUnwrap(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == id })
        XCTAssertEqual(item.label, "Hello")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(ran, 1)

        regs.toolbar.setHidden("tester/hello", true)
        XCTAssertFalse(toolbarIDs(wc).contains(id))
        regs.toolbar.setHidden("tester/hello", false)
        XCTAssertTrue(toolbarIDs(wc).contains(id))
        token.cancel()
        XCTAssertFalse(toolbarIDs(wc).contains(id))

        _ = try regs.toolbar.registerBatch([
            ToolbarItemSpec(id: "one", title: "One", placement: .before("viewMode"), action: { _ in }),
            ToolbarItemSpec(id: "two", title: "Two", placement: .end, action: { _ in }),
        ], owner: "batch")
        var now = toolbarIDs(wc)
        XCTAssertEqual(now.firstIndex(of: "bf.contrib.batch/one").map { now[$0 + 1] }, "viewMode")
        XCTAssertTrue(now.contains("bf.contrib.batch/two"))
        regs.toolbar.removeAll(owner: "batch")
        now = toolbarIDs(wc)
        XCTAssertFalse(now.contains("bf.contrib.batch/one") || now.contains("bf.contrib.batch/two"))

        let dual = try XCTUnwrap(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "dualPane" })
        XCTAssertEqual(dual.label, "Dual Pane")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(dual.action), to: dual.target, from: dual))
        XCTAssertTrue(wc.isDualPane)
        XCTAssertEqual(dual.label, "Single Pane")
        wc.toggleDualPane(nil)
        XCTAssertEqual(dual.label, "Dual Pane")
    }

    func testMenuToolbarItemBuildsFromRegistry() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        var picked = ""
        regs.toolbar.register(ToolbarItemSpec(id: "menu", title: "Menu", symbolName: "ellipsis", kind: .menu { _ in
            [BrowserMenuEntry(id: "x", title: "Pick X", action: { _ in picked = "x" }), .separator(), BrowserMenuEntry(id: "y", title: "Pick Y", action: { _ in picked = "y" })]
        }), owner: "tester")
        let item = try XCTUnwrap(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "bf.contrib.tester/menu" } as? NSMenuToolbarItem)
        let menu = try XCTUnwrap(item.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Pick X", "", "Pick Y"])
        let target = try XCTUnwrap(menu.items[2].target)
        _ = NSApp.sendAction(try XCTUnwrap(menu.items[2].action), to: target, from: menu.items[2])
        XCTAssertEqual(picked, "y")
    }

    func testSidebarSectionsRebuildLive() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        wc.sidebarController.loadViewIfNeeded()
        XCTAssertFalse(wc.sidebarController.sectionTitles.contains("Pinned"))
        let spec = SidebarSectionSpec(id: "pinned", title: "Pinned", entries: [SidebarEntrySpec(id: "a", title: "Alpha", symbolName: "star", action: .navigate(.folder(dir)))], placement: .after("Favorites"))
        let token = regs.sidebar.register(spec, owner: "tester")
        let titles = wc.sidebarController.sectionTitles
        XCTAssertEqual(titles.firstIndex(of: "Pinned"), (titles.firstIndex(of: "Favorites") ?? -2) + 1)
        XCTAssertEqual(wc.sidebarController.entryTitles(inSection: "Pinned"), ["Alpha"])
        regs.sidebar.register(SidebarSectionSpec(id: "pinned", title: "Pinned", provider: { [SidebarEntrySpec(id: "b", title: "Beta", action: .command("x")), SidebarEntrySpec(id: "c", title: "Gamma", action: .command("y"))] }), owner: "tester")
        XCTAssertEqual(wc.sidebarController.entryTitles(inSection: "Pinned"), ["Beta", "Gamma"])
        regs.sidebar.setHidden("tester/pinned", true)
        XCTAssertFalse(wc.sidebarController.sectionTitles.contains("Pinned"))
        regs.sidebar.setHidden("tester/pinned", false)
        XCTAssertTrue(wc.sidebarController.sectionTitles.contains("Pinned"))
        token.cancel()
        regs.sidebar.removeAll(owner: "tester")
        XCTAssertFalse(wc.sidebarController.sectionTitles.contains("Pinned"))
    }

    func testContextMenuBuilderPicksUpContributions() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 9 })
        func titles(_ m: NSMenu) -> [String] { m.items.map(\.title) }
        XCTAssertFalse(titles(ContextMenuBuilder.menu(for: pane)).contains("Do Thing"))
        var ran: [String] = []
        let token = regs.contextMenu.register(ContextMenuSpec(id: "bg", targets: [.background], entries: [BrowserMenuEntry(id: "bg", title: "Do Thing", action: { _ in ran.append("bg") })]), owner: "tester")
        let bg = ContextMenuBuilder.menu(for: pane)
        XCTAssertTrue(titles(bg).contains("Do Thing"))
        let bgItem = try XCTUnwrap(bg.items.first { $0.title == "Do Thing" })
        _ = NSApp.sendAction(try XCTUnwrap(bgItem.action), to: bgItem.target, from: bgItem)
        XCTAssertEqual(ran, ["bg"])
        token.cancel()
        XCTAssertFalse(titles(ContextMenuBuilder.menu(for: pane)).contains("Do Thing"))

        regs.contextMenu.register(ContextMenuSpec(id: "txt", targets: [.selection], maxSelection: 1, contentTypes: ["public.plain-text"], builder: { ctx in
            [BrowserMenuEntry(id: "t", title: "Count \(ctx.selection.count)", action: { _ in })]
        }), owner: "tester")
        regs.contextMenu.register(ContextMenuSpec(id: "folder", targets: [.selection], foldersOnly: true, entries: [BrowserMenuEntry(id: "f", title: "Folder Only", action: { _ in })]), owner: "tester")
        pane.content.select([dir.appendingPathComponent("file-1.txt")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.count == 1 })
        var t = titles(ContextMenuBuilder.menu(for: pane))
        XCTAssertTrue(t.contains("Count 1"))
        XCTAssertFalse(t.contains("Folder Only"))
        pane.content.select([dir.appendingPathComponent("Folder")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.first?.lastPathComponent == "Folder" })
        t = titles(ContextMenuBuilder.menu(for: pane))
        XCTAssertFalse(t.contains("Count 1"))
        XCTAssertTrue(t.contains("Folder Only"))
    }

    func testColumnsCreateFetchHideAndSortLive() throws {
        let regs = BrowserRegistries()
        let names = ["a.txt", "bbbbbb.txt", "cc.txt", "dddd.txt"]
        let dir = try makeTree(files: names)
        BrowserDefaults.viewMode = .list
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        let list = try XCTUnwrap(pane.content as? ListViewController)
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 5 })
        let qid = "tester/len"
        let id = ColumnRegistry.tableIdentifier(for: qid)
        XCTAssertNil(list.outline.tableColumn(withIdentifier: .init(id)))
        let token = regs.columns.register(ColumnSpec(id: "len", title: "Length", width: 80, alignment: .trailing, provider: EchoColumnProvider()), owner: "tester")
        let column = try XCTUnwrap(list.outline.tableColumn(withIdentifier: .init(id)))
        XCTAssertEqual(column.title, "Length")
        XCTAssertFalse(column.isHidden)
        XCTAssertTrue(spin { names.allSatisfy { n in pane.model.items.first { $0.name == n }.flatMap { list.columnStore.cachedValue(column: qid, for: $0) } != nil } })
        let row = list.outline.row(forItem: nil)
        _ = row
        let item = try XCTUnwrap(pane.model.items.first { $0.name == "bbbbbb.txt" })
        XCTAssertEqual(list.columnStore.cachedValue(column: qid, for: item), .number(10))

        list.outline.sortDescriptors = [NSSortDescriptor(key: id, ascending: false)]
        XCTAssertEqual(BrowserDefaults.sort.key, .custom)
        XCTAssertEqual(BrowserDefaults.sort.customColumn, qid)
        XCTAssertTrue(spin { pane.model.items.first(where: { !$0.isBrowsableFolder })?.name == "bbbbbb.txt" })
        list.outline.sortDescriptors = [NSSortDescriptor(key: id, ascending: true)]
        XCTAssertTrue(spin { pane.model.items.first(where: { !$0.isBrowsableFolder })?.name == "a.txt" })

        regs.columns.setHidden(qid, true)
        XCTAssertTrue(list.outline.tableColumn(withIdentifier: .init(id))?.isHidden ?? false)
        regs.columns.setHidden(qid, false)
        XCTAssertFalse(list.outline.tableColumn(withIdentifier: .init(id))?.isHidden ?? true)

        token.cancel()
        XCTAssertNil(list.outline.tableColumn(withIdentifier: .init(id)))
        XCTAssertEqual(BrowserDefaults.sort.key, .name)
        XCTAssertNil(BrowserDefaults.sort.customColumn)
    }

    func testStatusBarSegmentsLiveAndBuiltInSizeSegment() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 9 })
        XCTAssertTrue(pane.statusBar.text.contains("9 items"), pane.statusBar.text)
        XCTAssertEqual(pane.statusBar.segmentIDs, ["betterfinder/size"])
        let spec = StatusBarSegmentSpec(id: "count", alignment: .leading, accessibilityLabel: "Counter", text: { "n=\($0.itemCount)" })
        let token = regs.statusBar.register(spec, owner: "tester")
        let view = try XCTUnwrap(pane.statusBar.segmentView("tester/count"))
        XCTAssertEqual(view.label.stringValue, "n=9")
        XCTAssertEqual(view.label.accessibilityLabel(), "Counter")
        pane.content.select([dir.appendingPathComponent("file-1.txt")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.count == 1 })
        XCTAssertTrue(pane.statusBar.text.contains("file-1.txt"), pane.statusBar.text)
        regs.statusBar.register(StatusBarSegmentSpec(id: "count", alignment: .trailing, accessibilityLabel: "Counter", text: { _ in nil }), owner: "tester")
        XCTAssertTrue(pane.statusBar.segmentView("tester/count")?.isHidden ?? false)
        token.cancel()
        regs.statusBar.removeAll(owner: "tester")
        XCTAssertNil(pane.statusBar.segmentView("tester/count"))
        XCTAssertEqual(pane.statusBar.segmentIDs, ["betterfinder/size"])
    }

    func testBuiltInsAreRegisteredThroughRegistries() {
        let regs = BrowserRegistries()
        XCTAssertNotNil(regs.toolbar.entry("betterfinder/dualPane"))
        XCTAssertNotNil(regs.statusBar.entry("betterfinder/size"))
        XCTAssertNotNil(regs.commands.entry("betterfinder/go.up"))
        regs.toolbar.setHidden("betterfinder/dualPane", true)
        XCTAssertTrue(regs.toolbar.visibleEntries.isEmpty)
    }
}

final class RegistryPanelTests: RegistryTestCase {
    private func node(_ text: String) -> ModUINode {
        .stack(id: "root", [.label(id: "l", text), .button(id: "b", title: "Go")])
    }

    func testDockedPanelOpensCollapsesAndRestoresAcrossWindows() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        let qid = "tester/dock"
        regs.panels.register(PanelSpec(id: "dock", title: "Dock", edge: .right, presentation: .docked, defaultSize: 260, content: .ui(node("one"))), owner: "tester")
        let host = try XCTUnwrap(wc.panelHost)
        let inst = try XCTUnwrap(host.instances[qid])
        XCTAssertTrue(try XCTUnwrap(inst.item).isCollapsed)
        XCTAssertFalse(wc.isPanelOpen(qid))
        wc.setPanel(qid, open: true, animated: false)
        XCTAssertFalse(try XCTUnwrap(inst.item).isCollapsed)
        XCTAssertTrue(wc.isPanelOpen(qid))
        XCTAssertTrue(PanelStateStore.isOpen(qid, default: false))
        XCTAssertEqual(inst.vc.renderedUI, node("one"))
        regs.panels.updateContent(node("two"), for: qid)
        XCTAssertEqual(inst.vc.renderedUI, node("two"))
        wc.togglePanel(qid)
        XCTAssertTrue(try XCTUnwrap(inst.item).isCollapsed)
        XCTAssertFalse(PanelStateStore.isOpen(qid, default: true))
        wc.togglePanel(qid)
        wc.close()

        let wc2 = makeWindow(dir, registries: regs)
        defer { wc2.close() }
        XCTAssertTrue(wc2.isPanelOpen(qid))
        XCTAssertFalse(try XCTUnwrap(wc2.panelHost?.instances[qid]?.item).isCollapsed)
        regs.panels.removeAll(owner: "tester")
        XCTAssertNil(wc2.panelHost?.instances[qid])
    }

    func testSlideOutPanelsPersistOpenStateAndSizeAndAreExclusivePerEdge() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        let a = "tester/a", b = "tester/b"
        regs.panels.register(PanelSpec(id: "a", title: "A", edge: .left, presentation: .slideOut, defaultSize: 240, content: .ui(node("a"))), owner: "tester")
        regs.panels.register(PanelSpec(id: "b", title: "B", edge: .left, presentation: .slideOut, content: .ui(node("b"))), owner: "tester")
        regs.panels.register(PanelSpec(id: "c", title: "C", edge: .bottom, presentation: .slideOut, defaultOpen: true, content: .ui(node("c"))), owner: "tester")
        let host = try XCTUnwrap(wc.panelHost)
        XCTAssertEqual(host.instances[a]?.overlay?.isHidden, true)
        XCTAssertEqual(host.instances["tester/c"]?.overlay?.isHidden, false)
        wc.setPanel(a, open: true, animated: false)
        XCTAssertEqual(host.instances[a]?.overlay?.isHidden, false)
        XCTAssertEqual(host.instances[a]?.overlay?.offsetConstraint.constant, 0)
        wc.setPanel(b, open: true, animated: false)
        XCTAssertEqual(host.instances[a]?.overlay?.isHidden, true)
        XCTAssertFalse(wc.isPanelOpen(a))
        XCTAssertTrue(wc.isPanelOpen(b))
        let handle = try XCTUnwrap(host.instances[b]?.overlay?.handle)
        handle.onDrag?(60)
        handle.onEnd?()
        XCTAssertEqual(PanelStateStore.size(b, default: 0), 340)
        wc.setPanel(b, open: false, animated: true)
        XCTAssertTrue(spin { host.instances[b]?.overlay?.isHidden == true })
        XCTAssertFalse(PanelStateStore.isOpen(b, default: true))
        wc.setPanel(b, open: true, animated: true)
        XCTAssertEqual(host.instances[b]?.overlay?.isHidden, false)
        wc.close()

        let wc2 = makeWindow(dir, registries: regs)
        defer { wc2.close() }
        XCTAssertTrue(wc2.isPanelOpen(b))
        XCTAssertFalse(wc2.isPanelOpen(a))
        XCTAssertEqual(wc2.panelHost?.instances[b]?.overlay?.sizeConstraint.constant, 340)
        XCTAssertEqual(wc2.panelHost?.instances[b]?.overlay?.isHidden, false)
    }

    func testPanelCloseButtonAndCustomViewContent() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        let marker = NSView()
        marker.setAccessibilityLabel("marker")
        regs.panels.register(PanelSpec(id: "v", title: "Viewy", edge: .bottom, defaultOpen: true, content: .view({ marker })), owner: "tester")
        let inst = try XCTUnwrap(wc.panelHost?.instances["tester/v"])
        XCTAssertTrue(marker.isDescendant(of: inst.vc.view))
        XCTAssertEqual(inst.vc.view.accessibilityLabel(), "Viewy panel")
        XCTAssertTrue(wc.isPanelOpen("tester/v"))
        let close = try XCTUnwrap(descendantButtons(inst.vc.view).first { $0.accessibilityLabel() == "Close Viewy panel" })
        close.performClick(nil)
        XCTAssertFalse(wc.isPanelOpen("tester/v"))
    }

    private func descendantButtons(_ view: NSView) -> [NSButton] {
        var out: [NSButton] = []
        for v in view.subviews {
            if let b = v as? NSButton { out.append(b) }
            out += descendantButtons(v)
        }
        return out
    }
}
