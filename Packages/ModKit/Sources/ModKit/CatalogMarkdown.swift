import Foundation

public extension ModCatalog {
    static func markdownReference() -> String { v1.markdownReference() }

    func markdownReference() -> String {
        var out = [String]()
        func line(_ s: String = "") { out.append(s) }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        func req(_ r: [GrantRequirement]) -> String { r.isEmpty ? "none" : r.map { "`\($0.summary)`" }.joined(separator: ", ") }

        line("# betterfinder mod API \(catalogVersion)")
        line()
        line("Generated from the ModKit catalog (digest `\(digest)`). Manifest version \(manifestVersion), script format \(scriptFormat), toolchain `\(toolchain)`.")
        line()
        line("## Limits")
        line()
        line("| Limit | Value |")
        line("|---|---|")
        let l = limits
        for (k, v) in [
            ("Manifest bytes", l.manifestBytes), ("Script bytes", l.scriptBytes), ("Callback watchdog (ms)", l.callbackWatchdogMs),
            ("Control message bytes", l.controlMessageBytes), ("Batch items", l.batchItems), ("Host RSS restart (MiB)", l.hostRSSRestartMiB),
            ("Max permissions", l.maxPermissions), ("Max contributions per kind", l.maxContributionsPerKind), ("Max hooks", l.maxHooks),
            ("Max settings", l.maxSettings), ("Max dependencies", l.maxDependencies), ("Max conflicts", l.maxConflicts),
            ("Max package bytes", l.maxPackageBytes), ("Max package files", l.maxPackageFiles),
            ("bfscript max functions", l.maxFunctions), ("bfscript max statements", l.maxStatements),
            ("bfscript max statement nesting", l.maxNesting), ("bfscript max expression depth", l.maxExprDepth),
            ("bfscript max loop bound", l.maxLoopBound), ("bfscript max total loop iterations", l.maxLoopIterations),
            ("bfscript max loop nesting", l.maxLoopNesting), ("bfscript max call depth", l.maxCallDepth),
        ] { line("| \(k) | \(v) |") }
        line()

        line("## Permissions")
        line()
        line("| Kind | Required fields | Optional fields | Meaning |")
        line("|---|---|---|---|")
        for p in permissions {
            line("| `\(p.kind.rawValue)` | \(p.required.map { "`\($0)`" }.joined(separator: ", ")) | \(p.optional.map { "`\($0)`" }.joined(separator: ", ")) | \(esc(p.summary)) |")
        }
        line()

        line("## Contributions")
        line()
        line("| Key | UI grant surface | Handler hook | Meaning |")
        line("|---|---|---|---|")
        for c in contributions {
            line("| `\(c.key)` | \(c.surface.map { "`\($0.rawValue)`" } ?? "none") | \(c.hook.map { "`\($0)`" } ?? "none") | \(esc(c.summary)) |")
        }
        line()

        line("## Hooks")
        line()
        line("All hooks are async `(context: HookContext, input) → result`.")
        line()
        line("| Signature | Input | Result | Requires | Deadline | Cancellable | Failure | Multiple |")
        line("|---|---|---|---|---|---|---|---|")
        for h in hooks {
            line("| `\(h.signatureID)` | `\(h.input)` | `\(h.output)` | \(req(h.requires)) | \(h.deadlineMs) ms | \(h.cancellable ? "yes" : "no") | \(h.failure.rawValue) | \(h.multiple ? "yes" : "no") |")
        }
        line()
        for h in hooks { line("- `\(h.signatureID)` — \(h.summary)") }
        line()
        line("### Failure policies")
        line()
        for policy in [ModFailurePolicy.reject, .pause, .ignore, .degrade] { line("- `\(policy.rawValue)` — \(policy.summary)") }
        line()

        line("## Bridge functions")
        line()
        line("Every call is async and must be awaited. 64-bit sizes are decimal strings.")
        for ns in namespaces {
            line()
            line("### `\(ns.name)`")
            line()
            line(ns.summary)
            line()
            line("| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |")
            line("|---|---|---|---|---|---|---|---|")
            for fnDef in functions(in: ns.name) {
                let params = fnDef.params.map { "\($0.name)\($0.optional ? "?" : ""): \($0.type)" }.joined(separator: ", ")
                var notes = ""
                if fnDef.gesture { notes += " (user gesture)" }
                if let b = fnDef.batchLimit { notes += " (batch ≤ \(b))" }
                line("| `\(fnDef.name)`\(notes) | `\(esc(params))` | `\(fnDef.returns)` | \(req(fnDef.requires)) | \(fnDef.deadlineMs) ms | \(fnDef.cancellable ? "yes" : "no") | \(fnDef.failure.rawValue) | \(fnDef.errors.isEmpty ? "" : fnDef.errors.map { "`\($0)`" }.joined(separator: ", ")) |")
            }
        }
        line()

        line("## Broker operations")
        line()
        for b in brokerOperations { line("- `\(b.name)` (`\(b.function)`) — \(b.summary)") }
        line()

        line("## Types")
        for t in types {
            line()
            line("### `\(t.name)`")
            line()
            line(t.doc)
            line()
            switch t.kind {
            case .alias: line("Alias of `\(t.aliasOf.map(\.description) ?? "?")`.")
            case .enum: line("One of: " + (t.cases ?? []).map { "`\($0)`" }.joined(separator: ", "))
            case .record:
                line("| Field | Type | Required | Notes |")
                line("|---|---|---|---|")
                for fld in t.fields ?? [] {
                    line("| `\(fld.name)` | `\(fld.type)` | \(fld.optional ? "no" : "yes") | \(esc(fld.doc)) |")
                }
            }
        }
        line()

        line("## Diagnostic codes")
        line()
        line("| Code | Severity | Meaning |")
        line("|---|---|---|")
        for d in diagnostics { line("| `\(d.code)` | \(d.severity.rawValue) | \(esc(d.title)) |") }
        line()
        return out.joined(separator: "\n")
    }
}
