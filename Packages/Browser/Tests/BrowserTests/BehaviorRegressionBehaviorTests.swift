import AppKit
import Combine
import FileOps
import FSCore
import Remote
import XCTest
@testable import Browser

final class GatedRemote: ResourceProvider, @unchecked Sendable {
    struct Failure: LocalizedError { var errorDescription: String? { "gated failure" } }

    let providerID = "test.gated.\(UUID().uuidString.prefix(6).lowercased())"
    let displayName = "Gated"
    var capabilities: ResourceCapabilities = [.read, .trash]
    var root: ResourceID { ResourceID(providerID: providerID, path: "/") }
    private let lock = NSLock()
    private var contents: [String: Data] = [:]
    private var failing: Set<String> = []
    private var released: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var _targets: [String: URL] = [:]
    private var _trashed: [String] = []

    func seed(_ path: String, _ text: String) { lock.lock(); contents[path] = Data(text.utf8); lock.unlock() }
    func item(_ path: String) -> ResourceItem {
        lock.lock(); defer { lock.unlock() }
        return ResourceItem(id: ResourceID(providerID: providerID, path: path), isDirectory: false, size: Int64(contents[path]?.count ?? 0))
    }
    var targets: [String: URL] { lock.lock(); defer { lock.unlock() }; return _targets }
    var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    var trashed: [String] { lock.lock(); defer { lock.unlock() }; return _trashed }

    func release(_ path: String, failing fail: Bool = false) {
        lock.lock()
        if fail { failing.insert(path) }
        released.insert(path)
        let c = waiting.removeValue(forKey: path)
        lock.unlock()
        c?.resume()
    }

    private func gate(_ path: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released.contains(path) { lock.unlock(); c.resume(); return }
            waiting[path] = c
            lock.unlock()
        }
    }

    func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        lock.lock()
        let items = contents.keys.sorted().map { ResourceItem(id: ResourceID(providerID: providerID, path: $0), isDirectory: false, size: Int64(contents[$0]?.count ?? 0)) }
        lock.unlock()
        return AsyncThrowingStream { c in c.yield(items); c.finish() }
    }

    func stat(_ id: ResourceID) async throws -> ResourceItem { item(id.path) }

    func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        lock.lock(); _targets[id.path] = localFile; lock.unlock()
        await gate(id.path)
        lock.lock()
        let fail = failing.contains(id.path)
        let data = contents[id.path]
        lock.unlock()
        if fail { throw Failure() }
        guard let data else { throw ResourceError.notFound(id.path) }
        try? FileManager.default.removeItem(at: localFile)
        try data.write(to: localFile)
        return item(id.path)
    }

    func trash(_ id: ResourceID) async throws {
        await gate(id.path)
        lock.lock(); _trashed.append(id.path); contents[id.path] = nil; lock.unlock()
    }
}

final class BehaviorRegressionBehaviorTests: RegistryTestCase {
    var tokens: [ResourceRegistrationToken] = []
    var savedOpener: (@MainActor (URL) -> Void)!
    var savedPutBack: (@Sendable (TrashService, [URL]) -> PutBackReport)!
    var savedTrashService: TrashService!

    override func setUp() async throws {
        try await super.setUp()
        _ = RemoteIntegration.shared
        savedOpener = RemoteOpenCopies.opener
        savedPutBack = BrowserPaneController.putBackWork
        savedTrashService = FileOperationQueue.shared.trashService
    }

    override func tearDown() async throws {
        tokens.forEach { $0.cancel() }
        tokens = []
        RemoteOpenCopies.opener = savedOpener
        RemoteOpenCopies.directoryOverride = nil
        BrowserPaneController.putBackWork = savedPutBack
        FileOperationQueue.shared.trashService = savedTrashService
        try await super.tearDown()
    }

