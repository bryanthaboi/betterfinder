import AppKit
import XCTest
import FSCore
import FileOps
import Theming
@testable import Browser

final class ColumnProviderTests: RegistryTestCase {
    private func items(_ n: Int) -> [FileItem] {
        (0..<n).map { FileItem(url: URL(fileURLWithPath: "/tmp/bf-col/f\($0).txt"), name: "f\($0).txt", isDirectory: false) }
    }

    func testBatchesAreCappedAt128AndResultsCached() throws {
        let store = ColumnValueStore()
        let log = ProviderLog()
        let provider = SlowColumnProvider(log: log, delay: 20_000_000)
        var updated = Set<String>()
        store.onUpdate = { _, keys in updated.formUnion(keys) }
        let all = items(300)
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "1", timeout: 5), items: all)
        XCTAssertTrue(spin { updated.count == 300 })
        let batches = log.batches
        XCTAssertEqual(batches.sorted(), [44, 128, 128])
        XCTAssertEqual(store.largestBatch, 128)
        XCTAssertEqual(store.cachedValue(column: "o/c", for: all[0]), .string("v"))
        let before = log.started
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "1", timeout: 5), items: all)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let after = log.started
        XCTAssertEqual(before, after)
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "2", timeout: 5), items: Array(all.prefix(10)))
        XCTAssertTrue(spin { store.cachedValue(column: "o/c", for: all[0]) != nil && store.inflightChunkCount == 0 })
        let rev2 = log.started
        XCTAssertEqual(rev2, after + 1)
        XCTAssertNil(store.cachedValue(column: "o/c", for: all[100]))
    }

    func testChangedItemRevisionInvalidatesCache() throws {
        let store = ColumnValueStore()
        let log = ProviderLog()
        let provider = SlowColumnProvider(log: log, delay: 1_000_000)
        var item = items(1)[0]
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "1", timeout: 5), items: [item])
        XCTAssertTrue(spin { store.cachedValue(column: "o/c", for: item) != nil })
        item.logicalSize = 42
        XCTAssertNil(store.cachedValue(column: "o/c", for: item))
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "1", timeout: 5), items: [item])
        XCTAssertTrue(spin { store.cachedValue(column: "o/c", for: item) != nil })
        let started = log.started
        XCTAssertEqual(started, 2)
    }

    func testScrolledAwayWorkIsCancelledAndMainThreadStaysResponsive() throws {
        let store = ColumnValueStore()
        store.maxConcurrent = 1
        let log = ProviderLog()
        let provider = SlowColumnProvider(log: log, delay: 3_000_000_000)
        let first = items(40)
        let second = Array(items(200).suffix(40))
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "1", timeout: 30), items: first)
        XCTAssertTrue(spin { store.inflightChunkCount == 1 && store.providerCallCount == 1 })
        let responsive = expectation(description: "main queue responds while provider runs")
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 0.25)
        XCTAssertEqual(store.inflightChunkCount, 1)
        store.request(.init(qualifiedID: "o/c", provider: provider, specRevision: "1", timeout: 30), items: second)
        XCTAssertEqual(store.cancelledChunks, 1)
        XCTAssertTrue(spin { log.cancelled >= 1 })
        XCTAssertEqual(log.cancelled, 1)
        XCTAssertNil(store.cachedValue(column: "o/c", for: first[0]))
        store.cancelAll()
        XCTAssertEqual(store.inflightChunkCount, 0)
    }

    func testProviderTimeoutAndFailureDoNotWedgeTheStore() throws {
        struct Boom: ColumnProvider {
            func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue] { throw CocoaError(.fileReadUnknown) }
        }
        let store = ColumnValueStore()
        let list = items(3)
        store.request(.init(qualifiedID: "o/boom", provider: Boom(), specRevision: "1", timeout: 5), items: list)
        XCTAssertTrue(spin { store.cachedValue(column: "o/boom", for: list[0]) == ColumnValue.none })
        XCTAssertNotNil(store.lastError)
        let log = ProviderLog()
        store.request(.init(qualifiedID: "o/slow", provider: SlowColumnProvider(log: log, delay: 5_000_000_000), specRevision: "1", timeout: 0.1), items: list)
        XCTAssertTrue(spin(until: { store.cachedValue(column: "o/slow", for: list[0]) == ColumnValue.none }, timeout: 3))
        XCTAssertEqual(store.lastError, ColumnProviderTimeout().errorDescription)
    }
}

