@testable import AppBridge
@testable import Browser
import FileOps
import FSCore
import Foundation
import ImageIO
import Integration
@testable import ModHost
import ModKit
import Settings
import UniformTypeIdentifiers
import XCTest

struct PlainBookmarks: BookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) }
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

final class NoopRunner: ModCommandRunning, @unchecked Sendable {
    func run(selection: [URL], args: JSONValue?) async throws -> ModCommandOutcome { ModCommandOutcome(message: nil, operationId: nil) }
}

@MainActor
final class Env {
    let base: URL
    let work: URL
    let suite: String
    let registries = BrowserRegistries()
    let runtime: AppModRuntime

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appbridge-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        work = base.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        suite = "appbridge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = base.appendingPathComponent("support", isDirectory: true)
        let suite = suite
        let config = AppModRuntime.Configuration(
            paths: ModHostPaths(root: root), transport: ModHostTransports.inProcess(), checkTransport: ModHostTransports.inProcess(),
            registries: registries, scopedAccess: ScopedAccessAuthorizer(defaults: defaults, coder: PlainBookmarks()),
            secrets: InMemorySecretStore(), credentials: InMemorySecretStore(), hookRegistry: FileOperationHookRegistry(),
            indexURL: URL(string: "https://127.0.0.1:9/index.json")!, settingsDefaults: { UserDefaults(suiteName: "\(suite).\($0)") },
            globalKeybindings: false, systemAssets: false, defaults: defaults, checkGate: nil
        )
        runtime = try AppModRuntime(configuration: config)
        runtime.notifier = { _, _, _ in }
    }

    func cleanup() async {
        for s in runtime.controller.status() { try? await runtime.controller.uninstall(id: s.id, deleteData: true) }
        await runtime.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let fm = FileManager.default
        let prefs = NSHomeDirectory() + "/Library/Preferences"
        for f in (try? fm.contentsOfDirectory(atPath: prefs)) ?? [] where f.hasPrefix(suite) { try? fm.removeItem(atPath: prefs + "/" + f) }
        if let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) { while let u = en.nextObject() as? URL { chmod(u.path, 0o755) } }
        try? fm.removeItem(at: base)
    }

    static let approveAll: AppModRuntime.PermissionApprover = { m, _ in Set(m.permissions.map { ModHostManagementController.summary($0).id }) }

    func install(_ example: String, root: URL? = nil) async throws -> ModInstallOutcome {
        let dir = try XCTUnwrap(ModExamples.example(example)).directory
        let root = root ?? work
        return await runtime.install(from: dir, approver: Env.approveAll, rootChooser: { _, _ in root })
    }

    func png(_ name: String, width: Int, height: Int) -> URL {
        let u = work.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return u
    }

    static func item(_ url: URL) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: false, dateModified: Date(), contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
    }
}

func waitFor(_ timeout: TimeInterval = 5, _ check: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await check() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await check()
}

@MainActor
final class AppBridgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testExamplesLandInBrowserRegistries() async throws {
        let env = try Env()
        addTeardownBlock { @MainActor in await env.cleanup() }
        await env.runtime.start()
        for ex in ["image-dimensions", "markdown-previewer", "pinned-folders", "recent-downloads", "zip-selection"] {
            let outcome = try await env.install(ex)
            XCTAssertTrue(outcome.enabled, "\(ex): \(outcome.error ?? "")")
        }
        env.runtime.sink.flush()
        let r = env.registries
        XCTAssertEqual(r.columns.item("alice.image-dimensions/dimensions")?.title, "Dimensions")
        XCTAssertEqual(r.previews.entries(owner: "alice.markdown-previewer").map(\.qualifiedID), ["alice.markdown-previewer/markdown"])
        XCTAssertEqual(r.sidebar.item("alice.pinned-folders/pinned")?.entries.count, 2)
        XCTAssertEqual(r.keyBindings.item("alice.pinned-folders/go-downloads")?.commandID, "betterfinder/go.downloads")
        XCTAssertNotNil(r.locations.spec(for: "alice.recent-downloads.recent-downloads"))
        XCTAssertEqual(r.toolbar.item("alice.zip-selection/zip")?.commandID, "alice.zip-selection/zip-selection")
        XCTAssertEqual(r.commands.item("alice.zip-selection/zip-selection")?.category, "Archive")

