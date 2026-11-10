import FileOps
import Foundation
import Integration
import ModHostProtocol
import ModKit
import ModValidation
import Settings

public struct ModRuntimeOptions: Sendable {
    public var paths: ModHostPaths
    public var hostConfig: ModHostConfig
    public var transport: ModHostTransportFactory
    public var checkTransport: ModHostTransportFactory?
    public var hostVersions: ModHostVersions
    public var safeModeFailures: Int
    public var safeModeWindow: TimeInterval
    public var quarantineDisableThreshold: Int
    public var deadlineGraceMs: Int
    public var dryRunDeadlineMs: Int
    public var developerMode: Bool
    public var settingsDefaults: (@Sendable (String) -> UserDefaults?)?
    public var checkHostIdleTimeout: TimeInterval = 30
    public var checkHostStartTimeout: TimeInterval = 15
    public var checkHostRetryDelay: TimeInterval = 11

    public init(
        paths: ModHostPaths = .standard, hostConfig: ModHostConfig = ModHostConfig(), transport: ModHostTransportFactory = ModHostTransports.xpc(),
        checkTransport: ModHostTransportFactory? = nil, hostVersions: ModHostVersions = .current, safeModeFailures: Int = 3,
        safeModeWindow: TimeInterval = 120, quarantineDisableThreshold: Int = 3, deadlineGraceMs: Int = 1500, dryRunDeadlineMs: Int = 2000,
        developerMode: Bool = false, settingsDefaults: (@Sendable (String) -> UserDefaults?)? = nil
    ) {
        self.paths = paths
        self.hostConfig = hostConfig
        self.transport = transport
        self.checkTransport = checkTransport
        self.hostVersions = hostVersions
        self.safeModeFailures = safeModeFailures
        self.safeModeWindow = safeModeWindow
        self.quarantineDisableThreshold = quarantineDisableThreshold
        self.deadlineGraceMs = deadlineGraceMs
        self.dryRunDeadlineMs = dryRunDeadlineMs
        self.developerMode = developerMode
        self.settingsDefaults = settingsDefaults
    }
}

public struct ModRuntimeDependencies: @unchecked Sendable {
    public var scopedAccess: ScopedAccessAuthorizing
    public var services: ModHostServices
    public var fileOperations: ModFileOperationsPerforming?
    public var fileSearch: ModFileSearching?
    public var credentials: ModCredentialStoring?
    public var hookRegistry: FileOperationHookRegistry?
    public var resolver: ModHostResolving
    public var secrets: SecretStore

    public init(
        scopedAccess: ScopedAccessAuthorizing = ScopedAccessAuthorizer.shared, services: ModHostServices = DenyingModHostServices(),
        fileOperations: ModFileOperationsPerforming? = nil, fileSearch: ModFileSearching? = nil, credentials: ModCredentialStoring? = nil,
        hookRegistry: FileOperationHookRegistry? = .shared, resolver: ModHostResolving = SystemHostResolver(), secrets: SecretStore = KeychainSecretStore.shared
    ) {
        self.scopedAccess = scopedAccess
        self.services = services
        self.fileOperations = fileOperations
        self.fileSearch = fileSearch
        self.credentials = credentials
        self.hookRegistry = hookRegistry
        self.resolver = resolver
        self.secrets = secrets
    }
}

public struct ModPreflightReport: Sendable {
    public var manifest: ModManifest?
    public var receipt: PreflightReceipt
    public var installed: Bool
    public var version: String?
}

public enum ModRuntimeError: LocalizedError, Equatable {
    case notInstalled(String)
    case preflightFailed(String)
    case safeMode
    case activationFailed(String)
    case developerModeRequired

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let id): return "\(id) is not installed"
        case .preflightFailed(let m): return m
        case .safeMode: return "mods are paused in safe mode"
        case .activationFailed(let m): return m
        case .developerModeRequired: return "unsigned local mods require developer mode"
        }
    }
}

public struct ModStatus: Sendable, Equatable {
    public var id: String
    public var name: String
    public var author: String
    public var version: String
    public var enabled: Bool
    public var active: Bool
    public var generation: Int?
    public var developer: Bool
    public var receipt: PreflightReceipt
    public var permissions: [ModPermission]
    public var approvedPermissionIDs: Set<String>
    public var lastError: String?
    public var suspendedReason: String?
    public var snapshot: URL
    public var hasPrevious: Bool
}

actor ModAsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

final class ModLiveRecord: @unchecked Sendable {
    let mod: ActiveMod
    var tokens: [ModRegistrationToken] = []
    var fileOpToken: FileOpsRegistrationToken?
    var activeOperationHooks = 0
    init(mod: ActiveMod) { self.mod = mod }
}

public final class ModHostController: ModBrokerRuntime, @unchecked Sendable {
    public let options: ModRuntimeOptions
    public let store: ModStore
    public let grants: ModGrantStore
    let deps: ModRuntimeDependencies
    let catalog = ModCatalog.v1
    let validator = ModValueValidator()
    let health: ModHealthStore
    let broker: ModBroker
    let supervisor: ModHostSupervisor
    let lifecycle = ModAsyncLock()
    private let lock = NSLock()
    private var live: [String: ModLiveRecord] = [:]
    private var generationCounter = 0
    private var safeModeValue = false
    private var hostStarted = false
    private var eventLog: [ModHostEvent] = []
    private var stagedUI: [String: [ModUIUpdate]] = [:]
    private var sinkRef: AnyObject?
    private var assetsRef: AnyObject?
    private var checkHostValue: ModHostSupervisor?
    private var checkIdle: DispatchWorkItem?
    let checkLock = ModAsyncLock()
    let fixture: ModFixtureBroker
    public var onEvent: (@Sendable (ModHostEvent) -> Void)?

