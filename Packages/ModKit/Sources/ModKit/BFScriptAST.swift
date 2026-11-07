import Foundation

public enum BFSignature: Equatable, Sendable {
    case hook(name: String, version: Int)
    case helper(params: [BFParam], returns: ModTypeExpr)
}

public struct BFParam: Equatable, Sendable {
    public var name: String
    public var type: ModTypeExpr
}

public enum BFPathElement: Equatable, Sendable {
    case name(String)
    case index(Int)
}

public indirect enum BFExprKind: Equatable, Sendable {
    case literal(JSONValue)
    case get([BFPathElement])
    case record([String: BFExpr])
    case list([BFExpr])
    case call(name: String, args: [BFExpr])
    case fn(name: String, args: [BFExpr])
    case await(BFExpr)
    case op(String, [BFExpr])
}

public struct BFExpr: Equatable, Sendable {
    public var kind: BFExprKind
    public var pointer: String
}

public indirect enum BFStmtKind: Equatable, Sendable {
    case letBinding(name: String, type: ModTypeExpr?, value: BFExpr)
    case set(name: String, value: BFExpr)
    case append(name: String, value: BFExpr)
    case ifElse(condition: BFExpr, then: [BFStmt], else: [BFStmt]?)
    case forEach(item: String, in: BFExpr, max: Int, body: [BFStmt])
    case ret(BFExpr)
    case doExpr(BFExpr)
    case fail(BFExpr)
    case checkCancelled
}

public struct BFStmt: Equatable, Sendable {
    public var kind: BFStmtKind
    public var pointer: String
}

public struct BFFunction: Equatable, Sendable {
    public var name: String
    public var signature: BFSignature
    public var body: [BFStmt]
    public var pointer: String
}

public struct BFProgram: Equatable, Sendable {
    public var functions: [BFFunction]

    public func function(named n: String) -> BFFunction? { functions.first { $0.name == n } }
}

public enum BFOpArity: Equatable, Sendable {
    case unary
    case fixed(Int)
    case atLeast(Int)
}

public enum BFLanguage {
    public static let ops: [String: BFOpArity] = [
        "not": .unary, "length": .unary, "lower": .unary, "upper": .unary, "trim": .unary, "toString": .unary,
        "isNull": .unary, "floor": .unary, "unwrap": .unary,
        "eq": .fixed(2), "ne": .fixed(2), "lt": .fixed(2), "le": .fixed(2), "gt": .fixed(2), "ge": .fixed(2),
        "sub": .fixed(2), "div": .fixed(2), "mod": .fixed(2), "startsWith": .fixed(2), "endsWith": .fixed(2),
        "contains": .fixed(2), "split": .fixed(2), "join": .fixed(2), "index": .fixed(2), "coalesce": .fixed(2),
        "and": .atLeast(2), "or": .atLeast(2), "add": .atLeast(2), "mul": .atLeast(2), "concat": .atLeast(2),
        "substring": .fixed(3), "replace": .fixed(3), "slice": .fixed(3), "cond": .fixed(3),
    ]

    public static let statementHeads: [String: [String]] = [
        "let": ["type", "value"], "set": ["value"], "append": ["value"], "if": ["then", "else"],
        "forEach": ["in", "max", "body"], "return": [], "do": [], "fail": [], "checkCancelled": [],
    ]

    public static let reservedWords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let",
        "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while",
        "with", "yield", "async", "static", "implements", "interface", "package", "private", "protected", "public",
        "eval", "arguments", "undefined", "context", "input",
    ]

    public static let reservedFields: Set<String> = ["__proto__", "constructor", "prototype"]
    public static let identifierPattern = "^[a-z][a-zA-Z0-9]{0,31}$"
    public static let fieldPattern = "^[a-zA-Z][a-zA-Z0-9]{0,47}$"
    public static let callPattern = "^[a-z]+(\\.[a-zA-Z]+)+$"
    public static let signaturePattern = "^[a-z]+(\\.[a-z]+)*@[1-9][0-9]{0,2}$"
    public static let maxStringLiteral = 64 * 1024
    public static let maxIntegerLiteral = 9_007_199_254_740_991

    public static let runtimeMembers: [String] = [
        "call", "checkCancelled", "div", "fail", "i", "index", "loop", "mod", "replace", "substring", "unwrap",
    ]
}

