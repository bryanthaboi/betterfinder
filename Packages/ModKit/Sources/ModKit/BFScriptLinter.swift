import Foundation

public enum BFScriptLinter {
    public static func lint(program: BFProgram, file: String) -> [ModDiagnostic] {
        var diags = [ModDiagnostic]()
        var calledHelpers = Set<String>()
        for f in program.functions {
            var reads = Set<String>()
            var lets = [(String, String)]()
            walk(f.body, reads: &reads, lets: &lets, helpers: &calledHelpers, file: file, diags: &diags)
            for (name, ptr) in lets where !reads.contains(name) {
                diags.append(ModDiagnostic(.unusedVariable, file: file, pointer: ptr, message: "variable '\(name)' is never read", fix: "Remove it or use its value"))
            }
        }
        for f in program.functions {
            if case .helper = f.signature, !calledHelpers.contains(f.name) {
                diags.append(ModDiagnostic(.unusedFunction, file: file, pointer: f.pointer, message: "helper '\(f.name)' is never called", fix: "Remove it"))
            }
        }
        return diags
    }

    static func terminates(_ block: [BFStmt]) -> Bool {
        for s in block {
            switch s.kind {
            case .ret, .fail: return true
            case .ifElse(_, let t, let e):
                if let e, terminates(t), terminates(e) { return true }
            default: break
            }
        }
        return false
    }

    private static func walk(_ block: [BFStmt], reads: inout Set<String>, lets: inout [(String, String)], helpers: inout Set<String>, file: String, diags: inout [ModDiagnostic]) {
        var dead = false
        var warned = false
        for s in block {
            if dead, !warned {
                diags.append(ModDiagnostic(.unreachableCode, file: file, pointer: s.pointer, message: "statement can never run", fix: "Remove it or move it before the return/fail"))
                warned = true
            }
            switch s.kind {
            case .letBinding(let name, _, let v):
                lets.append((name, s.pointer))
                scan(v, &reads, &helpers)
            case .set(_, let v), .append(_, let v), .doExpr(let v), .fail(let v), .ret(let v):
                scan(v, &reads, &helpers)
            case .ifElse(let c, let t, let e):
                scan(c, &reads, &helpers)
                walk(t, reads: &reads, lets: &lets, helpers: &helpers, file: file, diags: &diags)
                if let e { walk(e, reads: &reads, lets: &lets, helpers: &helpers, file: file, diags: &diags) }
            case .forEach(_, let src, let max, let body):
                scan(src, &reads, &helpers)
                let hasCheck = body.contains { if case .checkCancelled = $0.kind { return true }; return false }
                if !hasCheck, max > 1 {
                    diags.append(ModDiagnostic(.missingCancellationCheck, file: file, pointer: s.pointer, message: "loop body never checks for cancellation", fix: "Add {\"checkCancelled\": true} to the body"))
                }
                walk(body, reads: &reads, lets: &lets, helpers: &helpers, file: file, diags: &diags)
            case .checkCancelled: break
            }
            switch s.kind {
            case .ret, .fail: dead = true
            case .ifElse(_, let t, let e): if let e, terminates(t), terminates(e) { dead = true }
            default: break
            }
        }
    }

    private static func scan(_ e: BFExpr, _ reads: inout Set<String>, _ helpers: inout Set<String>) {
        switch e.kind {
        case .literal: break
        case .get(let path): if case .name(let n) = path[0] { reads.insert(n) }
        case .record(let f): for v in f.values { scan(v, &reads, &helpers) }
        case .list(let items): for v in items { scan(v, &reads, &helpers) }
        case .call(_, let args): for a in args { scan(a, &reads, &helpers) }
        case .fn(let n, let args): helpers.insert(n); for a in args { scan(a, &reads, &helpers) }
        case .await(let inner): scan(inner, &reads, &helpers)
        case .op(_, let args): for a in args { scan(a, &reads, &helpers) }
        }
    }
}
