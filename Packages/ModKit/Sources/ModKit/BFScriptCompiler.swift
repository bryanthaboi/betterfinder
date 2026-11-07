import Foundation

enum BFScriptCompiler {
    static func compile(program: BFProgram, types: [String: BFType]) -> String {
        var c = Emitter(types: types)
        c.lines.append("\"use strict\";")
        for f in program.functions {
            c.lines.append("")
            c.emitFunction(f)
        }
        return c.lines.joined(separator: "\n") + "\n"
    }

    struct Emitter {
        let types: [String: BFType]
        var lines: [String] = []
        var loopCounter = 0

        init(types: [String: BFType]) { self.types = types }

        mutating func emitFunction(_ f: BFFunction) {
            loopCounter = 0
            switch f.signature {
            case .hook:
                lines.append("export async function \(f.name)(context, input) {")
            case .helper(let params, _):
                let ps = (["context"] + params.map { "v_\($0.name)" }).joined(separator: ", ")
                lines.append("async function fn_\(f.name)(\(ps)) {")
            }
            emitBlock(f.body, indent: 1)
            lines.append("}")
        }

        mutating func emitBlock(_ block: [BFStmt], indent: Int) {
            for s in block { emitStmt(s, indent: indent) }
        }

        func pad(_ n: Int) -> String { String(repeating: "  ", count: n) }

        func needsCopy(_ e: BFExpr) -> Bool {
            if case .list = e.kind { return false }
            if case .list? = types[e.pointer] { return true }
            return false
        }

        mutating func emitStmt(_ s: BFStmt, indent: Int) {
            let p = pad(indent)
            switch s.kind {
            case .letBinding(let name, _, let v):
                let x = expr(v)
                lines.append("\(p)let v_\(name) = \(needsCopy(v) ? "Array.from(\(x))" : x);")
            case .set(let name, let v):
                let x = expr(v)
                lines.append("\(p)v_\(name) = \(needsCopy(v) ? "Array.from(\(x))" : x);")
            case .append(let name, let v):
                lines.append("\(p)v_\(name).push(\(expr(v)));")
            case .ifElse(let c, let t, let e):
                lines.append("\(p)if (\(expr(c))) {")
                emitBlock(t, indent: indent + 1)
                if let e {
                    lines.append("\(p)} else {")
                    emitBlock(e, indent: indent + 1)
                }
                lines.append("\(p)}")
            case .forEach(let item, let src, let max, let body):
                loopCounter += 1
                let l = "l_\(loopCounter)"
                lines.append("\(p){")
                lines.append("\(p)  const \(l) = \(expr(src));")
                lines.append("\(p)  __bf.loop(\(l), \(max));")
                lines.append("\(p)  for (const v_\(item) of \(l)) {")
                emitBlock(body, indent: indent + 2)
                lines.append("\(p)  }")
                lines.append("\(p)}")
            case .ret(let v):
                if case .literal(.null) = v.kind { lines.append("\(p)return null;") }
                else { lines.append("\(p)return \(expr(v));") }
            case .doExpr(let v):
                lines.append("\(p)\(expr(v));")
            case .fail(let v):
                lines.append("\(p)throw __bf.fail(\(expr(v)));")
            case .checkCancelled:
                lines.append("\(p)__bf.checkCancelled(context);")
            }
        }

        func literal(_ v: JSONValue) -> String {
            switch v {
            case .int(let i): return i < 0 ? "(\(i))" : String(i)
            case .double(let d): return d < 0 ? "(\(JSONValue.double(d).canonicalString()))" : JSONValue.double(d).canonicalString()
            default: return v.canonicalString()
            }
        }

        func expr(_ e: BFExpr) -> String {
            switch e.kind {
            case .literal(let v): return literal(v)
            case .get(let path):
                var cur = ""
                for (i, el) in path.enumerated() {
                    switch el {
                    case .name(let n):
                        if i == 0 { cur = (n == "context" || n == "input") ? n : "v_\(n)" } else { cur += ".\(n)" }
                    case .index(let n):
                        cur = "__bf.index(\(cur), \(n))"
                    }
                }
                return cur
            case .record(let f):
                if f.isEmpty { return "{}" }
                return "{ " + f.keys.sorted().map { "\(JSONValue.string($0).canonicalString()): \(expr(f[$0]!))" }.joined(separator: ", ") + " }"
            case .list(let items):
                return "[" + items.map(expr).joined(separator: ", ") + "]"
            case .call(let name, let args):
                return "(await __bf.call(\(JSONValue.string(name).canonicalString()), [\(args.map(expr).joined(separator: ", "))], context))"
            case .fn(let name, let args):
                return "(await fn_\(name)(\((["context"] + args.map(expr)).joined(separator: ", "))))"
            case .await(let inner): return expr(inner)
            case .op(let name, let args): return op(name, args, e)
            }
        }

