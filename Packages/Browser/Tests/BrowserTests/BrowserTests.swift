import XCTest
import FSCore
@testable import Browser

final class BrowserTests: XCTestCase {
    func testUpFromFolderSelectsChild() {
        let loc = BrowserLocation.folder(URL(fileURLWithPath: "/Users/Shared"))
        let up = loc.parent(selected: nil)
        XCTAssertEqual(up?.location, .folder(URL(fileURLWithPath: "/Users/")))
        XCTAssertEqual(up?.select?.path, "/Users/Shared")
    }

    func testUpFromRootGoesToComputer() {
        XCTAssertEqual(BrowserLocation.folder(URL(fileURLWithPath: "/")).parent(selected: nil)?.location, .computer)
        XCTAssertNil(BrowserLocation.computer.parent(selected: nil))
    }

    func testUpFromSearchGoesToParentOfSelection() {
        let scope = URL(fileURLWithPath: "/Users/Shared")
        let loc = BrowserLocation.search(scope: scope, query: "x")
        let sel = URL(fileURLWithPath: "/Users/Shared/a/b/report.pdf")
        let up = loc.parent(selected: sel)
        XCTAssertEqual(up?.location.url?.pathKey, "/Users/Shared/a/b")
        XCTAssertEqual(up?.select?.path, sel.path)
        let none = loc.parent(selected: nil)
        XCTAssertEqual(none?.location.url?.pathKey, "/Users/Shared")
        XCTAssertNil(none?.select)
    }

    func testUpFromRecentsAndTags() {
        let home = FileManager.default.homeDirectoryForCurrentUser.pathKey
        XCTAssertEqual(BrowserLocation.recents.parent(selected: nil)?.location.url?.pathKey, home)
        XCTAssertEqual(BrowserLocation.tag("Red").parent(selected: nil)?.location.url?.pathKey, home)
        let f = URL(fileURLWithPath: "/tmp/x/y.txt")
        XCTAssertEqual(BrowserLocation.recents.parent(selected: f)?.location.url?.pathKey, "/tmp/x")
        XCTAssertTrue(BrowserLocation.recents.isVirtual)
        XCTAssertFalse(BrowserLocation.computer.isVirtual)
    }

    func testNormalizedLocationsCompareEqual() {
        let a = BrowserLocation.folder(URL(fileURLWithPath: "/Users/Shared"))
        let b = BrowserLocation.folder(URL(fileURLWithPath: "/Users/Shared/"))
        XCTAssertTrue(a.isSame(as: b))
        XCTAssertEqual(a.normalized, b.normalized)
    }

    private func item(_ name: String, dir: Bool = false, size: Int64? = nil, modified: Date? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/t/\(name)"), name: name, isDirectory: dir, logicalSize: size, dateModified: modified)
    }

    func testListDiffInsertRemoveUpdate() {
        let old = [item("a"), item("b"), item("c")]
        var changed = item("c"); changed.logicalSize = 9
        let new = [item("a"), changed, item("d")]
        let d = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(d?.removed, IndexSet([1]))
        XCTAssertEqual(d?.inserted, IndexSet([2]))
        XCTAssertEqual(d?.updated, IndexSet([1]))
    }

    func testListDiffReorderNeedsReset() {
        XCTAssertNil(ListDiff.compute(old: [item("a"), item("b")], new: [item("b"), item("a")]))
        XCTAssertEqual(ListDiff.compute(old: [item("a")], new: [item("a")])?.isEmpty, true)
    }

    func testSorterNumericAndFoldersFirst() {
        let items = [item("file10"), item("file2"), item("Zdir", dir: true), item("file1")]
        let byName = ItemSorter(spec: SortSpec(key: .name, ascending: true, foldersFirst: false)).sorted(items).map(\.name)
        XCTAssertEqual(byName, ["file1", "file2", "file10", "Zdir"])
        let ff = ItemSorter(spec: SortSpec(key: .name, ascending: true, foldersFirst: true)).sorted(items).map(\.name)
        XCTAssertEqual(ff.first, "Zdir")
        let desc = ItemSorter(spec: SortSpec(key: .name, ascending: false, foldersFirst: false)).sorted(items).map(\.name)
        XCTAssertEqual(desc, ["Zdir", "file10", "file2", "file1"])
    }

