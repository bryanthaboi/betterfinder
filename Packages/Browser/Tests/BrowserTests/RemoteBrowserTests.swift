import AppKit
import FileOps
import FSCore
import Remote
import XCTest
@testable import Browser

final class InMemoryRemote: ResourceProvider, @unchecked Sendable {
    let providerID: String
    let displayName = "Test Bucket"
    var capabilities: ResourceCapabilities = [.read, .write, .rename, .delete, .makeDirectory]
    var root: ResourceID { ResourceID(providerID: providerID, path: "/") }
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var dirs: Set<String> = ["/"]
    private(set) var downloads = 0

    init(id: String = "test.remote.\(UUID().uuidString.prefix(6).lowercased())") { providerID = id }

    func seed(_ path: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        files[path] = Data(text.utf8)
        var p = ResourceID(providerID: providerID, path: path).lexicalParent
        while let d = p { dirs.insert(d.path); p = d.lexicalParent }
    }

    func data(_ path: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[path] }
    func hasDir(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return dirs.contains(path) }

    private func itemLocked(_ path: String) -> ResourceItem? {
        let id = ResourceID(providerID: providerID, path: path)
        if dirs.contains(path) { return ResourceItem(id: id, isDirectory: true) }
        guard let d = files[path] else { return nil }
        return ResourceItem(id: id, isDirectory: false, size: Int64(d.count), modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        lock.lock()
        let prefix = directory.isRoot ? "/" : directory.path + "/"
        let names = Set((Array(files.keys) + Array(dirs)).filter { $0 != directory.path && $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") })
        let items = names.sorted().compactMap(itemLocked).filter { options.showHidden || !$0.isHidden }
        lock.unlock()
        return AsyncThrowingStream { c in c.yield(items); c.finish() }
    }

    func stat(_ id: ResourceID) async throws -> ResourceItem {
        lock.lock(); defer { lock.unlock() }
        guard let i = itemLocked(id.path) else { throw ResourceError.notFound(id.path) }
        return i
    }

    func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        lock.lock()
        downloads += 1
        let d = files[id.path]
        lock.unlock()
        guard let d else { throw ResourceError.notFound(id.path) }
        try d.write(to: localFile)
        return try await stat(id)
    }

    func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        let d = try Data(contentsOf: localFile)
        lock.lock(); files[id.path] = d; lock.unlock()
        return try await stat(id)
    }

    func makeDirectory(_ id: ResourceID) async throws -> ResourceItem {
        lock.lock(); dirs.insert(id.path); lock.unlock()
        return ResourceItem(id: id, isDirectory: true)
    }

    func delete(_ id: ResourceID, recursive: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        files = files.filter { $0.key != id.path && !$0.key.hasPrefix(id.path + "/") }
        dirs = dirs.filter { $0 != id.path && !$0.hasPrefix(id.path + "/") }
    }

    func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        lock.lock()
        if let d = files.removeValue(forKey: id.path) { files[destination.path] = d }
        lock.unlock()
        return try await stat(destination)
    }
}

final class RemoteBrowserTests: RegistryTestCase {
    var remote: InMemoryRemote!
    var token: ResourceRegistrationToken?

    override func setUp() async throws {
        try await super.setUp()
        remote = InMemoryRemote()
        remote.seed("/readme.txt", "hello")
        remote.seed("/docs/guide.md", "guide!")
        remote.seed("/photo.jpg", String(repeating: "p", count: 2048))
        token = try ResourceProviderRegistry.shared.register(remote, owner: "tests")
        _ = RemoteIntegration.shared
    }

    override func tearDown() async throws {
        token?.cancel()
        try await super.tearDown()
    }

    @MainActor
    func openRemote(_ regs: BrowserRegistries) throws -> (BrowserWindowController, BrowserPaneController, ResourceLocationProvider) {
        let lp = ResourceLocationProvider(remote, rootTitle: "Test Bucket", symbolName: "server.rack")
        regs.locations.register(LocationProviderSpec(id: remote.providerID, title: "Test Bucket", provider: lp, root: lp.rootLocation), owner: "tester")
        let wc = makeWindow(try makeTree(), registries: regs)
        wc.navigate(to: lp.rootLocation)
        return (wc, wc.activePane, lp)
    }

