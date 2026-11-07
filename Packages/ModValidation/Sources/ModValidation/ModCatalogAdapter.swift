import Foundation
import ModKit
import ModScriptTS

public enum ModCatalogAdapter {
    public static func hookKey(name: String, version: Int) -> String { version == 1 ? name : "\(name)@\(version)" }

    public static func handlerTypeName(name: String, version: Int) -> String {
        let words = name.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
        let base = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return base + (version == 1 ? "" : "V\(version)") + "Handler"
    }

    public static func typeScript(_ type: ModTypeExpr) -> String {
        switch type {
        case .string: return "string"
        case .integer, .number: return "number"
        case .boolean: return "boolean"
        case .null: return "null"
        case .void: return "void"
        case .json: return "JSONValue"
        case .ref(let name): return name
        case .list(let inner):
            if case .optional = inner { return "(\(typeScript(inner)))[]" }
            return "\(typeScript(inner))[]"
        case .optional(let inner):
            if case .optional = inner { return typeScript(inner) }
            return "\(typeScript(inner)) | null"
        }
    }

    static func parameterList(_ params: [ModParam]) -> [ModScriptTS.Catalog.Parameter] {
        params.map { .init($0.optional ? "\($0.name)?" : $0.name, typeScript($0.type)) }
    }

    static func asyncResult(_ type: ModTypeExpr) -> String { "Promise<\(typeScript(type))>" }

    public static func scriptName(_ catalogName: String) -> String { TSReservedNames.scriptPath(catalogName) }

    public static func catalog(from catalog: ModCatalog = .v1) -> ModScriptTS.Catalog {
        var buckets = [String: [ModScriptTS.Catalog.Function]]()
        for f in catalog.functions {
            let parts = f.name.split(separator: ".").map(String.init)
            let scope = parts.dropLast().joined(separator: ".")
            buckets[scope, default: []].append(.init(parts.last ?? f.name, parameters: parameterList(f.params), result: asyncResult(f.returns)))
        }
        let namespaces = buckets.keys.sorted().map { ModScriptTS.Catalog.Namespace($0, functions: buckets[$0] ?? []) }
        let hooks = catalog.hooks.map { h in
            ModScriptTS.Catalog.Hook(
                hookKey(name: h.name, version: h.version),
                handlerType: handlerTypeName(name: h.name, version: h.version),
                parameters: [.init("context", "HookContext"), .init("input", typeScript(h.input))],
                result: asyncResult(h.output)
            )
        }
        return .init(namespaces: namespaces, hooks: hooks, types: [typeDeclarations(catalog)])
    }