final class CommandAndKeyBindingTests: RegistryTestCase {
    func testPaletteListsBuiltInsAndContributionsAndRuns() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        var ran = 0
        regs.commands.register(CommandSpec(id: "zip", title: "Zip Selection", category: "Archive", handler: { _ in ran += 1 }), owner: "alice")
        regs.commands.register(CommandSpec(id: "never", title: "Never Enabled", isEnabled: { _ in false }, handler: { _ in ran += 100 }), owner: "alice")
        regs.commands.register(CommandSpec(id: "hidden", title: "Hidden Helper", showsInPalette: false, handler: { _ in }), owner: "alice")
        _ = try regs.keyBindings.registerBatch([KeyBindingSpec(id: "zipkey", chord: try XCTUnwrap(KeyChord.parse("ctrl+opt+z")), commandID: "zip")], owner: "alice")
        let model = CommandPaletteModel(registries: regs) { BrowserContext(controller: wc) }
        let titles = model.entries.map(\.title)
        XCTAssertTrue(titles.contains("Back"))
        XCTAssertTrue(titles.contains("Toggle Dual Pane"))
        XCTAssertTrue(titles.contains("Zip Selection"))
        XCTAssertFalse(titles.contains("Hidden Helper"))
        XCTAssertEqual(model.entries.first { $0.title == "Zip Selection" }?.chord, "⌃⌥Z")
        XCTAssertEqual(model.entries.first { $0.title == "Zip Selection" }?.isBuiltIn, false)
        XCTAssertEqual(model.entries.first { $0.title == "Back" }?.isBuiltIn, true)
        XCTAssertEqual(model.entries.first { $0.title == "Back" }?.isEnabled, false)
        XCTAssertEqual(model.entries.first { $0.title == "Never Enabled" }?.isEnabled, false)
        model.query = "zip"
        XCTAssertEqual(model.entries.first?.title, "Zip Selection")
        model.query = "tdp"
        XCTAssertEqual(model.entries.first?.title, "Toggle Dual Pane")
        model.query = "zzzzqq"
        XCTAssertTrue(model.entries.isEmpty)
        model.query = "zip"
        XCTAssertTrue(model.run(try XCTUnwrap(model.entries.first), controller: wc))
        XCTAssertEqual(ran, 1)
        model.query = "never"
        XCTAssertFalse(model.run(try XCTUnwrap(model.entries.first), controller: wc))
        XCTAssertEqual(ran, 1)
        model.query = "dual"
        XCTAssertTrue(model.run(try XCTUnwrap(model.entries.first { $0.qualifiedID == "betterfinder/view.toggleDualPane" }), controller: wc))
        XCTAssertTrue(wc.isDualPane)
        wc.toggleDualPane(nil)
    }

    func testPaletteIncludesPanelToggles() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        regs.panels.register(PanelSpec(id: "term", title: "Terminal", edge: .bottom, content: .ui(.label(id: "l", "hi"))), owner: "alice")
        let model = CommandPaletteModel(registries: regs) { BrowserContext(controller: wc) }
        let entry = try XCTUnwrap(model.entries.first { $0.title == "Toggle Terminal Panel" })
        XCTAssertFalse(wc.isPanelOpen("alice/term"))
        XCTAssertTrue(model.run(entry, controller: wc))
        XCTAssertTrue(wc.isPanelOpen("alice/term"))
    }

    func testPaletteWindowOpensWithEntriesAndAccessibleControls() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        let palette = CommandPaletteController(controller: wc)
        XCTAssertEqual(palette.field.accessibilityLabel(), "Command palette search")
        XCTAssertEqual(palette.table.accessibilityLabel(), "Commands")
        XCTAssertGreaterThan(palette.table.numberOfRows, 10)
        palette.field.stringValue = "refresh"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.field))
        XCTAssertEqual(palette.model.entries.first?.title, "Refresh")
        XCTAssertTrue(BrowserWindow.shortcuts.contains { $0.key == "p" && $0.mods == [.command, .shift] })
    }

    func testKeyBindingConflictsWithBuiltInsMenusAndOtherBindings() throws {
        let regs = BrowserRegistries()
        let menu = NSMenu()
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Edit")
        let item = NSMenuItem(title: "Frobnicate", action: nil, keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.command, .option]
        sub.addItem(item)
        top.submenu = sub
        menu.addItem(top)
        regs.keyBindings.menuProvider = { menu }

        let clash = KeyBindingSpec(id: "clash", chord: KeyChord(key: "d", command: true, shift: true), commandID: "x")
        XCTAssertEqual(regs.keyBindings.detectConflicts(for: clash, owner: "mod").first?.other, .builtIn("toggleDualPane:"))
        let menuClash = KeyBindingSpec(id: "menu", chord: KeyChord(key: "j", command: true, option: true), commandID: "x")
        XCTAssertEqual(regs.keyBindings.detectConflicts(for: menuClash, owner: "mod").first?.other, .builtIn("Edit ▸ Frobnicate"))
        let palette = KeyBindingSpec(id: "pal", chord: KeyChord(key: "p", command: true, shift: true), commandID: "x")
        XCTAssertFalse(regs.keyBindings.detectConflicts(for: palette, owner: "mod").isEmpty)
        let free = KeyBindingSpec(id: "free", chord: KeyChord(key: "z", option: true, control: true), commandID: "x")
        XCTAssertTrue(regs.keyBindings.detectConflicts(for: free, owner: "mod").isEmpty)

        regs.keyBindings.register(clash, owner: "mod")
        regs.keyBindings.register(menuClash, owner: "mod")
        regs.keyBindings.register(free, owner: "mod")
        regs.keyBindings.register(KeyBindingSpec(id: "free2", chord: free.chord, commandID: "y"), owner: "other")
        let byID = Dictionary(grouping: regs.keyBindings.conflicts, by: \.bindingID)
        XCTAssertEqual(Set(byID.keys), ["mod/clash", "mod/menu", "other/free2"])
        XCTAssertEqual(byID["other/free2"]?.first?.other, .contribution("mod/free"))
        XCTAssertFalse(regs.keyBindings.isActive("mod/clash"))
        XCTAssertTrue(regs.keyBindings.isActive("mod/free"))
        XCTAssertNil(regs.keyBindings.binding(for: clash.chord))
        XCTAssertEqual(regs.keyBindings.binding(for: free.chord)?.qualifiedID, "mod/free")
        regs.keyBindings.removeAll(owner: "mod")
        XCTAssertEqual(regs.keyBindings.conflicts.count, 0)
        XCTAssertTrue(regs.keyBindings.isActive("other/free2"))
    }

    func testKeyBindingRejectsUnmodifiedPlainKeysAndParsesChords() throws {
        let reg = KeyBindingRegistry()
        reg.register(KeyBindingSpec(id: "k", chord: KeyChord(key: "a"), commandID: "x"), owner: "o")
        XCTAssertNil(reg.entry("o/k"))
        XCTAssertThrowsError(try reg.registerBatch([KeyBindingSpec(id: "k", chord: KeyChord(key: "a"), commandID: "x")], owner: "o"))
        XCTAssertNotNil(KeyChord.parse("cmd+shift+p"))
        XCTAssertEqual(KeyChord.parse("⌘⇧p"), nil)
        XCTAssertEqual(KeyChord.parse("cmd+opt+j")?.description, "⌥⌘J")
        XCTAssertNotNil(KeyChord.parse("f6"))
        XCTAssertNil(KeyChord.parse("hyper+j"))
    }

    func testBoundKeyDispatchesThroughWindowAndCommandRegistry() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        var ran = 0
        regs.commands.register(CommandSpec(id: "go", title: "Go", handler: { _ in ran += 1 }), owner: "mod")
        regs.keyBindings.register(KeyBindingSpec(id: "key", chord: KeyChord(key: "j", option: true, control: true), commandID: "go"), owner: "mod")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: wc.window?.windowNumber ?? 0, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        XCTAssertTrue(wc.handleKeyBinding(event))
        XCTAssertEqual(ran, 1)
        regs.keyBindings.removeAll(owner: "mod")
        XCTAssertFalse(wc.handleKeyBinding(event))
    }
}

