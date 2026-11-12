import AppKit
import XCTest
import FSCore
import FileOps
@testable import Browser

@MainActor
final class NewTerminalInfoTabsHomeTests: XCTestCase {
    private var savedStore: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suite = "NewTerminalInfoTabsHomeTests.\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        MiniInfoPanelController.closeAll()
        BrowserDefaults.store.removePersistentDomain(forName: suite)
        BrowserDefaults.store = savedStore
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-features-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data("hello".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func folder(_ path: String) -> FileItem { FileItem(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isDirectory: true) }
    private func file(_ path: String) -> FileItem { FileItem(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isDirectory: false) }

    func testNewItemTemplatesAndUniqueNames() throws {
        XCTAssertEqual(FileTemplate.primary.map(\.title), ["Text Document", "Markdown Document", "Empty File"])
        XCTAssertEqual(FileTemplate.primary.map(\.fileName), ["untitled.txt", "untitled.md", "untitled"])
        XCTAssertEqual(Array(FileTemplate.all.prefix(3)), FileTemplate.primary)
        let dir = try makeTree()
        for template in FileTemplate.primary {
            let first = FileOperationQueue.uniqueDestination(for: template.fileName, in: dir)
            XCTAssertEqual(first.lastPathComponent, template.fileName)
            FileManager.default.createFile(atPath: first.path, contents: template.contents)
            let second = FileOperationQueue.uniqueDestination(for: template.fileName, in: dir)
            let base = (template.fileName as NSString).deletingPathExtension
            let ext = (template.fileName as NSString).pathExtension
            XCTAssertEqual(second.lastPathComponent, ext.isEmpty ? "\(base) 2" : "\(base) 2.\(ext)")
            FileManager.default.createFile(atPath: second.path, contents: Data())
            XCTAssertEqual(FileOperationQueue.uniqueDestination(for: template.fileName, in: dir).lastPathComponent, ext.isEmpty ? "\(base) 3" : "\(base) 3.\(ext)")
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("untitled folder"), withIntermediateDirectories: false)
        XCTAssertEqual(FileOperationQueue.uniqueDestination(for: "untitled folder", in: dir).lastPathComponent, "untitled folder 2")
    }

    func testNewFileIsCreatedSelectedAndTargetsShownFolder() throws {
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 2 })
        pane.content.select([dir.appendingPathComponent("Sub")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.count == 1 })
        pane.newMarkdownDocument(nil)
        let created = dir.appendingPathComponent("untitled.md")
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: created.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sub/untitled.md").path))
        XCTAssertTrue(spin { pane.selectedURLs.map(\.lastPathComponent) == ["untitled.md"] })
        pane.newMarkdownDocument(nil)
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: dir.appendingPathComponent("untitled 2.md").path) })
        pane.newEmptyFile(nil)
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: dir.appendingPathComponent("untitled").path) })
    }

    func testContextMenuAlwaysOffersNewTerminalAndMiniInfo() throws {
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        let pane = wc.activePane
        XCTAssertTrue(spin { !pane.model.isLoading && pane.model.items.count == 2 })

        func check(_ menu: NSMenu, selection: Bool, line: UInt = #line) throws {
            let new = try XCTUnwrap(menu.items.first { $0.title == "New" }, line: line)
            let entries = try XCTUnwrap(new.submenu).items.filter { !$0.isSeparatorItem }.map(\.title)
            XCTAssertEqual(Array(entries.prefix(4)), ["Folder", "Text Document", "Markdown Document", "Empty File"], line: line)
            XCTAssertEqual(menu.items.contains { $0.title == "New Folder with Selection" }, selection, line: line)
            XCTAssertTrue(menu.items.contains { $0.title == "Open in Terminal" }, line: line)
            let info = try XCTUnwrap(menu.items.firstIndex { $0.title == "Get Info" }, line: line)
            let mini = menu.items[info + 1]
            XCTAssertEqual(mini.title, "Mini Info", line: line)
            XCTAssertTrue(mini.isAlternate, line: line)
            XCTAssertEqual(mini.keyEquivalent, menu.items[info].keyEquivalent, line: line)
            XCTAssertEqual(mini.keyEquivalentModifierMask, [.command, .option], line: line)
            XCTAssertEqual(mini.action, #selector(BrowserPaneController.miniInfo(_:)), line: line)
            for item in try XCTUnwrap(new.submenu).items where !item.isSeparatorItem {
                XCTAssertTrue(pane.validateMenuItem(item), item.title, line: line)
            }
        }

        try check(ContextMenuBuilder.builtInMenu(for: pane), selection: false)
        pane.content.select([dir.appendingPathComponent("a.txt")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.count == 1 })
        try check(ContextMenuBuilder.builtInMenu(for: pane), selection: true)
        XCTAssertEqual(pane.terminalTarget?.pathKey, dir.pathKey)
        pane.content.select([dir.appendingPathComponent("Sub")], scroll: false)
        XCTAssertTrue(spin { pane.selectedURLs.first?.lastPathComponent == "Sub" })
        try check(ContextMenuBuilder.builtInMenu(for: pane), selection: true)
        XCTAssertEqual(pane.terminalTarget?.pathKey, dir.appendingPathComponent("Sub").pathKey)

        pane.navigate(to: .computer)
        let computer = ContextMenuBuilder.builtInMenu(for: pane)
        let new = try XCTUnwrap(computer.items.first { $0.title == "New" })
        XCTAssertFalse(pane.validateMenuItem(try XCTUnwrap(new.submenu?.items.first)))
    }

    func testCommandsAreInThePalette() throws {
        let dir = try makeTree()
        let wc = BrowserWindowController(location: .folder(dir))
        defer { wc.close() }
        XCTAssertTrue(spin { !wc.activePane.model.isLoading })
        let entries = wc.registries.commands.paletteEntries(query: "", context: BrowserContext(controller: wc))
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.qualifiedID, $0) })
        for id in ["file.newFolder", "file.newFile", "file.newMarkdownDocument", "file.newEmptyFile", "file.openInTerminal", "file.miniInfo"] {
            let entry = try XCTUnwrap(byID.first { $0.key.hasSuffix(id) }?.value, id)
            XCTAssertTrue(entry.isEnabled, id)
        }
    }

    func testTerminalTargetDirectory() {
        let here = URL(fileURLWithPath: "/tmp/here")
        XCTAssertEqual(TerminalApp.targetDirectory(selection: [], location: here), here)
        XCTAssertEqual(TerminalApp.targetDirectory(selection: [folder("/tmp/here/Sub")], location: here)?.path, "/tmp/here/Sub")
        XCTAssertEqual(TerminalApp.targetDirectory(selection: [file("/tmp/here/a.txt")], location: here), here)
        XCTAssertEqual(TerminalApp.targetDirectory(selection: [folder("/tmp/here/A"), folder("/tmp/here/B")], location: here), here)
        XCTAssertEqual(TerminalApp.targetDirectory(selection: [file("/tmp/elsewhere/a.txt")], location: nil)?.path, "/tmp/elsewhere")
        XCTAssertNil(TerminalApp.targetDirectory(selection: [], location: nil))
        let package = FileItem(url: URL(fileURLWithPath: "/tmp/here/App.app"), name: "App.app", isDirectory: true, isPackage: true)
        XCTAssertEqual(TerminalApp.targetDirectory(selection: [package], location: here), here)
    }

    func testTerminalAppResolution() {
        let installed = ["com.apple.Terminal": "/System/Applications/Utilities/Terminal.app", "com.mitchellh.ghostty": "/Applications/Ghostty.app"]
        let lookup: (String) -> URL? = { installed[$0].map { URL(fileURLWithPath: $0) } }
        let onDisk: Set<String> = ["/Applications/iTerm.app", TerminalApp.fallbackPath]
        let exists: (String) -> Bool = { onDisk.contains($0) }
        XCTAssertEqual(TerminalApp.resolve(customPath: nil, bundleID: nil, exists: exists, lookup: lookup)?.path, "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(TerminalApp.resolve(customPath: "", bundleID: "", exists: exists, lookup: lookup)?.path, "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(TerminalApp.resolve(customPath: "/Applications/iTerm.app", bundleID: "com.mitchellh.ghostty", exists: exists, lookup: lookup)?.path, "/Applications/iTerm.app")
        XCTAssertEqual(TerminalApp.resolve(customPath: "/Applications/Gone.app", bundleID: "com.mitchellh.ghostty", exists: exists, lookup: lookup)?.path, "/Applications/Ghostty.app")
        XCTAssertEqual(TerminalApp.resolve(customPath: "/Applications/Gone.app", bundleID: "com.example.missing", exists: exists, lookup: lookup)?.path, "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(TerminalApp.resolve(customPath: nil, bundleID: nil, exists: exists, lookup: { _ in nil })?.path, TerminalApp.fallbackPath)
        XCTAssertNil(TerminalApp.resolve(customPath: nil, bundleID: nil, exists: { _ in false }, lookup: { _ in nil }))
    }

    func testOpenRouteDecision() {
        typealias M = BrowserWindowManager
        XCTAssertEqual(M.route(intent: .request, tabsPreferred: false, hasWindow: true), .newWindow)
        XCTAssertEqual(M.route(intent: .request, tabsPreferred: false, hasWindow: false), .newWindow)
        XCTAssertEqual(M.route(intent: .request, tabsPreferred: true, hasWindow: true), .tabInActiveWindow)
        XCTAssertEqual(M.route(intent: .request, tabsPreferred: true, hasWindow: false), .newWindow)
        XCTAssertEqual(M.route(intent: .explicitNewWindow, tabsPreferred: true, hasWindow: true), .newWindow)
        XCTAssertEqual(M.route(intent: .explicitNewWindow, tabsPreferred: false, hasWindow: true), .newWindow)
    }

    func testRequestsJoinTheActiveWindowAsTabsOnlyWhenEnabled() throws {
        let dir = try makeTree()
        let sub = dir.appendingPathComponent("Sub")
        let manager = BrowserWindowManager(registries: BrowserRegistries())
        defer { for c in manager.controllers { c.close() } }
        XCTAssertFalse(BrowserDefaults.openFoldersInTabs)

        let first = manager.open(at: .folder(dir))
        XCTAssertEqual(manager.controllers.count, 1)
        let separate = manager.open(at: .folder(sub))
        XCTAssertEqual(manager.controllers.count, 2)
        XCTAssertFalse(first.window?.tabbedWindows?.contains { $0 === separate.window } ?? false)
        separate.close()
        XCTAssertTrue(spin { manager.controllers.count == 1 })

        BrowserDefaults.store.set(true, forKey: BrowserDefaults.Key.openFoldersInTabs)
        manager.handle(.openFolder(sub))
        XCTAssertEqual(manager.controllers.count, 2)
        let tab = try XCTUnwrap(manager.controllers.last)
        XCTAssertTrue(tab.location.isSame(as: .folder(sub)))
        XCTAssertTrue(first.window?.tabbedWindows?.contains { $0 === tab.window } ?? false)

        let file = dir.appendingPathComponent("a.txt")
        manager.handle(.reveal(file))
        XCTAssertEqual(manager.controllers.count, 2)

        let explicit = manager.open(at: .folder(sub), intent: .explicitNewWindow)
        XCTAssertEqual(manager.controllers.count, 3)
        XCTAssertFalse(first.window?.tabbedWindows?.contains { $0 === explicit.window } ?? false)
    }

    func testMiniInfoText() {
        XCTAssertEqual(MiniInfoText.file(logical: 1000, allocated: 1000), SizeFormatter.string(1000))
        XCTAssertEqual(MiniInfoText.file(logical: 1000, allocated: 4096), "\(SizeFormatter.string(1000)) (\(SizeFormatter.string(4096)) on disk)")
        XCTAssertEqual(MiniInfoText.file(logical: nil, allocated: nil), MiniInfoText.placeholder)
        XCTAssertEqual(MiniInfoText.folder(nil, allocated: true), "Calculating…")
        var r = SizeResult(allocatedBytes: 8192, logicalBytes: 5000, itemCount: 3, isComplete: false)
        XCTAssertEqual(MiniInfoText.folder(r, allocated: true), "Calculating… \(SizeFormatter.string(8192))")
        r.isComplete = true
        XCTAssertEqual(MiniInfoText.folder(r, allocated: true), "\(SizeFormatter.string(8192)) · 3 items")
        XCTAssertEqual(MiniInfoText.folder(r, allocated: false), "\(SizeFormatter.string(5000)) · 3 items")
        r.isComplete = false
        r.isPartial = true
        XCTAssertEqual(MiniInfoText.folder(r, allocated: true), "At least \(SizeFormatter.string(8192)) · 3 items")
        r.itemCount = 1
        r.isPartial = false
        r.isComplete = true
        XCTAssertEqual(MiniInfoText.folder(r, allocated: true), "\(SizeFormatter.string(8192)) · 1 item")
        XCTAssertEqual(MiniInfoText.volume(free: 10_000_000, total: 50_000_000), "\(SizeFormatter.string(10_000_000)) free of \(SizeFormatter.string(50_000_000))")
        XCTAssertEqual(MiniInfoText.volume(free: nil, total: nil), MiniInfoText.placeholder)
    }

    func testMiniInfoPanelShowsOnePerItemAndUpdatesFolderSize() throws {
        try IndexTestHost.attach(for: self)
        let dir = try makeTree()
        let file = dir.appendingPathComponent("a.txt")
        let shown = MiniInfoPanelController.show([file, dir], near: NSPoint(x: 200, y: 400))
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(MiniInfoPanelController.open.count, 2)
        let again = MiniInfoPanelController.show([file], near: NSPoint(x: 200, y: 400))
        XCTAssertTrue(again.first === shown.first)
        XCTAssertEqual(MiniInfoPanelController.open.count, 2)

        let filePanel = shown[0]
        XCTAssertEqual(filePanel.model.subject, .file)
        XCTAssertEqual(filePanel.infoView.nameLabel.stringValue, "a.txt")
        XCTAssertEqual(filePanel.infoView.nameLabel.accessibilityLabel(), "Name: a.txt")
        XCTAssertTrue(filePanel.infoView.sizeLabel.stringValue.hasPrefix(SizeFormatter.string(5)))
        XCTAssertEqual(filePanel.infoView.kindLabel.accessibilityLabel(), "Kind: \(filePanel.model.kind)")
        let panel = try XCTUnwrap(filePanel.window as? NSPanel)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertEqual(panel.accessibilityLabel(), "a.txt Mini Info")

        let folderPanel = shown[1]
        XCTAssertEqual(folderPanel.model.subject, .folder)
        XCTAssertTrue(spin { folderPanel.infoView.sizeLabel.stringValue.contains("item") })
        XCTAssertTrue(folderPanel.infoView.sizeLabel.accessibilityLabel()?.hasPrefix("Size: ") ?? false)

        panel.cancelOperation(nil)
        XCTAssertEqual(MiniInfoPanelController.open.count, 1)
        MiniInfoPanelController.closeAll()
        XCTAssertTrue(MiniInfoPanelController.open.isEmpty)
    }

    func testMiniInfoRemeasuresWhenFolderContentsChange() throws {
        let dir = try makeTree()
        let savedDelay = MiniInfoModel.rescanDelay
        MiniInfoModel.rescanDelay = 0.05
        defer { MiniInfoModel.rescanDelay = savedDelay }
        let model = MiniInfoModel(url: dir)
        final class Counter: @unchecked Sendable { var measured = 0; var invalidated: [String] = [] }
        let counter = Counter()
        model.measure = { _ in
            await MainActor.run { counter.measured += 1 }
            let n = await MainActor.run { counter.measured }
            return AsyncStream { c in
                c.yield(SizeResult(allocatedBytes: Int64(n) * 4096, logicalBytes: Int64(n) * 1000, itemCount: n, isComplete: true))
                c.finish()
            }
        }
        model.invalidate = { path in await MainActor.run { counter.invalidated.append(path) } }
        model.start()
        defer { model.stop() }
        XCTAssertTrue(spin { model.sizeText == MiniInfoText.folder(SizeResult(allocatedBytes: 4096, logicalBytes: 1000, itemCount: 1, isComplete: true), allocated: BrowserDefaults.showAllocatedSize) })
        model.contentsChanged([dir.appendingPathComponent("new.txt").path])
        XCTAssertTrue(spin { counter.measured == 2 })
        XCTAssertTrue(counter.invalidated.contains(dir.appendingPathComponent("new.txt").path))
        XCTAssertTrue(spin { model.sizeText.contains(" items") })
    }

    func testMiniInfoVolumeShowsFreeAndTotal() {
        let model = MiniInfoModel(url: URL(fileURLWithPath: "/"))
        model.start()
        defer { model.stop() }
        XCTAssertEqual(model.subject, .volume)
        XCTAssertTrue(model.sizeText.contains("free of"), model.sizeText)
    }

    func testHomeNameAppliesToTitlesCrumbsAndStatusItems() throws {
        let home = URL(fileURLWithPath: HomeLabel.display.homePath, isDirectory: true)
        let real = FileManager.default.displayName(atPath: home.path)
        XCTAssertEqual(BrowserLocation.folder(home).displayName, real)
        XCTAssertFalse(HomeLabel.hidesProxy(for: home))

        BrowserDefaults.store.set(HomeNameStyle.custom.rawValue, forKey: HomeNameDisplay.styleKey)
        BrowserDefaults.store.set("me", forKey: HomeNameDisplay.customKey)
        XCTAssertEqual(BrowserLocation.folder(home).displayName, "me")
        XCTAssertEqual(BrowserDestination.local(.folder(home)).displayName, "me")
        XCTAssertEqual(home.displayTitle, "me")
        XCTAssertEqual(home.appendingPathComponent("Documents").displayPath, home.deletingLastPathComponent().appendingPathComponent("me/Documents").path)
        XCTAssertTrue(BrowserLocation.search(scope: home, query: "x").displayName.hasSuffix("in me"))
        XCTAssertTrue(HomeLabel.hidesProxy(for: home.appendingPathComponent("Documents")))
        XCTAssertFalse(HomeLabel.hidesProxy(for: URL(fileURLWithPath: "/Applications")))
        let other = URL(fileURLWithPath: "/Users/Shared")
        XCTAssertEqual(BrowserLocation.folder(other).displayName, FileManager.default.displayName(atPath: other.path))

        let items = [FileItem(url: home, name: home.lastPathComponent, isDirectory: true), FileItem(url: other, name: "Shared", isDirectory: true)]
        XCTAssertEqual(HomeLabel.masked(items).map(\.name), ["me", "Shared"])
        XCTAssertEqual(HomeLabel.masked(items).map(\.url), items.map(\.url))

        BrowserDefaults.store.set(HomeNameStyle.redacted.rawValue, forKey: HomeNameDisplay.styleKey)
        XCTAssertEqual(BrowserLocation.folder(home).displayName, HomeNameDisplay.redactedPlaceholder)
        XCTAssertTrue(HomeLabel.isRedacted(home))
        XCTAssertFalse(HomeLabel.isRedacted(other))
        XCTAssertEqual(HomeLabel.accessibilityName(real, for: home), HomeNameDisplay.redactedAccessibilityName)
        let font = NSFont.systemFont(ofSize: 12)
        let image = RedactedText.image(real, font: font, color: .black)
        XCTAssertEqual(image.size.width, ceil((real as NSString).size(withAttributes: [.font: font]).width))
        let attributed = try XCTUnwrap(HomeLabel.attributed(for: home, font: font, color: .black))
        XCTAssertFalse(attributed.string.contains(real))
        XCTAssertNil(HomeLabel.attributed(for: other, font: font, color: .black))

        BrowserDefaults.store.set(HomeNameStyle.tilde.rawValue, forKey: HomeNameDisplay.styleKey)
        XCTAssertEqual(BrowserLocation.folder(home).displayName, "~")
        XCTAssertEqual(home.appendingPathComponent("Documents").displayPath, "~/Documents")
    }

    func testWindowTitleAndPathBarFollowHomeNameSetting() throws {
        let home = URL(fileURLWithPath: HomeLabel.display.homePath, isDirectory: true)
        guard FileManager.default.isReadableFile(atPath: home.path) else { throw XCTSkip("home folder not readable") }
        let real = FileManager.default.displayName(atPath: home.path)
        let wc = BrowserWindowController(location: .folder(home))
        defer { wc.close() }
        XCTAssertEqual(wc.window?.title, real)
        BrowserDefaults.store.set(HomeNameStyle.custom.rawValue, forKey: HomeNameDisplay.styleKey)
        BrowserDefaults.store.set("me", forKey: HomeNameDisplay.customKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: BrowserDefaults.store)
        XCTAssertTrue(spin { wc.window?.title == "me" })
        XCTAssertEqual(wc.window?.tab.title, "me")
        XCTAssertNil(wc.window?.representedURL)
        func crumbTitles() -> [String] {
            var out: [String] = []
            func walk(_ v: NSView) {
                if let b = v as? CrumbButton { out.append(b.attributedTitle.string) }
                v.subviews.forEach(walk)
            }
            walk(wc.activePane.pathBar)
            return out
        }
        XCTAssertTrue(crumbTitles().contains("me"), "\(crumbTitles())")
        XCTAssertFalse(crumbTitles().contains(real))
        let sidebar = wc.sidebarController
        XCTAssertTrue(spin { sidebar.sectionTitles.flatMap { sidebar.entryTitles(inSection: $0) }.contains("me") })
        XCTAssertFalse(sidebar.sectionTitles.flatMap { sidebar.entryTitles(inSection: $0) }.contains(real))

        BrowserDefaults.store.set(HomeNameStyle.redacted.rawValue, forKey: HomeNameDisplay.styleKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: BrowserDefaults.store)
        XCTAssertTrue(spin { wc.window?.title == HomeNameDisplay.redactedPlaceholder })
        XCTAssertFalse(crumbTitles().contains(real))
        XCTAssertFalse(crumbTitles().contains("me"))
    }

    func testEditingAcceptsRealPathAndTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        BrowserDefaults.store.set(HomeNameStyle.redacted.rawValue, forKey: HomeNameDisplay.styleKey)
        XCTAssertEqual(PathInput.normalize("~", relativeTo: nil), home)
        XCTAssertEqual(PathInput.normalize("~/Documents", relativeTo: nil), home + "/Documents")
        XCTAssertEqual(PathInput.normalize(home + "/Documents", relativeTo: nil), home + "/Documents")
    }
}
