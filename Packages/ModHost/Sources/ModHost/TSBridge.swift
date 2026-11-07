import Foundation
import ModHostRuntime
import ModKit
import ModScriptTS

public enum ModTSCatalog {
    public static let slotsPerHook = 64

    public static func make(_ catalog: ModCatalog = .v1) -> Catalog {
        var renderer = Renderer(catalog: catalog)
        var grouped = [String: [Catalog.Function]]()
        for f in catalog.functions {
            let parts = f.name.split(separator: ".").map(String.init)
            let ns = parts.dropLast().joined(separator: ".")
            let params = f.params.map { Catalog.Parameter($0.optional ? "\($0.name)?" : $0.name, renderer.render($0.type, output: false)) }
            grouped[ns, default: []].append(Catalog.Function(ModTSNames.scriptName(parts.last!), parameters: params, result: "Promise<\(renderer.render(f.returns, output: true))>"))
        }
        let namespaces = grouped.keys.sorted().map { Catalog.Namespace($0, functions: grouped[$0]!) }
        var hooks = [Catalog.Hook]()
        let ctx = "ModContext & { readonly modId: string; readonly locale: string; readonly appearance: \"light\" | \"dark\"; readonly deadlineMs: number }"
        for h in catalog.hooks {
            let base = typeName(h.name)
            let input = renderer.render(h.input, output: false)
            let out = renderer.render(h.output, output: true)
            let result = "Promise<\(out)> | \(out)"
            let params = [Catalog.Parameter("context", ctx), Catalog.Parameter("input", input)]
            hooks.append(Catalog.Hook(h.name, handlerType: base, parameters: params, result: result))
            if h.multiple {
                for i in 2...slotsPerHook {
                    hooks.append(Catalog.Hook("\(h.name)#\(i)", handlerType: "\(base)\(i)", parameters: params, result: result))
                }
            }
        }
        return Catalog(namespaces: namespaces, hooks: hooks)
    }

    public static func handlerMap(for manifest: ModManifest) -> [String: String] {
        var counts = [String: Int]()
        var out = [String: String]()
        for h in manifest.hooks {
            let n = (counts[h.name] ?? 0) + 1
            counts[h.name] = n
            out[n == 1 ? h.name : "\(h.name)#\(n)"] = h.handler
        }
        return out
    }

    static func typeName(_ hook: String) -> String {
        hook.split(separator: ".").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Handler"
    }

    struct Renderer {
        let catalog: ModCatalog
        var visiting = Set<String>()

        mutating func render(_ t: ModTypeExpr, output: Bool) -> String {
            switch t {
            case .string: return "string"
            case .integer, .number: return "number"
            case .boolean: return "boolean"
            case .null: return "null"
            case .void: return "void"
            case .json: return "unknown"
            case .optional(let inner): return "(\(render(inner, output: output)) | null)"
            case .list(let inner): return "Array<\(render(inner, output: output))>"
            case .ref(let name):
                guard let def = catalog.type(named: name) else { return "unknown" }
                switch def.kind {
                case .alias: return render(def.aliasOf ?? .json, output: output)
                case .enum: return "(" + (def.cases ?? []).map { "\"\($0)\"" }.joined(separator: " | ") + ")"
                case .record:
                    if visiting.contains(name) { return "unknown" }
                    visiting.insert(name)
                    defer { visiting.remove(name) }
                    let fields = (def.fields ?? []).map { f -> String in
                        f.optional ? "\(f.name)?: \(render(f.type, output: output)) | null" : "\(f.name): \(render(f.type, output: output))"
                    }
                    return "{ " + fields.joined(separator: "; ") + " }"
                }
            }
        }
    }

    public static func diagnostics(_ result: TSResult) -> [ModDiagnostic] {
        result.diagnostics.compactMap { d in
            let severity: ModSeverity
            switch d.category {
            case .error: severity = .error
            case .warning: severity = .warning
            case .suggestion, .message: severity = .info
            }
            let code: ModDiagnosticCode
            switch d.code {
            case 90001: code = .pathNotContained
            case 90002: code = .unknownConstruct
            case 90003: code = .unknownReference
            case 90004: code = .missingHandlerFunction
            default: code = .typeMismatch
            }
            let migrated = ModDiagnosticCode.legacyMapping(code, context: .typeScript(code: d.code), message: d.message)
            return ModDiagnostic(migrated, severity: severity, file: d.file, line: d.line, column: d.col, message: (d.code >= 90000 ? "policy \(d.code): " : "TS\(d.code): ") + d.message)
        }
    }
}