final class LocationAndSearchTests: RegistryTestCase {
    func testProvidedLocationNavigationHistoryUpAndRoutingByProviderIdentity() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading })
        let root = ProvidedLocation(providerID: "mock", id: "/", title: "remote", symbolName: "network")
        let token = regs.locations.register(LocationProviderSpec(id: "mock", title: "Mock", provider: StubLocationProvider(providerID: "mock"), root: root), owner: "tester")
        XCTAssertNil(wc.providedLocation)
        wc.navigate(to: root)
        XCTAssertEqual(wc.providedLocation, root)
        XCTAssertEqual(pane.location, BrowserLocation.folder(dir).normalized)
        XCTAssertEqual(wc.window?.title, "remote")
        XCTAssertFalse(pane.canGoUp)
        let aux = try XCTUnwrap(pane.auxViewController as? PaneAuxViewController)
        XCTAssertTrue(spin {
            if case .table(_, let rows, _)? = aux.currentNode?.kind { return rows.count == 2 }
            return false
        })
        XCTAssertTrue(pane.content.view.isHidden)
        XCTAssertTrue(spin { pane.statusBar.text == "2 items" })

        let child = ProvidedLocation(providerID: "mock", id: "/docs", title: "docs")
        pane.navigate(to: child)
        XCTAssertEqual(pane.providedLocation, child)
        XCTAssertTrue(pane.canGoUp)
        wc.goUp(nil)
        XCTAssertEqual(pane.providedLocation?.id, "/")
        wc.goBack(nil)
        XCTAssertEqual(pane.providedLocation, child)
        wc.goBack(nil)
        XCTAssertEqual(pane.providedLocation, root)
        wc.goBack(nil)
        XCTAssertNil(pane.providedLocation)
        XCTAssertFalse(pane.content.view.isHidden)
        XCTAssertNil(pane.auxViewController)
        wc.goForward(nil)
        XCTAssertEqual(pane.providedLocation, root)
        pane.navigate(to: .folder(dir.appendingPathComponent("Folder")))
        XCTAssertNil(pane.providedLocation)
        XCTAssertEqual(pane.location.url?.lastPathComponent, "Folder")
        XCTAssertEqual(BrowserDestination.provided(root), BrowserDestination.provided(ProvidedLocation(providerID: "mock", id: "/", title: "renamed")))
        token.cancel()
    }

    func testCustomBrowserViewReplacesDefaultAndRemovesLive() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        let root = ProvidedLocation(providerID: "mock", id: "/", title: "remote")
        regs.locations.register(LocationProviderSpec(id: "mock", title: "Mock", provider: StubLocationProvider(providerID: "mock"), root: root), owner: "tester")
        wc.navigate(to: root)
        var aux = try XCTUnwrap(pane.auxViewController as? PaneAuxViewController)
        XCTAssertNil(aux.specID)
        var events: [ModUIEvent] = []
        let token = regs.browserViews.register(BrowserViewSpec(id: "dash", title: "Dash", providerID: "mock", build: { ctx in
            ctx.setContent(.stack(id: "root", [.label(id: "hello", "custom!"), .button(id: "go", title: "Go")]))
            ctx.onEvent = { events.append($0) }
        }), owner: "tester")
        aux = try XCTUnwrap(pane.auxViewController as? PaneAuxViewController)
        XCTAssertEqual(aux.specID, "tester/dash")
        XCTAssertEqual(aux.currentNode?.find("hello"), .label(id: "hello", "custom!"))
        let button = try XCTUnwrap(aux.view.firstDescendant(of: NSButton.self))
        button.performClick(nil)
        XCTAssertEqual(events, [ModUIEvent(nodeID: "go", kind: .press)])
        token.cancel()
        aux = try XCTUnwrap(pane.auxViewController as? PaneAuxViewController)
        XCTAssertNil(aux.specID)
        XCTAssertTrue(spin {
            if case .table? = aux.currentNode?.kind { return true }
            return false
        })
    }

    func testCustomViewCanReplaceLocalLocation() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        regs.browserViews.register(BrowserViewSpec(id: "recents", title: "Recents", matches: { $0 == .local(.recents) }, build: { $0.setContent(.label(id: "l", "my recents")) }), owner: "tester")
        XCTAssertNil(pane.auxViewController)
        pane.navigate(to: .recents)
        XCTAssertNotNil(pane.auxViewController)
        pane.navigate(to: .folder(dir))
        XCTAssertNil(pane.auxViewController)
    }

    func testSearchProviderStreamsResultsAndCancelsWhenNavigatingAway() throws {
        final class Provider: SearchProvider, @unchecked Sendable {
            let terminated = FlagBox()
            func search(_ query: String, context: SearchContext) -> AsyncThrowingStream<SearchBatch, Error> {
                let flag = terminated
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        continuation.yield(SearchBatch(results: [SearchResult(id: "1", title: "\(query) one"), SearchResult(id: "2", title: "\(query) two")]))
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continuation.yield(SearchBatch(results: [SearchResult(id: "2", title: "dup"), SearchResult(id: "3", title: "\(query) three")]))
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in flag.set(); task.cancel() }
                }
            }
        }
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        let provider = Provider()
        regs.searchProviders.register(SearchProviderSpec(id: "web", title: "Web", symbolName: "globe", provider: provider), owner: "tester")
        pane.searchWithProvider("tester/web", query: "cats")
        XCTAssertEqual(pane.providedLocation?.kind, .search)
        XCTAssertEqual(pane.searchText, "cats")
        let aux = try XCTUnwrap(pane.auxViewController as? PaneAuxViewController)
        XCTAssertTrue(spin { aux.itemCount == 3 })
        XCTAssertFalse(provider.terminated.isSet)
        pane.navigate(to: .folder(dir))
        XCTAssertTrue(spin { provider.terminated.isSet })
        XCTAssertNil(pane.providedLocation)
    }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstDescendant(of: type) { return t }
        }
        return nil
    }
}
