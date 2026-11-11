import AppKit
import Browser
import FSCore
import FileOps
import Foundation
import Integration
import ModHost
import ModKit
import Settings
import UniformTypeIdentifiers

public enum AppModDefaults {
    public static let developerMode = "modDeveloperMode"
    public static let devFolders = "modDevFolders.v1"
}

public struct ModInstallOutcome: Sendable {
    public var id: String?
    public var installed: Bool
    public var enabled: Bool
    public var cancelled: Bool
    public var receipt: PreflightReceipt?
    public var error: String?
}

@MainActor
public final class AppModRuntime {
    public struct Configuration {
        public var paths: ModHostPaths
        public var transport: ModHostTransportFactory
        public var checkTransport: ModHostTransportFactory?
        public var registries: BrowserRegistries
        public var scopedAccess: ScopedAccessAuthorizing
        public var secrets: SecretStore
        public var credentials: SecretStore
        public var hookRegistry: FileOperationHookRegistry
        public var indexURL: URL
        public var settingsDefaults: (@Sendable (String) -> UserDefaults?)?
        public var globalKeybindings: Bool
        public var systemAssets: Bool
        public var defaults: UserDefaults
        public var checkGate: ModCheckGate?

        public init(
            paths: ModHostPaths = .standard, transport: ModHostTransportFactory = ModHostTransports.xpc(), checkTransport: ModHostTransportFactory? = GracefulXPCModHostTransportFactory(),
            registries: BrowserRegistries = .shared, scopedAccess: ScopedAccessAuthorizing = ScopedAccessAuthorizer.shared,
            secrets: SecretStore = KeychainSecretStore.shared, credentials: SecretStore = KeychainSecretStore(servicePrefix: "betterfinder.mod.credential."),
            hookRegistry: FileOperationHookRegistry = .shared, indexURL: URL = ModIndexBridge.defaultURL,
            settingsDefaults: (@Sendable (String) -> UserDefaults?)? = nil, globalKeybindings: Bool = true, systemAssets: Bool = true,
            defaults: UserDefaults = .standard, checkGate: ModCheckGate? = nil
        ) {
            self.defaults = defaults
            self.checkGate = checkGate
            self.paths = paths
            self.transport = transport
            self.checkTransport = checkTransport
            self.registries = registries
            self.scopedAccess = scopedAccess
            self.secrets = secrets
            self.credentials = credentials
            self.hookRegistry = hookRegistry
            self.indexURL = indexURL
            self.settingsDefaults = settingsDefaults
            self.globalKeybindings = globalKeybindings
            self.systemAssets = systemAssets
        }

        public static var standard: Configuration {
            var c = Configuration()
            let env = ProcessInfo.processInfo.environment
            if let root = env["BF_MODS_ROOT"], !root.isEmpty {
                let url = URL(fileURLWithPath: root, isDirectory: true)
                c.paths = ModHostPaths(root: url, caches: url.appendingPathComponent("Caches", isDirectory: true))
            }
            if env["BETTERFINDER_DEMO"] == "1" {
                c.transport = ModHostTransports.inProcess()
                c.checkTransport = ModHostTransports.inProcess()
                c.secrets = InMemorySecretStore()
                c.credentials = InMemorySecretStore()
                c.globalKeybindings = false
                return c
            }
            if let host = Self.debugSubprocessHost(env) {
                c.transport = host
                c.checkTransport = host
            }
            return c
        }

        public static func debugSubprocessHost(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ModHostTransportFactory? {
            #if DEBUG
            guard env["BF_MOD_HOST"] == "subprocess" else { return nil }
            let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/betterfinder-mod")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
            return ModHostTransports.subprocess(cli, arguments: ["__modhost"])
            #else
            return nil
            #endif
        }
    }

    public let configuration: Configuration
    public let environment = ModEnvironmentState()
    public let sink: BrowserModSink
    public let forwarder: ModEventForwarder
    public let services: AppModServices
    public let index: ModIndexBridge
    public private(set) var controller: ModHostController
    public private(set) var startDuration: TimeInterval?
    public var onControllerChanged: ((ModHostController) -> Void)?
    public var notifier: (String, String, String) -> Void = { ModToast.show(title: $0, message: $1, level: $2) }

