import Foundation

public struct SchemaViolation: Equatable, Sendable {
    public var pointer: String
    public var keyword: String
    public var message: String
}

public struct JSONSchema: Sendable {
    public let root: JSONValue

    public init(_ root: JSONValue) { self.root = root }

    public init(data: Data) throws { self.root = try JSONValue.parse(data) }

    public enum Name: String, CaseIterable, Sendable {
        case manifest = "manifest.schema"
        case bfscript = "bfscript.schema"
        case indexListing = "index-listing.schema"
        case authorTest = "author-test.schema"
    }

    public static func resourceURL(_ name: Name) -> URL? {
        Bundle.module.url(forResource: name.rawValue, withExtension: "json", subdirectory: "Resources/Schemas")
    }

    public static func load(_ name: Name) -> JSONSchema {
        guard let url = resourceURL(name), let data = try? Data(contentsOf: url), let s = try? JSONSchema(data: data) else {
            preconditionFailure("missing schema resource \(name.rawValue)")
        }
        return s
    }

    public static let manifest = load(.manifest)
    public static let bfscript = load(.bfscript)
    public static let indexListing = load(.indexListing)
    public static let authorTest = load(.authorTest)

    public func validate(_ instance: JSONValue, limit: Int = 200) -> [SchemaViolation] {
        var ctx = Context(root: root, limit: limit)
        ctx.check(instance, root, "")
        return ctx.violations
    }

    struct Context {
        let root: JSONValue
        let limit: Int
        var violations: [SchemaViolation] = []
        var depth = 0

        init(root: JSONValue, limit: Int) { self.root = root; self.limit = limit }

        mutating func add(_ pointer: String, _ keyword: String, _ message: String) {
            if violations.count < limit { violations.append(SchemaViolation(pointer: pointer, keyword: keyword, message: message)) }
        }

        func resolve(_ ref: String) -> JSONValue? {
            if ref == "#" { return root }
            guard ref.hasPrefix("#/") else { return nil }
            var node: JSONValue = root
            for part in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
                let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = node[key] else { return nil }
                node = next
            }
            return node
        }

        func valid(_ instance: JSONValue, _ schema: JSONValue) -> Bool {
            var sub = Context(root: root, limit: 1)
            sub.depth = depth
            sub.check(instance, schema, "")
            return sub.violations.isEmpty
        }

