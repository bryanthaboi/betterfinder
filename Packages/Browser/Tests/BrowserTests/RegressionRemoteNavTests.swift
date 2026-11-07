import AppKit
import FileOps
import FSCore
import Integration
import Quartz
import Remote
import XCTest
@testable import Browser

@MainActor
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { .zero }
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

final class RegressionRemoteNavTests: RegistryTestCase {
    var remote: InMemoryRemote!
    var token: ResourceRegistrationToken?
    var savedIntegration: RemoteIntegration!
    var savedAnnouncer: (@MainActor (String, NSView?) -> Void)!
    var savedReduceMotion: (@MainActor () -> Bool)!
    var savedTrashService: TrashService!

    override func setUp() async throws {
        try await super.setUp()
        remote = InMemoryRemote()
        remote.seed("/readme.txt", "hello")
        remote.seed("/docs/guide.md", "guide!")
        remote.seed("/photo.jpg", String(repeating: "p", count: 2048))
        remote.seed("/.secret", "hidden")
        token = try ResourceProviderRegistry.shared.register(remote, owner: "tests")
        await MainActor.run {
            savedIntegration = RemoteIntegration.shared
            savedAnnouncer = BrowserPaneController.announcer
            savedReduceMotion = BrowserPaneController.reduceMotion
            savedTrashService = FileOperationQueue.shared.trashService
        }
    }

    override func tearDown() async throws {
        token?.cancel()
        await MainActor.run {
            RemoteIntegration.shared = savedIntegration
            BrowserPaneController.announcer = savedAnnouncer
            BrowserPaneController.reduceMotion = savedReduceMotion
            FileOperationQueue.shared.trashService = savedTrashService
            RemoteOpenCopies.directoryOverride = nil
            InlineWarning.dismiss()
        }
        try await super.tearDown()
    }

    @MainActor
    func openRemote(_ regs: BrowserRegistries, tree: URL? = nil) throws -> (BrowserWindowController, BrowserPaneController, ResourceLocationProvider) {
        let lp = ResourceLocationProvider(remote, rootTitle: "Test Bucket", symbolName: "server.rack")
        regs.locations.register(LocationProviderSpec(id: remote.providerID, title: "Test Bucket", provider: lp, root: lp.rootLocation), owner: "tester")
        let wc = makeWindow(try tree ?? makeTree(), registries: regs)
        wc.navigate(to: lp.rootLocation)
        return (wc, wc.activePane, lp)
    }

    @MainActor
    func select(_ name: String, in r: RemoteBrowserViewController) {
        guard let row = r.items.firstIndex(where: { $0.name == name }) else { return XCTFail("no \(name)") }
        r.table.selectRowIndexes([row], byExtendingSelection: false)
    }

    @MainActor
    func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @MainActor
    func validates(_ wc: BrowserWindowController, _ sel: Selector) -> Bool {
        wc.validateUserInterfaceItem(NSMenuItem(title: "", action: sel, keyEquivalent: ""))
    }