    private var managementValue: GatedModManagement?
    private var watchers: [String: ModFolderWatcher] = [:]
    private var started = false
    private var lastHostEvent: ModHostEvent.Kind?

    public init(configuration: Configuration = .standard) throws {
        self.configuration = configuration
        sink = BrowserModSink(registries: configuration.registries, environment: environment)
        forwarder = ModEventForwarder(registries: configuration.registries, environment: environment)
        services = AppModServices(environment: environment)
        services.defaults = configuration.defaults
        services.folderSize = { url in
            guard let size = await SizeEngine.shared.cachedSize(of: url), size.isSettled else { return nil }
            return size.allocatedBytes
        }
        index = ModIndexBridge(paths: configuration.paths, url: configuration.indexURL)
        controller = try Self.makeController(configuration, services: services)
        services.modName = { [weak controller] id in controller?.status(id: id)?.name ?? id }
        wire()
    }

    static func makeController(_ c: Configuration, services: AppModServices) throws -> ModHostController {
        let options = ModRuntimeOptions(paths: c.paths, transport: c.transport, checkTransport: c.checkTransport, developerMode: true, settingsDefaults: c.settingsDefaults)
        let deps = ModRuntimeDependencies(
            scopedAccess: c.scopedAccess, services: services, fileOperations: FileOperationQueueAdapter(), fileSearch: ModNameSearch(),
            credentials: SecretStoreCredentials(secrets: c.credentials, paths: c.paths), hookRegistry: c.hookRegistry, secrets: c.secrets
        )
        return try ModHostController(options: options, dependencies: deps)
    }

    private func wire() {
        let globalSink: ModUIRegistrySink = configuration.globalKeybindings ? ModGlobalKeybindingSink(wrapping: sink) : sink
        controller.attach(sink: globalSink, assets: configuration.systemAssets ? ModSystemAssetRegistrar() : nil)
        controller.onEvent = { [weak self] e in
            Task { @MainActor in self?.hostEvent(e) }
        }
        sink.contextProvider = { [weak self] in self?.forwarder.currentContext ?? BrowserContext(location: .computer) }
        sink.onNotify = { [weak self] modId, message, level in
            guard let self else { return }
            self.notifier(self.controller.status(id: modId)?.name ?? modId, message, level)
        }
        forwarder.onSelection = { [weak self] urls, rev in
            guard let c = self?.controller else { return }
            Task { await c.notifySelectionChanged(urls, revision: rev) }
        }
        forwarder.onLocation = { [weak self] loc, rev in
            guard let c = self?.controller else { return }
            Task { await c.notifyLocationChanged(id: loc.id, title: loc.title, provider: loc.provider, revision: rev) }
        }
        forwarder.onTheme = { [weak self] name, dark in
            guard let c = self?.controller else { return }
            Task { await c.notifyThemeChanged(name: name, dark: dark) }
        }
    }

    private func hostEvent(_ e: ModHostEvent) {
        switch e.kind {
        case .safeMode:
            notifier("Mods", "Safe mode is on: \(e.detail)", "warning")
        case .quarantined:
            notifier(e.modId.flatMap { controller.status(id: $0)?.name } ?? "Mod", "A handler was stopped: \(e.detail)", "error")
        case .crashed, .hung:
            if lastHostEvent != e.kind { notifier("Mods", "The mod host restarted.", "warning") }
        default: break
        }
        lastHostEvent = e.kind
    }

    public var management: ModManagementControlling {
        if let m = managementValue { return m }
        let m = GatedModManagement(inner: ModHostManagementController(runtime: controller, index: index, fetcher: index), gate: configuration.checkGate)
        m.onUninstall = { [services] id in services.forgetAlwaysAllowedExecution(modId: id) }
        managementValue = m
        return m
    }

    func gated<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if let gate = configuration.checkGate { return try await gate.run(body) }
        return try await body()
    }

    public var isSafeMode: Bool { controller.isSafeMode }

    public var developerMode: Bool {
        get { configuration.defaults.bool(forKey: AppModDefaults.developerMode) }
        set { configuration.defaults.set(newValue, forKey: AppModDefaults.developerMode) }
    }

    public func start() async {
        guard !started else { return }
        started = true
        sink.restoreReplacedBuiltins()
        forwarder.install()
        let t0 = Date()
        await controller.start()
        sink.flush()
        startDuration = Date().timeIntervalSince(t0)
        resumeDevWatchers()
    }

