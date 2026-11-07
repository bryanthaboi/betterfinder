import AppKit
import XCTest
import FSCore
import FileOps
import Theming
import WebKit
@testable import Browser

private final class DenyRenameHook: FileOperationHook, @unchecked Sendable {
    let id = "test.deny-rename"
    let priority = 0
    let reason: String
    init(reason: String) { self.reason = reason }
    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision {
        snapshot.kind == .rename ? .deny(reason) : .allow
    }
}

private final class DenyKindHook: FileOperationHook, @unchecked Sendable {
    let id = "test.deny-kind"
    let priority = 0
    let kind: OperationKind
    init(_ kind: OperationKind) { self.kind = kind }
    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision {
        snapshot.kind == kind ? .deny("not today") : .allow
    }
}

final class MigrationTests: RegistryTestCase {
    private func makeField(for url: URL) -> (NSWindow, NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 10, y: 40, width: 260, height: 22)
        window.contentView?.addSubview(field)
        return (window, field)
    }

    func testInlineRenameWithDenyingHookKeepsTypedTextAndShowsReason() throws {
        let dir = try makeTree()
        let url = dir.appendingPathComponent("file-1.txt")
        let hook = DenyRenameHook(reason: "protected folder")
        let token = FileOperationHookRegistry.shared.register(hook, owner: "tester")
        defer { token.cancel() }
        let (window, field) = makeField(for: url)
        _ = window
        var finished: [URL?] = []
        RenameSession.begin(url: url, field: field) { finished.append($0) }
        let session = try XCTUnwrap(RenameSession.current)
        InlineWarning.resetLastMessage()
        field.stringValue = "renamed.txt"
        session.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(spin { session.failureMessage != nil })
        XCTAssertEqual(field.stringValue, "renamed.txt")
        XCTAssertEqual(session.failureMessage, "tester blocked this operation: protected folder")
        XCTAssertEqual(InlineWarning.lastMessage, session.failureMessage)
        XCTAssertFalse(session.isFinished)
        XCTAssertTrue(finished.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("renamed.txt").path))
        XCTAssertTrue(field.isEditable)

        token.cancel()
        field.stringValue = "renamed.txt"
        session.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(spin { session.isFinished })
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first??.lastPathComponent, "renamed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("renamed.txt").path))
        InlineWarning.dismiss()
    }

    func testRenameWithoutHooksStillWorksThroughAsyncAPIAndUndoRegisteredOnce() throws {
        let dir = try makeTree()
        let url = dir.appendingPathComponent("file-2.txt")
        let um = UndoManager()
        FileOperationQueue.shared.undoManager = um
        defer { FileOperationQueue.shared.undoManager = UndoManager() }
        let (window, field) = makeField(for: url)
        _ = window
        RenameSession.begin(url: url, field: field) { _ in }
        let session = try XCTUnwrap(RenameSession.current)
        field.stringValue = "two.txt"
        session.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(spin { session.isFinished })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("two.txt").path))
        XCTAssertEqual(um.undoActionName, "Rename")
        um.undo()
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: url.path) })
        XCTAssertFalse(um.canUndo)
    }

    func testSyncRenameThrowsWhenHooksRegisteredSoCallSitesMustBeAsync() throws {
        let dir = try makeTree()
        let token = FileOperationHookRegistry.shared.register(DenyRenameHook(reason: "x"), owner: "tester")
        defer { token.cancel() }
        XCTAssertThrowsError(try FileActions.rename(dir.appendingPathComponent("file-1.txt"), to: "q.txt")) { XCTAssertTrue($0 is HooksRequireAsync) }
        let exp = expectation(description: "denied")
        Task {
            do { _ = try await FileActions.renameAsync(dir.appendingPathComponent("file-1.txt"), to: "q.txt") } catch { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5)
    }

    func testNewFolderThroughPaneUsesAsyncPathAndDeniedHookCreatesNothing() throws {
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: BrowserRegistries())
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 9 })
        let token = FileOperationHookRegistry.shared.register(DenyKindHook(.newFile), owner: "tester")
        defer { token.cancel() }
        pane.newFolder(nil)
        XCTAssertTrue(spin { pane.model.items.contains { $0.name == "untitled folder" } })
        XCTAssertEqual(pane.model.items.filter { $0.name.hasPrefix("untitled") }.count, 1)
    }

    func testInfoModelRenameAndTagsUseAsyncAPIs() throws {
        let dir = try makeTree()
        let url = dir.appendingPathComponent("file-3.txt")
        let model = InfoModel(url: url)
        model.rename(to: "three.txt")
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: dir.appendingPathComponent("three.txt").path) })
        let token = FileOperationHookRegistry.shared.register(DenyRenameHook(reason: "locked"), owner: "tester")
        defer { token.cancel() }
        let model2 = InfoModel(url: dir.appendingPathComponent("file-4.txt"))
        model2.rename(to: "four.txt")
        XCTAssertTrue(spin { model2.message?.contains("locked") == true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("file-4.txt").path))
        model2.setTags(["Red"])
        XCTAssertTrue(spin { model2.tags == ["Red"] })
    }

    func testIconCacheConsultsIconResolverFirstAndFlushesOnNotification() throws {
        let marker = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.systemPink.setFill(); rect.fill(); return true }
        let item = FileItem(url: URL(fileURLWithPath: "/tmp/bf-icon/sample.txt"), name: "sample.txt", isDirectory: false, contentTypeIdentifier: "public.plain-text")
        let before = IconCache.shared.typeIcon(for: item, size: 16)
        XCTAssertNotEqual(before, marker)
        let provider = StaticIconSetProvider(setID: IconSetRegistry.shared.activeSetID, kinds: [.file: marker])
        let token = IconSetRegistry.shared.register(provider, owner: "bf-tests")
        defer { IconSetRegistry.shared.remove(token) }
        XCTAssertTrue(spin { IconCache.shared.typeIcon(for: item, size: 16) === marker })
        XCTAssertTrue(IconCache.shared.icon(for: item, size: 16) === marker)
        var notified = false
        let obs = NotificationCenter.default.addObserver(forName: .browserIconsDidInvalidate, object: nil, queue: .main) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(obs) }
        IconSetRegistry.shared.remove(token)
        XCTAssertTrue(spin { notified })
        XCTAssertFalse(IconCache.shared.typeIcon(for: item, size: 16) === marker)
        XCTAssertFalse(IconCache.shared.icon(for: item, size: 16) === marker)
    }
}

