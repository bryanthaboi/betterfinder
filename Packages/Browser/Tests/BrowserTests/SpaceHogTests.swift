import AppKit
import XCTest
import FSCore
@testable import Browser

@MainActor
final class SpaceHogTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bf-hog-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SizeIndexLocation.canonical(url)
    }

    private func make(_ url: URL, files: [String: Int] = [:]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, size) in files { try Data(count: size).write(to: url.appendingPathComponent(name)) }
    }

    private func index(_ root: URL, in temp: URL) throws -> URL {
        let database = temp.appendingPathComponent("index.sqlite")
        try SizeIndexWriter(databaseURL: database).scan(root)
        return database
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testHeatScaleUsesTheSameFixedStepsAsTheMod() {
        let mb = HeatScale.megabyte
        XCTAssertEqual([0, mb - 1, mb, 3 * mb, 99 * mb, 1024 * mb, 30 * 1024 * mb, 900 * 1024 * mb].map(HeatScale.level), [0, 0, 1, 2, 4, 7, 10, 10])
        XCTAssertEqual(HeatBarView.fills(level: 0), [0, 0, 0, 0, 0])
        XCTAssertEqual(HeatBarView.fills(level: 3), [1, 0.5, 0, 0, 0])
        XCTAssertEqual(HeatBarView.fills(level: 10), [1, 1, 1, 1, 1])
        XCTAssertEqual(HeatScale.label(nil), "Not measured yet")
        XCTAssertTrue(HeatScale.label(5 * mb).hasPrefix("small, "))
        XCTAssertTrue(HeatScale.label(40 * 1024 * mb).hasPrefix("huge, "))
        XCTAssertGreaterThan(HeatScale.hue(level: 1), HeatScale.hue(level: 5))
        XCTAssertEqual(HeatScale.hue(level: 10), 0, accuracy: 0.001)
        XCTAssertNotEqual(HeatScale.color(level: 1), HeatScale.color(level: 9))
    }

    func testSquarifiedLayoutFillsTheRectInProportion() {
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let weights: [Double] = [500, 300, 120, 50, 20, 9, 1, 0]
        let rects = Treemap.squarify(weights, in: rect)
        XCTAssertEqual(rects.count, weights.count)
        XCTAssertEqual(rects.last, .zero)
        let total = weights.reduce(0, +)
        for (weight, frame) in zip(weights, rects) where weight > 0 {
            XCTAssertEqual(Double(frame.width * frame.height), weight / total * 240_000, accuracy: 0.5)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(frame)")
        }
        for i in rects.indices { for j in rects.indices where i < j && weights[j] > 0 {
            let overlap = rects[i].intersection(rects[j])
            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01, "\(rects[i]) overlaps \(rects[j])")
        } }
        XCTAssertLessThan(rects[0].width / rects[0].height, 3)
        XCTAssertEqual(Treemap.squarify([], in: rect), [])
        XCTAssertEqual(Treemap.squarify([1, 2], in: .zero), [.zero, .zero])
    }

    func testMapIsBuiltFromTheIndexWithLooseFilesAndBigFilesBrokenOut() throws {
        let temp = try temporary()
        let root = temp.appendingPathComponent("root")
        try make(root.appendingPathComponent("media/raw"), files: ["clip": 900_000])
        try make(root.appendingPathComponent("media"), files: ["poster": 300_000])
        try make(root.appendingPathComponent("docs"), files: ["a": 60_000, "b": 20_000])
        try make(root.appendingPathComponent("empty"))
        try make(root, files: ["huge.bin": 500_000, "note": 4_000])
        let tree = try SizeIndexTree(databaseURL: try index(root, in: temp))
        let map = try XCTUnwrap(SpaceHogBuilder.build(tree: tree, root: root))

        XCTAssertEqual(map.children.map(\.name), ["media", "Files in root", "docs"])
        XCTAssertEqual(map.children.map(\.branch), [0, -1, 2])
        let media = map.children[0]
        XCTAssertEqual(media.children.map(\.name), ["raw", "Files in media"])
        XCTAssertTrue(media.children.allSatisfy { $0.branch == 0 && $0.depth == 2 })
        XCTAssertEqual(media.children[0].url.path, root.appendingPathComponent("media/raw").path)
        let loose = map.children[1]
        XCTAssertEqual(loose.kind, .looseFiles)
        XCTAssertEqual(loose.children.map(\.name), ["huge.bin", "note"])
        XCTAssertEqual(loose.children.first?.kind, .file)
        XCTAssertEqual(loose.children.first?.url.path, root.appendingPathComponent("huge.bin").path)
        XCTAssertEqual(loose.children.reduce(0) { $0 + $1.bytes }, loose.bytes)
        XCTAssertEqual(map.bytes, map.children.reduce(0) { $0 + $1.bytes })
        XCTAssertTrue(map.children[0].isActionable)
        XCTAssertFalse(loose.isActionable)
        XCTAssertTrue(loose.children[0].isActionable)
        XCTAssertEqual(loose.children[0].folderURL.path, root.path)

        SpaceHogBuilder.layout(map, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(map.rect.width, 800)
        var leaves: [HogNode] = []
        func collect(_ node: HogNode) { if node.children.isEmpty { leaves.append(node) } else { node.children.forEach(collect) } }
        collect(map)
        XCTAssertEqual(leaves.count, map.leafCount)
        for leaf in leaves {
            XCTAssertGreaterThan(leaf.rect.width, 0, leaf.name)
            XCTAssertTrue(map.rect.contains(leaf.rect), leaf.name)
            let centre = CGPoint(x: leaf.rect.midX, y: leaf.rect.midY)
            XCTAssertTrue(map.node(at: centre) === leaf, leaf.name)
            XCTAssertTrue(leaf.ancestor(below: map)?.parent === map)
        }
        XCTAssertNil(map.node(at: CGPoint(x: -5, y: 10)))
        XCTAssertNotEqual(SpaceHogBuilder.color(for: map.children[0]), SpaceHogBuilder.color(for: map.children[2]))
        XCTAssertNil(SpaceHogBuilder.build(tree: tree, root: temp.appendingPathComponent("missing")))

        let capped = try XCTUnwrap(SpaceHogBuilder.build(tree: tree, root: root, budget: 1))
        XCTAssertTrue(capped.children.isEmpty)
        let unlisted = try XCTUnwrap(SpaceHogBuilder.build(tree: tree, root: root, listFiles: { _ in [] }))
        XCTAssertTrue(unlisted.children[1].children.isEmpty)
    }

    func testIndexStatusNumbersSayWhatIsLeft() {
        XCTAssertEqual(IndexStatusLine.parts(nil).map(\.text), ["no index"])
        var stats = IndexStatistics()
        stats.roots = ["/Users/someone"]
        stats.folders = 1_690_112
        stats.items = 8_083_033
        stats.allocatedBytes = 5_000_000
        stats.databaseBytes = 2_000_000
        let done = IndexStatusLine.parts(stats)
        XCTAssertEqual(done.first?.text, "up to date")
        XCTAssertEqual(done.map(\.text).filter { $0.contains("folders") || $0.contains("items") }, ["1.69M folders", "8.08M items"])
        XCTAssertFalse(done.contains { $0.isAlert })
        XCTAssertTrue(done.allSatisfy { !$0.help.isEmpty })

        stats.unscannedFolders = 18_846
        stats.pendingFolders = 18_846 + 38_080
        stats.unreadableFolders = 252
        let busy = IndexStatusLine.parts(stats).map(\.text)
        XCTAssertEqual(busy.first, "indexing")
        XCTAssertTrue(busy.contains("18.8k never scanned"))
        XCTAssertTrue(busy.contains("38.1k to re-check"))
        XCTAssertTrue(busy.contains("252 unreadable"))
        XCTAssertEqual(IndexStatusLine.compact(999), "999")
    }

    func testSpaceHogWindowShowsTheFolderAndZoomsIn() throws {
        _ = NSApplication.shared
        let temp = try temporary()
        let root = temp.appendingPathComponent("root")
        try make(root.appendingPathComponent("big/deeper"), files: ["x": 700_000])
        try make(root.appendingPathComponent("small"), files: ["y": 90_000])
        try make(root, files: ["loose": 200_000])
        let database = try index(root, in: temp)
        let controller = SpaceHogViewController(rootURL: root)
        controller.database = { database }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        controller.reload()
        XCTAssertTrue(spin { controller.root != nil })
        XCTAssertEqual(controller.table.numberOfRows, 3)
        XCTAssertEqual(controller.root?.children.map(\.name), ["big", "Files in root", "small"])
        XCTAssertTrue(controller.emptyLabel.isHidden)
        XCTAssertTrue(controller.pathLabel.stringValue.contains("root"))
        XCTAssertEqual((controller.statusStack.arrangedSubviews.first as? NSTextField)?.stringValue, "up to date")
        XCTAssertTrue(controller.statusStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("4 folders"))
        XCTAssertFalse(controller.trashButton.isEnabled)

        window.layoutIfNeeded()
        controller.treemap.setFrameSize(NSSize(width: 700, height: 500))
        let big = try XCTUnwrap(controller.root?.children.first)
        XCTAssertGreaterThan(big.rect.width, 0)
        controller.treemap.selected = big
        controller.treemap.onSelect?(big)
        XCTAssertTrue(controller.trashButton.isEnabled)
        XCTAssertEqual(controller.table.selectedRow, 0)
        XCTAssertTrue(controller.detailLabel.stringValue.contains("big"))
        XCTAssertNotNil(controller.menu(for: big)?.items.first { $0.title.hasPrefix("Zoom Into") })
        let image = NSImage(size: controller.treemap.bounds.size)
        image.lockFocusFlipped(true)
        controller.treemap.draw(controller.treemap.bounds)
        image.unlockFocus()

        controller.treemap.onZoom?(big)
        XCTAssertTrue(spin { controller.root?.name == "big" })
        XCTAssertEqual(controller.root?.children.map(\.name), ["deeper"])
        controller.zoomOut()
        XCTAssertTrue(spin { controller.root?.name == "root" })

        controller.show(temp.appendingPathComponent("nowhere"))
        XCTAssertTrue(spin { controller.root == nil && !controller.emptyLabel.isHidden })
        XCTAssertEqual(controller.emptyLabel.stringValue, "This folder isn’t in the file index yet.")
    }

    func testHeatColumnIsBuiltInAndSortsBySize() throws {
        _ = NSApplication.shared
        let savedSort = BrowserDefaults.sort
        let savedMode = BrowserDefaults.viewMode
        addTeardownBlock { await MainActor.run { BrowserDefaults.sort = savedSort; BrowserDefaults.viewMode = savedMode } }
        BrowserDefaults.sort = SortSpec(key: .name, ascending: true, foldersFirst: false)
        XCTAssertTrue(BrowserDefaults.defaultColumns.contains("heat"))
        let dir = try temporary()
        try Data(count: 3_000_000).write(to: dir.appendingPathComponent("a-big"))
        try Data(count: 10).write(to: dir.appendingPathComponent("b-small"))
        let wc = BrowserWindowController(location: .folder(dir))
        wc.setViewMode(.list)
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 2 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        let outline = list.outline
        let column = try XCTUnwrap(outline.tableColumn(withIdentifier: ListViewController.Col.heat))
        XCTAssertEqual(column.title, "Heat")
        XCTAssertEqual(list.heatValue(for: pane.model.items[0]).bytes, 3_000_000)
        let index = outline.column(withIdentifier: ListViewController.Col.heat)
        column.isHidden = false
        let cell = try XCTUnwrap(list.outlineView(outline, viewFor: column, item: try XCTUnwrap(outline.item(atRow: 0))) as? HeatCellView)
        XCTAssertEqual(cell.bar.bytes, 3_000_000)
        XCTAssertEqual(cell.accessibilityValue() as? String, HeatScale.label(3_000_000))
        XCTAssertGreaterThanOrEqual(index, 0)

        outline.sortDescriptors = [try XCTUnwrap(column.sortDescriptorPrototype)]
        XCTAssertEqual(BrowserDefaults.sort.key, .size)
        XCTAssertFalse(BrowserDefaults.sort.ascending)
        XCTAssertTrue(spin { pane.model.items.map(\.name) == ["a-big", "b-small"] })
        outline.sortDescriptors = [try XCTUnwrap(column.sortDescriptorPrototype)]
        XCTAssertTrue(BrowserDefaults.sort.ascending)
        XCTAssertTrue(spin { pane.model.items.map(\.name) == ["b-small", "a-big"] })
    }
}
