import AppKit
import Browser
import FSCore
import Foundation
import ImageIO
import Integration
import ModHost
import ModKit
import Settings
import UniformTypeIdentifiers

@MainActor
public final class ModSelfTest {
    public struct Check: Codable, Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String
    }

    public struct Report: Codable, Sendable {
        public var ok: Bool
        public var checks: [Check]
        public var startMs: Int?
        public var hostPid: Int32?
        public var sandboxed: Bool?
    }

    public let examples: URL
    public let keepInstalled: Bool
    private(set) var checks: [Check] = []
    private var notes: [(String, String, String)] = []
    private let base: URL
    private let suiteName: String
    private var runtime: AppModRuntime?

    public init(examples: URL, keepInstalled: Bool = false) {
        self.examples = examples
        self.keepInstalled = keepInstalled
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bf-selftest-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        suiteName = "com.bryanthaboi.betterfinder.selftest.\(UUID().uuidString)"
    }

    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        let c = Check(name: name, ok: ok, detail: ok ? "" : detail())
        checks.append(c)
        FileHandle.standardError.write(Data("[selftest] \(ok ? "PASS" : "FAIL") \(name)\(c.detail.isEmpty ? "" : " — \(c.detail)")\n".utf8))
    }

    private func eventually(_ timeout: TimeInterval = 10, _ body: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await body() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await body()
    }

    static func item(_ url: URL) -> FileItem {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let type = UTType(filenameExtension: url.pathExtension)?.identifier
        return FileItem(url: url, name: url.lastPathComponent, isDirectory: isDir.boolValue, dateModified: Date(), contentTypeIdentifier: type)
    }

    static func png(_ url: URL, width: Int, height: Int) -> Bool {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    func ownerIsEmpty(_ r: BrowserRegistries, _ owner: String) -> Bool {
        r.toolbar.entries(owner: owner).isEmpty && r.sidebar.entries(owner: owner).isEmpty && r.contextMenu.entries(owner: owner).isEmpty
            && r.columns.entries(owner: owner).isEmpty && r.statusBar.entries(owner: owner).isEmpty && r.panels.entries(owner: owner).isEmpty
            && r.previews.entries(owner: owner).isEmpty && r.browserViews.entries(owner: owner).isEmpty && r.commands.entries(owner: owner).isEmpty
            && r.keyBindings.entries(owner: owner).isEmpty && r.locations.entries(owner: owner).isEmpty && r.searchProviders.entries(owner: owner).isEmpty
    }

    public func run() async -> Report {
        let fm = FileManager.default
        let work = base.appendingPathComponent("work", isDirectory: true)
        let downloads = work.appendingPathComponent("Downloads", isDirectory: true)
        let out = work.appendingPathComponent("out", isDirectory: true)
        for d in [work, downloads, out] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        let envRoot = ProcessInfo.processInfo.environment["BF_MODS_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let rootSupport = envRoot ?? base.appendingPathComponent("support", isDirectory: true)
        var config = AppModRuntime.Configuration(
            paths: ModHostPaths(root: rootSupport, caches: rootSupport.appendingPathComponent("Caches", isDirectory: true)),
            scopedAccess: ScopedAccessAuthorizer(defaults: suite), secrets: InMemorySecretStore(), credentials: InMemorySecretStore(),
            indexURL: URL(string: "https://127.0.0.1:9/index.json")!,
            settingsDefaults: { [suiteName] id in UserDefaults(suiteName: "\(suiteName).\(id)") }, defaults: suite
        )
        let subprocess = AppModRuntime.Configuration.debugSubprocessHost()
        if let subprocess {
            config.transport = subprocess
            config.checkTransport = subprocess
        }
        let runtime: AppModRuntime
        do { runtime = try AppModRuntime(configuration: config) } catch {
            check("runtime.create", false, error.localizedDescription)
            return finish(nil)
        }
        self.runtime = runtime
        runtime.notifier = { [weak self] title, message, level in self?.notes.append((title, message, level)) }
        let registries = runtime.configuration.registries
        await runtime.start()
        check("runtime.start", runtime.startDuration != nil)

        let window = BrowserWindowManager.shared.openWindow(at: .folder(work))

        let dirs = ((try? fm.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        check("examples.found", dirs.count >= 5, "found \(dirs.count) in \(examples.path)")
        var installed = [String]()
        let approveAll: AppModRuntime.PermissionApprover = { m, _ in Set(m.permissions.map { ModHostManagementController.summary($0).id }) }
        let chooseRoot: AppModRuntime.RootChooser = { _, p in p.rootId == "downloads" ? downloads : work }
        for dir in dirs {
            let t0 = Date()
            let outcome = await runtime.install(from: dir, approver: approveAll, rootChooser: chooseRoot)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            check("install.\(dir.lastPathComponent)", outcome.enabled, "\(outcome.error ?? "not enabled") \(outcome.receipt?.diagnostics.map(\.message).joined(separator: "; ") ?? "")")
            FileHandle.standardError.write(Data("[selftest] install \(dir.lastPathComponent) took \(ms) ms\n".utf8))
            if let id = outcome.id, outcome.installed { installed.append(id) }
        }
        runtime.sink.flush()

        installed += await releaseChecks(runtime, approver: approveAll, rootChooser: chooseRoot, work: work)

        if let info = runtime.controller.hostInfo, subprocess == nil { check("host.sandboxed", info.sandboxed, "host reports sandboxed=false") }

        let columnID = "alice.image-dimensions/dimensions"
        if let spec = registries.columns.item(columnID), let adapter = spec.provider as? ModColumnAdapter {
            check("column.registered", spec.title == "Dimensions", "title \(spec.title)")
            let png = work.appendingPathComponent("pic.png")
            let txt = work.appendingPathComponent("note.txt")
            _ = Self.png(png, width: 64, height: 48)
            try? Data("hi".utf8).write(to: txt)
            do {
                let values = try await adapter.values(for: [Self.item(png), Self.item(txt)], revision: 1)
                check("column.value", values[png] == .string("64×48"), "got \(String(describing: values[png]))")
                check("column.nonImage", values[txt] == nil || values[txt] == ColumnValue.none, "got \(String(describing: values[txt]))")
            } catch { check("column.value", false, error.localizedDescription) }
        } else { check("column.registered", false, "missing \(columnID)") }

        let md = work.appendingPathComponent("README.md")
        try? Data("# Hello\n\n**world** of mods".utf8).write(to: md)
        if let entry = registries.previews.entry(matching: Self.item(md)), entry.owner == "alice.markdown-previewer", let adapter = entry.item.provider as? ModPreviewAdapter {
            check("preview.registered", true)
            do {
                let content = try await adapter.render(Self.item(md))
                if case .text(let t) = content { check("preview.render", t.contains("Hello") && t.contains("world") && !t.contains("**"), "got \(t)") } else { check("preview.render", false, "not text") }
            } catch { check("preview.render", false, error.localizedDescription) }
        } else { check("preview.registered", false, "no previewer for .md") }

        if let section = registries.sidebar.item("alice.pinned-folders/pinned") {
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            check("sidebar.pinned", section.entries.count == 2 && section.entries.first?.action == .navigate(.folder(dl)), "entries \(section.entries.map(\.id))")
        } else { check("sidebar.pinned", false, "missing section") }
        if let kb = registries.keyBindings.item("alice.pinned-folders/go-downloads") {
            check("keybinding.builtin", kb.commandID == "betterfinder/go.downloads" && registries.commands.entry(kb.commandID) != nil, "command \(kb.commandID)")
            check("keybinding.chord", kb.chord == KeyChord(key: "d", command: true, option: true), "chord \(kb.chord)")
        } else { check("keybinding.builtin", false, "missing binding") }

        try? Data("x".utf8).write(to: downloads.appendingPathComponent("old.zip"))
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: downloads.appendingPathComponent("old.zip").path)
        try? Data("yy".utf8).write(to: downloads.appendingPathComponent("new.dmg"))
        let pid = BrowserModSink.locationProviderID(ModContributionID(modId: "alice.recent-downloads", localId: "recent-downloads"))
        if let spec = registries.locations.spec(for: pid), let adapter = spec.provider as? ModLocationAdapter {
            check("location.registered", true)
            do {
                let items = try await adapter.listAll(spec.root)
                check("location.list", items.map(\.name) == ["new.dmg", "old.zip"], "got \(items.map(\.name))")
            } catch { check("location.list", false, error.localizedDescription) }
            if let section = registries.sidebar.item("alice.recent-downloads/downloads") {
                check("sidebar.location", section.entries.first?.action == .navigateProvided(spec.root), "action \(String(describing: section.entries.first?.action))")
            } else { check("sidebar.location", false, "missing section") }
            window.navigate(to: spec.root)
            let navigated = await eventually(3) { window.providedLocation?.providerID == pid }
            check("location.navigate", navigated, "window shows \(String(describing: window.providedLocation))")
            window.navigate(to: .folder(work))
        } else { check("location.registered", false, "missing \(pid)") }

        if let tb = registries.toolbar.item("alice.zip-selection/zip") {
            check("toolbar.registered", tb.commandID == "alice.zip-selection/zip-selection" && registries.commands.entry("alice.zip-selection/zip-selection") != nil, "command \(tb.commandID ?? "nil")")
            let a = work.appendingPathComponent("docs/a.txt")
            let b = work.appendingPathComponent("docs/b.txt")
            try? fm.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("alpha".utf8).write(to: a)
            try? Data("beta".utf8).write(to: b)
            runtime.services.script(destination: out)
            let ran = registries.commands.run("alice.zip-selection/zip-selection", context: BrowserContext(location: .folder(work), selection: [Self.item(a), Self.item(b)]))
            let archive = out.appendingPathComponent("Archive.zip")
            let made = await eventually(15) { FileManager.default.fileExists(atPath: archive.path) }
            check("toolbar.invoke", ran && made, "ran=\(ran) archive=\(made)")
            let noted = await eventually(3) { self.notes.contains { $0.1 == "Zipping 2 items" } }
            check("command.message", noted, "notes \(self.notes.map(\.1))")
            runtime.services.script()
        } else { check("toolbar.registered", false, "missing toolbar item") }

        if let src = dirs.first(where: { $0.lastPathComponent == "image-dimensions" }) {
            let dev = base.appendingPathComponent("dev/image-dimensions", isDirectory: true)
            try? fm.createDirectory(at: dev.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dev)
            let outcome = await runtime.loadUnpacked(dev, approver: approveAll, rootChooser: chooseRoot)
            check("dev.load", outcome.enabled && runtime.watchedDevMods["alice.image-dimensions"] != nil, outcome.error ?? "not watched")
            try? await Task.sleep(nanoseconds: 400_000_000)
            let manifestURL = dev.appendingPathComponent("manifest.json")
            if let text = try? String(contentsOf: manifestURL, encoding: .utf8) {
                try? text.replacingOccurrences(of: "\"title\": \"Dimensions\"", with: "\"title\": \"Pixels\"").write(to: manifestURL, atomically: true, encoding: .utf8)
            }
            let reloaded = await eventually(15) { registries.columns.item(columnID)?.title == "Pixels" }
            check("dev.hotReload", reloaded, "title \(registries.columns.item(columnID)?.title ?? "nil"), last \(String(describing: runtime.lastDevReload))")
            if let text = try? String(contentsOf: manifestURL, encoding: .utf8) {
                try? text.replacingOccurrences(of: "\"handler\": \"dimensions\"}]", with: "\"handler\": \"missing\"}]").write(to: manifestURL, atomically: true, encoding: .utf8)
            }
            let rejected = await eventually(15) { runtime.lastDevReload?.ok == false }
            check("dev.badReloadKeepsPrevious", rejected && registries.columns.item(columnID)?.title == "Pixels", "last \(String(describing: runtime.lastDevReload))")
            runtime.unloadDev(id: "alice.image-dimensions")
        }

        if !keepInstalled {
            for id in installed {
                try? await runtime.controller.disable(id: id)
                runtime.sink.flush()
                check("disable.\(id)", ownerIsEmpty(registries, id), "contributions left behind")
            }
        }
        window.close()
        return finish(runtime)
    }

    static func argument(_ name: String) -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func nodes(_ n: Browser.ModUINode) -> [Browser.ModUINode] { [n] + n.children.flatMap(nodes) }

    func releaseChecks(_ runtime: AppModRuntime, approver: @escaping AppModRuntime.PermissionApprover, rootChooser: @escaping AppModRuntime.RootChooser, work: URL) async -> [String] {
        guard let releases = Self.argument("--bf-selftest-releases"), let index = Self.argument("--bf-selftest-index") else { return [] }
        let fm = FileManager.default
        let mods = index.appendingPathComponent("mods", isDirectory: true)
        let folders = ((try? fm.contentsOfDirectory(at: mods, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        check("releases.found", !folders.isEmpty, "no listings in \(mods.path)")
        var installed = [String]()
        var forgedChecked = false
        for folder in folders {
            let name = folder.lastPathComponent
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("listing.json")), case .success(let listing) = ModIndexListing.decode(data) else {
                check("release.listing.\(name)", false, "listing does not decode")
                continue
            }
            let authorURL = index.appendingPathComponent("authors/\(listing.author).json")
            guard let authorData = try? Data(contentsOf: authorURL), case .success(let author) = ModAuthorFile.decode(authorData) else {
                check("release.author.\(name)", false, "no valid \(authorURL.path)")
                continue
            }
            let archive = releases.appendingPathComponent(URL(string: listing.release.assetURL)?.lastPathComponent ?? "\(name).bfmod")
            guard fm.fileExists(atPath: archive.path) else {
                check("release.archive.\(name)", false, "missing \(archive.path)")
                continue
            }
            if !forgedChecked {
                forgedChecked = true
                var forged = listing
                forged.release.signature = String(repeating: "A", count: 86) + "=="
                let rejected = await runtime.installRelease(ModReleaseArtifact(archive: archive, listing: forged, author: author), approver: approver, rootChooser: rootChooser)
                check("release.rejectsForgedSignature", !rejected.installed && (rejected.error ?? "").contains("BF7011"), rejected.error ?? "installed")
                var other = listing
                other.release.sha256 = String(repeating: "0", count: 64)
                let mismatched = await runtime.installRelease(ModReleaseArtifact(archive: archive, listing: other, author: author), approver: approver, rootChooser: rootChooser)
                check("release.rejectsMismatchedArchive", !mismatched.installed, mismatched.error ?? "installed")
            }
            let t0 = Date()
            let outcome = await runtime.installRelease(ModReleaseArtifact(archive: archive, listing: listing, author: author), approver: approver, rootChooser: rootChooser)
            FileHandle.standardError.write(Data("[selftest] release \(listing.id) \(listing.version) took \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".utf8))
            check("release.install.\(listing.id)", outcome.enabled && runtime.controller.status(id: listing.id)?.version == listing.version.description,
                  "\(outcome.error ?? "not enabled") \(outcome.receipt?.diagnostics.map { "\($0.code.rawValue) \($0.message)" }.joined(separator: "; ") ?? "")")
            if outcome.installed { installed.append(listing.id) }
        }
        runtime.sink.flush()
        if installed.contains("bryanthaboi.folder-notes"), let v = runtime.controller.status(id: "bryanthaboi.folder-notes")?.version, (SemVer.parse(v) ?? SemVer(0, 0, 0)) >= SemVer(1, 1, 0) {
            await folderNotesCheck(runtime)
        }
        return installed
    }

    func folderNotesCheck(_ runtime: AppModRuntime) async {
        let registries = runtime.configuration.registries
        let qid = "bryanthaboi.folder-notes/notes"
        let hasField = await eventually(5) { registries.panels.contentOverrides[qid].map { Self.nodes($0).contains { if case .textField = $0.kind { return true }; return false } } ?? false }
        check("textField.rendered", hasField, "panel content \(String(describing: registries.panels.contentOverrides[qid]))")
        guard hasField, let node = registries.panels.contentOverrides[qid], let field = Self.nodes(node).first(where: { if case .textField = $0.kind { return true }; return false }),
              let spec = registries.panels.item(qid) else { return }
        let text = "selftest note \(UUID().uuidString.prefix(6))"
        spec.onEvent?(ModUIEvent(nodeID: field.id, kind: .textChanged(text)))
        spec.onEvent?(ModUIEvent(nodeID: field.id, kind: .textCommitted(text)))
        let saved = await eventually(10) {
            registries.panels.contentOverrides[qid].map { Self.nodes($0).contains { n in
                if case .list(let items, _) = n.kind { return items.contains { $0.title == text } }
                if case .label(let t, _) = n.kind { return t == text }
                return false
            } } ?? false
        }
        check("textField.event", saved, "notes \(self.notes.map(\.1)) panel \(String(describing: registries.panels.contentOverrides[qid]))")
    }

    private func finish(_ runtime: AppModRuntime?) -> Report {
        let report = Report(
            ok: !checks.isEmpty && checks.allSatisfy(\.ok), checks: checks, startMs: runtime?.startDuration.map { Int($0 * 1000) },
            hostPid: runtime?.controller.hostInfo?.pid, sandboxed: runtime?.controller.hostInfo?.sandboxed
        )
        return report
    }

    public func cleanup() async {
        if let runtime {
            if !keepInstalled {
                for s in runtime.controller.status() { try? await runtime.controller.uninstall(id: s.id, deleteData: true) }
            }
            await runtime.shutdown()
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Preferences") {
            for f in files where f.hasPrefix(suiteName) { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/" + f) }
        }
        if !keepInstalled { ModFilesCleanup.removeTree(base) }
    }

    public static func runAndExit(examples: URL, output: URL?, keepInstalled: Bool = false) {
        Task { @MainActor in
            let test = ModSelfTest(examples: examples, keepInstalled: keepInstalled)
            let report = await test.run()
            await test.cleanup()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(report) {
                if let output { try? data.write(to: output) }
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(report.ok ? 0 : 1)
        }
    }
}

enum ModFilesCleanup {
    static func removeTree(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            chmod(url.path, 0o755)
            while let u = en.nextObject() as? URL { chmod(u.path, 0o755) }
        }
        try? fm.removeItem(at: url)
    }
}