final class ModUITests: RegistryTestCase {
    private func sample() -> ModUINode {
        .stack(id: "root", [
            .label(id: "title", "Settings", style: .title),
            .label(id: "note", "Secondary", style: .secondary),
            .stack(id: "row", axis: .horizontal, [
                .textField(id: "name", value: "abc", placeholder: "Name", accessibilityLabel: "Name field"),
                .button(id: "go", title: "Go", symbolName: "play.fill"),
                .button(id: "iconOnly", title: "", symbolName: "gear", accessibilityLabel: "Settings"),
            ]),
            .toggle(id: "flag", title: "Enabled", isOn: true),
            .list(id: "list", items: [ModUIListItem(id: "a", title: "Alpha", subtitle: "first", symbolName: "star"), ModUIListItem(id: "b", title: "Beta")], selectedID: "a", accessibilityLabel: "Letters"),
            .table(id: "table", columns: [ModUITableColumn(id: "n", title: "Name"), ModUITableColumn(id: "s", title: "Size", isRightAligned: true)],
                   rows: [ModUITableRow(id: "r1", cells: ["n": "x.txt", "s": "1 KB"], symbolName: "doc")], accessibilityLabel: "Files"),
            .image(id: "img", source: .symbol("photo"), accessibilityLabel: "A photo"),
            .progress(id: "prog", value: 0.5, caption: "Halfway", accessibilityLabel: "Upload"),
            .separator(id: "sep"),
        ])
    }