        static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
            switch (a, b) {
            case (.int(let x), .double(let y)), (.double(let y), .int(let x)): return Double(x) == y
            default: return a == b
            }
        }

        func matchesType(_ instance: JSONValue, _ type: String) -> Bool {
            switch (type, instance) {
            case ("string", .string), ("boolean", .bool), ("null", .null), ("array", .array), ("object", .object): return true
            case ("integer", .int): return true
            case ("integer", .double(let d)): return d == d.rounded() && abs(d) < 9e15
            case ("number", .int), ("number", .double): return true
            default: return false
            }
        }

        mutating func check(_ instance: JSONValue, _ schema: JSONValue, _ ptr: String) {
            if violations.count >= limit { return }
            if case .bool(let b) = schema {
                if !b { add(ptr, "false", "no value is allowed here") }
                return
            }
            guard case .object(let s) = schema else { return }
            depth += 1
            defer { depth -= 1 }
            if depth > 96 { add(ptr, "depth", "schema recursion too deep"); return }

            if let r = s["$ref"]?.stringValue {
                if let target = resolve(r) { check(instance, target, ptr) } else { add(ptr, "$ref", "unresolvable reference \(r)") }
            }

            if let t = s["type"] {
                let names = t.stringValue.map { [$0] } ?? (t.arrayValue ?? []).compactMap(\.stringValue)
                if !names.contains(where: { matchesType(instance, $0) }) {
                    add(ptr, "type", "expected \(names.joined(separator: " or ")), found \(instance.typeName)")
                    return
                }
            }
            if let e = s["enum"]?.arrayValue, !e.contains(where: { Context.equal($0, instance) }) {
                add(ptr, "enum", "value is not one of: " + e.compactMap { $0.stringValue ?? $0.canonicalString() }.joined(separator: ", "))
            }
            if let c = s["const"], !Context.equal(c, instance) { add(ptr, "const", "value must be \(c.canonicalString())") }

            switch instance {
            case .string(let str):
                let len = str.unicodeScalars.count
                if let m = s["minLength"]?.intValue, len < m { add(ptr, "minLength", "shorter than \(m)") }
                if let m = s["maxLength"]?.intValue, len > m { add(ptr, "maxLength", "longer than \(m)") }
                if let p = s["pattern"]?.stringValue, !ModPatterns.matches(str, p) { add(ptr, "pattern", "does not match pattern \(p)") }
            case .int, .double:
                let n = instance.numberValue ?? 0
                if let m = s["minimum"]?.numberValue, n < m { add(ptr, "minimum", "below minimum \(m)") }
                if let m = s["maximum"]?.numberValue, n > m { add(ptr, "maximum", "above maximum \(m)") }
                if let m = s["exclusiveMinimum"]?.numberValue, n <= m { add(ptr, "exclusiveMinimum", "not above \(m)") }
                if let m = s["exclusiveMaximum"]?.numberValue, n >= m { add(ptr, "exclusiveMaximum", "not below \(m)") }
            case .array(let a):
                if let m = s["minItems"]?.intValue, a.count < m { add(ptr, "minItems", "fewer than \(m) items") }
                if let m = s["maxItems"]?.intValue, a.count > m { add(ptr, "maxItems", "more than \(m) items") }
                if s["uniqueItems"]?.boolValue == true {
                    for i in a.indices {
                        for j in a.indices where j < i && Context.equal(a[i], a[j]) {
                            add(JSONPointer.appending(ptr, i), "uniqueItems", "duplicates item \(j)")
                        }
                    }
                }
                let prefix = s["prefixItems"]?.arrayValue ?? []
                for (i, item) in a.enumerated() {
                    let p = JSONPointer.appending(ptr, i)
                    if i < prefix.count { check(item, prefix[i], p) }
                    else if let items = s["items"] { check(item, items, p) }
                }
            case .object(let o):
                if let m = s["minProperties"]?.intValue, o.count < m { add(ptr, "minProperties", "fewer than \(m) properties") }
                if let m = s["maxProperties"]?.intValue, o.count > m { add(ptr, "maxProperties", "more than \(m) properties") }
                if let req = s["required"]?.arrayValue {
                    for key in req.compactMap(\.stringValue) where o[key] == nil {
                        add(JSONPointer.appending(ptr, key), "required", "missing required property '\(key)'")
                    }
                }
                let props = s["properties"]?.objectValue ?? [:]
                let patternProps = s["patternProperties"]?.objectValue ?? [:]
                for key in o.keys.sorted() {
                    let p = JSONPointer.appending(ptr, key)
                    var matched = false
                    if let sub = props[key] { matched = true; check(o[key]!, sub, p) }
                    for (pat, sub) in patternProps where ModPatterns.matches(key, pat) { matched = true; check(o[key]!, sub, p) }
                    if let names = s["propertyNames"] { check(.string(key), names, p) }
                    if !matched, let extra = s["additionalProperties"] {
                        if case .bool(false) = extra { add(p, "additionalProperties", "unknown property '\(key)'") }
                        else if case .bool(true) = extra {} else { check(o[key]!, extra, p) }
                    }
                }
            default: break
            }

            if let all = s["allOf"]?.arrayValue { for sub in all { check(instance, sub, ptr) } }
            if let any = s["anyOf"]?.arrayValue, !any.contains(where: { valid(instance, $0) }) {
                add(ptr, "anyOf", "does not match any allowed alternative")
            }
            if let one = s["oneOf"]?.arrayValue {
                let n = one.filter { valid(instance, $0) }.count
                if n != 1 { add(ptr, "oneOf", n == 0 ? "does not match any allowed alternative" : "matches \(n) alternatives, expected exactly one") }
            }
            if let not = s["not"], valid(instance, not) { add(ptr, "not", "matches a forbidden schema") }
            if let cond = s["if"] {
                if valid(instance, cond) {
                    if let then = s["then"] { check(instance, then, ptr) }
                } else if let els = s["else"] {
                    check(instance, els, ptr)
                }
            }
        }
    }
}

public extension JSONSchema {
    static func diagnostics(_ violations: [SchemaViolation], file: String?, manifest: Bool) -> [ModDiagnostic] {
        violations.map { v in
            let code: ModDiagnosticCode
            switch v.keyword {
            case "additionalProperties": code = .unknownKey
            case "required": code = .missingKey
            case "type": code = .wrongType
            case "maxItems", "maxLength", "maxProperties": code = .sizeBound
            case "const" where v.pointer == "/manifestVersion": code = .unsupportedManifestVersion
            case "pattern" where manifest && v.pointer == "/id": code = .invalidModID
            case "pattern" where v.pointer == "/version" || v.pointer == "/api" || v.pointer == "/app": code = .invalidVersionOrRange
            case "enum", "const", "pattern", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength",
                 "minItems", "uniqueItems", "minProperties", "not", "false":
                code = .invalidValue
            default: code = .schemaViolation
            }
            return ModDiagnostic(code, file: file, pointer: v.pointer, message: v.message)
        }
    }
}
