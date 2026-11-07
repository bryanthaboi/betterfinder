import Foundation

public struct ScriptAnalysis: Equatable, Sendable {
    public var handlers: [String: String]
    public var catalogCalls: [String]
    public var literalRootIDs: [String]
    public var callsKnown: Bool

    public init(handlers: [String: String] = [:], catalogCalls: [String] = [], literalRootIDs: [String] = [], callsKnown: Bool = true) {
        self.handlers = handlers
        self.catalogCalls = catalogCalls
        self.literalRootIDs = literalRootIDs
        self.callsKnown = callsKnown
    }

    public static let unknown = ScriptAnalysis(callsKnown: false)
}

indirect enum BFType: Equatable {
    case string, integer, number, boolean, null, json, void, never
    case list(BFType)
    case optional(BFType)
    case record(String)
    case enumeration(String)
    case anon([String: BFType])

    var description: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .null: return "null"
        case .json: return "json"
        case .void: return "void"
        case .never: return "never"
        case .list(let t): return "\(t.parenthesized)[]"
        case .optional(let t): return "\(t)?"
        case .record(let n), .enumeration(let n): return n
        case .anon(let f): return "{" + f.keys.sorted().map { "\($0): \(f[$0]!)" }.joined(separator: ", ") + "}"
        }
    }

    private var parenthesized: String {
        if case .optional = self { return "(\(description))" }
        return description
    }

    var isNumeric: Bool { self == .integer || self == .number }
    var isStringLike: Bool { if case .enumeration = self { return true }; return self == .string }
    var containsNever: Bool {
        switch self {
        case .never: return true
        case .list(let t), .optional(let t): return t.containsNever
        default: return false
        }
    }
    var stripOptional: BFType { if case .optional(let t) = self { return t }; return self }
}

struct BFCheckOutput {
    var diagnostics: [ModDiagnostic]
    var analysis: ScriptAnalysis
    var types: [String: BFType]
}

final class BFChecker {
    struct VarInfo {
        var type: BFType
        var readOnly: Bool
    }

    let catalog: ModCatalog
    let file: String
    let program: BFProgram
    var diags: [ModDiagnostic] = []
    var types: [String: BFType] = [:]
    var helpers: [String: BFFunction] = [:]
    var callEdges: [String: Set<String>] = [:]
    var catalogCalls = Set<String>()
    var roots = Set<String>()
    var handlers: [String: String] = [:]

    var scopes: [[String: VarInfo]] = []
    var loopBounds: [Int] = []
    var returnType: BFType = .void
    var currentFunction = ""

    init(program: BFProgram, catalog: ModCatalog, file: String) {
        self.program = program
        self.catalog = catalog
        self.file = file
        for f in program.functions { if case .helper = f.signature { helpers[f.name] = f } }
    }

    func err(_ code: ModDiagnosticCode, _ ptr: String, _ message: String, fix: String? = nil) {
        diags.append(ModDiagnostic(code, file: file, pointer: ptr, message: message, fix: fix))
    }

    func run() -> BFCheckOutput {
        for f in program.functions { checkFunction(f) }
        checkCallGraph()
        return BFCheckOutput(
            diagnostics: diags,
            analysis: ScriptAnalysis(handlers: handlers, catalogCalls: catalogCalls.sorted(), literalRootIDs: roots.sorted(), callsKnown: true),
            types: types
        )
    }

    func convert(_ t: ModTypeExpr, _ ptr: String) -> BFType? {
        switch t {
        case .string: return .string
        case .integer: return .integer
        case .number: return .number
        case .boolean: return .boolean
        case .null: return .null
        case .void: return .void
        case .json: return .json
        case .list(let i): return convert(i, ptr).map { .list($0) }
        case .optional(let i): return convert(i, ptr).map { .optional($0) }
        case .ref(let name):
            guard let def = catalog.type(named: name) else {
                err(.unknownType, ptr, "unknown type '\(name)'")
                return nil
            }
            switch def.kind {
            case .alias: return def.aliasOf.flatMap { convert($0, ptr) }
            case .enum: return .enumeration(name)
            case .record: return .record(name)
            }
        }
    }

