import CryptoKit
import Foundation
import ModKit
@preconcurrency import ModScriptTS

public struct ModValidationResult: Sendable {
    public var receipt: PreflightReceipt
    public var manifest: ModManifest?
    public var package: ModPackage?
    public var compiled: CompiledMod?
    public var archiveSHA256: String?
    public var archiveBytes: Int?
}

private final class ToolchainBox: @unchecked Sendable {
    let toolchain: TSToolchain
    private let lock = NSLock()
    private let idleQueue = DispatchQueue(label: "betterfinder.modvalidator.idle", qos: .utility)
    private var active = 0
    private var generation = 0
    private var interval: TimeInterval = 60
    private var pressure: DispatchSourceMemoryPressure?

    init(_ toolchain: TSToolchain) {
        self.toolchain = toolchain
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: idleQueue)
        source.setEventHandler { [weak self] in _ = self?.unloadIfIdle(generation: nil) }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    var idleInterval: TimeInterval {
        get { lock.withLock { interval } }
        set { lock.withLock { interval = newValue } }
    }

    func begin() {
        lock.withLock {
            active += 1
            generation += 1
        }
    }

    func end() {
        let (gen, delay, idle): (Int, TimeInterval, Bool) = lock.withLock {
            active = max(0, active - 1)
            generation += 1
            return (generation, interval, active == 0)
        }
        guard idle, delay.isFinite, delay >= 0 else { return }
        idleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in _ = self?.unloadIfIdle(generation: gen) }
    }

    func unloadIfIdle(generation gen: Int?) -> Bool {
        toolchain.unloadIfIdle { [lock] in
            lock.withLock { active == 0 && (gen == nil || generation == gen) }
        }
    }
}

struct ScriptStage {
    var diagnostics: [ModDiagnostic] = []
    var analysis: ScriptAnalysis = .unknown
    var script: CompiledScript?
    var types: PreflightCheckStatus = .notRun
    var lint: PreflightCheckStatus = .notRun
    var compile: PreflightCheckStatus = .notRun
    var toolchainVersion: String?
    var sites: [String: String] = [:]
}

public final class ModValidator: @unchecked Sendable {
    public static let shared = ModValidator()

    public let catalog: ModCatalog
    private let box: ToolchainBox

    public init(catalog: ModCatalog = .v1) {
        self.catalog = catalog
        self.box = ToolchainBox(TSToolchain(catalog: ModCatalogAdapter.catalog(from: catalog)))
    }

    public var typeScriptVersion: String? { try? box.toolchain.toolchainVersion }

    public var idleUnloadInterval: TimeInterval {
        get { box.idleInterval }
        set { box.idleInterval = newValue }
    }

    public var isCompilerLoaded: Bool { box.toolchain.isLoaded }

    @discardableResult
    public func releaseCompilerIfIdle() -> Bool { box.unloadIfIdle(generation: nil) }

    public static func validate(
        _ source: ModPackageSource, host: HostInfo = .current, dryRunner: DryRunning = NotRunDryRunner()
    ) async -> PreflightReceipt {
        await shared.validate(source, host: host, dryRunner: dryRunner)
    }

    public static func validate(
        packageAt url: URL, host: HostInfo = .current, dryRunner: DryRunning = NotRunDryRunner()
    ) async -> PreflightReceipt {
        await shared.validate(ModPackageSource.detect(url), host: host, dryRunner: dryRunner)
    }

    public func validate(
        _ source: ModPackageSource, host: HostInfo = .current, dryRunner: DryRunning = NotRunDryRunner()
    ) async -> PreflightReceipt {
        await run(source, host: host, dryRunner: dryRunner).receipt
    }

