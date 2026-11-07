import Foundation
import ModKit
import ModScriptTS

public struct DocPage: Equatable, Sendable {
    public var name: String
    public var contents: String
}

public enum ModDocsGenerator {
    public static let pageNames = [
        "Home.md", "Getting-Started-bfscript.md", "Getting-Started-TypeScript.md", "Getting-Started-JavaScript.md",
        "Reference-API.md", "Reference-Manifest.md", "Reference-Diagnostics.md", "Reference-CLI.md", "betterfinder.d.ts",
    ]

    public static func pages(catalog: ModCatalog = .v1) -> [DocPage] {
        [
            DocPage(name: "Home.md", contents: home(catalog)),
            DocPage(name: "Getting-Started-bfscript.md", contents: gettingStarted(.bfscript)),
            DocPage(name: "Getting-Started-TypeScript.md", contents: gettingStarted(.ts)),
            DocPage(name: "Getting-Started-JavaScript.md", contents: gettingStarted(.js)),
            DocPage(name: "Reference-API.md", contents: catalog.markdownReference()),
            DocPage(name: "Reference-Manifest.md", contents: manifestReference(catalog)),
            DocPage(name: "Reference-Diagnostics.md", contents: diagnosticsReference(catalog)),
            DocPage(name: "Reference-CLI.md", contents: "# betterfinder-mod CLI\n\n```text\n" + ModCLI.usage + "```\n"),
            DocPage(name: "betterfinder.d.ts", contents: ModCatalogAdapter.declarations(from: catalog)),
        ]
    }

