import AppKit
import XCTest
import FSCore
@testable import Browser

@MainActor
final class IndexedSizeBrowsingTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-sizes-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeEngine() throws -> SizeEngine {
        let database = try tempDir("index").appendingPathComponent("index.sqlite")
        let daemon = try SizeIndexDaemon(databaseURL: database)
        addTeardownBlock { daemon.stop() }
        return SizeEngine(databaseURL: database, control: daemon)
    }

    func testCoordinatorShowsIndexedSizesAtOnceAndNeverBlanksThem() throws {
        let dir = try tempDir("coord")
        var folders: [URL] = []
        for i in 0..<6 {
            let folder = dir.appendingPathComponent("folder-\(i)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try Data(count: 100 * (i + 1)).write(to: folder.appendingPathComponent("inner/data"))
            folders.append(folder)
        }
        let engine = try makeEngine()
        let first = SizeCoordinator()
        first.engine = engine
        first.request(visible: folders, container: dir)
        XCTAssertTrue(spin { folders.allSatisfy { first.result(for: $0)?.isComplete == true } })
        XCTAssertEqual(folders.map { first.result(for: $0)?.logicalBytes }, [100, 200, 300, 400, 500, 600])
        first.reset()

        let again = SizeCoordinator()
        again.engine = engine
        var history: [String: [SizeResult]] = [:]
        again.onUpdate = { key in history[key, default: []].append(again.results[key]!) }
        again.request(visible: folders, container: dir)
        XCTAssertEqual(folders.map { again.result(for: $0)?.logicalBytes }, [100, 200, 300, 400, 500, 600])
        XCTAssertTrue(folders.allSatisfy { again.result(for: $0)?.isSettled == true })

        try Data(count: 5000).write(to: folders[2].appendingPathComponent("inner/more"))
        engine.refresh(paths: [folders[2].appendingPathComponent("inner/more").path])
        again.touch(path: folders[2].appendingPathComponent("inner/more").path, under: dir.pathKey)
        XCTAssertTrue(spin { again.result(for: folders[2])?.logicalBytes == 5300 && again.result(for: folders[2])?.isComplete == true })
        let seen = history[folders[2].pathKey] ?? []
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0.isSettled && ($0.logicalBytes == 300 || $0.logicalBytes == 5300) }, "\(seen)")
        XCTAssertEqual(again.result(for: folders[0])?.logicalBytes, 100)
        again.reset()
    }

    func testSizesArrivingWhileSortedBySizeKeepScrollPositionAndSelection() throws {
        _ = NSApplication.shared
        IndexTestHost.install()
        let savedSort = BrowserDefaults.sort
        let savedMode = BrowserDefaults.viewMode
        addTeardownBlock { await MainActor.run { BrowserDefaults.sort = savedSort; BrowserDefaults.viewMode = savedMode } }
        BrowserDefaults.sort = SortSpec(key: .size, ascending: false, foldersFirst: false)

        let dir = try tempDir("scroll")
        let count = 120
        for i in 0..<count {
            let folder = dir.appendingPathComponent(String(format: "folder-%03d", i))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: (i + 1) * 8192).write(to: folder.appendingPathComponent("data"))
        }
        let wc = BrowserWindowController(location: .folder(dir))
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 500), display: false)
        wc.setViewMode(.list)
        let pane = wc.activePane
        addTeardownBlock { await MainActor.run { wc.close() } }
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == count })
        let expected = (0..<count).reversed().map { String(format: "folder-%03d", $0) }
        XCTAssertTrue(spin(until: { pane.model.items.map(\.name) == expected }, timeout: 30), "never sorted by indexed size")
        XCTAssertEqual(pane.sizes.results.count, count)

        let scroll = try XCTUnwrap(pane.content.view as? NSScrollView)
        let clip = scroll.contentView
        pane.content.select([dir.appendingPathComponent("folder-118")], scroll: true)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 1400))
        scroll.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = clip.bounds.origin.y
        XCTAssertGreaterThan(before, 800)

        let riser = dir.appendingPathComponent("folder-000")
        try Data(count: 4_000_000).write(to: riser.appendingPathComponent("huge"))
        XCTAssertTrue(spin(until: { pane.model.items.first?.name == "folder-000" }, timeout: 30), "order never followed the new size")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(clip.bounds.origin.y, before, accuracy: 0.5)
        XCTAssertEqual(pane.selectedURLs.map(\.lastPathComponent), ["folder-118"])
        XCTAssertEqual(pane.model.items.count, count)
    }
}