    func catalogType(_ t: ModTypeExpr) -> BFType {
        var sink = [ModDiagnostic]()
        swap(&sink, &diags)
        defer { swap(&sink, &diags) }
        return convert(t, "") ?? .json
    }

    func checkFunction(_ f: BFFunction) {
        currentFunction = f.name
        scopes = [[:]]
        loopBounds = []
        callEdges[f.name] = callEdges[f.name] ?? []
        switch f.signature {
        case .hook(let name, let version):
            guard let sig = catalog.hook(named: name, version: version) else {
                if catalog.hookNames.contains(name) {
                    err(.unsupportedSignatureVersion, f.pointer + "/signature", "hook '\(name)' has no version \(version); latest is \(catalog.latestHookVersions[name] ?? 0)")
                } else {
                    err(.unknownSignature, f.pointer + "/signature", "unknown hook '\(name)'", fix: "Known hooks: " + catalog.hookNames.joined(separator: ", "))
                }
                return
            }
            handlers[f.name] = sig.signatureID
            scopes[0]["context"] = VarInfo(type: .record("HookContext"), readOnly: true)
            scopes[0]["input"] = VarInfo(type: catalogType(sig.input), readOnly: true)
            returnType = catalogType(sig.output)
        case .helper(let params, let returns):
            scopes[0]["context"] = VarInfo(type: .record("HookContext"), readOnly: true)
            var seen = Set<String>()
            for (i, p) in params.enumerated() {
                let pp = f.pointer + "/signature/params/\(i)"
                if !seen.insert(p.name).inserted { err(.duplicateVariable, pp, "duplicate parameter '\(p.name)'"); continue }
                if let t = convert(p.type, pp + "/type") { scopes[0][p.name] = VarInfo(type: t, readOnly: true) }
            }
            returnType = convert(returns, f.pointer + "/signature/returns") ?? .json
            if returnType == .never { returnType = .json }
        }
        let terminates = checkBlock(f.body, newScope: false)
        if returnType != .void, !terminates {
            err(.missingReturn, f.pointer + "/body", "function '\(f.name)' does not return a \(returnType.description) on every path",
                fix: "End every path with a return (or fail)")
        }
    }

    func declare(_ name: String, _ info: VarInfo, _ ptr: String) {
        for s in scopes where s[name] != nil {
            err(.duplicateVariable, ptr, "'\(name)' is already declared; shadowing is not allowed")
            return
        }
        scopes[scopes.count - 1][name] = info
    }

    func lookup(_ name: String) -> VarInfo? {
        for s in scopes.reversed() { if let v = s[name] { return v } }
        return nil
    }

    func checkBlock(_ stmts: [BFStmt], newScope: Bool = true) -> Bool {
        if newScope { scopes.append([:]) }
        defer { if newScope { scopes.removeLast() } }
        var terminated = false
        for s in stmts {
            if checkStmt(s) { terminated = true }
        }
        return terminated
    }

    func checkAssign(_ from: BFType, to: BFType, ptr: String, what: String) {
        if assignable(from, to) { return }
        if case .optional(let inner) = from, assignable(inner, to) {
            err(.optionalAccess, ptr, "\(what): value may be null; expected \(to.description)", fix: "Wrap with {\"unwrap\": …} or {\"coalesce\": […, default]}")
            return
        }
        err(.typeMismatch, ptr, "\(what): expected \(to.description), got \(from.description)")
    }