    @MainActor
    func testDropOnBackgroundOrPastLastRowDoesNotIndexOutOfRange() throws {
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        let src = try makeTree(files: ["up.txt"])
        let pb = NSPasteboard(name: NSPasteboard.Name("bf-test-drop-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([src.appendingPathComponent("up.txt") as NSURL])
        let info = FakeDraggingInfo(pb)
        XCTAssertEqual(r.tableView(r.table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on), .copy)
        XCTAssertEqual(r.tableView(r.table, validateDrop: info, proposedRow: r.items.count, proposedDropOperation: .on), .copy)
        XCTAssertEqual(r.tableView(r.table, validateDrop: info, proposedRow: r.items.count + 5, proposedDropOperation: .on), .copy)

        let empty = InMemoryRemote()
        let emptyToken = try ResourceProviderRegistry.shared.register(empty, owner: "tests")
        defer { emptyToken.cancel() }
        let elp = ResourceLocationProvider(empty, rootTitle: "Empty")
        let e = RemoteBrowserViewController(location: elp.rootLocation, provider: elp)
        e.start()
        defer { e.stop() }
        XCTAssertTrue(spin { !e.isLoading })
        XCTAssertTrue(e.items.isEmpty)
        XCTAssertEqual(e.tableView(e.table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on), .copy)
        XCTAssertEqual(e.tableView(e.table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on), .copy)
        XCTAssertNil(e.tableView(e.table, viewFor: e.table.tableColumns.first, row: -1))
        XCTAssertNil(e.tableView(e.table, pasteboardWriterForRow: -1))
    }

    @MainActor
    func testViewModeCommandsKeepRemoteListingAndTargets() throws {
        let regs = BrowserRegistries()
        let (wc, pane, lp) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        select("readme.txt", in: r)
        let readme = ResourceID(providerID: remote.providerID, path: "/readme.txt")
        XCTAssertFalse(pane.supportsViewModes)
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.asIcons(_:))))
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.asColumns(_:))))
        XCTAssertFalse(regs.commands.isEnabled(CommandRegistry.reference("view.icons", owner: BrowserOwner.builtIn), context: BrowserContext(controller: wc)))
        let modeBefore = pane.viewMode
        for action in [#selector(BrowserWindowController.asIcons(_:)), #selector(BrowserWindowController.asColumns(_:)), #selector(BrowserWindowController.asList(_:))] {
            wc.perform(action, with: nil)
            XCTAssertTrue(pane.remoteController === r)
            XCTAssertFalse(r.view.isHidden)
            XCTAssertTrue(pane.content.view.isHidden)
            XCTAssertEqual(pane.viewMode, modeBefore)
            XCTAssertEqual(r.items.map(\.name), ["docs", "photo.jpg", "readme.txt"])
            XCTAssertEqual(pane.selectedResources, [readme])
            XCTAssertEqual(pane.destinationResource, lp.rootLocation.resourceID)
        }
        for mode in [BrowserViewMode.icon, .column, .list] {
            pane.setViewMode(mode)
            XCTAssertTrue(pane.content.view.isHidden, "\(mode) exposed the hidden local listing")
            XCTAssertFalse(r.view.isHidden)
            XCTAssertEqual(pane.selectedResources, [readme])
        }
        wc.goBack(nil)
        XCTAssertNil(pane.remoteController)
        XCTAssertFalse(pane.content.view.isHidden)
        XCTAssertTrue(pane.supportsViewModes)
        XCTAssertTrue(validates(wc, #selector(BrowserWindowController.asIcons(_:))))
        wc.setViewMode(.icon)
        XCTAssertEqual(pane.viewMode, .icon)
    }

    @MainActor
    func testOpenCopyGoesToDurableDownloadsAndIsLabelled() throws {
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        select("readme.txt", in: r)
        XCTAssertEqual(r.openSelectionTitle, "Download and Open Copy…")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: -500, y: -500), modifierFlags: [], timestamp: 0,
                                                     windowNumber: wc.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(r.contextMenu(for: click))
        XCTAssertEqual(menu.items.first?.title, "Download and Open Copy…")
        select("docs", in: r)
        XCTAssertEqual(r.openSelectionTitle, "Open")
        XCTAssertTrue(RemoteOpenCopies.notice(serverTitle: "Test Bucket").contains("aren’t uploaded"))

        let dir = try makeTree(files: [])
        RemoteOpenCopies.directoryOverride = dir
        let provider = remote!
        var results: [[URL]] = []
        Task { @MainActor in
            let item = try await provider.stat(ResourceID(providerID: provider.providerID, path: "/readme.txt"))
            results.append(try await RemoteOpenCopies.download([item], provider: provider))
            results.append(try await RemoteOpenCopies.download([item], provider: provider))
        }
        XCTAssertTrue(spin { results.count == 2 })
        let first = results[0], second = results[1]
        XCTAssertEqual(first.map { $0.deletingLastPathComponent().standardizedFileURL }, [dir.standardizedFileURL])
        XCTAssertEqual(first.first?.lastPathComponent, "readme.txt")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: second[0], encoding: .utf8), "hello")
        XCTAssertFalse(first[0].path.hasPrefix(StagingArea.root.path))
        RemoteStaging.purge(olderThan: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second[0].path))
    }

    @MainActor
    func testRevealDoesNotReuseWindowShowingServer() throws {
        let regs = BrowserRegistries()
        let lp = ResourceLocationProvider(remote, rootTitle: "Test Bucket", symbolName: "server.rack")
        regs.locations.register(LocationProviderSpec(id: remote.providerID, title: "Test Bucket", provider: lp, root: lp.rootLocation), owner: "tester")
        let tree = try makeTree()
        let manager = BrowserWindowManager(registries: regs)
        let wc = manager.openWindow(at: .folder(tree))
        defer { for c in manager.controllers { c.close() } }
        XCTAssertTrue(manager.existing(showing: .folder(tree)) === wc)
        wc.navigate(to: lp.rootLocation)
        XCTAssertTrue(wc.location.isSame(as: .folder(tree)))
        XCTAssertNil(manager.existing(showing: .folder(tree)))
        let file = tree.appendingPathComponent("file-1.txt")
        manager.handle(.reveal(file))
        XCTAssertEqual(manager.controllers.count, 2)
        let revealed = try XCTUnwrap(manager.controllers.last)
        XCTAssertFalse(revealed === wc)
        XCTAssertTrue(revealed.location.isSame(as: .folder(tree)))
        XCTAssertNil(revealed.providedLocation)
        XCTAssertEqual(wc.destination, .provided(lp.rootLocation))
        wc.goBack(nil)
        XCTAssertNotNil(manager.existing(showing: .folder(tree)))
    }

    @MainActor
    func testNewTabFromRemoteKeepsRemoteDestination() throws {
        let regs = BrowserRegistries()
        let (wc, _, lp) = try openRemote(regs)
        defer { wc.close() }
        let before = BrowserWindowManager.shared.controllers.count
        wc.newTab(nil)
        XCTAssertEqual(BrowserWindowManager.shared.controllers.count, before + 1)
        let tab = try XCTUnwrap(BrowserWindowManager.shared.controllers.last)
        defer { tab.close() }
        XCTAssertEqual(tab.destination, .provided(lp.rootLocation))
        XCTAssertTrue(tab.activePane.backStack.isEmpty)
    }

    @MainActor
    func testRemoteSearchAndEditPathNeverFallBackToLocal() throws {
        let regs = BrowserRegistries()
        let (wc, pane, lp) = try openRemote(regs)
        defer { wc.close() }
        XCTAssertTrue(spin { pane.remoteController?.items.count == 3 })
        let local = pane.location
        pane.search("readme")
        XCTAssertEqual(pane.providedLocation, lp.rootLocation)
        XCTAssertEqual(pane.location, local)
        XCTAssertTrue(pane.lastNotice?.contains("isn’t available on this server") == true, pane.lastNotice ?? "nil")
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.focusPathBar(_:))))
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.goToFolder(_:))))
        wc.focusPathBar(nil)
        XCTAssertFalse(pane.pathBar.isEditing)
        XCTAssertTrue(pane.lastNotice?.contains("Copy Path") == true)
        pane.search("readme", scope: .home)
        XCTAssertNil(pane.providedLocation)
        guard case .search(let scope, "readme") = pane.location else { return XCTFail("\(pane.location)") }
        XCTAssertEqual(scope.pathKey, FileManager.default.homeDirectoryForCurrentUser.pathKey)
    }

    @MainActor
    func testWindowValidationUsesRemoteCapabilitiesAndSelections() throws {
        let regs = BrowserRegistries()
        let tree = try makeTree()
        let (wc, pane, _) = try openRemote(regs, tree: tree)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        XCTAssertTrue(validates(wc, #selector(BrowserWindowController.newFolder(_:))))
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.newFile(_:))))
        XCTAssertTrue(regs.commands.isEnabled(CommandRegistry.reference("file.newFolder", owner: BrowserOwner.builtIn), context: BrowserContext(controller: wc)))
        remote.capabilities = [.read]
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.newFolder(_:))))
        remote.capabilities = [.read, .write, .rename, .delete, .makeDirectory]

        wc.goBack(nil)
        pane.expectSelection([tree.appendingPathComponent("file-0.txt")])
        XCTAssertTrue(spin { !pane.selectedURLs.isEmpty })
        wc.goForward(nil)
        let r2 = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r2.items.count == 3 })
        wc.toggleDualPane(nil)
        let other = try XCTUnwrap(wc.otherPane(than: pane))
        other.navigate(to: .folder(try makeTree(files: [])))
        wc.window?.makeFirstResponder(r2.table)
        XCTAssertFalse(pane.selectedURLs.isEmpty)
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.copyToOtherPane(_:))))
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.moveToOtherPane(_:))))
        select("readme.txt", in: r2)
        XCTAssertTrue(validates(wc, #selector(BrowserWindowController.copyToOtherPane(_:))))
        XCTAssertTrue(validates(wc, #selector(BrowserWindowController.moveToOtherPane(_:))))
        remote.capabilities = [.read, .write]
        XCTAssertTrue(validates(wc, #selector(BrowserWindowController.copyToOtherPane(_:))))
        XCTAssertFalse(validates(wc, #selector(BrowserWindowController.moveToOtherPane(_:))))
    }

    @MainActor
    func testDisconnectShowsReconnectStateUntilUserReconnects() throws {
        let dir = try makeTree(files: [])
        let server = RemoteServer(name: "Media", kind: .s3(S3Configuration(endpoint: "https://media.example.invalid", bucket: "media")))
        let store = RemoteServerStore(url: dir.appendingPathComponent("servers.json"))
        try store.save([server])
        let manager = RemoteConnectionManager(store: store, credentials: InMemoryCredentialStore(), registry: ResourceProviderRegistry(), toolchain: SSHToolchain(supportDirectory: dir))
        RemoteIntegration.shared = RemoteIntegration(manager: manager, transferRegistry: ResourceTransferProviderRegistry())
        token?.cancel()
        remote = InMemoryRemote(id: server.providerID)
        remote.seed("/readme.txt", "hello")
        remote.seed("/docs/guide.md", "guide!")
        remote.seed("/photo.jpg", "p")
        token = try ResourceProviderRegistry.shared.register(remote, owner: "tests")

        let regs = BrowserRegistries()
        let (wc, pane, lp) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        XCTAssertTrue(r.reconnectButton.isHidden)

        RemoteIntegration.shared.disconnect(server)
        XCTAssertTrue(manager.isDisconnected(server))
        XCTAssertEqual(manager.state(of: server), .disconnected)
        XCTAssertTrue(spin { r.showsDisconnected })
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertFalse(r.reconnectButton.isHidden)
        XCTAssertNotNil(r.loadError as? RemoteDisconnectedError)
        r.reload()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertTrue(r.showsDisconnected)

        pane.navigate(to: lp.rootLocation)
        XCTAssertFalse(manager.isDisconnected(server))
        XCTAssertEqual(manager.state(of: server), .idle)
        XCTAssertTrue(spin { r.items.count == 3 })
        XCTAssertTrue(r.reconnectButton.isHidden)

        RemoteIntegration.shared.disconnect(server)
        XCTAssertTrue(spin { r.showsDisconnected })
        pane.refresh(nil)
        XCTAssertTrue(spin { r.items.count == 3 })

        RemoteIntegration.shared.disconnect(server)
        XCTAssertTrue(spin { r.showsDisconnected })
        RemoteIntegration.shared.reconnect(providerID: server.providerID)
        XCTAssertTrue(spin { !r.showsDisconnected && r.items.count == 3 })

        RemoteIntegration.shared.disconnect(server)
        XCTAssertTrue(spin { r.showsDisconnected })
        wc.goBack(nil)
        XCTAssertTrue(manager.isDisconnected(server))
        wc.goForward(nil)
        XCTAssertFalse(manager.isDisconnected(server))
        let r3 = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r3.items.count == 3 })
    }

    @MainActor
    func testFailedRemoteRenameKeepsTypedNameInEditor() throws {
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        select("readme.txt", in: r)
        r.beginRename()
        let id = ResourceID(providerID: remote.providerID, path: "/readme.txt")
        XCTAssertEqual(r.renamingID, id)
        let row = try XCTUnwrap(r.items.firstIndex { $0.id == id })
        let tf = try XCTUnwrap((r.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField)
        if let editor = tf.currentEditor() {
            editor.string = "bad/name.txt"
            wc.window?.makeFirstResponder(r.table)
        } else {
            tf.stringValue = "bad/name.txt"
            r.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: tf))
        }
        XCTAssertTrue(spin { r.renamingID == id })
        let field = try XCTUnwrap((r.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField)
        XCTAssertEqual(field.stringValue, "bad/name.txt")
        XCTAssertTrue(field.isEditable)
        XCTAssertNotNil(r.renameFailureMessage)
        XCTAssertNotNil(remote.data("/readme.txt"))
        _ = r.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(r.renamingID)
        XCTAssertEqual(field.stringValue, "readme.txt")
    }

    @MainActor
    func testSelectingFolderClearsPreviewBusyState() throws {
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        select("readme.txt", in: r)
        r.stagePreview(show: false)
        XCTAssertTrue(r.isStagingPreview)
        select("docs", in: r)
        r.stagePreview(show: false)
        XCTAssertFalse(r.isStagingPreview)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(r.isStagingPreview)
        XCTAssertTrue(r.stagedPreviewURLs.isEmpty)
        select("readme.txt", in: r)
        r.stagePreview(show: false)
        XCTAssertTrue(spin { !r.isStagingPreview && r.stagedPreviewURLs.count == 1 })
        r.table.deselectAll(nil)
        r.stagePreview(show: false)
        XCTAssertFalse(r.isStagingPreview)
        XCTAssertTrue(r.stagedPreviewURLs.isEmpty)
    }

    @MainActor
    func testOperationsIndicatorIsADefaultToolbarItemAndIsAddedOnce() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        XCTAssertTrue(wc.defaultToolbarIdentifierStrings().contains("operations"))
        let toolbar = try XCTUnwrap(wc.window?.toolbar)
        toolbar.autosavesConfiguration = false
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "operations" })
        XCTAssertTrue(item.view is OperationsIndicatorView)
        XCTAssertTrue(BrowserDefaults.store.bool(forKey: BrowserWindowController.operationsItemAddedKey))
        let index = try XCTUnwrap(toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "operations" })
        toolbar.removeItem(at: index)
        BrowserDefaults.store.set(false, forKey: BrowserWindowController.operationsItemAddedKey)
        wc.ensureOperationsItem(in: toolbar)
        XCTAssertTrue(toolbar.items.contains { $0.itemIdentifier.rawValue == "operations" })
        let again = try XCTUnwrap(toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "operations" })
        toolbar.removeItem(at: again)
        wc.ensureOperationsItem(in: toolbar)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "operations" })
    }

    @MainActor
    func testPutBackFromTrashContextMenuRestoresAndReportsFailures() throws {
        let root = try makeTree(files: [])
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let journal = try TrashJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        FileOperationQueue.shared.trashService = TrashService(journal: journal, provider: DirectoryTrashProvider(directory: trash))
        let trashed = trash.appendingPathComponent("a.txt")
        let orphan = trash.appendingPathComponent("orphan.txt")
        FileManager.default.createFile(atPath: trashed.path, contents: Data("a".utf8))
        FileManager.default.createFile(atPath: orphan.path, contents: Data("o".utf8))
        _ = try journal.record(originalURL: originals.appendingPathComponent("a.txt"), trashedURL: trashed)

        let regs = BrowserRegistries()
        let wc = makeWindow(trash, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { pane.model.items.count == 2 })
        XCTAssertTrue(pane.isShowingTrash)
        let empty = ContextMenuBuilder.builtInMenu(for: pane)
        XCTAssertTrue(empty.items.contains { $0.title == "Recently Trashed…" })
        pane.content.select([orphan], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.count == 1 })
        XCTAssertFalse(pane.canPutBack)
        XCTAssertFalse(ContextMenuBuilder.builtInMenu(for: pane).items.contains { $0.title == "Put Back" })
        pane.content.select([trashed], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs == [trashed] })
        XCTAssertTrue(pane.canPutBack)
        let menu = ContextMenuBuilder.builtInMenu(for: pane)
        XCTAssertEqual(menu.items.first?.title, "Put Back")
        XCTAssertTrue(pane.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserPaneController.putBack(_:)), keyEquivalent: "")))
        pane.putBack(nil)
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: originals.appendingPathComponent("a.txt").path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNil(journal.entry(forTrashedURL: trashed))

        let stuck = trash.appendingPathComponent("stuck.txt")
        FileManager.default.createFile(atPath: stuck.path, contents: Data("s".utf8))
        _ = try journal.record(originalURL: URL(fileURLWithPath: "/System/bf-test-\(UUID().uuidString)/stuck.txt"), trashedURL: stuck)
        XCTAssertTrue(spin { pane.model.items.contains { $0.url.lastPathComponent == "stuck.txt" } })
        pane.content.select([stuck], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs == [stuck] })
        pane.putBack(nil)
        XCTAssertTrue(spin { pane.lastNotice?.hasPrefix("Couldn’t put back 1 item.") == true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
        XCTAssertNotNil(journal.entry(forTrashedURL: stuck))
    }

    @MainActor
    func testWindowsKeysBackspaceF5ShiftF5AndForwardDelete() throws {
        let tree = try makeTree()
        let trashDir = try makeTree(files: [])
        let journal = try TrashJournal(databaseURL: trashDir.appendingPathComponent("j.sqlite"))
        FileOperationQueue.shared.trashService = TrashService(journal: journal, provider: DirectoryTrashProvider(directory: trashDir.appendingPathComponent("bin")))
        let regs = BrowserRegistries()
        let wc = makeWindow(tree.appendingPathComponent("Folder"), registries: regs)
        defer { wc.close() }
        let pane = wc.activePane

        BrowserDefaults.store.set(false, forKey: BrowserDefaults.Key.returnOpens)
        XCTAssertFalse(pane.handleKeyDown(key(51, "\u{7f}")))
        XCTAssertEqual(pane.location, .folder(tree.appendingPathComponent("Folder")))

        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.returnOpens)
        XCTAssertTrue(pane.handleKeyDown(key(51, "\u{7f}")))
        XCTAssertEqual(pane.location.url?.pathKey, tree.pathKey)
        XCTAssertTrue(spin { pane.model.items.count == 9 })

        wc.toggleDualPane(nil)
        let other = try XCTUnwrap(wc.otherPane(than: pane))
        let dest = try makeTree(files: [])
        other.navigate(to: .folder(dest))
        let file = tree.appendingPathComponent("file-0.txt")
        pane.content.select([file], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs == [file] })
        let opsBefore = FileOperationQueue.shared.operations.count
        XCTAssertTrue(pane.handleKeyDown(key(96, "\u{F708}", [.function])))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(FileOperationQueue.shared.operations.count, opsBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("file-0.txt").path))
        pane.content.select([file], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs == [file] })
        XCTAssertTrue(pane.handleKeyDown(key(96, "\u{F708}", [.shift, .function])))
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: dest.appendingPathComponent("file-0.txt").path) })

        let victim = tree.appendingPathComponent("file-1.txt")
        pane.content.select([victim], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs == [victim] })
        XCTAssertTrue(pane.handleKeyDown(key(117, "\u{F728}", [.function])))
        XCTAssertTrue(spin { !FileManager.default.fileExists(atPath: victim.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashDir.appendingPathComponent("bin/file-1.txt").path))

        BrowserDefaults.store.set(false, forKey: BrowserDefaults.Key.returnOpens)
        XCTAssertFalse(pane.handleKeyDown(key(117, "\u{F728}", [.function])))
        let menu = ContextMenuBuilder.builtInMenu(for: pane)
        XCTAssertEqual(menu.items.first { $0.title == "Copy to Other Pane" }?.keyEquivalentModifierMask, [])
        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.returnOpens)
        XCTAssertEqual(ContextMenuBuilder.builtInMenu(for: pane).items.first { $0.title == "Copy to Other Pane" }?.keyEquivalentModifierMask, [.shift])
    }

    @MainActor
    func testRemoteFollowsHiddenFilesAndSharedSort() throws {
        BrowserDefaults.sort = SortSpec(key: .size, ascending: false, foldersFirst: false)
        let regs = BrowserRegistries()
        let (wc, pane, lp) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        XCTAssertEqual(r.table.sortDescriptors.first?.key, "size")
        XCTAssertEqual(r.table.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(r.items.first?.name, "photo.jpg")

        select("readme.txt", in: r)
        BrowserDefaults.showHidden = true
        XCTAssertTrue(spin { r.items.count == 4 })
        XCTAssertTrue(r.items.contains { $0.name == ".secret" })
        XCTAssertEqual(r.selectedItems.map(\.name), ["readme.txt"])
        BrowserDefaults.showHidden = false
        XCTAssertTrue(spin { r.items.count == 3 })

        var spec = BrowserDefaults.sort
        spec.foldersFirst = true
        BrowserDefaults.sort = spec
        NotificationCenter.default.post(name: .browserSortDidChange, object: nil)
        XCTAssertTrue(spin { r.items.first?.name == "docs" })
        XCTAssertEqual(r.selectedItems.map(\.name), ["readme.txt"])

        r.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertEqual(BrowserDefaults.sort.key, .name)
        XCTAssertFalse(BrowserDefaults.sort.ascending)
        XCTAssertTrue(BrowserDefaults.sort.foldersFirst)

        select("docs", in: r)
        r.openSelection()
        let sub = try XCTUnwrap(pane.remoteController)
        XCTAssertFalse(sub === r)
        XCTAssertEqual(sub.table.sortDescriptors.first?.key, "name")
        XCTAssertEqual(sub.table.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(pane.providedLocation?.providerID, lp.rootLocation.providerID)
    }

    @MainActor
    func testNavigationAnnouncesDestinationAndCountOnce() throws {
        var said: [String] = []
        BrowserPaneController.announcer = { text, _ in said.append(text) }
        let tree = try makeTree()
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs, tree: tree)
        defer { wc.close() }
        XCTAssertTrue(spin { said.contains("Test Bucket, 3 items") }, "\(said)")
        said.removeAll()
        wc.goBack(nil)
        XCTAssertTrue(spin { said.count == 1 }, "\(said)")
        XCTAssertTrue(said[0].hasSuffix("9 items"), said[0])
        said.removeAll()
        pane.navigate(to: .folder(tree.appendingPathComponent("Folder")))
        XCTAssertTrue(spin { said == ["Folder, empty"] }, "\(said)")
        said.removeAll()
        pane.refresh(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(said.isEmpty, "\(said)")
        XCTAssertEqual(BrowserPaneController.navigationAnnouncement("X", count: 1, error: nil), "X, 1 item")
        XCTAssertTrue(BrowserPaneController.navigationAnnouncement("X", count: 0, error: CocoaError(.fileReadNoPermission)).hasPrefix("X, can’t be read"))
    }

    @MainActor
    func testMissingICloudDriveShowsVisibleNotice() throws {
        let saved = BrowserWindowController.iCloudDriveURL
        BrowserWindowController.iCloudDriveURL = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        defer { BrowserWindowController.iCloudDriveURL = saved }
        let tree = try makeTree()
        let wc = makeWindow(tree, registries: BrowserRegistries())
        defer { wc.close() }
        wc.goICloud(nil)
        XCTAssertTrue(wc.location.isSame(as: .folder(tree)))
        XCTAssertTrue(wc.activePane.lastNotice?.contains("iCloud Drive isn’t available") == true)
    }

    @MainActor
    func testQuickLookTransitionsHonorReduceMotion() throws {
        let tree = try makeTree()
        let wc = makeWindow(tree, registries: BrowserRegistries())
        defer { wc.close() }
        let pane = wc.activePane
        let url = tree.appendingPathComponent("file-0.txt") as NSURL
        BrowserPaneController.reduceMotion = { true }
        XCTAssertEqual(pane.previewPanel(nil, sourceFrameOnScreenFor: url), .zero)
        XCTAssertNil(pane.previewPanel(nil, transitionImageFor: url, contentRect: nil))
        BrowserPaneController.reduceMotion = { false }
        XCTAssertNotNil(pane.previewPanel(nil, transitionImageFor: url, contentRect: nil))
    }

    @MainActor
    func testConnectionManagerKeepsDisconnectedUntilCleared() throws {
        let dir = try makeTree(files: [])
        let server = RemoteServer(name: "S", kind: .s3(S3Configuration(endpoint: "https://s.example.invalid", bucket: "b")))
        let store = RemoteServerStore(url: dir.appendingPathComponent("servers.json"))
        try store.save([server])
        let registry = ResourceProviderRegistry()
        let manager = RemoteConnectionManager(store: store, credentials: InMemoryCredentialStore(), registry: registry, toolchain: SSHToolchain(supportDirectory: dir))
        let first = try manager.provider(for: server)
        var posts = 0
        let obs = NotificationCenter.default.addObserver(forName: .remoteConnectionStateDidChange, object: manager, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(obs) }
        manager.disconnect(server)
        manager.disconnect(server)
        XCTAssertEqual(posts, 2)
        XCTAssertTrue(manager.isDisconnected(server))
        XCTAssertEqual(manager.state(of: server), .disconnected)
        let second = try manager.provider(for: server)
        XCTAssertFalse(first === second)
        XCTAssertTrue(manager.isDisconnected(server))
        manager.clearDisconnected(server)
        XCTAssertFalse(manager.isDisconnected(server))
        XCTAssertEqual(manager.state(of: server), .idle)
        try manager.remove(server)
        XCTAssertFalse(manager.isDisconnected(server))
    }
}