    func testRenderedControlsAreAccessibleFocusableAndThemed() throws {
        let node = sample()
        XCTAssertEqual(node.accessibilityIssues(), [])
        let renderer = ModUIRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(renderer.rootView)
        NSLayoutConstraint.activate([
            renderer.rootView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            renderer.rootView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            renderer.rootView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        renderer.render(node)
        window.contentView?.layoutSubtreeIfNeeded()
        let ids = Set(node.allIDs)
        for id in ids where id != "root" && id != "row" {
            XCTAssertNotNil(renderer.control(withID: id), id)
        }
        for id in ["name", "go", "iconOnly", "flag", "list", "table", "prog", "img"] {
            let view = try XCTUnwrap(renderer.control(withID: id))
            XCTAssertFalse((view.accessibilityLabel() ?? "").isEmpty, "\(id) needs a VoiceOver label")
        }
        XCTAssertEqual(renderer.control(withID: "iconOnly")?.accessibilityLabel(), "Settings")
        XCTAssertEqual(renderer.control(withID: "name")?.accessibilityLabel(), "Name field")
        XCTAssertEqual(renderer.control(withID: "prog")?.accessibilityValue() as? String, "50 percent")
        for id in ["name", "go", "iconOnly", "flag"] {
            XCTAssertTrue(renderer.control(withID: id)?.acceptsFirstResponder ?? false, "\(id) must be keyboard focusable")
        }
        XCTAssertTrue(renderer.control(withID: "list")?.acceptsFirstResponder ?? false)
        let theme = ThemeManager.shared.current
        XCTAssertEqual((renderer.control(withID: "title") as? NSTextField)?.font?.pointSize, theme.uiFont.pointSize + 3)
        XCTAssertEqual((renderer.control(withID: "note") as? NSTextField)?.textColor, theme.secondaryTextColor)
        XCTAssertEqual((renderer.control(withID: "name") as? NSTextField)?.font, theme.uiFont)
        XCTAssertEqual((renderer.control(withID: "list") as? NSTableView)?.backgroundColor, theme.listBackground)
        XCTAssertEqual((renderer.control(withID: "table") as? NSTableView)?.numberOfRows, 1)
        XCTAssertEqual((renderer.control(withID: "list") as? NSTableView)?.selectedRow, 0)
        window.makeFirstResponder(renderer.control(withID: "name"))
        XCTAssertTrue(window.firstResponder is NSText)
    }

    func testEventsGoBackThroughCallback() throws {
        let renderer = ModUIRenderer()
        var events: [ModUIEvent] = []
        renderer.onEvent = { events.append($0) }
        renderer.render(sample())
        (renderer.control(withID: "go") as? NSButton)?.performClick(nil)
        let field = try XCTUnwrap(renderer.control(withID: "name") as? NSTextField)
        field.stringValue = "abcd"
        renderer.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        renderer.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        (renderer.control(withID: "flag") as? NSButton)?.performClick(nil)
        let list = try XCTUnwrap(renderer.control(withID: "list") as? NSTableView)
        list.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertEqual(events, [
            ModUIEvent(nodeID: "go", kind: .press),
            ModUIEvent(nodeID: "name", kind: .textChanged("abcd")),
            ModUIEvent(nodeID: "name", kind: .textCommitted("abcd")),
            ModUIEvent(nodeID: "flag", kind: .toggled(false)),
            ModUIEvent(nodeID: "list", kind: .selected("b")),
        ])
    }

    func testRerenderKeepsFocusAndAccessibilityIssuesAreReported() throws {
        let renderer = ModUIRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(renderer.rootView)
        renderer.render(.stack(id: "root", [.textField(id: "t", value: "a", accessibilityLabel: "T")]))
        window.makeFirstResponder(renderer.control(withID: "t"))
        renderer.render(.stack(id: "root", [.textField(id: "t", value: "ab", accessibilityLabel: "T")]))
        XCTAssertEqual((renderer.control(withID: "t") as? NSTextField)?.stringValue, "ab")
        XCTAssertTrue(window.firstResponder is NSText)

        let bad = ModUINode.stack(id: "r", [.textField(id: "t", value: ""), .image(id: "i", source: .symbol("star")), .button(id: "b", title: "")])
        XCTAssertEqual(bad.accessibilityIssues().count, 3)
    }

    func testPanelRendersModUINodeThroughRegistry() throws {
        let regs = BrowserRegistries()
        let wc = makeWindow(try makeTree(), registries: regs)
        defer { wc.close() }
        var events: [ModUIEvent] = []
        regs.panels.register(PanelSpec(id: "p", title: "UI", defaultOpen: true, content: .ui(.stack(id: "r", [.button(id: "hit", title: "Hit")])), onEvent: { events.append($0) }), owner: "tester")
        let inst = try XCTUnwrap(wc.panelHost?.instances["tester/p"])
        inst.vc.uiRenderer.control(withID: "hit").flatMap { $0 as? NSButton }?.performClick(nil)
        XCTAssertEqual(events, [ModUIEvent(nodeID: "hit", kind: .press)])
    }
}

final class PreviewTests: RegistryTestCase {
    struct StaticPreview: PreviewProvider {
        let content: PreviewContent
        func render(_ item: FileItem, context: PreviewContext) async throws -> PreviewContent { content }
    }

    struct SlowPreview: PreviewProvider {
        func render(_ item: FileItem, context: PreviewContext) async throws -> PreviewContent {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return .text("slow \(item.name)")
        }
    }

    struct FailingPreview: PreviewProvider {
        func render(_ item: FileItem, context: PreviewContext) async throws -> PreviewContent { throw CocoaError(.fileReadCorruptFile) }
    }

    private func item(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/tmp/bf-prev/\(name)"), name: name, isDirectory: false, contentTypeIdentifier: name.hasSuffix(".md") ? "net.daringfireball.markdown" : "public.plain-text") }

    func testPreviewMatchingPriorityAndLiveRemoval() {
        let reg = PreviewRegistry()
        let low = reg.register(PreviewSpec(id: "low", title: "Low", extensions: ["md"], priority: 0, provider: StaticPreview(content: .text("low"))), owner: "a")
        _ = reg.register(PreviewSpec(id: "high", title: "High", extensions: [".MD"], priority: 5, provider: StaticPreview(content: .text("high"))), owner: "b")
        _ = reg.register(PreviewSpec(id: "txt", title: "Text", typeIdentifiers: ["public.text"], provider: StaticPreview(content: .text("t"))), owner: "c")
        XCTAssertEqual(reg.entry(matching: item("a.md"))?.qualifiedID, "b/high")
        XCTAssertEqual(reg.entry(matching: item("a.txt"))?.qualifiedID, "c/txt")
        XCTAssertNil(reg.entry(matching: FileItem(url: URL(fileURLWithPath: "/tmp/x"), name: "x", isDirectory: true)))
        reg.removeAll(owner: "b")
        XCTAssertEqual(reg.entry(matching: item("a.md"))?.qualifiedID, "a/low")
        low.cancel()
        XCTAssertEqual(reg.entry(matching: item("a.md"))?.qualifiedID, "c/txt")
        reg.register(PreviewSpec(id: "none", title: "None", provider: StaticPreview(content: .text(""))), owner: "z")
        XCTAssertNil(reg.entry("z/none"))
    }

    func testPreviewPanelRendersNativeSpecAndHandlesFailureAndSwitching() throws {
        let regs = BrowserRegistries()
        regs.previews.register(PreviewSpec(id: "native", title: "Native", extensions: ["txt"], provider: StaticPreview(content: .native(.stack(id: "r", [.label(id: "l", "hello")])))), owner: "a")
        regs.previews.register(PreviewSpec(id: "bad", title: "Bad", extensions: ["bad"], provider: FailingPreview()), owner: "a")
        regs.previews.register(PreviewSpec(id: "slow", title: "Slow", extensions: ["slow"], provider: SlowPreview()), owner: "a")
        let panel = PreviewPanelController(registries: regs)
        defer { panel.close() }
        panel.present(item("a.txt"), location: .computer, selectionCount: 1)
        XCTAssertEqual(panel.state, .loading)
        XCTAssertTrue(spin { panel.state == .ready })
        if case .native(let node)? = panel.currentContent { XCTAssertEqual(node.find("l"), .label(id: "l", "hello")) } else { XCTFail("expected native content") }
        panel.present(item("x.bad"), location: .computer, selectionCount: 1)
        XCTAssertTrue(spin { if case .failed = panel.state { return true } else { return false } })
        panel.present(item("y.slow"), location: .computer, selectionCount: 1)
        panel.present(item("a.txt"), location: .computer, selectionCount: 1)
        XCTAssertTrue(spin { panel.state == .ready })
        XCTAssertEqual(panel.currentItem?.name, "a.txt")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(panel.state, .ready)
        panel.present(item("nomatch.zip"), location: .computer, selectionCount: 1)
        XCTAssertEqual(panel.state, .idle)
    }

    func testQuickLookKeyUsesCustomPreviewWhenAMatchingPreviewerExistsElseFallsBack() throws {
        let regs = BrowserRegistries()
        let dir = try makeTree()
        let wc = makeWindow(dir, registries: regs)
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 9 })
        pane.content.select([dir.appendingPathComponent("file-1.txt")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.count == 1 })
        XCTAssertNil(pane.customPreviewItem)
        regs.previews.register(PreviewSpec(id: "t", title: "Text", extensions: ["txt"], provider: StaticPreview(content: .text("hello text"))), owner: "a")
        XCTAssertEqual(pane.customPreviewItem?.name, "file-1.txt")
        pane.toggleQuickLook(nil)
        let controller = try XCTUnwrap(pane.customPreviewController)
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(spin { controller.state == .ready })
        pane.content.select([dir.appendingPathComponent("file-2.txt")], scroll: false)
        XCTAssertTrue(spin { controller.currentItem?.name == "file-2.txt" })
        pane.toggleQuickLook(nil)
        XCTAssertFalse(controller.isVisible)
    }

    func testSandboxedHTMLUsesNonPersistentNoJavaScriptWebViewWithCSP() throws {
        let view = SandboxedHTMLView()
        let config = view.webView.configuration
        XCTAssertFalse(config.websiteDataStore.isPersistent)
        XCTAssertFalse(config.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(config.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(view.webView.navigationDelegate === view)
        let wrapped = SandboxedHTML.wrap("<h1>Hi</h1><script>alert(1)</script>")
        XCTAssertTrue(wrapped.contains("Content-Security-Policy"))
        XCTAssertTrue(wrapped.contains("default-src 'none'"))
        XCTAssertTrue(wrapped.contains("script-src 'none'"))
        XCTAssertTrue(wrapped.contains("connect-src 'none'"))
        XCTAssertTrue(wrapped.contains("form-action 'none'"))
        XCTAssertTrue(wrapped.range(of: "Content-Security-Policy")!.lowerBound < wrapped.range(of: "<h1>")!.lowerBound)
        let huge = String(repeating: "a", count: SandboxedHTML.maxBytes * 2)
        XCTAssertLessThan(SandboxedHTML.wrap(huge).utf8.count, SandboxedHTML.maxBytes + 2048)
    }

    func testSandboxedHTMLRendersOnceAndBlocksAllOtherNavigation() throws {
        let view = SandboxedHTMLView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds
        view.load(html: "<p id='x'>hello</p><a href='https://example.com'>link</a>")
        XCTAssertTrue(spin { view.webView.isLoading == false && view.webView.url?.absoluteString == "about:blank" }, "html never loaded")
        XCTAssertEqual(view.blockedNavigations, 0)
        let blocked = view.blockedNavigations
        view.webView.load(URLRequest(url: URL(string: "https://example.com/")!))
        XCTAssertTrue(spin { view.blockedNavigations > blocked })
        XCTAssertEqual(view.webView.url?.absoluteString, "about:blank")
    }
}
