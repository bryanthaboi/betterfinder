import AppKit
import XCTest
import FSCore
@testable import Browser

@MainActor
final class AccessibilityTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var out: [T] = []
        for v in view.subviews {
            if let t = v as? T { out.append(t) }
            out += descendants(of: v, as: type)
        }
        return out
    }

    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-a11y-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for i in 0..<5 { FileManager.default.createFile(atPath: dir.appendingPathComponent("doc-\(i).txt").path, contents: Data("x".utf8)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func label(_ element: NSAccessibilityProtocol?) -> String { (element?.accessibilityLabel() ?? nil) ?? "" }

    func testKeyControlsExposeAccessibilityLabels() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 6 })
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(label(pane.pathBar), "Path bar")
        XCTAssertFalse(pane.pathBar.accessibilityCustomActions()?.isEmpty ?? true)
        let crumbs = descendants(of: pane.pathBar, as: CrumbButton.self)
        XCTAssertFalse(crumbs.isEmpty)
        for c in crumbs { XCTAssertFalse(label(c).isEmpty) }
        XCTAssertEqual(crumbs.last?.accessibilityValue() as? String, "Current location")
        XCTAssertEqual(label(crumbs.last), FileManager.default.displayName(atPath: dir.path))

        XCTAssertEqual(label(pane.statusBar), "Status bar")
        let statusLabel = try XCTUnwrap(descendants(of: pane.statusBar, as: ClickableLabel.self).first)
        XCTAssertEqual(label(statusLabel), "Status")
        XCTAssertTrue((statusLabel.accessibilityValue() as? String)?.contains("6 items") ?? false)
        XCTAssertEqual(label(descendants(of: pane.statusBar, as: NSSlider.self).first), "Icon size")

        XCTAssertEqual(label(pane.view), "Browser")
        XCTAssertTrue(pane.view.isAccessibilityElement())

        let sidebar = try XCTUnwrap(descendants(of: wc.sidebarController.view, as: SidebarOutlineView.self).first)
        XCTAssertEqual(label(sidebar), "Sidebar")
        var sidebarLabels: [String] = []
        for row in 0..<sidebar.numberOfRows {
            guard sidebar.item(atRow: row) is EntryBox, let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            sidebarLabels.append(label(cell))
        }
        XCTAssertFalse(sidebarLabels.isEmpty)
        XCTAssertFalse(sidebarLabels.contains(""))

        let list = try XCTUnwrap(pane.content as? ListViewController)
        XCTAssertEqual(label(list.outline), "Files in \(BrowserLocation.folder(dir).displayName)")
        let nameColumn = list.outline.column(withIdentifier: ListViewController.Col.name)
        let cells = (0..<list.outline.numberOfRows).compactMap { list.outline.view(atColumn: nameColumn, row: $0, makeIfNecessary: true) }
        XCTAssertEqual(cells.count, 6)
        XCTAssertTrue(cells.contains { label($0) == "Folder, Folder" }, cells.map { label($0) }.description)
        XCTAssertTrue(cells.allSatisfy { label($0).hasPrefix("Folder") || label($0).hasPrefix("doc-") })
        XCTAssertFalse(cells.flatMap { $0.subviews.compactMap { $0 as? NSImageView } }.contains { $0.isAccessibilityElement() })

        wc.setViewMode(.column)
        XCTAssertTrue(spin { (pane.content as? ColumnViewController)?.keyView.map { ($0 as? NSTableView)?.numberOfRows == 6 } ?? false })
        let columnTable = try XCTUnwrap(pane.content.keyView as? NSTableView)
        XCTAssertTrue(label(columnTable).hasPrefix("Files in"))
        XCTAssertTrue((0..<columnTable.numberOfRows).contains { label(columnTable.view(atColumn: 0, row: $0, makeIfNecessary: true)).hasPrefix("doc-") })

        wc.setViewMode(.icon)
        let icons = try XCTUnwrap(pane.content as? IconViewController)
        icons.view.layoutSubtreeIfNeeded()
        icons.collection.layoutSubtreeIfNeeded()
        XCTAssertTrue(spin { !icons.collection.visibleItems().isEmpty })
        for item in icons.collection.visibleItems() {
            XCTAssertTrue(item.view.isAccessibilityElement())
            XCTAssertFalse(label(item.view).isEmpty)
        }

        let toolbarItems = window.toolbar?.items ?? []
        XCTAssertFalse(toolbarItems.isEmpty)
        for item in toolbarItems where !item.label.isEmpty || item.view != nil {
            XCTAssertFalse(item.label.isEmpty && label(item.view).isEmpty, "\(item.itemIdentifier.rawValue)")
        }

        wc.toggleDualPane(nil)
        XCTAssertTrue(wc.isDualPane)
        XCTAssertEqual(wc.panes.map { label($0.view) }, ["Left pane", "Right pane"])
        XCTAssertTrue((wc.activePane.view.accessibilityValue() as? String)?.hasPrefix("Active") ?? false)
        wc.toggleDualPane(nil)
        XCTAssertEqual(label(wc.activePane.view), "Browser")
        wc.setViewMode(.list)
    }

    func testPathBarEscapeEndsEditingAndCustomActionBegins() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        let bar = wc.activePane.pathBar
        let action = try XCTUnwrap(bar.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.name, "Edit path")
        _ = action.handler?()
        XCTAssertTrue(bar.isEditing)
        let field = try XCTUnwrap(descendants(of: bar, as: NSTextField.self).first { $0.accessibilityLabel() == "Path" })
        XCTAssertTrue(bar.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(bar.isEditing)
    }

    func testInfoPanelIsLabelled() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let file = dir.appendingPathComponent("doc-1.txt")
        let c = InfoPanelController(url: file)
        XCTAssertEqual(c.window?.accessibilityLabel(), "doc-1.txt Info")
        XCTAssertEqual(c.model.icon?.representations.count, 1)
        c.close()
    }

    func testIconsAreRasterizedToRequestedSize() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let scale = IconRaster.scale
        let folder = try XCTUnwrap(DirectoryLister.item(for: dir.appendingPathComponent("Folder")))
        let placeholder = IconCache.shared.icon(for: folder, size: 16)
        XCTAssertEqual(placeholder.representations.count, 1)
        XCTAssertEqual(placeholder.representations.first?.pixelsWide, Int(16 * scale))
        let big = IconCache.shared.fileIcon(dir, size: 64)
        XCTAssertEqual(big.size, NSSize(width: 64, height: 64))
        XCTAssertEqual(big.representations.first?.pixelsWide, Int(64 * scale))
        var loaded: NSImage?
        _ = IconCache.shared.icon(for: folder, size: 32) { loaded = $0 }
        XCTAssertTrue(spin { loaded != nil })
        XCTAssertEqual(loaded?.representations.first?.pixelsWide, Int(32 * scale))
        XCTAssertTrue(IconCache.shared.icon(for: folder, size: 32) === loaded)
    }

    func testListDiffSpliceKeepsRowsInModelOrder() throws {
        _ = NSApplication.shared
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        wc.setViewMode(.list)
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 6 })
        let list = try XCTUnwrap(pane.content as? ListViewController)
        func rowsMatch() -> Bool {
            let rows = (0..<list.outline.numberOfRows).compactMap { (list.outline.item(atRow: $0) as? FileNode)?.item.url.pathKey }
            return rows == pane.model.items.map(\.url.pathKey)
        }
        XCTAssertTrue(rowsMatch())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("aaa-new.txt").path, contents: Data())
        try FileManager.default.removeItem(at: dir.appendingPathComponent("doc-2.txt"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("zzz-new.txt").path, contents: Data())
        XCTAssertTrue(spin { pane.model.items.count == 7 && pane.model.items.contains { $0.name == "zzz-new.txt" } })
        XCTAssertTrue(spin { rowsMatch() })
        try Data("bigger".utf8).write(to: dir.appendingPathComponent("doc-1.txt"))
        XCTAssertTrue(spin { pane.model.items.first { $0.name == "doc-1.txt" }?.logicalSize == 6 })
        XCTAssertTrue(spin { rowsMatch() })
        let node = (0..<list.outline.numberOfRows).compactMap { list.outline.item(atRow: $0) as? FileNode }.first { $0.item.name == "doc-1.txt" }
        XCTAssertEqual(node?.item.logicalSize, 6)
    }
}