        let spec = try XCTUnwrap(r.columns.item("alice.image-dimensions/dimensions"))
        XCTAssertEqual(spec.alignment, .leading)
        let png = env.png("a.png", width: 30, height: 20)
        let column = try XCTUnwrap(spec.provider as? ModColumnAdapter)
        let values = try await column.values(for: [Env.item(png)], revision: 1)
        XCTAssertEqual(values[png], .string("30×20"))
        let md = env.work.appendingPathComponent("x.md")
        try Data("# Title\n\n*hi*".utf8).write(to: md)
        let preview = try XCTUnwrap(r.previews.entry(matching: Env.item(md))?.item.provider as? ModPreviewAdapter)
        guard case .text(let text) = try await preview.render(Env.item(md)) else { return XCTFail("expected text preview") }
        XCTAssertEqual(text, "# Title\n\nhi")

        try await env.runtime.controller.disable(id: "alice.zip-selection")
        env.runtime.sink.flush()
        XCTAssertNil(r.toolbar.item("alice.zip-selection/zip"))
        XCTAssertNil(r.commands.item("alice.zip-selection/zip-selection"))
    }

    func testHotReloadSwapsOwnerAtomically() throws {
        let registries = BrowserRegistries()
        let sink = BrowserModSink(registries: registries)
        sink.autoFlush = false
        func item(_ id: String, _ title: String) -> ModToolbarContribution {
            ModToolbarContribution(id: ModContributionID(modId: "a.mod", localId: id), title: title, symbolName: nil, command: ModTestRefs.command("run", owner: "a.mod"), replaces: nil)
        }
        let old = try [sink.registerToolbarItem(item("one", "One"), owner: "a.mod"), sink.registerToolbarItem(item("two", "Two"), owner: "a.mod")]
        sink.flush()
        XCTAssertEqual(registries.toolbar.entries(owner: "a.mod").map(\.item.title), ["One", "Two"])
        var notifications = 0
        let observer = NSObject()
        registries.toolbar.addObserver(observer) { notifications += 1 }
        old.forEach { $0.cancel() }
        _ = try sink.registerToolbarItem(item("one", "Uno"), owner: "a.mod")
        XCTAssertEqual(registries.toolbar.entries(owner: "a.mod").map(\.item.title), ["One", "Two"])
        sink.flush()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(registries.toolbar.entries(owner: "a.mod").map(\.item.title), ["Uno"])
        sink.removeAll(owner: "a.mod")
        XCTAssertTrue(registries.toolbar.entries(owner: "a.mod").isEmpty)
    }

    func testRegistrationErrorsAreSynchronous() throws {
        let sink = BrowserModSink(registries: BrowserRegistries())
        sink.autoFlush = false
        let bad = ModToolbarContribution(id: ModContributionID(modId: "a.mod", localId: "x"), title: "", symbolName: nil, command: ModTestRefs.command("run", owner: "a.mod"), replaces: nil)
        XCTAssertThrowsError(try sink.registerToolbarItem(bad, owner: "a.mod"))
        let good = ModToolbarContribution(id: ModContributionID(modId: "a.mod", localId: "x"), title: "X", symbolName: nil, command: ModTestRefs.command("run", owner: "a.mod"), replaces: nil)
        _ = try sink.registerToolbarItem(good, owner: "a.mod")
        XCTAssertThrowsError(try sink.registerToolbarItem(good, owner: "a.mod"))
        XCTAssertThrowsError(try sink.registerKeybinding(ModKeybindingContribution(id: ModContributionID(modId: "a.mod", localId: "k"), chord: "cmd+", command: ModTestRefs.command("run", owner: "a.mod")), owner: "a.mod"))
    }

    func testReplacesHidesBuiltinUntilRemoved() throws {
        let registries = BrowserRegistries()
        let sink = BrowserModSink(registries: registries)
        sink.autoFlush = false
        let builtin = "betterfinder/dualPane"
        defer { registries.toolbar.resetPreferences() }
        XCTAssertFalse(registries.toolbar.isHidden(builtin))
        let t = try sink.registerToolbarItem(ModToolbarContribution(id: ModContributionID(modId: "a.mod", localId: "split"), title: "Split", symbolName: nil, command: ModTestRefs.command("run", owner: "a.mod"), replaces: "builtin.dual-pane"), owner: "a.mod")
        XCTAssertTrue(registries.toolbar.isHidden(builtin))
        t.cancel()
        XCTAssertFalse(registries.toolbar.isHidden(builtin))
    }

    func testBuiltinCommandIDs() {
        let sink = BrowserModSink(registries: BrowserRegistries())
        XCTAssertEqual(sink.browserCommandID(ModTestRefs.command("builtin.go-downloads", owner: "a.mod")), "betterfinder/go.downloads")
        XCTAssertEqual(sink.browserCommandID(ModTestRefs.command("builtin.view-toggle-dual-pane", owner: "a.mod")), "betterfinder/view.toggleDualPane")
        XCTAssertEqual(sink.browserCommandID(ModTestRefs.command("builtin.file.new-folder", owner: "a.mod")), "betterfinder/file.newFolder")
        XCTAssertEqual(sink.browserCommandID(ModTestRefs.command("zip", owner: "a.mod")), "a.mod/zip")
    }

    func testUINodeConversion() throws {
        let json = try JSONValue.parse(Data("""
        {"type":"vstack","children":[{"type":"text","text":"Hi"},{"type":"button","id":"go","text":"Go","command":"run"},
         {"type":"markdown","text":"**bold** text"},{"type":"list","label":"Things","items":[{"id":"1","title":"One"}]},{"type":"progress","value":0.5},{"type":"divider"}]}
        """.utf8))
        let node = try XCTUnwrap(ModHost.ModUINode.from(json, owner: "a.mod"))
        let sink = BrowserModSink(registries: BrowserRegistries())
        let out = ModUIConversion.convert(node, commandResolver: sink.browserCommandID)
        guard case .stack(let axis, _, let children) = out.node.kind else { return XCTFail("not a stack") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children.count, 6)
        XCTAssertEqual(children[1].id, "id:go")
        XCTAssertEqual(out.commands["id:go"], "a.mod/run")
        if case .label(let text, _) = children[2].kind { XCTAssertEqual(text, "bold text") } else { XCTFail("markdown") }
        if case .list(let items, _) = children[3].kind { XCTAssertEqual(items.map(\.title), ["One"]) } else { XCTFail("list") }
        XCTAssertTrue(out.node.accessibilityIssues().isEmpty, "\(out.node.accessibilityIssues())")
    }

    func testTextFieldNodeConvertsWithFieldIDs() throws {
        let json: JSONValue = .object(["type": .string("vstack"), "children": .array([
            .object(["type": .string("textField"), "id": .string("draft"), "text": .string("hi"), "placeholder": .string("note"), "command": .string("add")]),
        ])])
        let node = try XCTUnwrap(ModHost.ModUINode.from(json, owner: "a.mod"))
        let out = ModUIConversion.convert(node, commandResolver: BrowserModSink(registries: BrowserRegistries()).browserCommandID)
        guard case .stack(_, _, let children) = out.node.kind, case .textField(let value, let placeholder) = children[0].kind else { return XCTFail("\(out.node)") }
        XCTAssertEqual(value, "hi")
        XCTAssertEqual(placeholder, "note")
        XCTAssertEqual(out.fields[children[0].id], "draft")
        XCTAssertEqual(out.fieldValues[children[0].id], "hi")
        XCTAssertEqual(out.commands[children[0].id], "a.mod/add")
        XCTAssertTrue(out.node.accessibilityIssues().isEmpty, "\(out.node.accessibilityIssues())")
    }

    func testIndexDegradesWhenUnreachable() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("idx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let bridge = ModIndexBridge(paths: ModHostPaths(root: base), url: URL(string: "https://127.0.0.1:9/index.json")!, tokenService: "betterfinder.tests.absent-\(UUID().uuidString)")
        let snapshot = try await bridge.fetch()
        XCTAssertTrue(snapshot.listings.isEmpty)
        XCTAssertTrue(snapshot.isOffline)
        XCTAssertFalse(snapshot.canInstall)
        XCTAssertNotNil(bridge.problem)
    }

    func testEventForwarderDedupesAndDebounces() async throws {
        let registries = BrowserRegistries()
        let env = ModEnvironmentState()
        let fwd = ModEventForwarder(registries: registries, environment: env)
        fwd.debounce = 0.01
        var locations: [String] = []
        var selections: [[URL]] = []
        fwd.onLocation = { l, _ in locations.append(l.id) }
        fwd.onSelection = { u, _ in selections.append(u) }
        fwd.install()
        defer { fwd.uninstall() }
        let spec = try XCTUnwrap(registries.statusBar.item("\(ModEventForwarder.owner)/\(ModEventForwarder.segmentID)"))
        let driver = try XCTUnwrap(spec.makeDriver?())
        let output = StatusBarSegmentOutput()
        let a = URL(fileURLWithPath: "/tmp/a")
        driver.update(StatusBarContext(location: .folder(URL(fileURLWithPath: "/tmp"))), output: output)
        driver.update(StatusBarContext(location: .folder(URL(fileURLWithPath: "/tmp"))), output: output)
        XCTAssertTrue(output.isHidden)
        XCTAssertEqual(locations, ["/tmp"])
        driver.update(StatusBarContext(location: .folder(URL(fileURLWithPath: "/tmp")), selection: [Env.item(a)]), output: output)
        let got = await waitFor { selections.last == [a] }
        XCTAssertTrue(got)
        XCTAssertEqual(env.location?.id, "/tmp")
        XCTAssertEqual(env.selection, [a])
    }

    func testFolderWatcherFires() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fired = LockedFlag()
        let w = ModFolderWatcher(folder: dir, latency: 0.05, debounce: 0.05) { fired.set() }
        XCTAssertTrue(w.start())
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("x".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        let ok = await waitFor(5) { fired.value }
        w.stop()
        XCTAssertTrue(ok)
    }

    func testDevReloadAndRejectKeepsPrevious() async throws {
        let env = try Env()
        addTeardownBlock { @MainActor in await env.cleanup() }
        await env.runtime.start()
        let src = try XCTUnwrap(ModExamples.example("image-dimensions")).directory
        let dev = env.work.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.copyItem(at: src, to: dev)
        let outcome = await env.runtime.loadUnpacked(dev, approver: Env.approveAll, rootChooser: { _, _ in nil })
        XCTAssertTrue(outcome.enabled, outcome.error ?? "")
        let manifest = dev.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try text.replacingOccurrences(of: "\"title\": \"Dimensions\"", with: "\"title\": \"Pixels\"").write(to: manifest, atomically: true, encoding: .utf8)
        await env.runtime.reloadDev(id: "alice.image-dimensions", folder: dev, quiet: true)
        XCTAssertEqual(env.registries.columns.item("alice.image-dimensions/dimensions")?.title, "Pixels")
        try "{".write(to: manifest, atomically: true, encoding: .utf8)
        await env.runtime.reloadDev(id: "alice.image-dimensions", folder: dev, quiet: true)
        XCTAssertEqual(env.runtime.lastDevReload?.ok, false)
        XCTAssertEqual(env.registries.columns.item("alice.image-dimensions/dimensions")?.title, "Pixels")
        let folders = try FileManager.default.contentsOfDirectory(atPath: env.runtime.configuration.paths.modDirectory("alice.image-dimensions").path).filter { !$0.hasPrefix(".") && $0 != "state.json" }
        XCTAssertLessThanOrEqual(folders.count, 2)
    }

    func testSafeModeToggle() async throws {
        let env = try Env()
        addTeardownBlock { @MainActor in await env.cleanup() }
        await env.runtime.start()
        let outcome = try await env.install("pinned-folders")
        XCTAssertTrue(outcome.enabled)
        await env.runtime.enterSafeMode()
        XCTAssertTrue(env.runtime.isSafeMode)
        XCTAssertNil(env.registries.sidebar.item("alice.pinned-folders/pinned"))
        await env.runtime.exitSafeMode()
        XCTAssertFalse(env.runtime.isSafeMode)
        XCTAssertNotNil(env.registries.sidebar.item("alice.pinned-folders/pinned"))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}

enum ModTestRefs {
    static func command(_ raw: String, owner: String) -> ModCommandReference { ModCommandReference(raw: raw, owner: owner) }
}