public struct BFParseResult: Sendable {
    public var program: BFProgram?
    public var diagnostics: [ModDiagnostic]
}

public enum BFScriptParser {
    public static func parse(data: Data, file: String, limits: ModCatalogLimits = .v1) -> BFParseResult {
        if data.count > limits.scriptBytes {
            return BFParseResult(program: nil, diagnostics: [ModDiagnostic(.scriptSizeLimit, file: file, message: "script is \(data.count) bytes; limit is \(limits.scriptBytes)")])
        }
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch let e as JSONParseError {
            return BFParseResult(program: nil, diagnostics: [ModDiagnostic(.invalidJSON, file: file, pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message)])
        } catch {
            return BFParseResult(program: nil, diagnostics: [ModDiagnostic(.invalidJSON, file: file, message: "\(error)")])
        }
        return parse(value: value, file: file, limits: limits)
    }

    public static func parse(value: JSONValue, file: String, limits: ModCatalogLimits = .v1) -> BFParseResult {
        var p = Parser(file: file, limits: limits)
        let program = p.parseProgram(value)
        return BFParseResult(program: p.diagnostics.hasErrors ? nil : program, diagnostics: p.diagnostics)
    }

    struct Parser {
        let file: String
        let limits: ModCatalogLimits
        var diagnostics: [ModDiagnostic] = []
        var statementCount = 0

        init(file: String, limits: ModCatalogLimits) { self.file = file; self.limits = limits }

        mutating func err(_ code: ModDiagnosticCode, _ pointer: String, _ message: String, fix: String? = nil) {
            diagnostics.append(ModDiagnostic(code, file: file, pointer: pointer, message: message, fix: fix))
        }

        mutating func closedKeys(_ o: [String: JSONValue], allowed: Set<String>, ptr: String, what: String) {
            for k in o.keys.sorted() where !allowed.contains(k) {
                err(.unknownConstruct, JSONPointer.appending(ptr, k), "unknown key '\(k)' in \(what)",
                    fix: "Allowed keys: " + allowed.sorted().joined(separator: ", "))
            }
        }

        mutating func ident(_ v: JSONValue?, _ ptr: String, what: String, allowReserved: Bool = false) -> String? {
            guard let s = v?.stringValue else { err(.malformedProgram, ptr, "\(what) must be a string"); return nil }
            guard ModPatterns.matches(s, BFLanguage.identifierPattern) else {
                err(.invalidIdentifier, ptr, "invalid \(what) '\(s)'", fix: "Use lowerCamelCase letters and digits, at most 32 characters")
                return nil
            }
            if !allowReserved, BFLanguage.reservedWords.contains(s) {
                err(.reservedName, ptr, "'\(s)' is reserved")
                return nil
            }
            return s
        }

        mutating func parseProgram(_ v: JSONValue) -> BFProgram? {
            guard case .object(let o) = v else { err(.malformedProgram, "", "program must be a JSON object"); return nil }
            closedKeys(o, allowed: ["$schema", "format", "functions"], ptr: "", what: "program")
            guard let fmt = o["format"] else { err(.malformedProgram, "/format", "missing 'format'"); return nil }
            guard case .int(let n) = fmt else { err(.malformedProgram, "/format", "format must be an integer"); return nil }
            guard n == ModKitVersion.scriptFormat else {
                err(.unsupportedFormat, "/format", "script format \(n) is not supported (expected \(ModKitVersion.scriptFormat))")
                return nil
            }
            guard case .object(let fns)? = o["functions"] else {
                err(.malformedProgram, "/functions", "'functions' must be an object")
                return nil
            }
            if fns.isEmpty { err(.malformedProgram, "/functions", "at least one function is required") }
            if fns.count > limits.maxFunctions { err(.scriptSizeLimit, "/functions", "\(fns.count) functions; limit is \(limits.maxFunctions)") }
            var out = [BFFunction]()
            for name in fns.keys.sorted() {
                let ptr = JSONPointer.appending("/functions", name)
                guard ModPatterns.matches(name, BFLanguage.identifierPattern) else {
                    err(.invalidIdentifier, ptr, "invalid function name '\(name)'")
                    continue
                }
                if BFLanguage.reservedWords.contains(name) { err(.reservedName, ptr, "'\(name)' is reserved"); continue }
                if let f = parseFunction(name, fns[name]!, ptr) { out.append(f) }
            }
            return BFProgram(functions: out)
        }