        func op(_ name: String, _ args: [BFExpr], _ e: BFExpr) -> String {
            let a = args.map(expr)
            let isInt = types[e.pointer] == .integer
            switch name {
            case "add": return isInt ? "__bf.i(\(a.joined(separator: " + ")))" : "(\(a.joined(separator: " + ")))"
            case "mul": return isInt ? "__bf.i(\(a.joined(separator: " * ")))" : "(\(a.joined(separator: " * ")))"
            case "sub": return isInt ? "__bf.i(\(a[0]) - \(a[1]))" : "(\(a[0]) - \(a[1]))"
            case "div": return "__bf.div(\(a[0]), \(a[1]))"
            case "mod": return "__bf.mod(\(a[0]), \(a[1]))"
            case "floor": return "__bf.i(Math.floor(\(a[0])))"
            case "eq": return "(\(a[0]) === \(a[1]))"
            case "ne": return "(\(a[0]) !== \(a[1]))"
            case "lt": return "(\(a[0]) < \(a[1]))"
            case "le": return "(\(a[0]) <= \(a[1]))"
            case "gt": return "(\(a[0]) > \(a[1]))"
            case "ge": return "(\(a[0]) >= \(a[1]))"
            case "and": return "(\(a.joined(separator: " && ")))"
            case "or": return "(\(a.joined(separator: " || ")))"
            case "not": return "(!\(a[0]))"
            case "concat": return "(\(a.joined(separator: " + ")))"
            case "toString": return "String(\(a[0]))"
            case "length": return "(\(a[0])).length"
            case "lower": return "(\(a[0])).toLowerCase()"
            case "upper": return "(\(a[0])).toUpperCase()"
            case "trim": return "(\(a[0])).trim()"
            case "contains": return "(\(a[0])).includes(\(a[1]))"
            case "startsWith": return "(\(a[0])).startsWith(\(a[1]))"
            case "endsWith": return "(\(a[0])).endsWith(\(a[1]))"
            case "split": return "(\(a[0])).split(\(a[1]))"
            case "join": return "(\(a[0])).join(\(a[1]))"
            case "substring": return "__bf.substring(\(a[0]), \(a[1]), \(a[2]))"
            case "replace": return "__bf.replace(\(a[0]), \(a[1]), \(a[2]))"
            case "slice": return "(\(a[0])).slice(\(a[1]), \(a[2]))"
            case "index": return "__bf.index(\(a[0]), \(a[1]))"
            case "coalesce": return "(\(a[0]) ?? \(a[1]))"
            case "isNull": return "(\(a[0]) == null)"
            case "unwrap": return "__bf.unwrap(\(a[0]))"
            case "cond": return "(\(a[0]) ? \(a[1]) : \(a[2]))"
            default: return "undefined"
            }
        }
    }
}

public struct BFScriptReport: Sendable {
    public var program: BFProgram?
    public var diagnostics: [ModDiagnostic]
    public var analysis: ScriptAnalysis
    public var compiledJS: String?

    public var ok: Bool { !diagnostics.hasErrors && compiledJS != nil }
}

public enum BFScript {
    public static func process(data: Data, file: String, catalog: ModCatalog = .v1) -> BFScriptReport {
        let parsed = BFScriptParser.parse(data: data, file: file, limits: catalog.limits)
        guard let program = parsed.program else {
            return BFScriptReport(program: nil, diagnostics: parsed.diagnostics, analysis: ScriptAnalysis(callsKnown: false), compiledJS: nil)
        }
        var diags = parsed.diagnostics
        if let value = try? JSONValue.parse(data) {
            for v in JSONSchema.bfscript.validate(value, limit: 5) {
                diags.append(ModDiagnostic(.internalMismatch, file: file, pointer: v.pointer, message: "parser accepted a script the JSON Schema rejects: \(v.message)"))
            }
        }
        let checked = BFChecker(program: program, catalog: catalog, file: file).run()
        diags += checked.diagnostics
        diags += BFScriptLinter.lint(program: program, file: file)
        var js: String?
        if !diags.hasErrors { js = BFScriptCompiler.compile(program: program, types: checked.types) }
        return BFScriptReport(program: program, diagnostics: diags, analysis: checked.analysis, compiledJS: js)
    }

    public static func process(text: String, file: String = "script.bfscript.json", catalog: ModCatalog = .v1) -> BFScriptReport {
        process(data: Data(text.utf8), file: file, catalog: catalog)
    }
}