    func emptyDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-r2-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    func startDownload(_ item: ResourceItem, provider: ResourceProvider, into dir: URL) -> (Box<Result<[URL], Error>>, Task<Void, Never>) {
        let box = Box<Result<[URL], Error>>()
        let task = Task { @MainActor in
            do { box.value = .success(try await RemoteOpenCopies.download([item], provider: provider, into: dir)) } catch { box.value = .failure(error) }
        }
        return (box, task)
    }

    func testOverlappingSameNameOpenCopiesGetDistinctFilesWithTheirOwnContents() throws {
        let dir = try emptyDir()
        let p = GatedRemote()
        p.seed("/a/report.txt", "alpha")
        p.seed("/b/report.txt", "bravo")
        let (ra, _) = startDownload(p.item("/a/report.txt"), provider: p, into: dir)
        let (rb, _) = startDownload(p.item("/b/report.txt"), provider: p, into: dir)
        XCTAssertTrue(spin { p.waitingCount == 2 })
        let ta = try XCTUnwrap(p.targets["/a/report.txt"]), tb = try XCTUnwrap(p.targets["/b/report.txt"])
        XCTAssertNotEqual(ta, tb)
        XCTAssertFalse(ta.path.hasPrefix(dir.path + "/"), ta.path)
        XCTAssertFalse(tb.path.hasPrefix(dir.path + "/"), tb.path)
        XCTAssertEqual(ta.lastPathComponent, "report.txt")
        XCTAssertEqual(names(dir), [])

        p.release("/b/report.txt")
        XCTAssertTrue(spin { rb.value != nil })
        p.release("/a/report.txt")
        XCTAssertTrue(spin { ra.value != nil })
        let ua = try XCTUnwrap(try ra.value?.get().first), ub = try XCTUnwrap(try rb.value?.get().first)
        XCTAssertNotEqual(ua, ub)
        XCTAssertEqual(ub.lastPathComponent, "report.txt")
        XCTAssertEqual(ua.lastPathComponent, "report 2.txt")
        XCTAssertEqual(text(ua), "alpha")
        XCTAssertEqual(text(ub), "bravo")
        XCTAssertEqual(names(dir), ["report 2.txt", "report.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ta.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tb.deletingLastPathComponent().path))
    }

    func testFailedOpenCopyNeverRemovesAnotherDownloadsEditedCopy() throws {
        let dir = try emptyDir()
        let p = GatedRemote()
        p.seed("/a/report.txt", "alpha")
        p.seed("/b/report.txt", "bravo")
        let (ra, _) = startDownload(p.item("/a/report.txt"), provider: p, into: dir)
        let (rb, _) = startDownload(p.item("/b/report.txt"), provider: p, into: dir)
        XCTAssertTrue(spin { p.waitingCount == 2 })
        p.release("/b/report.txt")
        XCTAssertTrue(spin { rb.value != nil })
        let ub = try XCTUnwrap(try rb.value?.get().first)
        try Data("edited after open".utf8).write(to: ub)

        p.release("/a/report.txt", failing: true)
        XCTAssertTrue(spin { ra.value != nil })
        XCTAssertThrowsError(try ra.value?.get())
        XCTAssertEqual(text(ub), "edited after open")
        XCTAssertEqual(names(dir), ["report.txt"])
        let ta = try XCTUnwrap(p.targets["/a/report.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ta.deletingLastPathComponent().path))
    }

    func testOpenCopyNeverTouchesAnExistingOrNewlyCreatedUserFile() throws {
        let dir = try emptyDir()
        let p = GatedRemote()
        p.seed("/a/report.txt", "alpha")
        let mine = dir.appendingPathComponent("report.txt")
        let (r1, _) = startDownload(p.item("/a/report.txt"), provider: p, into: dir)
        XCTAssertTrue(spin { p.waitingCount == 1 })
        try Data("mine".utf8).write(to: mine)
        let inode = try FileManager.default.attributesOfItem(atPath: mine.path)[.systemFileNumber] as? Int
        p.release("/a/report.txt")
        XCTAssertTrue(spin { r1.value != nil })
        let u1 = try XCTUnwrap(try r1.value?.get().first)
        XCTAssertEqual(u1.lastPathComponent, "report 2.txt")
        XCTAssertEqual(text(u1), "alpha")
        XCTAssertEqual(text(mine), "mine")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mine.path)[.systemFileNumber] as? Int, inode)

        let q = GatedRemote()
        q.seed("/c/report.txt", "charlie")
        q.release("/c/report.txt")
        let (r2, _) = startDownload(q.item("/c/report.txt"), provider: q, into: dir)
        XCTAssertTrue(spin { r2.value != nil })
        XCTAssertEqual(try r2.value?.get().first?.lastPathComponent, "report 3.txt")
        XCTAssertEqual(text(mine), "mine")
        XCTAssertEqual(text(u1), "alpha")
    }

    func testCancelledOpenCopyPublishesNothingAndCleansStaging() throws {
        let dir = try emptyDir()
        let p = GatedRemote()
        p.seed("/a/report.txt", "alpha")
        let (r, task) = startDownload(p.item("/a/report.txt"), provider: p, into: dir)
        XCTAssertTrue(spin { p.waitingCount == 1 })
        task.cancel()
        p.release("/a/report.txt")
        XCTAssertTrue(spin { r.value != nil })
        XCTAssertThrowsError(try r.value?.get())
        XCTAssertEqual(names(dir), [])
        let t = try XCTUnwrap(p.targets["/a/report.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.deletingLastPathComponent().path))
    }

    func testExclusiveCopyFallbackRefusesExistingDestination() throws {
        let dir = try emptyDir()
        let src = dir.appendingPathComponent("src.txt")
        try Data("new".utf8).write(to: src)
        let existing = dir.appendingPathComponent("taken.txt")
        try Data("keep".utf8).write(to: existing)
        XCTAssertFalse(try RemoteOpenCopies.copyExclusively(src, to: existing))
        XCTAssertEqual(text(existing), "keep")
        let fresh = dir.appendingPathComponent("fresh.txt")
        XCTAssertTrue(try RemoteOpenCopies.copyExclusively(src, to: fresh))
        XCTAssertEqual(text(fresh), "new")
        XCTAssertEqual(RemoteOpenCopies.candidateName("report.txt", attempt: 2), "report 2.txt")
        XCTAssertEqual(RemoteOpenCopies.candidateName("README", attempt: 3), "README 3")
    }

    func openGated(_ p: GatedRemote, regs: BrowserRegistries) throws -> (BrowserWindowController, BrowserPaneController, RemoteBrowserViewController) {
        tokens.append(try ResourceProviderRegistry.shared.register(p, owner: "tests"))
        let lp = ResourceLocationProvider(p, rootTitle: "Gated", symbolName: "server.rack")
        regs.locations.register(LocationProviderSpec(id: p.providerID, title: "Gated", provider: lp, root: lp.rootLocation), owner: "tester")
        let wc = makeWindow(try makeTree(), registries: regs)
        wc.navigate(to: lp.rootLocation)
        let pane = wc.activePane
        let r = try XCTUnwrap(pane.remoteController)
        return (wc, pane, r)
    }

    func select(_ name: String, in r: RemoteBrowserViewController) {
        guard let row = r.items.firstIndex(where: { $0.name == name }) else { return XCTFail("no \(name)") }
        r.table.selectRowIndexes([row], byExtendingSelection: false)
    }

    func testOpenCopyAndRemoteTrashCountAsActiveWorkUntilFinished() throws {
        let dir = try emptyDir()
        RemoteOpenCopies.directoryOverride = dir
        BrowserDefaults.store.set(true, forKey: RemoteOpenCopies.confirmedKey)
        var opened: [URL] = []
        RemoteOpenCopies.opener = { opened.append($0) }
        let p = GatedRemote()
        p.seed("/report.txt", "alpha")
        p.seed("/old.txt", "old")
        let regs = BrowserRegistries()
        let (wc, _, r) = try openGated(p, regs: regs)
        defer { wc.close() }
        XCTAssertTrue(spin { r.items.count == 2 })
        let tracker = RemoteMutationTracker.shared
        let before = tracker.activeCount

        select("report.txt", in: r)
        r.openSelection()
        XCTAssertEqual(tracker.activeCount, before + 1)
        XCTAssertTrue(spin { p.waitingCount == 1 })
        p.release("/report.txt")
        XCTAssertTrue(spin { opened.count == 1 && tracker.activeCount == before })
        XCTAssertEqual(opened.first?.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(opened.first.flatMap(text), "alpha")

        select("old.txt", in: r)
        r.moveToTrash()
        XCTAssertEqual(tracker.activeCount, before + 1)
        XCTAssertTrue(spin { p.waitingCount == 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(tracker.activeCount, before + 1)
        p.release("/old.txt")
        XCTAssertTrue(spin { tracker.activeCount == before })
        XCTAssertEqual(p.trashed, ["/old.txt"])
    }

    final class FixedMeasure: @unchecked Sendable {
        var results: [String: SizeResult] = [:]
        var measure: SizeSummaryDriver.Measure {
            { [self] url in
                let r = self.results[url.lastPathComponent]
                return AsyncStream { c in
                    if let r { c.yield(r) }
                    c.finish()
                }
            }
        }
    }

    func makeSparse(_ url: URL, logical: UInt64 = 64 << 20) throws -> FileItem {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: logical - 1)
        try h.write(contentsOf: Data([1]))
        try h.close()
        return try XCTUnwrap(DirectoryLister.item(for: url))
    }

    func status(_ selection: [FileItem], in dir: URL, measure: FixedMeasure) -> StatusBarSegmentOutput {
        let driver = SizeSummaryDriver()
        driver.measure = measure.measure
        let output = StatusBarSegmentOutput()
        let sizes = SizeCoordinator()
        sizes.enabled = false
        driver.update(StatusBarContext(location: .folder(dir), providedLocation: nil, model: FolderModel(location: .folder(dir)), selection: selection, sizes: sizes), output: output)
        XCTAssertTrue(spin { !output.isBusy && !output.text.contains("calculating") }, output.text)
        withExtendedLifetime(driver) {}
        return output
    }

    func testSparseFileUsesTheSameUnitAloneInMultiSelectionAndInsideFolders() throws {
        let dir = try emptyDir()
        let sparse = try makeSparse(dir.appendingPathComponent("sparse.bin"))
        let small = dir.appendingPathComponent("small.txt")
        try Data(repeating: 7, count: 10).write(to: small)
        let smallItem = try XCTUnwrap(DirectoryLister.item(for: small))
        let folderURL = dir.appendingPathComponent("F", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        let inner = try makeSparse(folderURL.appendingPathComponent("inner.bin"))
        let folder = try XCTUnwrap(DirectoryLister.item(for: folderURL))

        let sparseLogical = try XCTUnwrap(sparse.logicalSize), sparseAlloc = try XCTUnwrap(sparse.allocatedSize)
        XCTAssertLessThan(sparseAlloc * 8, sparseLogical, "fixture isn't sparse")
        let measure = FixedMeasure()
        measure.results["F"] = SizeResult(allocatedBytes: inner.allocatedSize ?? 0, logicalBytes: inner.logicalSize ?? 0, itemCount: 1, isComplete: true)

        var singles: [String] = []
        for onDisk in [true, false] {
            BrowserDefaults.showAllocatedSize = onDisk
            XCTAssertEqual(BrowserDefaults.statusAlternateSize, !onDisk)
            let unit = onDisk ? " on disk" : " logical"
            let other = onDisk ? " logical" : " on disk"
            func pick(_ i: FileItem) -> Int64 { onDisk ? (i.allocatedSize ?? 0) : (i.logicalSize ?? 0) }
            func pickOther(_ i: FileItem) -> Int64 { onDisk ? (i.logicalSize ?? 0) : (i.allocatedSize ?? 0) }
            let folderBytes = pick(inner)

            let single = status([sparse], in: dir, measure: measure)
            XCTAssertEqual(single.text, "sparse.bin — \(SizeFormatter.string(pick(sparse)))\(unit) (\(SizeFormatter.exact(pick(sparse))))")
            XCTAssertEqual(single.toolTip, "\(SizeFormatter.string(pickOther(sparse)))\(other) (\(SizeFormatter.exact(pickOther(sparse))))")
            singles.append(single.text)

            let multi = status([sparse, smallItem], in: dir, measure: measure)
            XCTAssertEqual(multi.text, "2 selected — \(SizeFormatter.string(pick(sparse) + pick(smallItem)))\(unit) (2 files)")

            let folderOnly = status([folder], in: dir, measure: measure)
            XCTAssertEqual(folderOnly.text, "F — \(SizeFormatter.string(folderBytes))\(unit) · 1 item")
            XCTAssertEqual(folderOnly.toolTip, "\(SizeFormatter.string(pickOther(inner)))\(other) (\(SizeFormatter.exact(pickOther(inner))))")

            let mixed = status([sparse, folder], in: dir, measure: measure)
            XCTAssertEqual(mixed.text, "2 selected — \(SizeFormatter.string(pick(sparse) + folderBytes))\(unit) (1 file, 1 folder)")
        }
        XCTAssertNotEqual(singles[0], singles[1])
    }

    func testPanelRemovalWithUnavailableInvokerFocusesVisibleRemoteTable() throws {
        let remote = InMemoryRemote()
        remote.seed("/readme.txt", "hello")
        tokens.append(try ResourceProviderRegistry.shared.register(remote, owner: "tests"))
        let regs = BrowserRegistries()
        let lp = ResourceLocationProvider(remote, rootTitle: "Test Bucket", symbolName: "server.rack")
        regs.locations.register(LocationProviderSpec(id: remote.providerID, title: "Test Bucket", provider: lp, root: lp.rootLocation), owner: "tester")
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        wc.navigate(to: lp.rootLocation)
        let pane = wc.activePane
        let r = try XCTUnwrap(pane.remoteController)
        XCTAssertTrue(spin { r.items.count == 1 })
        XCTAssertTrue(pane.content.view.isHidden)

        regs.panels.register(PanelSpec(id: "s", title: "Edit", edge: .left, presentation: .slideOut,
                                       content: .ui(.stack(id: "r", [.textField(id: "t", value: "x", accessibilityLabel: "Note")]))), owner: "tester")
        let host = try XCTUnwrap(wc.panelHost)
        let panelView = try XCTUnwrap(host.instances["tester/s"]?.vc.view)
        let invoker = NSTextField(string: "invoker")
        window.contentView?.addSubview(invoker)
        XCTAssertTrue(window.makeFirstResponder(invoker))
        host.open("tester/s", focus: true, animated: false)
        XCTAssertTrue(PanelHostController.focusIsInside(panelView), String(describing: window.firstResponder))
        invoker.removeFromSuperview()

        regs.panels.removeAll(owner: "tester")
        XCTAssertNil(host.instances["tester/s"])
        let fr = try XCTUnwrap(window.firstResponder as? NSView, String(describing: window.firstResponder))
        XCTAssertTrue(fr === r.table || fr.isDescendant(of: r.table), String(describing: fr))
        XCTAssertFalse(fr.isDescendant(of: pane.content.view))
        XCTAssertFalse(fr.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(pane.visibleContentView === r.table)
    }

    func testExplicitlyOpeningTextOnlyPanelFocusesLabeledRoot() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        regs.panels.register(PanelSpec(id: "t", title: "Readme", edge: .right, presentation: .slideOut,
                                       content: .ui(.stack(id: "r", [.label(id: "l", "Just some text")]))), owner: "tester")
        let host = try XCTUnwrap(wc.panelHost)
        let inst = try XCTUnwrap(host.instances["tester/t"])
        let root = try XCTUnwrap(inst.vc.view as? ThemedPanelRoot)
        XCTAssertFalse(root.acceptsFirstResponder)
        XCTAssertNil(PanelContentViewController.firstKeyView(in: root.subviews.last ?? root))
        wc.activePane.focusVisibleContent()
        let before = window.firstResponder

        host.toggle("tester/t")
        XCTAssertTrue(host.isOpen("tester/t"))
        XCTAssertTrue(PanelHostController.focusIsInside(root), String(describing: window.firstResponder))
        if inst.vc.firstKeyView == nil {
            XCTAssertTrue(window.firstResponder === root, String(describing: window.firstResponder))
        }
        XCTAssertEqual(root.accessibilityLabel(), "Readme panel")
        XCTAssertTrue(root.accessibilityLabel()?.contains("Readme") == true)
        XCTAssertEqual(root.accessibilityRole(), .group)

        host.toggle("tester/t")
        XCTAssertFalse(host.isOpen("tester/t"))
        XCTAssertFalse(PanelHostController.focusIsInside(root))
        XCTAssertTrue(window.firstResponder === before, String(describing: window.firstResponder))
        XCTAssertFalse(root.acceptsFirstResponder)

        XCTAssertTrue(window.makeFirstResponder(nil))
        inst.vc.focusRoot()
        XCTAssertTrue(window.firstResponder === root)
        XCTAssertTrue(wc.activePane.focusVisibleContent())
        XCTAssertFalse(root.acceptsFirstResponder)
    }

    func testPutBackInFlightCountsAsBackgroundMutation() throws {
        let root = try makeTree(files: [])
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let journal = try TrashJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        FileOperationQueue.shared.trashService = TrashService(journal: journal, provider: DirectoryTrashProvider(directory: trash))
        let trashed = trash.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: trashed.path, contents: Data("a".utf8))
        _ = try journal.record(originalURL: originals.appendingPathComponent("a.txt"), trashedURL: trashed)
        let gate = DispatchSemaphore(value: 0)
        BrowserPaneController.putBackWork = { service, urls in
            gate.wait()
            return service.putBack(urls)
        }

        let wc = makeWindow(trash, registries: BrowserRegistries())
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { pane.model.items.count == 1 })
        pane.content.select([trashed], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs == [trashed] })
        let queue = FileOperationQueue.shared
        let before = queue.backgroundMutationCount

        pane.putBack(nil)
        XCTAssertEqual(queue.backgroundMutationCount, before + 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(queue.backgroundMutationCount, before + 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        gate.signal()
        XCTAssertTrue(spin { queue.backgroundMutationCount == before })
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testLocalCreateAndTagMutationsCountUntilFinished() throws {
        let dir = try makeTree(files: ["tagme.txt"])
        let wc = makeWindow(dir, registries: BrowserRegistries())
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { pane.model.items.count == 2 })
        let queue = FileOperationQueue.shared
        let before = queue.backgroundMutationCount
        var seen: [Int] = []
        let sub = queue.$backgroundMutationCount.sink { seen.append($0) }
        defer { sub.cancel() }

        seen = []
        pane.newFolder(nil)
        XCTAssertTrue(spin { queue.backgroundMutationCount == before && FileManager.default.fileExists(atPath: dir.appendingPathComponent("untitled folder").path) })
        XCTAssertEqual(seen.max(), before + 1)
        XCTAssertEqual(seen.last, before)

        seen = []
        pane.newFile(nil)
        XCTAssertTrue(spin { queue.backgroundMutationCount == before && seen.last == before && seen.contains(before + 1) })
        XCTAssertEqual(seen.max(), before + 1)

        let file = dir.appendingPathComponent("tagme.txt")
        pane.content.select([file], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.map(\.pathKey) == [file.pathKey] })
        let item = NSMenuItem()
        item.representedObject = "Logging"
        seen = []
        pane.toggleTag(item)
        XCTAssertTrue(spin { queue.backgroundMutationCount == before && FileCommands.tags(of: file).contains("Logging") })
        XCTAssertEqual(seen.max(), before + 1)
        XCTAssertEqual(seen.last, before)
    }
}