        mutating func parseFunction(_ name: String, _ v: JSONValue, _ ptr: String) -> BFFunction? {
            guard case .object(let o) = v else { err(.malformedProgram, ptr, "function must be an object"); return nil }
            closedKeys(o, allowed: ["signature", "body"], ptr: ptr, what: "function")
            guard let sigV = o["signature"] else { err(.malformedProgram, ptr + "/signature", "missing 'signature'"); return nil }
            var signature: BFSignature?
            let sigPtr = ptr + "/signature"
            switch sigV {
            case .string(let s):
                if ModPatterns.matches(s, BFLanguage.signaturePattern), let at = s.lastIndex(of: "@"), let ver = Int(s[s.index(after: at)...]) {
                    signature = .hook(name: String(s[..<at]), version: ver)
                } else {
                    err(.malformedProgram, sigPtr, "invalid hook signature '\(s)'", fix: "Use \"<hook.name>@<version>\", for example \"column.values@1\"")
                }
            case .object(let so):
                closedKeys(so, allowed: ["params", "returns"], ptr: sigPtr, what: "helper signature")
                var params = [BFParam]()
                if case .array(let arr)? = so["params"] {
                    if arr.count > 8 { err(.scriptSizeLimit, sigPtr + "/params", "at most 8 parameters") }
                    for (i, pv) in arr.enumerated() {
                        let pp = JSONPointer.appending(sigPtr + "/params", i)
                        guard case .object(let po) = pv else { err(.malformedProgram, pp, "parameter must be an object"); continue }
                        closedKeys(po, allowed: ["name", "type"], ptr: pp, what: "parameter")
                        let pname = ident(po["name"], pp + "/name", what: "parameter name")
                        let ptype = po["type"].flatMap { ModTypeExpr.parse($0) }
                        if ptype == nil { err(.unknownType, pp + "/type", "invalid type expression") }
                        if let pname, let ptype { params.append(BFParam(name: pname, type: ptype)) }
                    }
                } else { err(.malformedProgram, sigPtr + "/params", "'params' must be an array") }
                let returns = so["returns"].flatMap { ModTypeExpr.parse($0) }
                if returns == nil { err(.unknownType, sigPtr + "/returns", "missing or invalid return type") }
                if let returns { signature = .helper(params: params, returns: returns) }
            default:
                err(.malformedProgram, sigPtr, "signature must be a string or helper signature object")
            }
            guard case .array(let body)? = o["body"] else { err(.malformedProgram, ptr + "/body", "'body' must be an array of statements"); return nil }
            let stmts = parseBlock(body, ptr + "/body", depth: 1)
            guard let signature else { return nil }
            return BFFunction(name: name, signature: signature, body: stmts, pointer: ptr)
        }

        mutating func parseBlock(_ arr: [JSONValue], _ ptr: String, depth: Int) -> [BFStmt] {
            if depth > limits.maxNesting {
                err(.scriptSizeLimit, ptr, "statements nested deeper than \(limits.maxNesting)")
                return []
            }
            var out = [BFStmt]()
            for (i, s) in arr.enumerated() {
                if let st = parseStmt(s, JSONPointer.appending(ptr, i), depth: depth) { out.append(st) }
            }
            return out
        }