    func assignable(_ from: BFType, _ to: BFType) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.void, _), (_, .void): return false
        case (_, .json): return true
        case (.never, _): return true
        case (.integer, .number): return true
        case (.null, .optional): return true
        case (.optional(let a), .optional(let b)): return assignable(a, b)
        case (_, .optional(let b)): return assignable(from, b)
        case (.list(let a), .list(let b)): return assignable(a, b)
        case (.enumeration, .string): return true
        case (.anon(let fields), .record(let name)):
            guard let def = catalog.type(named: name), let defFields = def.fields else { return false }
            for k in fields.keys where !defFields.contains(where: { $0.name == k }) { return false }
            for df in defFields {
                guard let ft = fields[df.name] else { if df.optional { continue }; return false }
                if !assignable(ft, optionalWrapped(df)) { return false }
            }
            return true
        default: return false
        }
    }

    func optionalWrapped(_ f: ModField) -> BFType {
        let t = catalogType(f.type)
        return f.optional ? .optional(t) : t
    }

    @discardableResult
    func checkStmt(_ s: BFStmt) -> Bool {
        switch s.kind {
        case .letBinding(let name, let declared, let value):
            var target: BFType?
            if let d = declared { target = convert(d, s.pointer + "/type") }
            guard let vt = infer(value, expected: target) else {
                if let target { declare(name, VarInfo(type: target, readOnly: false), s.pointer) }
                return false
            }
            var final = vt
            if let target {
                checkAssign(vt, to: target, ptr: value.pointer, what: "initializer of '\(name)'")
                final = target
            } else if vt.containsNever {
                err(.typeMismatch, value.pointer, "cannot infer the element type of an empty list for '\(name)'", fix: "Add \"type\": {\"list\": \"<Element>\"} to the let")
                final = .json
            } else if vt == .null {
                err(.typeMismatch, value.pointer, "cannot infer a type from null for '\(name)'", fix: "Add \"type\": {\"optional\": \"<Type>\"} to the let")
                final = .json
            } else if vt == .void {
                err(.typeMismatch, value.pointer, "'\(name)' would be bound to a void result")
                final = .json
            }
            declare(name, VarInfo(type: final, readOnly: false), s.pointer)
            return false
        case .set(let name, let value):
            guard let info = lookup(name) else {
                err(.unknownVariable, s.pointer + "/set", "unknown variable '\(name)'")
                _ = infer(value, expected: nil)
                return false
            }
            if info.readOnly { err(.readOnlyVariable, s.pointer + "/set", "'\(name)' is read-only") }
            if let vt = infer(value, expected: info.type) { checkAssign(vt, to: info.type, ptr: value.pointer, what: "assignment to '\(name)'") }
            return false
        case .append(let name, let value):
            guard let info = lookup(name) else {
                err(.unknownVariable, s.pointer + "/append", "unknown variable '\(name)'")
                _ = infer(value, expected: nil)
                return false
            }
            guard case .list(let elem) = info.type else {
                err(.notIterable, s.pointer + "/append", "'\(name)' is \(info.type.description), not a list")
                _ = infer(value, expected: nil)
                return false
            }
            if info.readOnly { err(.readOnlyVariable, s.pointer + "/append", "'\(name)' is read-only") }
            if let vt = infer(value, expected: elem) { checkAssign(vt, to: elem, ptr: value.pointer, what: "appended value") }
            return false
        case .ifElse(let cond, let thenB, let elseB):
            if let ct = infer(cond, expected: .boolean) { checkAssign(ct, to: .boolean, ptr: cond.pointer, what: "condition") }
            let t1 = checkBlock(thenB)
            guard let elseB else { return false }
            let t2 = checkBlock(elseB)
            return t1 && t2
        case .forEach(let item, let source, let bound, let body):
            if bound > catalog.limits.maxLoopBound {
                err(.loopBoundExceeded, s.pointer + "/max", "loop bound \(bound) exceeds the limit of \(catalog.limits.maxLoopBound)")
            }
            var elem: BFType = .json
            if let st = infer(source, expected: nil) {
                if case .list(let e) = st { elem = e == .never ? .json : e }
                else if case .json = st { elem = .json }
                else { err(.notIterable, source.pointer, "forEach needs a list, got \(st.description)") }
            }
            loopBounds.append(bound)
            if loopBounds.count > catalog.limits.maxLoopNesting {
                err(.scriptSizeLimit, s.pointer, "loops nested deeper than \(catalog.limits.maxLoopNesting)")
            }
            let product = loopBounds.reduce(1) { $0 > Int.max / max($1, 1) ? Int.max : $0 * $1 }
            if product > catalog.limits.maxLoopIterations {
                err(.loopBoundExceeded, s.pointer + "/max", "nested loop bounds multiply to \(product), above the limit of \(catalog.limits.maxLoopIterations)")
            }
            scopes.append([:])
            declare(item, VarInfo(type: elem, readOnly: true), s.pointer + "/forEach")
            _ = checkBlock(body, newScope: false)
            scopes.removeLast()
            loopBounds.removeLast()
            return false
        case .ret(let value):
            if returnType == .void {
                if case .literal(.null) = value.kind { types[value.pointer] = .null; return true }
                _ = infer(value, expected: nil)
                err(.typeMismatch, value.pointer, "this hook returns nothing; use {\"return\": null}")
                return true
            }
            if let vt = infer(value, expected: returnType) { checkAssign(vt, to: returnType, ptr: value.pointer, what: "return value") }
            return true
        case .doExpr(let value):
            if case .await = value.kind { _ = infer(value, expected: nil) }
            else if case .call = value.kind { _ = infer(value, expected: nil) }
            else if case .fn = value.kind { _ = infer(value, expected: nil) }
            else { err(.malformedProgram, value.pointer, "'do' requires an awaited call") }
            return false
        case .fail(let value):
            if let vt = infer(value, expected: .string) { checkAssign(vt, to: .string, ptr: value.pointer, what: "failure message") }
            return true
        case .checkCancelled:
            return false
        }
    }

    func infer(_ e: BFExpr, expected: BFType?) -> BFType? {
        guard let t = inferInner(e, expected) else { return nil }
        types[e.pointer] = t
        return t
    }

    func inferInner(_ e: BFExpr, _ expected: BFType?) -> BFType? {
        switch e.kind {
        case .literal(let v):
            switch v {
            case .string(let s):
                if let exp = expected?.stripOptional, case .enumeration(let name) = exp {
                    let cases = catalog.type(named: name)?.cases ?? []
                    if !cases.contains(s) {
                        err(.typeMismatch, e.pointer, "'\(s)' is not a member of \(name)", fix: "Allowed: " + cases.joined(separator: ", "))
                        return nil
                    }
                    return .enumeration(name)
                }
                return .string
            case .int: return .integer
            case .double: return .number
            case .bool: return .boolean
            case .null: return .null
            default: return nil
            }
        case .get(let path): return inferGet(path, e)
        case .record(let fields): return inferRecord(fields, e, expected)
        case .list(let items): return inferList(items, e, expected)
        case .call:
            err(.callNotAwaited, e.pointer, "catalog calls are async and must be wrapped in {\"await\": …}")
            return nil
        case .fn:
            err(.callNotAwaited, e.pointer, "helper calls are async and must be wrapped in {\"await\": …}")
            return nil
        case .await(let inner): return checkCall(inner)
        case .op(let name, let args): return inferOp(name, args, e, expected)
        }
    }

    func inferGet(_ path: [BFPathElement], _ e: BFExpr) -> BFType? {
        guard case .name(let root) = path[0] else { return nil }
        guard let info = lookup(root) else {
            err(.unknownVariable, e.pointer + "/get/0", "unknown variable '\(root)'")
            return nil
        }
        var t = info.type
        for (i, el) in path.enumerated().dropFirst() {
            let ep = JSONPointer.appending(e.pointer + "/get", i)
            if case .optional = t {
                err(.optionalAccess, ep, "cannot read into a value that may be null", fix: "Unwrap first with {\"unwrap\": …}")
                return nil
            }
            switch (el, t) {
            case (.name(let f), .record(let rn)):
                guard let def = catalog.type(named: rn)?.fields?.first(where: { $0.name == f }) else {
                    err(.unknownField, ep, "'\(rn)' has no field '\(f)'", fix: "Fields: " + (catalog.type(named: rn)?.fields ?? []).map(\.name).joined(separator: ", "))
                    return nil
                }
                let ft = catalogType(def.type)
                t = def.optional ? .optional(ft) : ft
            case (.name(let f), .anon(let fields)):
                guard let ft = fields[f] else { err(.unknownField, ep, "no field '\(f)'"); return nil }
                t = ft
            case (.name, .json), (.index, .json):
                t = .json
            case (.index, .list(let inner)):
                t = inner == .never ? .json : inner
            default:
                err(.typeMismatch, ep, "cannot read into \(t.description)")
                return nil
            }
        }
        return t
    }

    func inferRecord(_ fields: [String: BFExpr], _ e: BFExpr, _ expected: BFType?) -> BFType? {
        if let exp = expected?.stripOptional, case .record(let name) = exp, let defFields = catalog.type(named: name)?.fields {
            var ok = true
            for k in fields.keys.sorted() {
                let fe = fields[k]!
                guard let df = defFields.first(where: { $0.name == k }) else {
                    err(.unknownField, fe.pointer, "'\(name)' has no field '\(k)'", fix: "Fields: " + defFields.map(\.name).joined(separator: ", "))
                    ok = false
                    continue
                }
                let want = optionalWrapped(df)
                if let ft = infer(fe, expected: want) {
                    if !assignable(ft, want) { checkAssign(ft, to: want, ptr: fe.pointer, what: "field '\(k)'"); ok = false }
                } else { ok = false }
            }
            for df in defFields where !df.optional && fields[df.name] == nil {
                err(.typeMismatch, e.pointer, "missing required field '\(df.name)' of \(name)")
                ok = false
            }
            return ok ? .record(name) : nil
        }
        var out = [String: BFType]()
        var ok = true
        for k in fields.keys.sorted() {
            if let ft = infer(fields[k]!, expected: nil) { out[k] = ft } else { ok = false }
        }
        return ok ? .anon(out) : nil
    }

    func inferList(_ items: [BFExpr], _ e: BFExpr, _ expected: BFType?) -> BFType? {
        if let exp = expected?.stripOptional, case .list(let elem) = exp {
            var ok = true
            for it in items {
                if let t = infer(it, expected: elem) {
                    if !assignable(t, elem) { checkAssign(t, to: elem, ptr: it.pointer, what: "list element"); ok = false }
                } else { ok = false }
            }
            return ok ? .list(elem) : nil
        }
        if items.isEmpty { return .list(.never) }
        var elem: BFType?
        var ok = true
        for it in items {
            guard let t = infer(it, expected: elem) else { ok = false; continue }
            if let cur = elem {
                if assignable(t, cur) { continue }
                if assignable(cur, t) { elem = t; continue }
                err(.typeMismatch, it.pointer, "list elements must share a type: \(cur.description) vs \(t.description)")
                ok = false
            } else { elem = t }
        }
        return ok ? elem.map { .list($0) } : nil
    }

    func checkCall(_ inner: BFExpr) -> BFType? {
        switch inner.kind {
        case .call(let name, let args):
            guard let f = catalog.function(named: name) else {
                let sameNS = catalog.functions.filter { $0.namespace == name.split(separator: ".").first.map(String.init) ?? "" }.map(\.name)
                err(.unknownFunction, inner.pointer, "unknown catalog function '\(name)'",
                    fix: sameNS.isEmpty ? "Namespaces: " + catalog.namespaces.map(\.name).joined(separator: ", ") : "Available: " + sameNS.joined(separator: ", "))
                for a in args { _ = infer(a, expected: nil) }
                return nil
            }
            catalogCalls.insert(name)
            if name == "fs.root", case .literal(.string(let r))? = args.first?.kind { roots.insert(r) }
            let required = f.params.filter { !$0.optional }.count
            if args.count < required || args.count > f.params.count {
                err(.argumentCount, inner.pointer, "'\(name)' takes \(required == f.params.count ? "\(required)" : "\(required)–\(f.params.count)") argument(s), got \(args.count)",
                    fix: "Signature: \(name)(" + f.params.map { "\($0.name)\($0.optional ? "?" : ""): \($0.type)" }.joined(separator: ", ") + ")")
            }
            for (i, a) in args.enumerated() where i < f.params.count {
                let pt = catalogType(f.params[i].type)
                if let at = infer(a, expected: pt) { checkAssign(at, to: pt, ptr: a.pointer, what: "argument '\(f.params[i].name)' of \(name)") }
            }
            return catalogType(f.returns)
        case .fn(let name, let args):
            guard let h = helpers[name], case .helper(let params, let returns) = h.signature else {
                err(.unknownFunction, inner.pointer, "unknown helper function '\(name)'", fix: "Helpers: " + helpers.keys.sorted().joined(separator: ", "))
                for a in args { _ = infer(a, expected: nil) }
                return nil
            }
            callEdges[currentFunction, default: []].insert(name)
            if args.count != params.count {
                err(.argumentCount, inner.pointer, "'\(name)' takes \(params.count) argument(s), got \(args.count)")
            }
            for (i, a) in args.enumerated() where i < params.count {
                let pt = catalogType(params[i].type)
                if let at = infer(a, expected: pt) { checkAssign(at, to: pt, ptr: a.pointer, what: "argument '\(params[i].name)' of \(name)") }
            }
            return catalogType(returns)
        default:
            err(.callNotAwaited, inner.pointer, "'await' applies only to calls")
            return nil
        }
    }

    func inferOp(_ name: String, _ args: [BFExpr], _ e: BFExpr, _ expected: BFType?) -> BFType? {
        func bad(_ msg: String, _ ptr: String? = nil) -> BFType? { err(.typeMismatch, ptr ?? e.pointer, msg); return nil }
        func operands(_ expectedTypes: [BFType?]) -> [BFType]? {
            var out = [BFType]()
            var ok = true
            for (i, a) in args.enumerated() {
                if let t = infer(a, expected: i < expectedTypes.count ? expectedTypes[i] : expectedTypes.last ?? nil) { out.append(t) } else { ok = false }
            }
            return ok ? out : nil
        }
        switch name {
        case "eq", "ne":
            var order = [0, 1]
            if case .literal = args[0].kind, case .literal = args[1].kind {} else if case .literal = args[0].kind { order = [1, 0] }
            guard let first = infer(args[order[0]], expected: nil) else { _ = infer(args[order[1]], expected: nil); return nil }
            guard let second = infer(args[order[1]], expected: first) else { return nil }
            let comparable = (first.isNumeric && second.isNumeric) || (first == .boolean && second == .boolean) || (first.isStringLike && second.isStringLike)
            if !comparable { return bad("cannot compare \(first.description) with \(second.description); '\(name)' works on numbers, booleans and strings") }
            return .boolean
        case "lt", "le", "gt", "ge":
            guard let ts = operands([nil, nil]) else { return nil }
            let ok = (ts[0].isNumeric && ts[1].isNumeric) || (ts[0].isStringLike && ts[1].isStringLike)
            if !ok { return bad("'\(name)' needs two numbers or two strings, got \(ts[0].description) and \(ts[1].description)") }
            return .boolean
        case "and", "or":
            guard let ts = operands([.boolean]) else { return nil }
            for (i, t) in ts.enumerated() where t != .boolean { return bad("'\(name)' operand must be boolean, got \(t.description)", args[i].pointer) }
            return .boolean
        case "not":
            guard let ts = operands([.boolean]) else { return nil }
            if ts[0] != .boolean { return bad("'not' operand must be boolean, got \(ts[0].description)") }
            return .boolean
        case "add", "mul", "sub":
            guard let ts = operands([.number]) else { return nil }
            for (i, t) in ts.enumerated() where !t.isNumeric { return bad("'\(name)' operand must be a number, got \(t.description)", args[i].pointer) }
            return ts.allSatisfy { $0 == .integer } ? .integer : .number
        case "div":
            guard let ts = operands([.number]) else { return nil }
            for (i, t) in ts.enumerated() where !t.isNumeric { return bad("'div' operand must be a number, got \(t.description)", args[i].pointer) }
            return .number
        case "mod":
            guard let ts = operands([.integer]) else { return nil }
            for (i, t) in ts.enumerated() where t != .integer { return bad("'mod' operand must be an integer, got \(t.description)", args[i].pointer) }
            return .integer
        case "floor":
            guard let ts = operands([.number]) else { return nil }
            if !ts[0].isNumeric { return bad("'floor' operand must be a number, got \(ts[0].description)") }
            return .integer
        case "concat":
            guard let ts = operands([.string]) else { return nil }
            for (i, t) in ts.enumerated() where !t.isStringLike { return bad("'concat' operand must be a string, got \(t.description)", args[i].pointer) }
            return .string
        case "toString":
            guard let ts = operands([nil]) else { return nil }
            if !(ts[0].isNumeric || ts[0].isStringLike || ts[0] == .boolean) { return bad("'toString' needs a primitive, got \(ts[0].description)") }
            return .string
        case "length":
            guard let ts = operands([nil]) else { return nil }
            if ts[0].isStringLike { return .integer }
            if case .list = ts[0] { return .integer }
            return bad("'length' needs a string or list, got \(ts[0].description)")
        case "lower", "upper", "trim":
            guard let ts = operands([.string]) else { return nil }
            if !ts[0].isStringLike { return bad("'\(name)' needs a string, got \(ts[0].description)") }
            return .string
        case "startsWith", "endsWith":
            guard let ts = operands([.string]) else { return nil }
            for (i, t) in ts.enumerated() where !t.isStringLike { return bad("'\(name)' operand must be a string, got \(t.description)", args[i].pointer) }
            return .boolean
        case "contains":
            guard let first = infer(args[0], expected: nil) else { _ = infer(args[1], expected: nil); return nil }
            if first.isStringLike {
                guard let s = infer(args[1], expected: .string) else { return nil }
                if !s.isStringLike { return bad("'contains' needle must be a string, got \(s.description)", args[1].pointer) }
                return .boolean
            }
            if case .list(let elem) = first {
                guard let n = infer(args[1], expected: elem) else { return nil }
                if !(elem.isNumeric || elem.isStringLike || elem == .boolean) { return bad("'contains' on lists supports primitive elements only") }
                if !assignable(n, elem) { return bad("'contains' needle must be \(elem.description), got \(n.description)", args[1].pointer) }
                return .boolean
            }
            _ = infer(args[1], expected: nil)
            return bad("'contains' needs a string or list, got \(first.description)")
        case "split":
            guard let ts = operands([.string]) else { return nil }
            for (i, t) in ts.enumerated() where !t.isStringLike { return bad("'split' operand must be a string, got \(t.description)", args[i].pointer) }
            return .list(.string)
        case "join":
            guard let l = infer(args[0], expected: .list(.string)), let sep = infer(args[1], expected: .string) else { return nil }
            if l != .list(.string) && !(l == .list(.never)) { return bad("'join' needs a list of strings, got \(l.description)", args[0].pointer) }
            if !sep.isStringLike { return bad("'join' separator must be a string", args[1].pointer) }
            return .string
        case "substring":
            guard let ts = operands([.string, .integer, .integer]) else { return nil }
            if !ts[0].isStringLike || ts[1] != .integer || ts[2] != .integer { return bad("'substring' takes (string, integer, integer)") }
            return .string
        case "replace":
            guard let ts = operands([.string]) else { return nil }
            for (i, t) in ts.enumerated() where !t.isStringLike { return bad("'replace' operand must be a string, got \(t.description)", args[i].pointer) }
            return .string
        case "slice":
            guard let l = infer(args[0], expected: nil) else { _ = infer(args[1], expected: .integer); _ = infer(args[2], expected: .integer); return nil }
            guard case .list = l else { return bad("'slice' needs a list, got \(l.description)", args[0].pointer) }
            guard let a = infer(args[1], expected: .integer), let b = infer(args[2], expected: .integer) else { return nil }
            if a != .integer || b != .integer { return bad("'slice' bounds must be integers") }
            return l
        case "index":
            guard let l = infer(args[0], expected: nil) else { _ = infer(args[1], expected: .integer); return nil }
            guard let i = infer(args[1], expected: .integer) else { return nil }
            if i != .integer { return bad("'index' position must be an integer", args[1].pointer) }
            if case .list(let elem) = l { return elem == .never ? .json : elem }
            return bad("'index' needs a list, got \(l.description)", args[0].pointer)
        case "coalesce":
            guard let o = infer(args[0], expected: nil) else { _ = infer(args[1], expected: nil); return nil }
            guard case .optional(let inner) = o else { _ = infer(args[1], expected: nil); return bad("'coalesce' needs an optional first operand, got \(o.description)", args[0].pointer) }
            guard let d = infer(args[1], expected: inner) else { return nil }
            checkAssign(d, to: inner, ptr: args[1].pointer, what: "coalesce default")
            return inner
        case "isNull":
            guard let t = infer(args[0], expected: nil) else { return nil }
            if case .optional = t { return .boolean }
            if t == .json { return .boolean }
            return bad("'isNull' needs an optional value, got \(t.description)")
        case "unwrap":
            guard let t = infer(args[0], expected: nil) else { return nil }
            guard case .optional(let inner) = t else { return bad("'unwrap' needs an optional value, got \(t.description)") }
            return inner
        case "cond":
            guard let c = infer(args[0], expected: .boolean) else { _ = infer(args[1], expected: expected); _ = infer(args[2], expected: expected); return nil }
            if c != .boolean { return bad("'cond' condition must be boolean", args[0].pointer) }
            guard let a = infer(args[1], expected: expected), let b = infer(args[2], expected: expected) else { return nil }
            if assignable(a, b) { return b }
            if assignable(b, a) { return a }
            return bad("'cond' branches have different types: \(a.description) vs \(b.description)")
        default:
            return bad("unknown operator '\(name)'")
        }
    }

    func checkCallGraph() {
        var state = [String: Int]()
        var reported = Set<String>()
        var longest = [String: Int]()
        func visit(_ n: String, _ stack: [String]) -> Int {
            if state[n] == 2 { return longest[n] ?? 0 }
            if state[n] == 1 {
                if let f = helpers[n], reported.insert(n).inserted {
                    let cycle = (stack.drop(while: { $0 != n }) + [n]).joined(separator: " → ")
                    err(.recursion, f.pointer, "recursive call chain: \(cycle)", fix: "Recursion is not allowed; use forEach with a bound")
                }
                return 0
            }
            state[n] = 1
            var depth = 0
            for callee in (callEdges[n] ?? []).sorted() { depth = max(depth, 1 + visit(callee, stack + [n])) }
            state[n] = 2
            longest[n] = depth
            return depth
        }
        for f in program.functions {
            let d = visit(f.name, [])
            if d > catalog.limits.maxCallDepth {
                err(.callDepthExceeded, f.pointer, "'\(f.name)' has a helper call chain of depth \(d); limit is \(catalog.limits.maxCallDepth)")
            }
        }
    }
}