    public init(options: ModRuntimeOptions = ModRuntimeOptions(), dependencies: ModRuntimeDependencies = ModRuntimeDependencies()) throws {
        self.options = options
        self.deps = dependencies
        self.store = try ModStore(paths: options.paths)
        self.grants = ModGrantStore(paths: options.paths, scopedAccess: dependencies.scopedAccess)
        self.health = ModHealthStore(url: options.paths.healthFile)
        self.fixture = ModFixtureBroker(catalog: .v1)
        let ledger = ModOperationLedger()
        broker = ModBroker(deps: ModBrokerDependencies(
            catalog: .v1, grants: grants, services: dependencies.services, fileOperations: dependencies.fileOperations,
            fileSearch: dependencies.fileSearch, credentials: dependencies.credentials,
            net: ModNetBroker(resolver: dependencies.resolver), ledger: ledger
        ))
        supervisor = ModHostSupervisor(factory: options.transport, config: options.hostConfig, deadlineGraceMs: options.deadlineGraceMs, callHandler: broker)
        broker.runtime = self
        supervisor.onEvent = { [weak self] e in self?.record(e) }
        supervisor.onHostFailure = { [weak self] offender, reason in self?.hostFailed(offender: offender, reason: reason) }
        supervisor.onRestarted = { [weak self] in self?.hostRestarted() }
    }

    @MainActor
    public func attach(sink: ModUIRegistrySink?, assets: ModAssetRegistering?) {
        lock.lock()
        sinkRef = sink
        assetsRef = assets
        lock.unlock()
    }

    @MainActor var sink: ModUIRegistrySink? { lock.lock(); defer { lock.unlock() }; return sinkRef as? ModUIRegistrySink }
    @MainActor var assets: ModAssetRegistering? { lock.lock(); defer { lock.unlock() }; return assetsRef as? ModAssetRegistering }

    public var isSafeMode: Bool { lock.lock(); defer { lock.unlock() }; return safeModeValue }
    public var events: [ModHostEvent] { lock.lock(); defer { lock.unlock() }; return eventLog }
    public var hostProcessIdentifier: pid_t? { supervisor.processIdentifier }
    public var hostInfo: ModHostInfo? { supervisor.hostInfo }
    public var hostStats: ModHostStats? { supervisor.lastStats }

    private func record(_ e: ModHostEvent) {
        lock.lock()
        eventLog.append(e)
        if eventLog.count > 200 { eventLog.removeFirst(eventLog.count - 200) }
        lock.unlock()
        onEvent?(e)
    }

    func liveRecord(_ id: String) -> ModLiveRecord? { lock.lock(); defer { lock.unlock() }; return live[id] }
    func activeMod(_ id: String) -> ActiveMod? { liveRecord(id)?.mod }
    var liveRecords: [ModLiveRecord] { lock.lock(); defer { lock.unlock() }; return Array(live.values) }