    public func run(
        _ source: ModPackageSource, host: HostInfo = .current, dryRunner: DryRunning = NotRunDryRunner()
    ) async -> ModValidationResult {
        var archiveSHA: String?
        var archiveBytes: Int?
        let package: ModPackage
        switch source {
        case .package(let p):
            package = p
        case .directory(let url):
            package = PackageLoader.loadDirectory(url, limits: catalog.limits)
        case .archive(let url):
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return failure(
                    treeHash: SHA256.hex(url.path),
                    [ModDiagnostic(.invalidValue, file: url.lastPathComponent, message: "cannot read archive \(url.path)")]
                )
            }
            archiveSHA = Self.sha256(data)
            archiveBytes = data.count
            let loaded = PackageLoader.loadArchive(data, name: url.lastPathComponent, limits: catalog.limits)
            if loaded.fatal {
                var out = failure(treeHash: archiveSHA ?? "", loaded.package.inventoryDiagnostics)
                out.archiveSHA256 = archiveSHA
                out.archiveBytes = archiveBytes
                out.receipt.archiveSHA256 = archiveSHA
                return out
            }
            package = loaded.package
        case .archiveData(let data, let name):
            archiveSHA = Self.sha256(data)
            archiveBytes = data.count
            let loaded = PackageLoader.loadArchive(data, name: name, limits: catalog.limits)
            if loaded.fatal {
                var out = failure(treeHash: archiveSHA ?? "", loaded.package.inventoryDiagnostics)
                out.archiveSHA256 = archiveSHA
                out.archiveBytes = archiveBytes
                out.receipt.archiveSHA256 = archiveSHA
                return out
            }
            package = loaded.package
        }
        var result = await validate(package: package, host: host, dryRunner: dryRunner)
        result.archiveSHA256 = archiveSHA
        result.archiveBytes = archiveBytes
        result.receipt.archiveSHA256 = archiveSHA
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func failure(treeHash: String, _ diagnostics: [ModDiagnostic]) -> ModValidationResult {
        var checks = [PreflightCheck: PreflightCheckStatus]()
        checks[.paths] = .fail
        let receipt = PreflightReceipt(
            treeHash: treeHash, api: catalog.catalogVersion, toolchain: catalog.toolchain,
            checks: checks, diagnostics: Self.sorted(Self.dedupe(diagnostics))
        )
        return ModValidationResult(receipt: receipt, manifest: nil, package: nil, compiled: nil, archiveSHA256: nil, archiveBytes: nil)
    }

    private func validate(package: ModPackage, host: HostInfo, dryRunner: DryRunning) async -> ModValidationResult {
        let first = ModStaticPreflight.run(package: package, host: host, catalog: catalog)
        var outcome = first
        var stage: ScriptStage?
        if let manifest = first.manifest, manifest.runtime == .js || manifest.runtime == .ts {
            let s = await typeScriptStage(manifest: manifest, package: package)
            stage = s
            outcome = ModStaticPreflight.run(package: package, host: host, catalog: catalog, externalAnalysis: s.analysis)
        }

        var checks = [PreflightCheck: PreflightCheckStatus]()
        for (k, v) in outcome.receipt.checks { if let c = PreflightCheck(rawValue: k) { checks[c] = v } }
        var diagnostics = outcome.receipt.diagnostics
        var toolchain = catalog.toolchain
        if let s = stage {
            checks[.types] = s.types
            checks[.lint] = s.lint
            checks[.compile] = s.compile
            let existing = Set(diagnostics.compactMap { d -> String? in d.pointer.map { "\(d.code.rawValue)|\(d.file ?? "")|\($0)" } })
            for d in s.diagnostics {
                if let p = d.pointer, existing.contains("\(d.code.rawValue)|\(d.file ?? "")|\(p)") { continue }
                diagnostics.append(d)
            }
            if let v = s.toolchainVersion { toolchain += " " + v }
        }
        diagnostics += package.inventoryDiagnostics
        if package.inventoryDiagnostics.hasErrors { checks[.paths] = .fail }

        let manifest = outcome.manifest
        let staticOK = !diagnostics.hasErrors && PreflightCheck.staticChecks.allSatisfy { checks[$0] == .pass }

        var compiled: CompiledMod?
        if let manifest {
            var script: CompiledScript?
            if let s = stage { script = s.script }
            else if manifest.runtime == .jscIR, let entry = manifest.entry, let js = outcome.compiledScript {
                script = CompiledScript(runtime: .jscIR, entry: entry, executionSource: js)
            }
            compiled = CompiledMod(manifest: manifest, script: script, analysis: outcome.analysis)
        }

        if staticOK, let compiled {
            let extra = await dryRunner.dryRun(package: package, compiled: compiled)
            diagnostics += extra
            if extra.contains(where: { $0.code == .checkNotRun }) { checks[.dryRun] = .notRun }
            else { checks[.dryRun] = extra.hasErrors ? .fail : .pass }
        } else {
            checks[.dryRun] = .notRun
            diagnostics.append(ModDiagnostic(.checkNotRun, message: "dry run skipped: static checks did not pass"))
        }

        if let sites = stage?.sites, !sites.isEmpty { diagnostics = Self.annotateSites(diagnostics, sites: sites) }
        diagnostics = Self.locate(Self.sorted(Self.dedupe(diagnostics)), in: package, manifest: manifest)
        diagnostics = Self.sorted(diagnostics)
        let receipt = PreflightReceipt(
            treeHash: package.treeHash, api: catalog.catalogVersion, toolchain: toolchain, checks: checks, diagnostics: diagnostics
        )
        return ModValidationResult(receipt: receipt, manifest: manifest, package: package, compiled: compiled, archiveSHA256: nil, archiveBytes: nil)
    }