    static func typeDeclarations(_ catalog: ModCatalog) -> String {
        var lines = [String]()
        lines.append("  export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };")
        func doc(_ text: String, indent: String) {
            guard !text.isEmpty else { return }
            lines.append("\(indent)/** \(text.replacingOccurrences(of: "*/", with: "* /")) */")
        }
        for t in catalog.types {
            doc(t.doc, indent: "  ")
            switch t.kind {
            case .alias:
                lines.append("  export type \(t.name) = \(t.aliasOf.map(typeScript) ?? "unknown");")
            case .enum:
                lines.append("  export type \(t.name) = " + (t.cases ?? []).map { "\"\($0)\"" }.joined(separator: " | ") + ";")
            case .record:
                lines.append("  export interface \(t.name) {")
                for f in t.fields ?? [] {
                    doc(f.doc, indent: "    ")
                    lines.append("    \(f.name)\(f.optional ? "?" : ""): \(typeScript(f.type));")
                }
                lines.append("  }")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func declarations(from catalog: ModCatalog = .v1) -> String {
        DeclarationGenerator.generate(self.catalog(from: catalog))
    }

    public static func namespaceNames(_ catalog: ModCatalog = .v1) -> Set<String> {
        Set(catalog.namespaces.map(\.name))
    }
}

struct TSMappingContext {
    var entry: String
    var hookChecks: [(manifestIndex: Int, hook: String, handler: String)]
    var manifestHooks: [ModHookDecl]
}

enum TSDiagnosticMapper {
    static let hookCheckFile = "__bf_hook_check.ts"

    static func code(for d: TSDiagnostic) -> ModDiagnosticCode {
        ModDiagnosticCode.legacyMapping(code(forCode: d.code, message: d.message), context: .typeScript(code: d.code), message: d.message)
    }

    static func code(forCode code: Int, message: String) -> ModDiagnosticCode {
        switch code {
        case 90001: return message.hasPrefix("Entry") ? .entryInvalid : .forbiddenFileType
        case 90002: return .unknownConstruct
        case 90003: return .pathNotContained
        case 90004: return message.hasPrefix("Unknown hook or missing") ? .missingHandlerFunction : .unknownConstruct
        case 1000..<2000: return .malformedProgram
        case 2304, 2552, 2663, 2686: return .unknownVariable
        case 2503, 2694: return .unknownType
        case 2305, 2724: return .unknownReference
        case 2307: return .pathNotContained
        case 2339, 2551:
            return message.contains("on type 'typeof ") ? .unknownFunction : .unknownField
        case 2353, 2561: return .unknownField
        case 2554, 2555, 2556, 2557, 2575: return .argumentCount
        case 2531, 2532, 2533, 18047, 18048, 18049, 18050: return .optionalAccess
        case 2355, 2366, 7030: return .missingReturn
        case 2300, 2392, 2393, 2403, 2451, 2528: return .duplicateVariable
        case 2540, 2588: return .readOnlyVariable
        default: return .typeMismatch
        }
    }

    static func fix(for d: TSDiagnostic) -> String? {
        switch d.code {
        case 90001: return d.message.hasPrefix("Entry") ? "Point entry at an existing script with the right extension" : "Remove the file or rename it to .ts, .js or .mjs"
        case 90002: return "Remove the construct; scripts cannot use eval, Function, with, dynamic import, prototype access, require, globalThis or type-check suppression"
        case 90003: return "Import only files inside the package or the virtual 'betterfinder' module"
        case 90004: return "Export the handler under the name the manifest declares"
        case 2304: return "Import it from 'betterfinder' or declare it"
        default: return nil
        }
    }

    static func map(_ d: TSDiagnostic, context: TSMappingContext) -> ModDiagnostic? {
        let severity: ModSeverity
        switch d.category {
        case .error: severity = .error
        case .warning: severity = .warning
        case .suggestion, .message: return nil
        }
        let prefix = d.code >= 90000 ? "policy \(d.code): " : "TS\(d.code): "

        if d.file == hookCheckFile {
            let index = (d.line ?? 2) - 2
            if context.hookChecks.indices.contains(index) {
                let check = context.hookChecks[index]
                return ModDiagnostic(
                    .handlerHookMismatch, severity: severity, file: "manifest.json", pointer: "/hooks/\(check.manifestIndex)/handler",
                    message: "export '\(check.handler)' does not satisfy hook '\(check.hook)': \(prefix)\(d.message)",
                    fix: "Match the handler signature documented for \(check.hook)"
                )
            }
        }
        if d.code == 90004, d.message.hasPrefix("Unknown hook or missing handler export: ") {
            let tail = d.message.dropFirst("Unknown hook or missing handler export: ".count)
            let parts = tail.components(separatedBy: " -> ")
            if parts.count == 2, let i = context.manifestHooks.firstIndex(where: { ModCatalogAdapter.hookKey(name: $0.name, version: $0.version) == parts[0] && $0.handler == parts[1] }) {
                return ModDiagnostic(
                    .missingHandlerFunction, severity: severity, file: "manifest.json", pointer: "/hooks/\(i)/handler",
                    message: "script exports no '\(parts[1])' for hook '\(parts[0])'",
                    fix: "Export a function named '\(parts[1])' from \(context.entry)"
                )
            }
        }
        return ModDiagnostic(
            code(for: d), severity: severity, file: d.file, line: d.line, column: d.col,
            message: prefix + d.message, fix: fix(for: d)
        )
    }
}