    func testSorterBySizeUsesFolderSizes() {
        let items = [item("small", size: 10), item("big", size: 1000), item("dir", dir: true)]
        var s = ItemSorter(spec: SortSpec(key: .size, ascending: false, foldersFirst: false))
        s.sizes = ["/t/dir": 500]
        XCTAssertEqual(s.sorted(items).map(\.name), ["big", "dir", "small"])
    }

    func testPathInputNormalization() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(PathInput.normalize("~/Documents", relativeTo: nil), (home as NSString).appendingPathComponent("Documents"))
        XCTAssertEqual(PathInput.normalize("file:///Users/Shared/My%20Folder/", relativeTo: nil), "/Users/Shared/My Folder")
        XCTAssertEqual(PathInput.normalize("  '/tmp/../usr'  ", relativeTo: nil), "/usr")
        XCTAssertEqual(PathInput.normalize("sub/dir", relativeTo: URL(fileURLWithPath: "/base")), "/base/sub/dir")
        XCTAssertNil(PathInput.normalize("relative", relativeTo: nil))
        XCTAssertEqual(PathInput.normalize("/a/b\\ c", relativeTo: nil), "/a/b c")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testPathResolveAndCompletion() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data())
        let file = PathInput.resolve(dir.appendingPathComponent("notes.txt").path, relativeTo: nil)
        XCTAssertEqual(file?.location.url?.pathKey, dir.pathKey)
        XCTAssertEqual(file?.select.first?.lastPathComponent, "notes.txt")
        let folder = PathInput.resolve(dir.appendingPathComponent("Projects").path, relativeTo: nil)
        XCTAssertEqual(folder?.location.url?.lastPathComponent, "Projects")
        XCTAssertNil(PathInput.resolve(dir.appendingPathComponent("nope").path, relativeTo: nil))
        let one = PathInput.complete(dir.path + "/Pro", relativeTo: nil, showHidden: false)
        XCTAssertEqual(one.text, dir.path + "/Projects/")
        let many = PathInput.complete(dir.path + "/P", relativeTo: nil, showHidden: false)
        XCTAssertEqual(many.matches.count, 2)
        XCTAssertEqual(PathInput.commonPrefix(["Projects", "Pictures"]), "P")
    }

    func testRenameValidationKeepsCollisionMessage() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: a.path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("b.txt").path, contents: Data())
        XCTAssertNotNil(RenameSession.validate("b.txt", renaming: a))
        XCTAssertNil(RenameSession.validate("A.txt", renaming: a))
        XCTAssertNil(RenameSession.validate("c.txt", renaming: a))
        XCTAssertNotNil(RenameSession.validate("x/y", renaming: a))
        XCTAssertNotNil(RenameSession.validate("   ", renaming: a))
    }

    func testExpansionMemoryIsBounded() {
        let suite = "bf-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let previous = BrowserDefaults.store
        BrowserDefaults.store = store
        defer { BrowserDefaults.store = previous; store.removePersistentDomain(forName: suite) }
        let oldMax = ExpansionMemory.maxRoots
        ExpansionMemory.maxRoots = 3
        defer { ExpansionMemory.maxRoots = oldMax }
        for i in 0..<5 { ExpansionMemory.set(["/r\(i)/a"], in: "/r\(i)") }
        XCTAssertTrue(ExpansionMemory.expanded(in: "/r0").isEmpty)
        XCTAssertEqual(ExpansionMemory.expanded(in: "/r4"), ["/r4/a"])
        ExpansionMemory.set([], in: "/r4")
        XCTAssertTrue(ExpansionMemory.expanded(in: "/r4").isEmpty)
    }

    private func cpuSeconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private func makeFolder(count: Int) throws -> URL {
        let dir = try makeTempDir()
        for i in 0..<count {
            let fd = open(dir.appendingPathComponent("file-\(i).txt").path, O_CREAT | O_WRONLY, 0o644)
            if fd >= 0 { close(fd) }
        }
        return dir
    }

    func testDirectoryStreamLists20kFilesQuickly() async throws {
        let dir = try makeFolder(count: 20_000)
        let listingStart = cpuSeconds()
        XCTAssertEqual(try DirectoryLister.list(dir).count, 20_000)
        let listing = cpuSeconds() - listingStart
        let token = CancelToken()
        var batches = 0
        var firstBatchSize = 0
        let start = Date()
        let cpuStart = cpuSeconds()
        let result = try await DirectoryStream.enumerate(dir, showHidden: false, token: token) { items, _ in
            batches += 1
            if firstBatchSize == 0 { firstBatchSize = items.count }
        }
        let sorted = ItemSorter(spec: SortSpec(key: .name, ascending: true, foldersFirst: false)).sorted(result.visible)
        let elapsed = Date().timeIntervalSince(start)
        let cpu = cpuSeconds() - cpuStart
        print("20k listing+sort: \(Int(elapsed * 1000)) ms, cpu \(Int(cpu * 1000)) ms, \(batches) batches")
        XCTAssertEqual(sorted.count, 20_000)
        XCTAssertGreaterThanOrEqual(firstBatchSize, 500)
        XCTAssertEqual(sorted.first?.name, "file-0.txt")
        XCTAssertLessThan(cpu, max(1.5, listing * 10))
    }

    @MainActor
    func testFolderModelLoads20kWithoutBlockingMain() throws {
        let dir = try makeFolder(count: 20_000)
        let listingStart = cpuSeconds()
        XCTAssertEqual(try DirectoryLister.list(dir).count, 20_000)
        let listing = cpuSeconds() - listingStart
        let model = FolderModel(location: .folder(dir), sort: SortSpec(key: .name, ascending: true, foldersFirst: false))
        let done = expectation(description: "loaded")
        var sawPartial = false
        var mainTicks = 0
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in mainTicks += 1 }
        model.addObserver(self) { _ in
            if model.isLoading && model.items.count > 0 && model.items.count < 20_000 { sawPartial = true }
        }
        model.onLoadingChange = {
            if !model.isLoading { done.fulfill() }
        }
        let start = Date()
        let cpuStart = cpuSeconds()
        model.start()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        wait(for: [done], timeout: 20)
        ticker.invalidate()
        let elapsed = Date().timeIntervalSince(start)
        let cpu = cpuSeconds() - cpuStart
        print("FolderModel 20k: \(Int(elapsed * 1000)) ms, cpu \(Int(cpu * 1000)) ms, main ticks \(mainTicks), partial \(sawPartial)")
        XCTAssertEqual(model.items.count, 20_000)
        XCTAssertLessThan(cpu, max(5.0, listing * 10))
        XCTAssertGreaterThan(Double(mainTicks), elapsed * 100 * 0.2)
        model.stop()
    }

    @MainActor
    func testFolderModelAppliesDiffOnFileSystemChange() throws {
        let dir = try makeFolder(count: 50)
        let model = FolderModel(location: .folder(dir.resolvingSymlinksInPath()))
        let loaded = expectation(description: "loaded")
        model.onLoadingChange = { if !model.isLoading { loaded.fulfill() } }
        model.start()
        wait(for: [loaded], timeout: 10)
        let changed = expectation(description: "diff")
        model.addObserver(self) { change in
            if case .diff(let d) = change, !d.inserted.isEmpty, model.items.contains(where: { $0.name == "new-file.txt" }) { changed.fulfill() }
        }
        model.onLoadingChange = nil
        FileManager.default.createFile(atPath: dir.appendingPathComponent("new-file.txt").path, contents: Data("x".utf8))
        wait(for: [changed], timeout: 10)
        XCTAssertEqual(model.items.count, 51)
        model.stop()
    }

    func testBusyProcessFinderRuns() {
        let found = BusyProcessFinder.processes(using: "/nonexistent-volume-\(UUID().uuidString)")
        XCTAssertTrue(found.isEmpty)
    }
}
