import AppKit
import XCTest
import FSCore
@testable import Browser

@MainActor
final class WindowSmokeTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-smoke-\(UUID().uuidString)").resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Sub/Deeper"), withIntermediateDirectories: true)
        for i in 0..<30 { fm.createFile(atPath: dir.appendingPathComponent("file-\(i).txt").path, contents: Data("hello \(i)".utf8)) }
        fm.createFile(atPath: dir.appendingPathComponent("Sub/inner-needle.txt").path, contents: Data())
        fm.createFile(atPath: dir.appendingPathComponent(".hidden").path, contents: Data())
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testBrowserWindowEndToEnd() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 31 })
        XCTAssertEqual(pane.model.hiddenCount, 1)
        XCTAssertTrue(pane.statusBar.text.contains("31 items"), pane.statusBar.text)
        XCTAssertTrue(pane.statusBar.text.contains("1 hidden"), pane.statusBar.text)

        let sub = dir.appendingPathComponent("Sub")
        pane.navigate(to: .folder(sub))
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 2 })
        wc.goUp(nil)
        XCTAssertTrue(spin { pane.location.url?.pathKey == dir.pathKey && pane.selectedURLs.first?.pathKey == sub.pathKey })
        XCTAssertTrue(pane.statusBar.text.hasPrefix("Sub"), pane.statusBar.text)

        wc.goBack(nil)
        XCTAssertTrue(spin { pane.location.url?.pathKey == sub.pathKey })
        wc.goForward(nil)
        XCTAssertTrue(spin { pane.location.url?.pathKey == dir.pathKey })

        for mode in [BrowserViewMode.column, .icon, .list] {
            wc.setViewMode(mode)
            XCTAssertEqual(pane.viewMode, mode)
            XCTAssertTrue(spin { pane.model.items.count == 31 })
            pane.content.select([dir.appendingPathComponent("file-3.txt")], scroll: true)
            XCTAssertEqual(pane.selectedURLs.map(\.lastPathComponent), ["file-3.txt"], "\(mode)")
        }

        wc.setViewMode(.column)
        pane.content.select([sub], scroll: true)
        (pane.content as? ColumnViewController)?.moveRight()
        XCTAssertTrue(spin { pane.location.url.map { $0.pathKey == sub.pathKey || $0.pathKey == sub.appendingPathComponent("Deeper").pathKey } ?? false })
        pane.navigate(to: .folder(sub))
        wc.setViewMode(.list)
        XCTAssertTrue(spin { pane.model.items.count == 2 })
        wc.goUp(nil)
        XCTAssertTrue(spin { pane.location.url?.pathKey == dir.pathKey && pane.model.items.count == 31 })

        wc.toggleDualPane(nil)
        XCTAssertTrue(wc.isDualPane)
        let second = try XCTUnwrap(wc.otherPane(than: pane))
        XCTAssertTrue(spin { second.model.items.count == 31 })
        wc.switchPane(nil)
        XCTAssertTrue(wc.activePane === second)
        wc.switchPane(nil)
        wc.toggleDualPane(nil)
        XCTAssertFalse(wc.isDualPane)

        pane.search("needle", scope: .folder)
        guard case .search(let scope, let q) = pane.location else { return XCTFail("not searching") }
        XCTAssertEqual(scope.pathKey, dir.pathKey)
        XCTAssertEqual(q, "needle")
        XCTAssertTrue(spin(until: { pane.model.items.contains { $0.name == "inner-needle.txt" } }, timeout: 20), "search found nothing")
        pane.content.select([sub.appendingPathComponent("inner-needle.txt")], scroll: true)
        XCTAssertEqual(pane.selectedURLs.count, 1)
        wc.goUp(nil)
        XCTAssertTrue(spin { pane.location.url?.pathKey == sub.pathKey && pane.selectedURLs.first?.lastPathComponent == "inner-needle.txt" })

        pane.navigate(to: .folder(URL(fileURLWithPath: "/")))
        XCTAssertNotNil(pane.upTarget)
        wc.goUp(nil)
        XCTAssertEqual(pane.location, .computer)
        XCTAssertNil(pane.upTarget)
        XCTAssertTrue(spin { !pane.model.items.isEmpty })

        pane.navigate(to: .folder(dir))
        XCTAssertTrue(spin { pane.model.items.count == 31 })
        FileManager.default.createFile(atPath: dir.appendingPathComponent("live.txt").path, contents: Data())
        XCTAssertTrue(spin { pane.model.items.contains { $0.name == "live.txt" } })
        pane.newFolder(nil)
        XCTAssertTrue(spin { pane.model.items.contains { $0.name == "untitled folder" } })

        wc.close()
    }

    func testPathBarResolvesTypedPath() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(FileManager.default.homeDirectoryForCurrentUser))
        let pane = wc.activePane
        let r = PathInput.resolve("file://" + dir.appendingPathComponent("file-1.txt").path, relativeTo: nil)
        let res = try XCTUnwrap(r)
        pane.navigate(to: res.location, select: res.select)
        XCTAssertTrue(spin { pane.selectedURLs.first?.lastPathComponent == "file-1.txt" })
        wc.close()
    }
}