    @discardableResult
    public static func write(to directory: URL, catalog: ModCatalog = .v1) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = [String]()
        for page in pages(catalog: catalog) {
            try Data(page.contents.utf8).write(to: directory.appendingPathComponent(page.name), options: .atomic)
            written.append(page.name)
        }
        return written
    }

    static func home(_ catalog: ModCatalog) -> String {
        """
        # betterfinder mods

        API \(catalog.catalogVersion), manifest version \(catalog.manifestVersion), script format \(catalog.scriptFormat).

        A mod is a folder (or a `.bfmod` archive) with a root `manifest.json`, declarative contributions and, unless it is data-only, one script. Three script languages share the same runtime, grants and validator:

        - [typed JSON (`bfscript`)](Getting-Started-bfscript) — the default for generated mods
        - [TypeScript](Getting-Started-TypeScript)
        - [JavaScript](Getting-Started-JavaScript)

        ## Reference

        - [API catalog](Reference-API) — namespaces, hooks, types, limits, permissions
        - [Manifest fields](Reference-Manifest)
        - [Diagnostic codes](Reference-Diagnostics)
        - [CLI](Reference-CLI)
        - `betterfinder.d.ts` — editor declarations for the virtual `betterfinder` module

        ## Workflow

        ```sh
        betterfinder-mod scaffold alice.my-mod --language bfscript --template column
        betterfinder-mod validate alice.my-mod
        betterfinder-mod package alice.my-mod --out alice.my-mod.bfmod
        ```

        `validate` is the single preflight used by the CLI, Settings, MCP and index CI. Any error, skipped required check, crash or timeout refuses enablement; warnings stay visible.

        """
    }

    static func gettingStarted(_ language: ScaffoldLanguage) -> String {
        let title: String, entry: String, body: String
        switch language {
        case .bfscript:
            title = "Getting started with typed JSON (bfscript)"
            entry = "scripts/main.bfscript.json"
            body = """
            A bfscript file is a closed JSON grammar: typed records and lists, locals, conditionals, bounded `forEach` loops, and awaited catalog calls. There is no dynamic code, import or prototype access. Every expression is type-checked against the catalog, and the linter flags unreachable code, unused variables and missing cancellation checks.

            ```json
            {"format": 1, "functions": {"columnValues": {
              "signature": "column.values@1",
              "body": [{"return": {"await": {"call": "media.imageDimensions", "args": [{"get": ["input", "items"]}]}}}]
            }}}
            ```

            Each function names the hook signature it implements (`name@version`); the manifest binds it with a `hooks` entry whose `handler` is the function name.
            """
        case .ts:
            title = "Getting started with TypeScript"
            entry = "scripts/main.ts"
            body = """
            Scripts are checked by a pinned, vendored TypeScript compiler running offline under `strict`, `noImplicitAny` and `isolatedModules`. Every compiler diagnostic blocks enablement; there is no emit-anyway. Import only package files or the virtual `betterfinder` module, whose declarations are in `betterfinder.d.ts`.

            ```ts
            import { media } from "betterfinder";
            import type { ColumnValuesHandler } from "betterfinder";

            export const columnValues: ColumnValuesHandler = async (context, input) => {
              return await media.imageDimensions(input.items);
            };
            ```

            Use catalog functions as `namespace.function(...)` so the validator can compare them with your declared permissions. `eval`, `Function`, `with`, `require`, dynamic `import()`, `globalThis`, prototype tampering, top-level `await` and `@ts-ignore` are rejected.
            """
        case .js:
            title = "Getting started with JavaScript"
            entry = "scripts/main.js"
            body = """
            JavaScript is checked with the same TypeScript toolchain and strictness as TypeScript, whether or not the file has `@ts-check`. Annotate handlers with JSDoc so parameters are typed:

            ```js
            import { media } from "betterfinder";

            /** @type {import("betterfinder").ColumnValuesHandler} */
            export const columnValues = async (context, input) => {
              return await media.imageDimensions(input.items);
            };
            ```

            The same import, construct and permission rules as TypeScript apply.
            """
        }
        return """
        # \(title)

        ## 1. Scaffold

        ```sh
        betterfinder-mod scaffold alice.my-mod --language \(language.rawValue) --template column
        cd alice.my-mod
        ```

        Templates: \(ScaffoldTemplate.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")). `sidebar` and `theme` are data-only and need no script.

        ## 2. Write the script

        The entry for this language is `\(entry)`.

        \(body)

        ## 3. Validate

        ```sh
        betterfinder-mod validate . --json
        ```

        Output lists `file:line:col`, a stable `BF####` code and a suggested fix for every finding. The exit status is non-zero when any error is reported.

        ## 4. Package

        ```sh
        betterfinder-mod package . --out alice.my-mod.bfmod
        ```

        The archive is reproducible: sorted entries, fixed timestamps, no compression. Editor files (`betterfinder.d.ts`, `tsconfig.json`), VCS metadata and `node_modules` are left out.

        """
    }

    static func describe(_ node: JSONValue, defs: [String: JSONValue]) -> String {
        guard let o = node.objectValue else { return node.boolValue == false ? "forbidden" : "any" }
        if let ref = o["$ref"]?.stringValue { return "`\(ref.split(separator: "/").last.map(String.init) ?? ref)`" }
        var parts = [String]()
        if let c = o["const"] { parts.append("const `\(c.canonicalString())`") }
        if let e = o["enum"]?.arrayValue { parts.append(e.map { "`\($0.canonicalString().replacingOccurrences(of: "\"", with: ""))`" }.joined(separator: " \\| ")) }
        if o["enum"] == nil, let t = o["type"]?.stringValue {
            if t == "array", let items = o["items"] {
                var s = "array of \(describe(items, defs: defs))"
                if let m = o["maxItems"]?.intValue { s += " (max \(m))" }
                if o["uniqueItems"]?.boolValue == true { s += " (unique)" }
                parts.append(s)
            } else if t != "object" { parts.append(t) } else { parts.append("object") }
        }
        if let p = o["pattern"]?.stringValue { parts.append("pattern `\(p.replacingOccurrences(of: "|", with: "\\|"))`") }
        if let m = o["minLength"]?.intValue { parts.append("min length \(m)") }
        if let m = o["maxLength"]?.intValue { parts.append("max length \(m)") }
        if let m = o["minimum"]?.numberValue { parts.append("min \(trim(m))") }
        if let m = o["maximum"]?.numberValue { parts.append("max \(trim(m))") }
        if let one = o["oneOf"]?.arrayValue ?? o["anyOf"]?.arrayValue { parts.append(one.map { describe($0, defs: defs) }.joined(separator: " or ")) }
        return parts.isEmpty ? "any" : parts.joined(separator: ", ")
    }

    static func trim(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    static func table(_ node: JSONValue, defs: [String: JSONValue]) -> [String] {
        guard let o = node.objectValue, let props = o["properties"]?.objectValue else { return [] }
        let required = Set((o["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        var rows = ["| Field | Type | Required |", "|---|---|---|"]
        for key in props.keys.sorted() {
            rows.append("| `\(key)` | \(describe(props[key]!, defs: defs)) | \(required.contains(key) ? "yes" : "no") |")
        }
        return rows
    }

    static func manifestReference(_ catalog: ModCatalog) -> String {
        let root = JSONSchema.manifest.root
        let defs = root["$defs"]?.objectValue ?? [:]
        var out = ["# Manifest reference", ""]
        out.append("Generated from the manifest JSON Schema (`\(root["$id"]?.stringValue ?? "manifest")`). Objects are closed: unknown keys are errors. `entry` is required for every runtime except `data/1`, where it is forbidden.")
        out.append("")
        out.append("## Manifest")
        out.append("")
        out += table(root, defs: defs)
        out.append("")
        out.append("## Runtimes")
        out.append("")
        out.append("| Runtime | Entry extension | Language |")
        out.append("|---|---|---|")
        for r in ModRuntime.allCases {
            let language: String
            switch r {
            case .data: language = "none (declarative only)"
            case .jscIR: language = "typed JSON (bfscript)"
            case .js: language = "JavaScript"
            case .ts: language = "TypeScript"
            }
            out.append("| `\(r.rawValue)` | \(r.allowedEntryExtensions.isEmpty ? "none" : r.allowedEntryExtensions.map { "`\($0)`" }.joined(separator: ", ")) | \(language) |")
        }
        out.append("")
        let order = defs.keys.sorted()
        out.append("## Definitions")
        for name in order {
            let node = defs[name]!
            out.append("")
            out.append("### `\(name)`")
            out.append("")
            let rows = table(node, defs: defs)
            if rows.isEmpty { out.append(describe(node, defs: defs)) }
            else { out += rows }
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    static func diagnosticsReference(_ catalog: ModCatalog) -> String {
        var out = ["# Diagnostic codes", ""]
        out.append("Every diagnostic carries a stable `BF####` code, a severity, a package-relative file, optional `line:column` or JSON pointer, a message and usually a fix. Any `error` blocks enablement.")
        out.append("")
        out.append("| Code | Severity | Meaning |")
        out.append("|---|---|---|")
        for d in catalog.diagnostics { out.append("| `\(d.code)` | \(d.severity.rawValue) | \(d.title.replacingOccurrences(of: "|", with: "\\|")) |") }
        out.append("")
        out.append("## TypeScript and JavaScript mapping")
        out.append("")
        out.append("TypeScript compiler errors are reported with the nearest catalog code and the compiler's own number at the start of the message (`TS2322: ...`). Script policy violations use `policy 9000x`.")
        out.append("")
        out.append("| Compiler code | Reported as | Typical cause |")
        out.append("|---|---|---|")
        let samples: [(Int, String, String)] = [
            (1005, "';' expected.", "syntax error"),
            (2304, "Cannot find name 'x'.", "unknown identifier"),
            (2305, "Module has no exported member.", "unknown import from betterfinder"),
            (2322, "Type 'string' is not assignable to type 'number'.", "wrong value type"),
            (2339, "Property 'x' does not exist on type 'typeof fs'.", "unknown catalog function"),
            (2339, "Property 'x' does not exist on type 'FileRef'.", "unknown record field"),
            (2345, "Argument of type is not assignable to parameter of type.", "wrong argument type"),
            (2554, "Expected 2 arguments, but got 1.", "wrong argument count"),
            (2366, "Function lacks ending return statement.", "missing return"),
            (18048, "'x' is possibly 'undefined'.", "optional value used without a check"),
            (2540, "Cannot assign to 'x' because it is a constant.", "assignment to const"),
            (90001, "Invalid package source path", "invalid script file name"),
            (90002, "Forbidden identifier: eval", "forbidden construct"),
            (90003, "Import must resolve inside the package or to betterfinder", "escaping or bare import"),
            (90004, "Unknown hook or missing handler export: x -> y", "missing handler export"),
        ]
        for (code, message, cause) in samples {
            let mapped = TSDiagnosticMapper.code(forCode: code, message: message)
            out.append("| \(code >= 90000 ? "policy \(code)" : "TS\(code)") | `\(mapped.rawValue)` \(mapped.title) | \(cause) |")
        }
        out.append("")
        out.append("Everything else reports as `\(ModDiagnosticCode.typeMismatch.rawValue)`. Catalog use the validator cannot follow (a namespace passed around as a value or accessed with a computed key) is `\(ModDiagnosticCode.unknownConstruct.rawValue)` because grants could not be checked.")
        out.append("")
        return out.joined(separator: "\n")
    }
}
