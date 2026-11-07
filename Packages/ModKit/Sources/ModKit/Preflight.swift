import Foundation

public struct ModPreflightOutcome: Sendable {
    public var manifest: ModManifest?
    public var receipt: PreflightReceipt
    public var compiledScript: String?
    public var analysis: ScriptAnalysis?
}

public enum ModStaticPreflight {
    public static func run(
        package: ModPackage, host: ModHostVersions = .current, catalog: ModCatalog = .v1,
        externalAnalysis: ScriptAnalysis? = nil
    ) -> ModPreflightOutcome {
        var checks = [PreflightCheck: PreflightCheckStatus]()
        var diags = [ModDiagnostic]()

        func finish(_ manifest: ModManifest?, _ compiled: String?, _ analysis: ScriptAnalysis?) -> ModPreflightOutcome {
            let receipt = PreflightReceipt(
                treeHash: package.treeHash, api: catalog.catalogVersion, toolchain: catalog.toolchain,
                checks: checks, diagnostics: diags
            )
            return ModPreflightOutcome(manifest: manifest, receipt: receipt, compiledScript: compiled, analysis: analysis)
        }

        guard let manifestData = package.data("manifest.json") else {
            diags.append(ModDiagnostic(.missingManifest, file: "manifest.json", message: "package has no manifest.json at its root", fix: "Add manifest.json"))
            diags += package.inventoryDiagnostics
            checks[.schema] = .fail
            return finish(nil, nil, nil)
        }
        if manifestData.count > catalog.limits.manifestBytes {
            diags.append(ModDiagnostic(.sizeBound, file: "manifest.json", message: "manifest is \(manifestData.count) bytes; limit is \(catalog.limits.manifestBytes)"))
            checks[.schema] = .fail
            return finish(nil, nil, nil)
        }

        let value: JSONValue
        do { value = try JSONValue.parse(manifestData) } catch let e as JSONParseError {
            diags.append(ModDiagnostic(.invalidJSON, file: "manifest.json", pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message))
            checks[.schema] = .fail
            return finish(nil, nil, nil)
        } catch {
            diags.append(ModDiagnostic(.invalidJSON, file: "manifest.json", message: "\(error)"))
            checks[.schema] = .fail
            return finish(nil, nil, nil)
        }

        let violations = JSONSchema.manifest.validate(value)
        let schemaDiags = JSONSchema.diagnostics(violations, file: "manifest.json", manifest: true)
        checks[.schema] = schemaDiags.isEmpty ? .pass : .fail
        var manifest: ModManifest?
        var decodeDiags = [ModDiagnostic]()
        switch ModDecoding.decode(ModManifest.self, from: value, file: "manifest.json") {
        case .success(let m): manifest = m
        case .failure(let e):
            if schemaDiags.isEmpty {
                decodeDiags.append(ModDiagnostic(.internalMismatch, file: "manifest.json", pointer: e.pointer, message: "decoder rejects a manifest the JSON Schema accepts: \(e.message)"))
            }
            if !schemaDiags.contains(where: { $0.pointer == e.pointer }) { decodeDiags.append(e) }
        }
        guard let m = manifest else {
            diags += schemaDiags + decodeDiags
            checks[.schema] = .fail
            return finish(nil, nil, nil)
        }

        var analysis: ScriptAnalysis? = externalAnalysis
        var compiled: String?
        var scriptDiags = [ModDiagnostic]()
        switch m.runtime {
        case .data:
            checks[.types] = .pass; checks[.lint] = .pass; checks[.compile] = .pass
            analysis = ScriptAnalysis(callsKnown: true)
        case .jscIR:
            if let entry = m.entry, let data = package.data(entry) {
                let report = BFScript.process(data: data, file: entry, catalog: catalog)
                scriptDiags = report.diagnostics
                analysis = report.analysis
                compiled = report.compiledJS
                let typeErrors = scriptDiags.filter { $0.severity == .error }
                checks[.types] = typeErrors.isEmpty ? .pass : .fail
                checks[.lint] = report.program == nil ? .notRun : .pass
                checks[.compile] = report.compiledJS != nil ? .pass : (report.program == nil ? .notRun : .fail)
            } else {
                analysis = ScriptAnalysis(callsKnown: false)
            }
        case .js, .ts:
            checks[.types] = .notRun; checks[.lint] = .notRun; checks[.compile] = .notRun
            if analysis == nil { analysis = .unknown }
        }

        let findings = ModManifestValidator.validate(m, package: package, host: host, catalog: catalog, analysis: analysis)
        let fixtureDiags = ModAuthorTests.validate(package: package, manifest: m, catalog: catalog)
        checks[.manifest] = (findings.manifest + fixtureDiags).hasErrors ? .fail : .pass
        checks[.grants] = findings.grants.hasErrors ? .fail : .pass
        checks[.paths] = findings.paths.hasErrors ? .fail : .pass
        if m.runtime == .jscIR, m.entry.flatMap({ package.data($0) }) == nil {
            checks[.types] = .notRun; checks[.lint] = .notRun; checks[.compile] = .notRun
        }
        let semantic = findings.manifest + fixtureDiags + findings.grants + findings.paths
        let covered = Set(semantic.filter { $0.severity == .error }.compactMap(\.pointer))
        diags += schemaDiags.filter { !covered.contains($0.pointer ?? "\u{0}") }
        diags += semantic + scriptDiags
        diags.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if (a.file ?? "") != (b.file ?? "") { return (a.file ?? "") < (b.file ?? "") }
            if (a.pointer ?? "") != (b.pointer ?? "") { return (a.pointer ?? "") < (b.pointer ?? "") }
            return a.code.rawValue < b.code.rawValue
        }
        return finish(m, compiled, analysis)
    }
}