    private func nextGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generationCounter += 1
        return generationCounter
    }

    public func start() async {
        let h = health.read()
        let recent = h.failures.filter { Date().timeIntervalSince($0) < options.safeModeWindow }
        if h.safeMode || recent.count >= options.safeModeFailures {
            lock.withLock { safeModeValue = true }
            _ = health.update { $0.safeMode = true }
            record(ModHostEvent(kind: .safeMode, modId: nil, detail: "starting in safe mode after repeated host failures"))
            return
        }
        for s in store.allStates() where s.enabled && s.suspendedReason == nil {
            do { try await enable(id: s.id, reason: "startup") } catch {
                _ = try? store.update(s.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    public func shutdown() async {
        for r in liveRecords { await deactivate(r, reason: "shutdown") }
        supervisor.stop()
        stopCheckHost()
        lock.withLock { hostStarted = false }
        _ = health.update { $0.lastCleanShutdown = Date() }
    }

    public func exitSafeMode() async {
        _ = health.update { $0.safeMode = false; $0.failures = [] }
        lock.withLock { safeModeValue = false }
        await start()
    }

    func ensureHost() async throws {
        let started = lock.withLock { () -> Bool in
            let s = hostStarted
            hostStarted = true
            return s
        }
        if !started {
            do { try supervisor.start() } catch {
                lock.withLock { hostStarted = false }
                throw ModRuntimeError.activationFailed("cannot start the mod host: \(error.localizedDescription)")
            }
        }
        guard await supervisor.waitReady() else { throw ModRuntimeError.activationFailed("the mod host did not start") }
    }

    public func status() -> [ModStatus] { store.allStates().compactMap { status(id: $0.id) } }

    public func status(id: String) -> ModStatus? {
        guard let s = store.state(id) else { return nil }
        let manifest = manifestOf(s)
        let r = grants.record(id)
        let liveMod = activeMod(id)
        return ModStatus(
            id: id, name: manifest?.name ?? id, author: manifest?.author ?? "", version: s.active.version, enabled: s.enabled,
            active: liveMod != nil, generation: liveMod?.generation, developer: s.developer, receipt: s.active.receipt,
            permissions: manifest?.permissions ?? [], approvedPermissionIDs: r.approvedIDs, lastError: s.lastError,
            suspendedReason: s.suspendedReason, snapshot: store.snapshotURL(id, s.active), hasPrevious: s.previous != nil
        )
    }

    func manifestOf(_ s: ModState) -> ModManifest? {
        let url = store.snapshotURL(s.id, s.active).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), case .success(let m) = ModManifest.decode(data) else { return nil }
        return m
    }

    public func logs(id: String) -> [ModLogEntry] {
        if let m = activeMod(id) { return m.logs.all }
        return ModLogBuffer.read(file: options.paths.dataDirectory(id).appendingPathComponent("mod.log"))
    }

    func logBuffer(_ id: String) -> ModLogBuffer {
        if let m = activeMod(id) { return m.logs }
        return ModLogBuffer(file: options.paths.dataDirectory(id).appendingPathComponent("mod.log"))
    }

    func settingsStore(_ m: ModManifest) -> ModSettingsStore? {
        guard !m.settings.isEmpty else { return nil }
        let defaults = options.settingsDefaults?(m.id)
        return try? ModSettingsStore(modID: m.id, schema: ModSettingsBridge.schema(m.settings), defaults: defaults, secrets: deps.secrets)
    }


    struct Checked {
        var manifest: ModManifest?
        var receipt: PreflightReceipt
        var compiled: ModCompiledScript?
    }

    final class StagedDryRunner: DryRunning, @unchecked Sendable {
        weak var controller: ModHostController?
        let staged: URL
        init(controller: ModHostController, staged: URL) { self.controller = controller; self.staged = staged }

        func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] {
            guard let controller else { return [ModDiagnostic(.checkNotRun, message: "dry run not performed: the runtime shut down")] }
            let script = ModHostDryRunner.compiledScript(compiled, treeHash: package.treeHash, toolchain: controller.catalog.toolchain)
            return await controller.dryRun(manifest: compiled.manifest, package: package, staged: staged, compiled: script)
        }
    }

    func check(package: ModPackage, staged: URL) async -> Checked {
        let result = await ModValidator.shared.run(.package(package), host: options.hostVersions, dryRunner: StagedDryRunner(controller: self, staged: staged))
        let compiled = result.compiled.flatMap { ModHostDryRunner.compiledScript($0, treeHash: package.treeHash, toolchain: catalog.toolchain) }
        return Checked(manifest: result.manifest, receipt: result.receipt, compiled: compiled)
    }

    func dryRun(manifest: ModManifest, staged: URL, compiled: ModCompiledScript?) async -> [ModDiagnostic] {
        await dryRun(manifest: manifest, package: ModPackage.load(directory: staged), staged: staged, compiled: compiled)
    }

    public func dryRun(package: ModPackage, manifest: ModManifest, script: ModCompiledScript?) async -> [ModDiagnostic] {
        let dir = options.paths.staging.appendingPathComponent("dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { ModFiles.removeTree(dir) }
        do {
            for (path, data) in package.files {
                let out = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: out.path, contents: data, attributes: [.posixPermissions: 0o644]) else { throw ModStoreError.io(path) }
            }
        } catch {
            return [ModDiagnostic(.dryRunCrash, file: manifest.entry, message: "dry run: cannot stage the package: \(error.localizedDescription)")]
        }
        return await dryRun(manifest: manifest, package: package, staged: dir, compiled: script)
    }

    func dryRun(manifest: ModManifest, package: ModPackage, staged: URL, compiled: ModCompiledScript?) async -> [ModDiagnostic] {
        await checkLock.run { await self.dryRunLocked(manifest: manifest, package: package, staged: staged, compiled: compiled) }
    }

    static func dryRunCode(_ callCode: String) -> ModDiagnosticCode {
        switch callCode {
        case "timeout", "loadTimeout": return .dryRunTimeout
        case "quarantined", "hostRestarted", "hostStopped": return .dryRunCrash
        default: return .dryRunFailure
        }
    }

    private func dryRunLocked(manifest: ModManifest, package: ModPackage, staged: URL, compiled: ModCompiledScript?) async -> [ModDiagnostic] {
        var diags = [ModDiagnostic]()
        func fail(_ code: ModDiagnosticCode, _ m: String, file: String? = nil) {
            diags.append(ModDiagnostic(code, severity: .error, file: file ?? manifest.entry, message: "dry run: \(m)"))
        }
        let tmp = options.paths.staging.appendingPathComponent("dry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let generation = nextGeneration()
        let mod = ActiveMod(manifest: manifest, generation: generation, snapshot: staged, mode: .dryRun, grants: manifest.permissions,
                            logs: ModLogBuffer(file: nil), storageURL: tmp.appendingPathComponent("storage.json"), settings: nil)
        let regs = await MainActor.run { () -> (Bool, String?) in
            let sink = ModRecordingSink()
            do {
                let tokens = try self.registerContributions(mod, sink: sink, assets: nil, settings: nil)
                tokens.forEach { sink.removeNow($0) }
                return (sink.entries.isEmpty, nil)
            } catch {
                return (false, error.localizedDescription)
            }
        }
        if let e = regs.1 { fail(.dryRunFailure, "contributions failed to register: \(e)") } else if !regs.0 { fail(.dryRunFailure, "teardown left contributions registered") }
        guard manifest.runtime != .data else { return diags }
        guard let compiled else { fail(.dryRunFailure, "no compiled script"); return diags }
        let host: ModHostSupervisor
        switch await readyCheckHost() {
        case .success(let h): host = h
        case .failure(let e): fail(.dryRunCrash, e.message); return diags
        }
        defer {
            host.unload(mod)
            releaseCheckHost()
        }
        let handlers = Array(Set(manifest.hooks.map(\.handler))).sorted()
        if let e = await host.load(mod, request: ModLoadRequest(modId: manifest.id, generation: generation, kind: ModScriptKind(rawValue: compiled.kind) ?? .bfscript, source: compiled.source, handlers: handlers)) {
            fail(Self.dryRunCode(e.code), "load failed: \(e.message)")
            return diags
        }
        let synth = ModFixtureSynthesizer(catalog: catalog)
        var ordered = manifest.hooks.filter { $0.name == "activate" }
        ordered += manifest.hooks.filter { $0.name != "activate" && $0.name != "deactivate" }
        ordered += manifest.hooks.filter { $0.name == "deactivate" }
        for decl in ordered {
            guard let sig = catalog.hook(named: decl.name, version: decl.version) else { continue }
            var input = synth.value(sig.input)
            if decl.name == "activate" { input = .object(["reason": .string("enable")]) }
            if decl.name == "deactivate" { input = .object(["reason": .string("disable")]) }
            let inv = ModInvocation(mod: mod, hook: sig, handler: decl.handler, gesture: true, parent: nil)
            let deadline = min(sig.deadlineMs, options.dryRunDeadlineMs)
            let outcome = await host.invoke(inv, input: input, context: context(mod, deadline: deadline, env: ModHostEnvironment()), deadlineMs: deadline)
            switch outcome {
            case .value(let v):
                if sig.output != .void, let violation = validator.validate(v, sig.output) { fail(.dryRunFailure, "\(decl.handler) (\(decl.name)) returned an invalid result: \(violation)") }
            case .failure(let e):
                fail(Self.dryRunCode(e.code), "\(decl.handler) (\(decl.name)) failed: \(e.code): \(e.message)")
            }
            if !host.isReady, diags.last.map({ $0.message.contains(decl.handler) }) == true { return diags }
        }
        for test in ModAuthorTests.load(package: package, manifest: manifest, catalog: catalog).cases {
            guard let sig = catalog.hook(named: test.test.hook, version: test.test.version) else { continue }
            let inv = ModInvocation(mod: mod, hook: sig, handler: test.handler, gesture: true, parent: nil)
            let deadline = min(sig.deadlineMs, options.dryRunDeadlineMs)
            let outcome = await host.invoke(inv, input: test.test.input, context: context(mod, deadline: deadline, env: ModHostEnvironment()), deadlineMs: deadline)
            let observed: ModAuthorTestOutcome
            switch outcome {
            case .value(let v): observed = .value(sig.output == .void ? .null : v)
            case .failure(let e): observed = .failure(code: e.code, message: e.message)
            }
            if case .fail(let why) = ModAuthorTestEvaluator.evaluate(test.test.expect, outcome: observed) {
                var code = ModDiagnosticCode.dryRunFailure
                if case .failure(let e) = outcome { code = Self.dryRunCode(e.code) }
                fail(code, "author test \(test.displayName) failed: \(why)", file: test.path)
            }
            if !host.isReady { break }
        }
        return diags
    }

    private func readyCheckHost() async -> Result<ModHostSupervisor, CheckHostError> {
        let existing = lock.withLock { () -> ModHostSupervisor? in
            checkIdle?.cancel()
            checkIdle = nil
            return checkHostValue
        }
        if let h = existing {
            if h.isReady { return .success(h) }
            if await h.waitReady(timeout: options.checkHostStartTimeout) { return .success(h) }
            h.stop()
            lock.withLock { if checkHostValue === h { checkHostValue = nil } }
        }
        let checkFactory = options.checkTransport ?? (options.transport as? XPCModHostTransportFactory)?.checkCounterpart ?? options.transport
        var checkConfig = options.hostConfig
        checkConfig.memoryLimitMiB = max(checkConfig.memoryLimitMiB, 1024)
        var lastError = "check host did not start"
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(options.checkHostRetryDelay * 1_000_000_000)) }
            let host = ModHostSupervisor(factory: checkFactory, config: checkConfig, deadlineGraceMs: 500, callHandler: fixture)
            do { try host.start() } catch {
                lastError = "check host failed to start: \(error.localizedDescription)"
                continue
            }
            if await host.waitReady(timeout: options.checkHostStartTimeout) {
                lock.withLock { checkHostValue = host }
                return .success(host)
            }
            host.stop()
            lastError = "check host did not start"
        }
        return .failure(CheckHostError(message: lastError))
    }

    struct CheckHostError: Error { var message: String }

    private func releaseCheckHost() {
        let idle = options.checkHostIdleTimeout
        let item = DispatchWorkItem { [weak self] in self?.stopCheckHost() }
        lock.withLock {
            checkIdle?.cancel()
            checkIdle = item
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + idle, execute: item)
    }

    func stopCheckHost() {
        let h = lock.withLock { () -> ModHostSupervisor? in
            let h = checkHostValue
            checkHostValue = nil
            checkIdle?.cancel()
            checkIdle = nil
            return h
        }
        h?.stop()
    }

    public var checkHostIsWarm: Bool { lock.withLock { checkHostValue?.isReady ?? false } }

    public func preflight(directory: URL) async -> ModPreflightReport {
        let package = ModPackage.load(directory: directory)
        let c = await check(package: package, staged: directory)
        return ModPreflightReport(manifest: c.manifest, receipt: c.receipt, installed: false, version: c.manifest?.version.description)
    }

    public func preflight(id: String) async throws -> PreflightReceipt {
        guard let s = store.state(id) else { throw ModRuntimeError.notInstalled(id) }
        let dir = store.snapshotURL(id, s.active)
        let c = await check(package: store.loadPackage(id, s.active), staged: dir)
        _ = try store.update(id) { $0.active.receipt = c.receipt }
        if let compiled = c.compiled { store.saveCompiled(id, compiled) }
        if !c.receipt.ok, activeMod(id) != nil { try? await disable(id: id) }
        return c.receipt
    }


    @discardableResult
    public func install(from source: URL, developer: Bool = false, approvedPermissionIDs: Set<String>? = nil) async throws -> ModPreflightReport {
        if developer, !options.developerMode { throw ModRuntimeError.developerModeRequired }
        return try await lifecycle.run { try await self.installLocked(from: source, developer: developer, approvedPermissionIDs: developer ? approvedPermissionIDs : nil) }
    }

    func installLocked(from source: URL, developer: Bool, approvedPermissionIDs: Set<String>? = nil) async throws -> ModPreflightReport {
        let staged = try store.stage(source)
        defer { store.discardStaging(staged) }
        let package = ModPackage.load(directory: staged)
        let c = await check(package: package, staged: staged)
        guard let manifest = c.manifest, c.receipt.ok else {
            return ModPreflightReport(manifest: c.manifest, receipt: c.receipt, installed: false, version: c.manifest?.version.description)
        }
        let snap = try store.installSnapshot(id: manifest.id, version: manifest.version.description, package: package, stagedDirectory: staged)
        let version = ModInstalledVersion(version: manifest.version.description, folder: snap.folder, treeHash: package.treeHash, installedAt: Date(), receipt: c.receipt)
        if let compiled = c.compiled { store.saveCompiled(manifest.id, compiled) }
        if var existing = store.state(manifest.id) {
            let wasActive = activeMod(manifest.id) != nil
            if existing.active.folder != version.folder { existing.previous = existing.active }
            existing.active = version
            existing.developer = existing.developer || developer
            existing.lastError = nil
            try store.save(existing)
            _ = try grants.reconcile(manifest)
            if let approvedPermissionIDs {
                let declared = Set(manifest.permissions.map { ModPermissionID.make($0) })
                _ = try grants.approve(manifest, permissionIDs: approvedPermissionIDs.intersection(declared))
            }
            if wasActive {
                do { try await swapLocked(id: manifest.id, reason: "update") } catch {
                    if let prev = existing.previous {
                        existing.active = prev
                        existing.previous = version
                        existing.lastError = error.localizedDescription
                        try? store.save(existing)
                    }
                    throw error
                }
            }
        } else {
            try store.save(ModState(id: manifest.id, enabled: false, developer: developer, active: version))
        }
        if store.state(manifest.id)?.developer == true { pruneSnapshots(id: manifest.id) }
        return ModPreflightReport(manifest: manifest, receipt: c.receipt, installed: true, version: version.version)
    }

    @discardableResult
    public func pruneSnapshots(id: String) -> [String] {
        guard let s = store.state(id) else { return [] }
        let keep = Set([s.active.folder, s.previous?.folder].compactMap { $0 })
        let dir = options.paths.modDirectory(id)
        var removed = [String]()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") && !keep.contains(name) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue else { continue }
            store.removeVersion(id, folder: name)
            removed.append(name)
        }
        return removed.sorted()
    }

    public static func verifyRelease(_ artifact: ModReleaseArtifact, at date: Date? = nil) -> [ModDiagnostic] {
        var diags = [ModDiagnostic]()
        if artifact.author.author != artifact.listing.author {
            diags.append(ModDiagnostic(.untrustedAuthorKey, file: "listing.json", pointer: "/author", message: "author keys belong to \(artifact.author.author), not \(artifact.listing.author)"))
        }
        diags += ModAuthorKeys.verifyRelease(artifact.listing, authors: [artifact.author], at: date)
        guard let data = try? Data(contentsOf: artifact.archive, options: .mappedIfSafe) else {
            return diags + [ModDiagnostic(.artifactMismatch, file: artifact.archive.lastPathComponent, message: "cannot read the downloaded archive")]
        }
        diags += ModAuthorKeys.verifyArtifact(data, listing: artifact.listing)
        guard !diags.hasErrors else { return diags }
        let loaded = PackageLoader.loadArchive(data, name: artifact.archive.lastPathComponent)
        guard !loaded.fatal, let manifestData = loaded.package.data("manifest.json") else {
            return diags + loaded.package.inventoryDiagnostics + [ModDiagnostic(.missingManifest, message: "the archive has no readable manifest.json")]
        }
        switch ModManifest.decode(manifestData) {
        case .success(let m): diags += artifact.listing.consistency(with: m)
        case .failure(let d): diags.append(d)
        }
        return diags
    }

    @discardableResult
    public func installRelease(_ artifact: ModReleaseArtifact) async throws -> ModPreflightReport {
        let problems = Self.verifyRelease(artifact).filter { $0.severity == .error }
        if let first = problems.first {
            throw ModRuntimeError.preflightFailed("\(artifact.listing.title) \(artifact.listing.version) is not a trusted release: \(first.code.rawValue) \(first.message)")
        }
        let report = try await install(from: artifact.archive)
        if let m = report.manifest, report.installed, m.id != artifact.listing.id || m.version != artifact.listing.version {
            throw ModRuntimeError.preflightFailed("the installed package is \(m.id) \(m.version), not \(artifact.listing.id) \(artifact.listing.version)")
        }
        return report
    }

    public func approve(id: String, permissionIDs: Set<String>) async throws {
        guard let s = store.state(id), let m = manifestOf(s) else { throw ModRuntimeError.notInstalled(id) }
        let r = try grants.approve(m, permissionIDs: permissionIDs)
        activeMod(id)?.grants = r.approved
    }

    public func approveAll(id: String) async throws {
        guard let s = store.state(id), let m = manifestOf(s) else { throw ModRuntimeError.notInstalled(id) }
        let r = try grants.approveAll(m)
        activeMod(id)?.grants = r.approved
    }

    public func bindRoot(id: String, rootId: String, to url: URL) throws {
        guard let s = store.state(id), let m = manifestOf(s) else { throw ModRuntimeError.notInstalled(id) }
        try grants.bindRoot(m, rootId: rootId, url: url)
    }


    public func enable(id: String) async throws {
        try await lifecycle.run { try await self.enable(id: id, reason: "enable") }
    }

    func enable(id: String, reason: String) async throws {
        if isSafeMode { throw ModRuntimeError.safeMode }
        guard var s = store.state(id), let manifest = manifestOf(s) else { throw ModRuntimeError.notInstalled(id) }
        if activeMod(id) != nil {
            if !s.enabled { s.enabled = true; try store.save(s) }
            return
        }
        let package = store.loadPackage(id, s.active)
        guard s.active.receipt.ok, s.active.receipt.treeHash == package.treeHash, s.active.receipt.validator == ModKitVersion.validator,
              s.active.receipt.api == catalog.catalogVersion else {
            throw ModRuntimeError.preflightFailed("\(manifest.name) must pass preflight before it can be enabled")
        }
        let record = try await activate(manifest: manifest, state: s, reason: reason)
        do {
            try await registerLive(record)
        } catch {
            await deactivate(record, reason: "disable")
            throw ModRuntimeError.activationFailed("\(manifest.name) failed to register: \(error.localizedDescription)")
        }
        s.enabled = true
        s.lastError = nil
        s.suspendedReason = nil
        try store.save(s)
    }

    func compiledScript(id: String, state s: ModState, manifest: ModManifest) async throws -> ModCompiledScript? {
        guard manifest.runtime != .data else { return nil }
        let toolchain = manifest.runtime == .jscIR ? catalog.toolchain : "ts"
        if let c = store.compiled(id, treeHash: s.active.treeHash, toolchain: toolchain) { return c }
        let package = store.loadPackage(id, s.active)
        let result = await ModValidator.shared.run(.package(package), host: options.hostVersions, dryRunner: NotRunDryRunner())
        guard !result.receipt.diagnostics.hasErrors, let compiled = result.compiled,
              let c = ModHostDryRunner.compiledScript(compiled, treeHash: s.active.treeHash, toolchain: catalog.toolchain) else {
            throw ModRuntimeError.preflightFailed("script no longer compiles")
        }
        store.saveCompiled(id, c)
        return c
    }

    func activate(manifest: ModManifest, state s: ModState, reason: String) async throws -> ModLiveRecord {
        let approved = grants.record(manifest.id).approved.filter { manifest.permissions.contains($0) }
        let mod = ActiveMod(
            manifest: manifest, generation: nextGeneration(), snapshot: store.snapshotURL(manifest.id, s.active), mode: .live, grants: approved,
            logs: logBuffer(manifest.id), storageURL: options.paths.dataDirectory(manifest.id).appendingPathComponent("storage.json"),
            settings: settingsStore(manifest)
        )
        let record = ModLiveRecord(mod: mod)
        if let compiled = try await compiledScript(id: manifest.id, state: s, manifest: manifest) {
            try await ensureHost()
            let handlers = Array(Set(manifest.hooks.map(\.handler))).sorted()
            if let e = await supervisor.load(mod, request: ModLoadRequest(modId: mod.id, generation: mod.generation, kind: ModScriptKind(rawValue: compiled.kind) ?? .bfscript, source: compiled.source, handlers: handlers)) {
                throw ModRuntimeError.activationFailed("\(manifest.name) failed to load: \(e.message)")
            }
            if let decl = mod.handlers(for: "activate").first {
                lock.withLock { stagedUI[mod.id] = [] }
                let r = await invoke(mod, decl: decl, input: { _ in .object(["reason": .string(reason)]) }, gesture: false)
                if case .failure(let e) = r {
                    discardStagedUI(mod.id)
                    supervisor.unload(mod)
                    throw ModRuntimeError.activationFailed("\(manifest.name) activate failed: \(e.localizedDescription)")
                }
            }
        }
        return record
    }

    func registerLive(_ record: ModLiveRecord) async throws {
        let mod = record.mod
        let tokens: [ModRegistrationToken]
        do {
            tokens = try await MainActor.run { () throws -> [ModRegistrationToken] in
                let tokens = try self.registerContributions(mod, sink: self.sink, assets: self.assets, settings: mod.settings)
                self.replayStagedUI(mod.id)
                return tokens
            }
        } catch {
            discardStagedUI(mod.id)
            throw error
        }
        record.tokens = tokens
        record.fileOpToken = registerFileOpHook(mod, record: record)
        lock.withLock { live[mod.id] = record }
    }

    func deactivate(_ record: ModLiveRecord, reason: String) async {
        let mod = record.mod
        lock.withLock { if live[mod.id] === record { live.removeValue(forKey: mod.id) } }
        if let decl = mod.handlers(for: "deactivate").first {
            _ = await invoke(mod, decl: decl, input: { _ in .object(["reason": .string(reason)]) }, gesture: false, force: true)
        }
        record.fileOpToken?.cancel()
        let tokens = record.tokens
        record.tokens = []
        await MainActor.run { tokens.forEach { $0.cancel() } }
        if mod.manifest.runtime != .data { supervisor.unload(mod) }
        mod.handles.revokeAll()
        broker.deps.ledger.cancelAll(owner: mod.id)
    }

    public func disable(id: String) async throws {
        try await lifecycle.run {
            guard self.store.state(id) != nil else { throw ModRuntimeError.notInstalled(id) }
            if let r = self.liveRecord(id) { await self.deactivate(r, reason: "disable") }
            _ = try self.store.update(id) { $0.enabled = false }
        }
    }

    public func uninstall(id: String, deleteData: Bool) async throws {
        try await lifecycle.run {
            guard let s = self.store.state(id) else { throw ModRuntimeError.notInstalled(id) }
            if let r = self.liveRecord(id) { await self.deactivate(r, reason: "uninstall") }
            if deleteData {
                if let m = self.manifestOf(s) { try? self.settingsStore(m)?.eraseAllData() }
                self.grants.revokeAll(id)
                self.deps.credentials?.removeAll(modId: id)
            }
            self.store.removeAll(id, deleteData: deleteData)
        }
    }


    @discardableResult
    public func reload(id: String, from source: URL) async throws -> ModPreflightReport {
        try await lifecycle.run { try await self.installLocked(from: source, developer: self.store.state(id)?.developer ?? false) }
    }

    public func rollback(id: String) async throws {
        try await lifecycle.run {
            guard var s = self.store.state(id), let prev = s.previous else { throw ModRuntimeError.notInstalled(id) }
            let current = s.active
            s.active = prev
            s.previous = current
            try self.store.save(s)
            if let m = self.manifestOf(s) { _ = try self.grants.reconcile(m) }
            if self.activeMod(id) != nil { try await self.swapLocked(id: id, reason: "update") }
        }
    }

    func swapLocked(id: String, reason: String) async throws {
        guard let old = liveRecord(id), let s = store.state(id), let manifest = manifestOf(s) else { return }
        for _ in 0..<200 where old.activeOperationHooks > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let fresh = try await activate(manifest: manifest, state: s, reason: reason)
        let freshMod = fresh.mod
        let swapped: Result<[ModRegistrationToken], Error> = await MainActor.run {
            let oldTokens = old.tokens
            oldTokens.forEach { $0.cancel() }
            do {
                let tokens = try self.registerContributions(freshMod, sink: self.sink, assets: self.assets, settings: freshMod.settings)
                self.replayStagedUI(id)
                return .success(tokens)
            } catch {
                self.discardStagedUI(id)
                if let restored = try? self.registerContributions(old.mod, sink: self.sink, assets: self.assets, settings: old.mod.settings) { old.tokens = restored }
                return .failure(error)
            }
        }
        switch swapped {
        case .failure(let e):
            if freshMod.manifest.runtime != .data { supervisor.unload(freshMod) }
            throw ModRuntimeError.activationFailed("reload failed; kept the previous version: \(e.localizedDescription)")
        case .success(let tokens):
            fresh.tokens = tokens
            old.tokens = []
            old.fileOpToken?.cancel()
            fresh.fileOpToken = registerFileOpHook(freshMod, record: fresh)
            lock.withLock { live[id] = fresh }
            if let decl = old.mod.handlers(for: "deactivate").first {
                _ = await invoke(old.mod, decl: decl, input: { _ in .object(["reason": .string("reload")]) }, gesture: false, force: true)
            }
            if old.mod.manifest.runtime != .data { supervisor.unload(old.mod) }
            old.mod.handles.revokeAll()
        }
    }


    func context(_ mod: ActiveMod, deadline: Int, env: ModHostEnvironment) -> JSONValue {
        .object([
            "modId": .string(mod.id), "modID": .string(mod.id), "generation": .int(mod.generation), "locale": .string(env.locale),
            "appearance": .string(env.dark ? "dark" : "light"), "deadlineMs": .int(deadline),
        ])
    }

    func invoke(_ mod: ActiveMod, decl: ModHookDecl, input build: (ModInvocation) -> JSONValue, gesture: Bool, parent: ModInvocation? = nil, force: Bool = false) async -> Result<JSONValue, ModInvocationError> {
        if isSafeMode, !force { return .failure(.safeMode) }
        guard let sig = catalog.hook(named: decl.name, version: decl.version) else { return .failure(.notActive(decl.name)) }
        if mod.isQuarantined(decl.handler) { return .failure(.quarantined(decl.handler)) }
        let inv = ModInvocation(mod: mod, hook: sig, handler: decl.handler, gesture: gesture, parent: parent)
        let input = build(inv)
        defer { for t in inv.finish() { deps.scopedAccess.revokeSelectionToken(t) } }
        if let v = validator.validate(input, sig.input) { return .failure(.invalidInput(v.description)) }
        let env = await deps.services.environment()
        let outcome = await supervisor.invoke(inv, input: input, context: context(mod, deadline: sig.deadlineMs, env: env), deadlineMs: sig.deadlineMs)
        switch outcome {
        case .value(let v):
            if sig.output == .void { return .success(.null) }
            if let violation = validator.validate(v, sig.output) {
                mod.logs.append("error", "\(decl.handler) returned an invalid \(sig.signatureID) result: \(violation)", rateLimited: false)
                return .failure(.invalidOutput(violation.description))
            }
            return .success(v)
        case .failure(let e):
            if e.code != "cancelled" { mod.logs.append("error", "\(decl.handler) (\(decl.name)) failed: \(e.code): \(e.message)") }
            switch e.code {
            case "timeout": return .failure(.timeout(sig.deadlineMs))
            case "quarantined": return .failure(.quarantined(decl.handler))
            case "hostRestarted", "hostStopped", "notLoaded", "unloaded": return .failure(.hostFailure(e.message))
            default: return .failure(.script(code: e.code, message: e.message))
            }
        }
    }

    func runCommand(modId: String, commandId: String, selection: [URL], args: JSONValue?, parent: ModInvocation?) async throws -> JSONValue {
        guard let mod = parent?.mod ?? activeMod(modId) else { throw ModInvocationError.notActive(modId) }
        guard let cmd = mod.manifest.contributes.commands.first(where: { $0.id == commandId }),
              let decl = mod.manifest.hooks.first(where: { $0.name == "command.run" && $0.handler == cmd.handler }) else { throw ModInvocationError.notActive(commandId) }
        guard mod.isCommandEnabled(commandId) else { throw ModInvocationError.script(code: "disabled", message: "command is disabled") }
        let broker = broker
        let r = await invoke(mod, decl: decl, input: { inv in
            var o: [String: JSONValue] = ["commandId": .string(commandId), "selection": .array(broker.makeRefs(mod, urls: Array(selection.prefix(128)), invocation: inv))]
            if let args { o["args"] = args }
            return .object(o)
        }, gesture: true, parent: parent)
        return try r.get()
    }

    func runNestedCommand(_ commandId: String, args: JSONValue?, parent: ModInvocation) async -> ModCallOutcome {
        do { return .value(try await runCommand(modId: parent.mod.id, commandId: commandId, selection: [], args: args, parent: parent)) } catch let e as ModInvocationError {
            return .failure(ModCallError("commandFailed", e.localizedDescription))
        } catch {
            return .failure(ModCallError("commandFailed", error.localizedDescription))
        }
    }

    func applyUI(_ update: ModUIUpdate) async {
        if let owner = update.stagingOwner {
            let staged = lock.withLock { () -> Bool in
                guard var pending = stagedUI[owner] else { return false }
                if pending.count >= 256 { pending.removeFirst() }
                pending.append(update)
                stagedUI[owner] = pending
                return true
            }
            if staged { return }
        }
        await MainActor.run { self.sink?.apply(update) }
    }

    func discardStagedUI(_ id: String) {
        lock.withLock { _ = stagedUI.removeValue(forKey: id) }
    }

    @MainActor
    func replayStagedUI(_ id: String) {
        let pending = lock.withLock { stagedUI.removeValue(forKey: id) } ?? []
        for update in pending { sink?.apply(update) }
    }

    func settingsChanged(_ mod: ActiveMod, keys: [String]) async {
        guard let decl = mod.handlers(for: "settings.changed").first, let s = mod.settings else { return }
        _ = await invoke(mod, decl: decl, input: { _ in .object(["changed": .array(keys.map(JSONValue.string)), "values": .object(s.values.mapValues(ModBroker.json))]) }, gesture: false)
    }

    public func settingsDidChange(id: String, keys: [String]) async {
        guard let mod = activeMod(id) else { return }
        await settingsChanged(mod, keys: keys)
    }

    public func notifySelectionChanged(_ urls: [URL], revision: Int) async {
        for r in liveRecords {
            let mod = r.mod
            guard let decl = mod.handlers(for: "selection.changed").first, mod.grants.contains(where: { $0.kind == .uiSelection }) else { continue }
            let broker = broker
            _ = await invoke(mod, decl: decl, input: { inv in
                .object(["revision": .int(revision), "count": .int(urls.count), "items": .array(broker.makeRefs(mod, urls: Array(urls.prefix(128)), invocation: inv))])
            }, gesture: false)
        }
    }

    public func notifyLocationChanged(id: String, title: String, provider: String?, revision: Int) async {
        for r in liveRecords {
            guard let decl = r.mod.handlers(for: "location.changed").first else { continue }
            var loc: [String: JSONValue] = ["id": .string(id), "title": .string(title)]
            if let provider { loc["provider"] = .string(provider) }
            _ = await invoke(r.mod, decl: decl, input: { _ in .object(["revision": .int(revision), "location": .object(loc)]) }, gesture: false)
        }
    }

    public func notifyThemeChanged(name: String, dark: Bool) async {
        for r in liveRecords {
            guard let decl = r.mod.handlers(for: "theme.changed").first else { continue }
            _ = await invoke(r.mod, decl: decl, input: { _ in .object(["name": .string(name), "appearance": .string(dark ? "dark" : "light")]) }, gesture: false)
        }
    }

    public func runCommand(qualifiedID: String, selection: [URL], args: JSONValue? = nil) async throws -> ModCommandOutcome {
        guard let cid = ModContributionID(qualified: qualifiedID) else { throw ModInvocationError.notActive(qualifiedID) }
        let v = try await runCommand(modId: cid.modId, commandId: cid.localId, selection: selection, args: args, parent: nil)
        return ModCommandOutcome(message: v["message"]?.stringValue, operationId: v["operationId"]?.stringValue)
    }


    private func hostFailed(offender: ModInvocation?, reason: String) {
        let h = health.update { h in
            h.failures.append(Date())
            h.failures = h.failures.filter { Date().timeIntervalSince($0) < options.safeModeWindow }
        }
        if let offender {
            let count = offender.mod.quarantine(offender.handler)
            record(ModHostEvent(kind: .quarantined, modId: offender.mod.id, detail: "\(offender.handler): \(reason)"))
            offender.mod.logs.append("error", "quarantined \(offender.handler): \(reason)", rateLimited: false)
            if count >= options.quarantineDisableThreshold {
                let id = offender.mod.id
                Task { await self.suspend(id: id, reason: "suspended after \(count) host failures") }
            }
        }
        if h.failures.count >= options.safeModeFailures {
            Task { await self.enterSafeMode(reason: reason) }
        }
    }

    func suspend(id: String, reason: String) async {
        await lifecycle.run {
            if let r = self.liveRecord(id) { await self.deactivate(r, reason: "disable") }
            _ = try? self.store.update(id) { $0.suspendedReason = reason; $0.lastError = reason }
        }
    }

    public func enterSafeMode(reason: String = "entered from the app") async {
        let already = lock.withLock { () -> Bool in
            let a = safeModeValue
            safeModeValue = true
            return a
        }
        guard !already else { return }
        _ = health.update { $0.safeMode = true }
        record(ModHostEvent(kind: .safeMode, modId: nil, detail: reason))
        for r in liveRecords { await deactivate(r, reason: "shutdown") }
        supervisor.stop()
        lock.withLock { hostStarted = false }
    }

    private func hostRestarted() {
        let records = liveRecords
        Task {
            for r in records where r.mod.manifest.runtime != .data {
                if let decl = r.mod.handlers(for: "activate").first {
                    _ = await self.invoke(r.mod, decl: decl, input: { _ in .object(["reason": .string("reload")]) }, gesture: false)
                }
            }
        }
    }

    public func benchmarkHost(iterations: Int = 2_000_000) async throws -> UInt64? {
        try await ensureHost()
        return await supervisor.benchmark(iterations: iterations)
    }

    public func pingHost() async -> ModHostStats? { await supervisor.ping() }

    public func probeHostContainment(paths: [String], hosts: [String], spawn: String?) async throws -> [String: String] {
        try await ensureHost()
        return await supervisor.probe(paths: paths, hosts: hosts, spawn: spawn)
    }

    public func killHostForTesting() {
        if let pid = supervisor.processIdentifier { kill(pid, SIGKILL) }
    }
}

final class ModFixtureBroker: ModCallHandling, @unchecked Sendable {
    let catalog: ModCatalog
    let synth: ModFixtureSynthesizer
    let validator: ModValueValidator

    init(catalog: ModCatalog) {
        self.catalog = catalog
        self.synth = ModFixtureSynthesizer(catalog: catalog)
        self.validator = ModValueValidator(catalog: catalog)
    }

    func handle(_ call: ModCallRequest, invocation: ModInvocation) async -> ModCallOutcome {
        guard let fn = catalog.function(named: call.name) else { return .failure(.notFound("unknown catalog function '\(call.name)'")) }
        if let v = validator.validateArguments(call.args, for: fn) { return .failure(.invalid(v.description)) }
        for r in fn.requires where !invocation.mod.grants.satisfies(r) { return .failure(.notGranted("\(call.name) requires grant \(r.summary)")) }
        if call.name == "events.delay" { return .value(.null) }
        return .value(synth.value(fn.returns))
    }
}