        mutating func parseStmt(_ v: JSONValue, _ ptr: String, depth: Int) -> BFStmt? {
            statementCount += 1
            if statementCount == limits.maxStatements + 1 {
                err(.scriptSizeLimit, ptr, "more than \(limits.maxStatements) statements")
            }
            guard case .object(let o) = v else { err(.malformedProgram, ptr, "statement must be an object"); return nil }
            let heads = o.keys.filter { BFLanguage.statementHeads[$0] != nil }.sorted()
            guard heads.count == 1, let head = heads.first else {
                if heads.isEmpty {
                    err(.unknownConstruct, ptr, "unknown statement; keys: " + o.keys.sorted().joined(separator: ", "),
                        fix: "Statements start with one of: " + BFLanguage.statementHeads.keys.sorted().joined(separator: ", "))
                } else {
                    err(.unknownConstruct, ptr, "statement has several heads: " + heads.joined(separator: ", "))
                }
                return nil
            }
            closedKeys(o, allowed: Set([head] + BFLanguage.statementHeads[head]!), ptr: ptr, what: "'\(head)' statement")
            let hp = JSONPointer.appending(ptr, head)
            func req(_ key: String) -> JSONValue? {
                guard let x = o[key] else { return nil }
                return x
            }
            switch head {
            case "let":
                let name = ident(o["let"], hp, what: "variable name")
                var type: ModTypeExpr?
                if let t = o["type"] {
                    type = ModTypeExpr.parse(t)
                    if type == nil { err(.unknownType, ptr + "/type", "invalid type expression") }
                }
                guard let vv = req("value") else { err(.malformedProgram, ptr + "/value", "'let' requires 'value'"); return nil }
                let e = parseExpr(vv, ptr + "/value", depth: 1)
                guard let name, let e else { return nil }
                return BFStmt(kind: .letBinding(name: name, type: type, value: e), pointer: ptr)
            case "set", "append":
                let name = ident(o[head], hp, what: "variable name", allowReserved: true)
                guard let vv = req("value") else { err(.malformedProgram, ptr + "/value", "'\(head)' requires 'value'"); return nil }
                let e = parseExpr(vv, ptr + "/value", depth: 1)
                guard let name, let e else { return nil }
                return BFStmt(kind: head == "set" ? .set(name: name, value: e) : .append(name: name, value: e), pointer: ptr)
            case "if":
                let c = parseExpr(o["if"]!, hp, depth: 1)
                var thenB: [BFStmt]?
                if case .array(let a)? = o["then"] { thenB = parseBlock(a, ptr + "/then", depth: depth + 1) }
                else { err(.malformedProgram, ptr + "/then", "'if' requires a 'then' array") }
                var elseB: [BFStmt]?
                if let ev = o["else"] {
                    if case .array(let a) = ev { elseB = parseBlock(a, ptr + "/else", depth: depth + 1) }
                    else { err(.malformedProgram, ptr + "/else", "'else' must be an array") }
                }
                guard let c, let thenB else { return nil }
                return BFStmt(kind: .ifElse(condition: c, then: thenB, else: elseB), pointer: ptr)
            case "forEach":
                let item = ident(o["forEach"], hp, what: "loop variable")
                let inE = o["in"].flatMap { parseExpr($0, ptr + "/in", depth: 1) }
                if o["in"] == nil { err(.malformedProgram, ptr + "/in", "'forEach' requires 'in'") }
                var bound: Int?
                if let m = o["max"] {
                    if case .int(let n) = m, n >= 1 { bound = n }
                    else { err(.unboundedLoop, ptr + "/max", "'max' must be a positive integer", fix: "Set \"max\" to the largest iteration count the loop may need") }
                } else {
                    err(.unboundedLoop, ptr, "'forEach' has no 'max' bound", fix: "Add \"max\": <n> with n <= \(limits.maxLoopBound)")
                }
                var body: [BFStmt]?
                if case .array(let a)? = o["body"] { body = parseBlock(a, ptr + "/body", depth: depth + 1) }
                else { err(.malformedProgram, ptr + "/body", "'forEach' requires a 'body' array") }
                guard let item, let inE, let bound, let body else { return nil }
                return BFStmt(kind: .forEach(item: item, in: inE, max: bound, body: body), pointer: ptr)
            case "return", "do", "fail":
                guard let e = parseExpr(o[head]!, hp, depth: 1) else { return nil }
                switch head {
                case "return": return BFStmt(kind: .ret(e), pointer: ptr)
                case "do": return BFStmt(kind: .doExpr(e), pointer: ptr)
                default: return BFStmt(kind: .fail(e), pointer: ptr)
                }
            default:
                guard o["checkCancelled"] == .bool(true) else { err(.malformedProgram, hp, "'checkCancelled' must be true"); return nil }
                return BFStmt(kind: .checkCancelled, pointer: ptr)
            }
        }