    @MainActor
    func select(_ name: String, in r: RemoteBrowserViewController) {
        guard let row = r.items.firstIndex(where: { $0.name == name }) else { return XCTFail("no \(name)") }
        r.table.selectRowIndexes([row], byExtendingSelection: false)
    }

    @MainActor
    func testRemoteLocationUsesRemoteBrowserWithStatusAndCapabilities() throws {
        let regs = BrowserRegistries()
        let (wc, pane, lp) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertNil(pane.auxViewController)
        XCTAssertTrue(pane.content.view.isHidden)
        XCTAssertTrue(spin { r.items.count == 3 })
        XCTAssertEqual(r.items.map(\.name), ["docs", "photo.jpg", "readme.txt"])
        XCTAssertTrue(spin { pane.statusBar.text == "3 items" })
        XCTAssertEqual(wc.window?.title, "Test Bucket")
        select("readme.txt", in: r)
        XCTAssertEqual(r.selectedItems.map(\.name), ["readme.txt"])
        XCTAssertTrue(spin { pane.statusBar.text.hasPrefix("readme.txt — ") }, "status: \(pane.statusBar.text)")
        XCTAssertTrue(pane.selectedURLs.isEmpty)
        XCTAssertNil(pane.destinationFolder)
        XCTAssertEqual(pane.destinationResource, lp.rootLocation.resourceID)
        XCTAssertTrue(pane.sizes.results.isEmpty)
        func enabled(_ sel: Selector) -> Bool { pane.validateMenuItem(NSMenuItem(title: "", action: sel, keyEquivalent: "")) }
        XCTAssertFalse(enabled(#selector(BrowserPaneController.moveToTrash(_:))))
        XCTAssertTrue(enabled(#selector(BrowserPaneController.deleteImmediately(_:))))
        XCTAssertTrue(enabled(#selector(BrowserPaneController.renameSelection(_:))))
        XCTAssertTrue(enabled(#selector(BrowserPaneController.newFolder(_:))))
        XCTAssertTrue(enabled(#selector(BrowserPaneController.toggleQuickLook(_:))))
        XCTAssertFalse(enabled(#selector(BrowserPaneController.getInfo(_:))))
        XCTAssertFalse(enabled(#selector(BrowserPaneController.newFile(_:))))
        XCTAssertFalse(enabled(#selector(BrowserPaneController.duplicate(_:))))
        remote.capabilities = [.read]
        XCTAssertFalse(enabled(#selector(BrowserPaneController.renameSelection(_:))))
        XCTAssertFalse(enabled(#selector(BrowserPaneController.newFolder(_:))))
        XCTAssertNil(pane.destinationResource)
    }

    @MainActor
    func testRemoteNavigationUpBackForwardByProviderIdentity() throws {
        let regs = BrowserRegistries()
        let (wc, pane, lp) = try openRemote(regs)
        defer { wc.close() }
        var r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        XCTAssertFalse(pane.canGoUp)
        select("docs", in: r)
        r.openSelection()
        XCTAssertEqual(pane.providedLocation?.id, "/docs")
        XCTAssertEqual(pane.providedLocation?.providerID, remote.providerID)
        r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.map(\.name) == ["guide.md"] })
        XCTAssertTrue(pane.canGoUp)
        wc.goUp(nil)
        XCTAssertEqual(pane.providedLocation, lp.rootLocation)
        wc.goBack(nil)
        XCTAssertEqual(pane.providedLocation?.id, "/docs")
        wc.goBack(nil)
        XCTAssertEqual(pane.providedLocation, lp.rootLocation)
        wc.goBack(nil)
        XCTAssertNil(pane.providedLocation)
        XCTAssertNil(pane.remoteController)
        XCTAssertFalse(pane.content.view.isHidden)
        wc.goForward(nil)
        XCTAssertNotNil(pane.remoteController)
    }

    @MainActor
    func testStatusSummaryForRemoteMultiSelection() {
        let a = ResourceItem(id: ResourceID(providerID: "x", path: "/a.bin"), isDirectory: false, size: 1000)
        let b = ResourceItem(id: ResourceID(providerID: "x", path: "/b.bin"), isDirectory: false, size: 2000)
        let d = ResourceItem(id: ResourceID(providerID: "x", path: "/d"), isDirectory: true)
        let loc = ProvidedLocation.resource(ResourceID(providerID: "x", path: "/"))
        let multi = StatusBarContext(location: .computer, providedLocation: loc, itemCount: 3, resourceSelection: [a, b, d])
        XCTAssertEqual(SizeSummaryDriver.providedSummary(multi), "3 selected — \(SizeFormatter.string(3000)) in files (2 files, 1 folder)")
        XCTAssertEqual(SizeSummaryDriver.providedSummary(StatusBarContext(location: .computer, providedLocation: loc, resourceSelection: [d])), "d — folder")
        XCTAssertEqual(SizeSummaryDriver.providedSummary(StatusBarContext(location: .computer, providedLocation: loc, itemCount: 0, errorDescription: "boom")), "Can't read this folder: boom")
    }

    @MainActor
    func testClipboardCarriesResourceIDsWithoutFileURLs() throws {
        let id = ResourceID(providerID: remote.providerID, path: "/readme.txt")
        Clipboard.shared.copy(resources: [id])
        let pb = NSPasteboard.general
        XCTAssertNil(pb.availableType(from: [.fileURL]))
        XCTAssertFalse(pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
        XCTAssertEqual(Clipboard.resources(from: pb), [id])
        XCTAssertTrue(Clipboard.shared.hasResources)
        let local = URL(fileURLWithPath: "/tmp/x.txt")
        Clipboard.shared.copy(resources: [.local(local)])
        XCTAssertTrue(Clipboard.shared.hasFiles)
        XCTAssertTrue(Clipboard.resources(from: pb).isEmpty)
    }

    @MainActor
    func testPasteRemoteFileIntoLocalFolderDownloadsIt() throws {
        let dest = try makeTree(files: [])
        Clipboard.shared.copy(resources: [ResourceID(providerID: remote.providerID, path: "/readme.txt")])
        Clipboard.shared.paste(into: dest, forceMove: false)
        XCTAssertTrue(spin { (try? String(contentsOf: dest.appendingPathComponent("readme.txt"), encoding: .utf8)) == "hello" })
        XCTAssertNotNil(remote.data("/readme.txt"))
        let op = try XCTUnwrap(FileOperationQueue.shared.operations.last)
        XCTAssertTrue(op.isResourceTransfer)
        XCTAssertNotNil(op.undoUnavailableReason)
    }

    @MainActor
    func testUploadByDropAndCopyToOtherPane() throws {
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        let src = try makeTree(files: ["up.txt"])
        RemoteTransfers.enqueue([.local(src.appendingPathComponent("up.txt"))], into: r.directory, move: false)
        XCTAssertTrue(spin { self.remote.data("/up.txt") == Data("x".utf8) })
        XCTAssertTrue(spin { r.items.contains { $0.name == "up.txt" } })
        wc.toggleDualPane(nil)
        let other = try XCTUnwrap(wc.otherPane(than: pane))
        let local = try makeTree(files: [])
        other.navigate(to: .folder(local))
        wc.window?.makeFirstResponder(r.table)
        select("photo.jpg", in: r)
        pane.copyToOtherPane(nil)
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: local.appendingPathComponent("photo.jpg").path) })
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("photo.jpg")).count, 2048)
    }

    @MainActor
    func testRenameNewFolderAndDelete() throws {
        let regs = BrowserRegistries()
        let (wc, pane, _) = try openRemote(regs)
        defer { wc.close() }
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 3 })
        let provider = remote!
        let id = ResourceID(providerID: remote.providerID, path: "/readme.txt")
        Task { _ = try await ResourceActions.rename(id, to: "README.md", provider: provider) }
        XCTAssertTrue(spin { self.remote.data("/README.md") != nil })
        r.newFolder()
        XCTAssertTrue(spin { self.remote.hasDir("/untitled folder") })
        r.reload()
        XCTAssertTrue(spin { r.items.contains { $0.name == "README.md" } })
        select("README.md", in: r)
        r.deleteSelection(confirm: false)
        XCTAssertTrue(spin { self.remote.data("/README.md") == nil })
    }

    @MainActor
    func testQuickLookStagingUsesTemporaryCopies() async throws {
        let items = [try await remote.stat(ResourceID(providerID: remote.providerID, path: "/readme.txt"))]
        let urls = try await RemoteStaging.stage(items, provider: remote, purpose: "QuickLook", limit: RemoteStaging.previewLimit)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].lastPathComponent, "readme.txt")
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "hello")
        XCTAssertTrue(urls[0].path.hasPrefix(StagingArea.root.path))
        XCTAssertFalse(urls[0].path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        RemoteStaging.discard(urls)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        let big = ResourceItem(id: ResourceID(providerID: remote.providerID, path: "/huge.iso"), isDirectory: false, size: RemoteStaging.previewLimit + 1)
        do {
            _ = try await RemoteStaging.stage([big], provider: remote, purpose: "QuickLook", limit: RemoteStaging.previewLimit)
            XCTFail("expected size refusal")
        } catch ResourceError.unsupported {}
    }

    @MainActor
    func testConnectModelValidatesInput() throws {
        let m = ConnectToServerModel()
        m.kind = .sftp
        m.sftpAddress = "deploy@files.example.com:2200/srv"
        XCTAssertTrue(m.canConnect)
        let (server, secret) = try m.makeServer()
        XCTAssertNil(secret)
        guard case .sftp(let c) = server.kind else { return XCTFail() }
        XCTAssertEqual(c.port, 2200)
        m.sftpAddress = "-oProxyCommand=x@h"
        XCTAssertThrowsError(try m.makeServer())
        m.kind = .s3
        m.bucket = "media"
        m.accessKey = "AK"
        m.secretKey = "SK"
        m.endpoint = "https://acct.r2.cloudflarestorage.com"
        m.region = "auto"
        XCTAssertTrue(m.canConnect)
        let (s3, s3secret) = try m.makeServer()
        XCTAssertEqual(try AWSCredentials.decode(XCTUnwrap(s3secret)).accessKeyID, "AK")
        XCTAssertEqual(s3.credentialScope.host, "acct.r2.cloudflarestorage.com")
        m.endpoint = "http://example.com"
        XCTAssertThrowsError(try m.makeServer())
    }

    @MainActor
    func testSavedServersAppearInLocationsAndSidebar() throws {
        let dir = try makeTree(files: [])
        let store = RemoteServerStore(url: dir.appendingPathComponent("servers.json"))
        let server = RemoteServer(name: "Media Bucket", kind: .s3(S3Configuration(endpoint: "https://media.example.com", bucket: "media")))
        try store.save([server])
        let manager = RemoteConnectionManager(store: store, credentials: InMemoryCredentialStore(), registry: ResourceProviderRegistry(), toolchain: SSHToolchain(supportDirectory: dir))
        let integration = RemoteIntegration(manager: manager, transferRegistry: ResourceTransferProviderRegistry())
        let saved = RemoteIntegration.shared
        RemoteIntegration.shared = integration
        defer { RemoteIntegration.shared = saved }
        let regs = BrowserRegistries()
        integration.install(into: regs)
        let lp = try XCTUnwrap(regs.locations.provider(for: server.providerID) as? ResourceLocationProvider)
        XCTAssertEqual(lp.rootLocation.title, "Media Bucket")
        XCTAssertFalse(lp.capabilities.contains(.trash))
        XCTAssertTrue(lp.capabilities.contains(.write))
        let sidebar = SidebarViewController(registries: regs)
        _ = sidebar.view
        XCTAssertTrue(sidebar.entryTitles(inSection: "Locations").contains("Media Bucket"))
        integration.remove(server)
        XCTAssertNil(regs.locations.provider(for: server.providerID))
        XCTAssertTrue(spin { !sidebar.entryTitles(inSection: "Locations").contains("Media Bucket") })
        sidebar.teardown()
    }
}