    static func dedupe(_ diagnostics: [ModDiagnostic]) -> [ModDiagnostic] {
        var seen = Set<String>()
        return diagnostics.filter { d in
            let key = [d.code.rawValue, d.severity.rawValue, d.file ?? "", d.pointer ?? "", "\(d.line ?? 0)", "\(d.column ?? 0)", d.message].joined(separator: "\u{1}")
            return seen.insert(key).inserted
        }
    }

    static func sorted(_ diagnostics: [ModDiagnostic]) -> [ModDiagnostic] {
        diagnostics.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            let fa = a.file ?? "", fb = b.file ?? ""
            if fa != fb { return fa.utf8.lexicographicallyPrecedes(fb.utf8) }
            let pa = a.pointer ?? "", pb = b.pointer ?? ""
            if pa != pb { return pa.utf8.lexicographicallyPrecedes(pb.utf8) }
            if (a.line ?? 0) != (b.line ?? 0) { return (a.line ?? 0) < (b.line ?? 0) }
            if (a.column ?? 0) != (b.column ?? 0) { return (a.column ?? 0) < (b.column ?? 0) }
            if a.code != b.code { return a.code.rawValue < b.code.rawValue }
            return a.message.utf8.lexicographicallyPrecedes(b.message.utf8)
        }
    }

    static func annotateSites(_ diagnostics: [ModDiagnostic], sites: [String: String]) -> [ModDiagnostic] {
        diagnostics.map { d in
            var out = d
            switch d.code {
            case .missingGrant:
                guard d.message.hasPrefix("script call ") else { return d }
                let name = d.message.dropFirst("script call ".count).prefix { $0 != " " }
                if let site = sites[String(name)] { out.message += " (first call at \(site))" }
            case .undeclaredRoot:
                guard let q = d.message.firstIndex(of: "'") else { return d }
                let rest = d.message[d.message.index(after: q)...]
                let root = rest.prefix { $0 != "'" }
                if let site = sites["root:" + root] { out.message += " (at \(site))" }
            default: break
            }
            return out
        }
    }

    static func locate(_ diagnostics: [ModDiagnostic], in package: ModPackage, manifest: ModManifest?) -> [ModDiagnostic] {
        var indexes = [String: JSONPositionIndex]()
        return diagnostics.map { d in
            guard d.line == nil, let pointer = d.pointer, let file = d.file, file.hasSuffix(".json"), let data = package.data(file) else { return d }
            if indexes[file] == nil { indexes[file] = JSONPositionIndex(data) }
            guard let at = indexes[file]?.locate(pointer) else { return d }
            var out = d
            out.line = at.line
            out.column = at.column
            return out
        }
    }

    private func typeScriptStage(manifest: ModManifest, package: ModPackage) async -> ScriptStage {
        var stage = ScriptStage()
        guard let entry = manifest.entry, package.exists(entry) else { return stage }
        let language: ScriptLanguage = manifest.runtime == .ts ? .ts : .js

        var sources = [String: String]()
        var total = 0
        for path in package.files.keys.sorted() {
            let lower = path.lowercased()
            if lower.hasSuffix(".d.ts") {
                stage.diagnostics.append(ModDiagnostic(
                    .forbiddenFileType, severity: .warning, file: path,
                    message: "declaration file '\(path)' is ignored by the validator",
                    fix: "Keep editor declarations out of the package; `betterfinder-mod package` excludes betterfinder.d.ts"
                ))
                continue
            }
            guard lower.hasSuffix(".ts") || lower.hasSuffix(".js") || lower.hasSuffix(".mjs") else { continue }
            let data = package.files[path]!
            total += data.count
            guard let text = String(data: data, encoding: .utf8) else {
                stage.diagnostics.append(ModDiagnostic(.invalidValue, file: path, message: "'\(path)' is not valid UTF-8"))
                continue
            }
            sources[path] = text
        }
        if total > catalog.limits.scriptBytes {
            stage.diagnostics.append(ModDiagnostic(.scriptSizeLimit, file: entry, message: "scripts total \(total) bytes; limit is \(catalog.limits.scriptBytes)"))
            stage.types = .fail
            return stage
        }
        guard sources[entry] != nil else { return stage }
        box.begin()
        defer { box.end() }

        var groups = [String: [(index: Int, handler: String)]]()
        for (i, h) in manifest.hooks.enumerated() where catalog.hook(named: h.name, version: h.version) != nil {
            let key = ModCatalogAdapter.hookKey(name: h.name, version: h.version)
            if groups[key, default: []].contains(where: { $0.handler == h.handler }) { continue }
            groups[key, default: []].append((i, h.handler))
        }
        let rounds = max(1, groups.values.map(\.count).max() ?? 0)

        var mapped = [ModDiagnostic]()
        var policyFailed = false
        var typesFailed = false
        var confirmed = Set<String>()
        var first: TSResult?
        let handle = box
        let language_ = language
        let sources_ = sources
        let entry_ = entry

        for round in 0..<rounds {
            var handlers = [String: String]()
            var chosen = [(key: String, index: Int, handler: String)]()
            for key in groups.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
                let list = groups[key]!
                if round < list.count {
                    handlers[key] = list[round].handler
                    chosen.append((key, list[round].index, list[round].handler))
                }
            }
            let emit = round == 0
            let handlers_ = handlers
            let outcome: Result<TSResult, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Result {
                        emit
                            ? try handle.toolchain.transpile(files: sources_, entry: entry_, language: language_, handlers: handlers_)
                            : try handle.toolchain.check(files: sources_, entry: entry_, language: language_, handlers: handlers_)
                    }
                    continuation.resume(returning: r)
                }
            }
            switch outcome {
            case .failure(let error):
                stage.diagnostics.append(ModDiagnostic(.internalMismatch, file: entry, message: "TypeScript toolchain failed: \(error)"))
                stage.toolchainVersion = try? handle.toolchain.toolchainVersion
                return stage
            case .success(let result):
                if round == 0 { first = result }
                var missing = Set<String>()
                for d in result.diagnostics where d.code == 90004 && d.message.hasPrefix("Unknown hook or missing handler export: ") {
                    missing.insert(String(d.message.dropFirst("Unknown hook or missing handler export: ".count)))
                }
                let live = chosen.filter { !missing.contains("\($0.key) -> \($0.handler)") }
                for c in live { confirmed.insert(c.handler) }
                let context = TSMappingContext(
                    entry: entry,
                    hookChecks: live.map { ($0.index, $0.key, $0.handler) },
                    manifestHooks: manifest.hooks
                )
                let importLines = Set(result.diagnostics.filter { $0.code == 90003 }.map { "\($0.file ?? ""):\($0.line ?? 0)" })
                for d in result.diagnostics {
                    if d.code == 2307, importLines.contains("\(d.file ?? ""):\(d.line ?? 0)") { continue }
                    guard let m = TSDiagnosticMapper.map(d, context: context) else { continue }
                    mapped.append(m)
                    if m.severity == .error {
                        if d.code >= 90000 { policyFailed = true } else { typesFailed = true }
                    }
                }
            }
        }

        var calls = [String]()
        var roots = [String]()
        var callsKnown = true
        if let result = first {
            calls = result.catalogCallNames
            roots = result.literalRootIDs
            for (k, v) in result.callSites where stage.sites[k] == nil { stage.sites[k] = v }
            for (k, v) in result.rootSites where stage.sites["root:" + k] == nil { stage.sites["root:" + k] = v }
            for e in result.escapes {
                callsKnown = false
                policyFailed = true
                mapped.append(ModDiagnostic(
                    .dynamicCatalogAccess, file: e.file, line: e.line, column: e.col, message: e.reason,
                    fix: "Call catalog functions directly as namespace.function(...) so grants can be checked, e.g. fs.readText(item, 4096)"
                ))
            }
        } else {
            callsKnown = false
        }
        var handlerTable = [String: String]()
        for h in confirmed { handlerTable[h] = "" }
        stage.analysis = ScriptAnalysis(handlers: handlerTable, catalogCalls: calls, literalRootIDs: roots, callsKnown: callsKnown)
        stage.diagnostics += ModValidator.dedupe(mapped)
        stage.toolchainVersion = try? handle.toolchain.toolchainVersion
        stage.types = typesFailed ? .fail : .pass
        stage.lint = policyFailed ? .fail : .pass
        if let result = first, let module = result.moduleSource, let exec = result.executionSource, !typesFailed, !policyFailed {
            stage.compile = .pass
            stage.script = CompiledScript(runtime: manifest.runtime, entry: entry, executionSource: exec, moduleSource: module)
        } else {
            stage.compile = .fail
        }
        return stage
    }
}