    public func shutdown() async {
        for w in watchers.values { w.stop() }
        watchers.removeAll()
        await controller.shutdown()
        sink.flush()
        forwarder.uninstall()
        started = false
    }

    public func enterSafeMode() async {
        guard !controller.isSafeMode else { return }
        await controller.enterSafeMode(reason: "turned on from the Mods menu")
        sink.flush()
    }

    public func exitSafeMode() async {
        guard controller.isSafeMode else { return }
        await controller.exitSafeMode()
        sink.flush()
    }

    public func toggleSafeMode() async {
        if controller.isSafeMode { await exitSafeMode() } else { await enterSafeMode() }
    }

    static func writeHealth(_ url: URL, _ body: (inout [String: Any]) -> Void) {
        var dict = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["failures": [Any]()]
        body(&dict)
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    public func reloadAll() async {
        let ids = controller.status().filter(\.enabled).map(\.id)
        for id in ids where !controller.isSafeMode {
            if let folder = devFolder(id) {
                await reloadDev(id: id, folder: folder, quiet: true)
                continue
            }
            try? await controller.disable(id: id)
            do { try await controller.enable(id: id) } catch { notifier(controller.status(id: id)?.name ?? id, error.localizedDescription, "error") }
        }
        sink.flush()
        notifier("Mods", ids.isEmpty ? "No enabled mods to reload." : "Reloaded \(ids.count) mod\(ids.count == 1 ? "" : "s").", "info")
    }

    public typealias PermissionApprover = @MainActor (_ manifest: ModManifest, _ receipt: PreflightReceipt) async -> Set<String>?
    public typealias RootChooser = @MainActor (_ manifest: ModManifest, _ permission: ModPermission) async -> URL?

    public static let interactiveApprover: PermissionApprover = { m, r in
        await ModPermissionSheet.approve(name: m.name, version: m.version.description, permissions: m.permissions, receipt: r)
    }

    public static let interactiveRootChooser: RootChooser = { m, p in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "Choose the folder “\(m.name)” may \(p.kind == .fsWrite ? "write to" : "read") as “\(p.rootId ?? "root")”." + (p.reason.map { " \($0)" } ?? "")
        if p.rootId == "downloads" { panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    public func install(from source: URL, developer: Bool = false, approver: PermissionApprover? = nil, rootChooser: RootChooser? = nil, preapproved: Set<String>? = nil) async -> ModInstallOutcome {
        let approver = approver ?? Self.interactiveApprover
        let rootChooser = rootChooser ?? Self.interactiveRootChooser
        let report: ModPreflightReport
        do {
            let controller = controller
            report = try await gated { try await controller.install(from: source, developer: developer, approvedPermissionIDs: preapproved) }
        } catch {
            return ModInstallOutcome(id: nil, installed: false, enabled: false, cancelled: false, receipt: nil, error: error.localizedDescription)
        }
        return await finishInstall(report, approver: approver, rootChooser: rootChooser)
    }

    @discardableResult
    public func installRelease(_ artifact: ModReleaseArtifact, approver: PermissionApprover? = nil, rootChooser: RootChooser? = nil) async -> ModInstallOutcome {
        let approver = approver ?? Self.interactiveApprover
        let rootChooser = rootChooser ?? Self.interactiveRootChooser
        let report: ModPreflightReport
        do {
            let controller = controller
            report = try await gated { try await controller.installRelease(artifact) }
        } catch {
            return ModInstallOutcome(id: artifact.listing.id, installed: false, enabled: false, cancelled: false, receipt: nil, error: error.localizedDescription)
        }
        return await finishInstall(report, approver: approver, rootChooser: rootChooser)
    }

    private func finishInstall(_ report: ModPreflightReport, approver: PermissionApprover, rootChooser: RootChooser) async -> ModInstallOutcome {
        guard report.installed, let manifest = report.manifest else {
            let first = report.receipt.diagnostics.first { $0.severity == .error }?.message ?? "preflight did not complete"
            return ModInstallOutcome(id: report.manifest?.id, installed: false, enabled: false, cancelled: false, receipt: report.receipt, error: first)
        }
        let id = manifest.id
        let wasEnabled = controller.status(id: id)?.enabled == true && controller.status(id: id)?.active == true
        if wasEnabled {
            sink.flush()
            return ModInstallOutcome(id: id, installed: true, enabled: true, cancelled: false, receipt: report.receipt, error: nil)
        }
        guard let approved = await approver(manifest, report.receipt) else {
            if controller.status(id: id)?.hasPrevious != true { try? await controller.uninstall(id: id, deleteData: false) }
            return ModInstallOutcome(id: id, installed: false, enabled: false, cancelled: true, receipt: report.receipt, error: nil)
        }
        do {
            try await controller.approve(id: id, permissionIDs: approved)
            for p in manifest.permissions where (p.kind == .fsRead || p.kind == .fsWrite) && p.scope == .root && approved.contains(ModHostManagementController.summary(p).id) {
                guard let rootId = p.rootId, controller.grants.boundRoot(id, rootId: rootId) == nil else { continue }
                if let url = await rootChooser(manifest, p) { try controller.bindRoot(id: id, rootId: rootId, to: url) }
            }
            try await controller.enable(id: id)
            sink.flush()
            return ModInstallOutcome(id: id, installed: true, enabled: true, cancelled: false, receipt: report.receipt, error: nil)
        } catch {
            return ModInstallOutcome(id: id, installed: true, enabled: false, cancelled: false, receipt: report.receipt, error: error.localizedDescription)
        }
    }

    public func installFromFile() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        var types: [UTType] = [.folder, .zip]
        if let bfmod = UTType(filenameExtension: "bfmod") { types.append(bfmod) }
        panel.allowedContentTypes = types
        panel.prompt = "Install"
        panel.message = "Choose a mod folder, .bfmod or .zip package."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await present(await install(from: url), source: url)
    }

    func present(_ outcome: ModInstallOutcome, source: URL) async {
        if outcome.cancelled { return }
        let name = outcome.id.flatMap { controller.status(id: $0)?.name } ?? source.deletingPathExtension().lastPathComponent
        if outcome.enabled {
            notifier(name, "Installed and enabled.", "info")
        } else if !outcome.installed {
            let error: Error? = outcome.error.map { ModRuntimeError.preflightFailed($0) }
            await ModPermissionSheet.showFailure(title: "“\(name)” couldn't be installed", receipt: outcome.receipt, error: error)
        } else {
            let error: Error? = outcome.error.map { ModRuntimeError.activationFailed($0) }
            await ModPermissionSheet.showFailure(title: "“\(name)” was installed but couldn't be enabled", receipt: nil, error: error)
        }
    }

    public func devFolder(_ id: String) -> URL? {
        (configuration.defaults.dictionary(forKey: AppModDefaults.devFolders) as? [String: String])?[id].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func setDevFolder(_ id: String, _ url: URL?) {
        var all = configuration.defaults.dictionary(forKey: AppModDefaults.devFolders) as? [String: String] ?? [:]
        all[id] = url?.path
        configuration.defaults.set(all, forKey: AppModDefaults.devFolders)
    }

    public func loadUnpackedMod() async {
        if !developerMode {
            let alert = NSAlert()
            alert.messageText = "Turn on mod developer mode?"
            alert.informativeText = "Developer mode loads unsigned mods straight from a folder and reloads them when you save. They still go through preflight and ask for permissions."
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            guard await AppModServices.present(alert) == .alertFirstButtonReturn else { return }
            developerMode = true
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose an unpacked mod folder (with manifest.json)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let outcome = await loadUnpacked(url)
        await present(outcome, source: url)
    }

    @discardableResult
    public func loadUnpacked(_ folder: URL, approver: PermissionApprover? = nil, rootChooser: RootChooser? = nil, preapproved: Set<String>? = nil) async -> ModInstallOutcome {
        let outcome = await install(from: folder, developer: true, approver: approver, rootChooser: rootChooser, preapproved: preapproved)
        if let id = outcome.id, outcome.installed {
            setDevFolder(id, folder)
            watch(id: id, folder: folder)
        }
        return outcome
    }

    public func unloadDev(id: String) {
        watchers.removeValue(forKey: id)?.stop()
        setDevFolder(id, nil)
    }

    public var watchedDevMods: [String: URL] { watchers.mapValues(\.folder) }

    private func resumeDevWatchers() {
        guard developerMode else { return }
        let all = configuration.defaults.dictionary(forKey: AppModDefaults.devFolders) as? [String: String] ?? [:]
        for (id, path) in all {
            guard controller.status(id: id) != nil, FileManager.default.fileExists(atPath: path) else { setDevFolder(id, nil); continue }
            watch(id: id, folder: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func watch(id: String, folder: URL) {
        watchers[id]?.stop()
        let w = ModFolderWatcher(folder: folder) { [weak self] in
            Task { @MainActor in await self?.reloadDev(id: id, folder: folder, quiet: false) }
        }
        w.start()
        watchers[id] = w
    }

    public private(set) var lastDevReload: (id: String, ok: Bool, message: String)?

    public func reloadDev(id: String, folder: URL, quiet: Bool) async {
        let name = controller.status(id: id)?.name ?? id
        do {
            let controller = controller
            let report = try await gated { try await controller.reload(id: id, from: folder) }
            sink.flush()
            if report.installed {
                pruneSnapshots(id)
                lastDevReload = (id, true, "reloaded")
                if !quiet { notifier(name, "Reloaded.", "info") }
            } else {
                let first = report.receipt.diagnostics.first { $0.severity == .error }
                let msg = first.map { "\($0.code.rawValue)\($0.file.map { " \($0)" } ?? ""): \($0.message)" } ?? "preflight did not complete"
                lastDevReload = (id, false, msg)
                notifier(name, "Kept the previous version. \(msg)", "error")
            }
        } catch {
            lastDevReload = (id, false, error.localizedDescription)
            notifier(name, "Kept the previous version. \(error.localizedDescription)", "error")
        }
    }

    private func pruneSnapshots(_ id: String) {
        controller.pruneSnapshots(id: id)
    }

    public func logText(id: String) -> String {
        let f = ISO8601DateFormatter()
        return controller.logs(id: id).map { "\(f.string(from: $0.time)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
    }

    public func eventText() -> String {
        let f = ISO8601DateFormatter()
        var lines = controller.events.map { "\(f.string(from: $0.time)) [\($0.kind.rawValue)]\($0.modId.map { " \($0)" } ?? "") \($0.detail)" }
        if controller.isSafeMode { lines.append("Safe mode is on.") }
        if let p = index.problem { lines.append("Index: \(p)") }
        if let d = startDuration { lines.append(String(format: "Mod start took %.0f ms.", d * 1000)) }
        return lines.joined(separator: "\n")
    }

    public func showLogs() {
        let logs = ModLogsWindowController.shared
        logs.source = { [weak self] in self?.controller.status().map { ($0.id, "\($0.name) (\($0.id))") } ?? [] }
        logs.logs = { [weak self] id in self?.logText(id: id) ?? "" }
        logs.events = { [weak self] in self?.eventText() ?? "" }
        logs.present()
    }
}

public final class GatedModManagement: ModManagementControlling, @unchecked Sendable {
    public let inner: ModHostManagementController
    public let gate: ModCheckGate?
    public var onUninstall: (@Sendable (String) -> Void)?

    public init(inner: ModHostManagementController, gate: ModCheckGate?) {
        self.inner = inner
        self.gate = gate
    }

    private func gated<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if let gate { return try await gate.run(body) }
        return try await body()
    }

    public func listInstalled() async throws -> [Settings.InstalledMod] { try await inner.listInstalled() }
    public func fetchIndex() async throws -> ModIndexSnapshot { try await inner.fetchIndex() }
    public func preflight(id: String) async throws -> PreflightResultSummary { try await gated { try await self.inner.preflight(id: id) } }
    public func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> Settings.InstalledMod {
        try await gated { try await self.inner.install(listing, approvedPermissionIDs: approvedPermissionIDs) }
    }
    public func enable(id: String) async throws -> Settings.InstalledMod { try await inner.enable(id: id) }
    public func disable(id: String) async throws -> Settings.InstalledMod { try await inner.disable(id: id) }
    public func uninstall(id: String, deleteData: Bool) async throws {
        try await inner.uninstall(id: id, deleteData: deleteData)
        onUninstall?(id)
    }
    public func update(id: String, approvedPermissionIDs: Set<String>) async throws -> Settings.InstalledMod {
        try await gated { try await self.inner.update(id: id, approvedPermissionIDs: approvedPermissionIDs) }
    }
}