        mutating func parseExpr(_ v: JSONValue, _ ptr: String, depth: Int) -> BFExpr? {
            if depth > limits.maxExprDepth {
                err(.scriptSizeLimit, ptr, "expression nested deeper than \(limits.maxExprDepth)")
                return nil
            }
            switch v {
            case .null, .bool: return BFExpr(kind: .literal(v), pointer: ptr)
            case .int(let i):
                if abs(i) > BFLanguage.maxIntegerLiteral { err(.literalOutOfRange, ptr, "integer literal outside the safe range ±2^53-1"); return nil }
                return BFExpr(kind: .literal(v), pointer: ptr)
            case .double: return BFExpr(kind: .literal(v), pointer: ptr)
            case .string(let s):
                if s.utf8.count > BFLanguage.maxStringLiteral { err(.scriptSizeLimit, ptr, "string literal longer than \(BFLanguage.maxStringLiteral) bytes"); return nil }
                return BFExpr(kind: .literal(v), pointer: ptr)
            case .array:
                err(.unknownConstruct, ptr, "bare arrays are not expressions", fix: "Use {\"list\": [...]}")
                return nil
            case .object(let o):
                return parseObjectExpr(o, ptr, depth: depth)
            }
        }

        mutating func parseObjectExpr(_ o: [String: JSONValue], _ ptr: String, depth: Int) -> BFExpr? {
            let structural: Set<String> = ["get", "record", "list", "call", "fn", "await"]
            let heads = o.keys.filter { structural.contains($0) || BFLanguage.ops[$0] != nil }.sorted()
            guard heads.count == 1, let head = heads.first else {
                if heads.isEmpty {
                    err(.unknownConstruct, ptr, "unknown expression; keys: " + o.keys.sorted().joined(separator: ", "),
                        fix: "Expressions are literals or objects headed by get, record, list, call, fn, await or an operator")
                } else {
                    err(.unknownConstruct, ptr, "expression has several heads: " + heads.joined(separator: ", "))
                }
                return nil
            }
            let hp = JSONPointer.appending(ptr, head)
            let extra: [String] = (head == "call" || head == "fn") ? ["args"] : []
            closedKeys(o, allowed: Set([head] + extra), ptr: ptr, what: "'\(head)' expression")
            let value = o[head]!
            switch head {
            case "get":
                guard case .array(let a) = value, !a.isEmpty else { err(.malformedProgram, hp, "'get' requires a non-empty path array"); return nil }
                if a.count > 8 { err(.scriptSizeLimit, hp, "path longer than 8 elements"); return nil }
                var path = [BFPathElement]()
                for (i, el) in a.enumerated() {
                    let ep = JSONPointer.appending(hp, i)
                    switch el {
                    case .string(let s):
                        if i == 0 {
                            guard ModPatterns.matches(s, BFLanguage.identifierPattern) || s == "context" || s == "input" else {
                                err(.invalidIdentifier, ep, "invalid variable name '\(s)'"); return nil
                            }
                        } else {
                            guard ModPatterns.matches(s, BFLanguage.fieldPattern) else { err(.invalidIdentifier, ep, "invalid field name '\(s)'"); return nil }
                            if BFLanguage.reservedFields.contains(s) { err(.reservedName, ep, "field '\(s)' is reserved"); return nil }
                        }
                        path.append(.name(s))
                    case .int(let n) where i > 0 && n >= 0 && n <= 1_000_000:
                        path.append(.index(n))
                    default:
                        err(.malformedProgram, ep, i == 0 ? "path must start with a variable name" : "path elements are field names or non-negative integer indexes")
                        return nil
                    }
                }
                return BFExpr(kind: .get(path), pointer: ptr)
            case "record":
                guard case .object(let ro) = value else { err(.malformedProgram, hp, "'record' requires an object"); return nil }
                if ro.count > 64 { err(.scriptSizeLimit, hp, "record literal with more than 64 fields"); return nil }
                var fields = [String: BFExpr]()
                var ok = true
                for k in ro.keys.sorted() {
                    let fp = JSONPointer.appending(hp, k)
                    guard ModPatterns.matches(k, BFLanguage.fieldPattern) else { err(.invalidIdentifier, fp, "invalid field name '\(k)'"); ok = false; continue }
                    if BFLanguage.reservedFields.contains(k) { err(.reservedName, fp, "field '\(k)' is reserved"); ok = false; continue }
                    if let e = parseExpr(ro[k]!, fp, depth: depth + 1) { fields[k] = e } else { ok = false }
                }
                return ok ? BFExpr(kind: .record(fields), pointer: ptr) : nil
            case "list":
                guard case .array(let a) = value else { err(.malformedProgram, hp, "'list' requires an array"); return nil }
                if a.count > 1024 { err(.scriptSizeLimit, hp, "list literal with more than 1024 elements"); return nil }
                var items = [BFExpr]()
                var ok = true
                for (i, el) in a.enumerated() {
                    if let e = parseExpr(el, JSONPointer.appending(hp, i), depth: depth + 1) { items.append(e) } else { ok = false }
                }
                return ok ? BFExpr(kind: .list(items), pointer: ptr) : nil
            case "call", "fn":
                guard let name = value.stringValue else { err(.malformedProgram, hp, "'\(head)' requires a function name string"); return nil }
                if head == "call", !ModPatterns.matches(name, BFLanguage.callPattern) {
                    err(.malformedProgram, hp, "invalid catalog function name '\(name)'"); return nil
                }
                if head == "fn", !ModPatterns.matches(name, BFLanguage.identifierPattern) {
                    err(.invalidIdentifier, hp, "invalid helper name '\(name)'"); return nil
                }
                guard case .array(let a)? = o["args"] else { err(.malformedProgram, ptr + "/args", "'\(head)' requires an 'args' array"); return nil }
                if a.count > 8 { err(.scriptSizeLimit, ptr + "/args", "at most 8 arguments"); return nil }
                var args = [BFExpr]()
                var ok = true
                for (i, el) in a.enumerated() {
                    if let e = parseExpr(el, JSONPointer.appending(ptr + "/args", i), depth: depth + 1) { args.append(e) } else { ok = false }
                }
                guard ok else { return nil }
                return BFExpr(kind: head == "call" ? .call(name: name, args: args) : .fn(name: name, args: args), pointer: ptr)
            case "await":
                guard let inner = parseExpr(value, hp, depth: depth + 1) else { return nil }
                switch inner.kind {
                case .call, .fn: return BFExpr(kind: .await(inner), pointer: ptr)
                default:
                    err(.callNotAwaited, hp, "'await' applies only to a 'call' or 'fn' expression")
                    return nil
                }
            default:
                let arity = BFLanguage.ops[head]!
                switch arity {
                case .unary:
                    guard let a = parseExpr(value, hp, depth: depth + 1) else { return nil }
                    return BFExpr(kind: .op(head, [a]), pointer: ptr)
                case .fixed(let n), .atLeast(let n):
                    guard case .array(let arr) = value else { err(.malformedProgram, hp, "'\(head)' requires an array of operands"); return nil }
                    if case .fixed = arity, arr.count != n {
                        err(.argumentCount, hp, "'\(head)' takes exactly \(n) operands, got \(arr.count)"); return nil
                    }
                    if case .atLeast = arity, arr.count < n {
                        err(.argumentCount, hp, "'\(head)' takes at least \(n) operands, got \(arr.count)"); return nil
                    }
                    if arr.count > 16 { err(.scriptSizeLimit, hp, "at most 16 operands"); return nil }
                    var args = [BFExpr]()
                    var ok = true
                    for (i, el) in arr.enumerated() {
                        if let e = parseExpr(el, JSONPointer.appending(hp, i), depth: depth + 1) { args.append(e) } else { ok = false }
                    }
                    return ok ? BFExpr(kind: .op(head, args), pointer: ptr) : nil
                }
            }
        }
    }
}
