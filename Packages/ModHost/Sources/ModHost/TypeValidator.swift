import Foundation
import ModKit

public struct ModTypeViolation: Error, Equatable, Sendable, CustomStringConvertible {
    public var pointer: String
    public var message: String
    public var description: String { pointer.isEmpty ? message : "\(pointer): \(message)" }
}

public struct ModValueValidator: Sendable {
    public let catalog: ModCatalog
    public var maxDepth = 48
    public var maxStringBytes = 1 << 20

    public init(catalog: ModCatalog = .v1) { self.catalog = catalog }

    public func validate(_ value: JSONValue, _ type: ModTypeExpr, pointer: String = "") -> ModTypeViolation? {
        check(value, type, pointer, 0)
    }

    public func validateArguments(_ args: [JSONValue], for function: ModFunction) -> ModTypeViolation? {
        let required = function.params.filter { !$0.optional }.count
        guard args.count >= required, args.count <= function.params.count else {
            return ModTypeViolation(pointer: "", message: "\(function.name) takes \(required == function.params.count ? "\(required)" : "\(required)...\(function.params.count)") arguments, got \(args.count)")
        }
        for (i, arg) in args.enumerated() {
            let p = function.params[i]
            if p.optional, arg.isNull { continue }
            if let v = check(arg, p.type, "/\(p.name)", 0) { return v }
        }
        return nil
    }

    private func check(_ value: JSONValue, _ type: ModTypeExpr, _ ptr: String, _ depth: Int) -> ModTypeViolation? {
        if depth > maxDepth { return ModTypeViolation(pointer: ptr, message: "value nests too deeply") }
        func fail(_ m: String) -> ModTypeViolation { ModTypeViolation(pointer: ptr, message: m) }
        switch type {
        case .json:
            return nil
        case .void, .null:
            return value.isNull ? nil : fail("expected null, got \(value.typeName)")
        case .string:
            guard case .string(let s) = value else { return fail("expected string, got \(value.typeName)") }
            return s.utf8.count > maxStringBytes ? fail("string too long") : nil
        case .integer:
            switch value {
            case .int: return nil
            case .double(let d) where d.rounded() == d && abs(d) <= 9_007_199_254_740_991: return nil
            default: return fail("expected integer, got \(value.typeName)")
            }
        case .number:
            guard let n = value.numberValue else { return fail("expected number, got \(value.typeName)") }
            return n.isFinite ? nil : fail("expected a finite number")
        case .boolean:
            return value.boolValue == nil ? fail("expected boolean, got \(value.typeName)") : nil
        case .optional(let inner):
            return value.isNull ? nil : check(value, inner, ptr, depth + 1)
        case .list(let inner):
            guard case .array(let items) = value else { return fail("expected list, got \(value.typeName)") }
            for (i, item) in items.enumerated() {
                if let v = check(item, inner, "\(ptr)/\(i)", depth + 1) { return v }
            }
            return nil
        case .ref(let name):
            guard let def = catalog.type(named: name) else { return fail("unknown type \(name)") }
            switch def.kind {
            case .alias:
                return check(value, def.aliasOf ?? .json, ptr, depth + 1)
            case .enum:
                guard case .string(let s) = value else { return fail("expected \(name), got \(value.typeName)") }
                return (def.cases ?? []).contains(s) ? nil : fail("'\(s)' is not a \(name)")
            case .record:
                guard case .object(let obj) = value else { return fail("expected \(name), got \(value.typeName)") }
                let fields = def.fields ?? []
                let known = Set(fields.map(\.name))
                if let extra = obj.keys.sorted().first(where: { !known.contains($0) }) {
                    return ModTypeViolation(pointer: "\(ptr)/\(extra)", message: "unknown field '\(extra)' in \(name)")
                }
                for f in fields {
                    let fp = "\(ptr)/\(f.name)"
                    guard let v = obj[f.name] else {
                        if f.optional { continue }
                        return ModTypeViolation(pointer: fp, message: "missing field '\(f.name)' of \(name)")
                    }
                    if f.optional, v.isNull { continue }
                    if let violation = check(v, f.type, fp, depth + 1) { return violation }
                }
                return nil
            }
        }
    }
}

public struct ModFixtureSynthesizer: Sendable {
    public let catalog: ModCatalog

    public init(catalog: ModCatalog = .v1) { self.catalog = catalog }

    public func value(_ type: ModTypeExpr, depth: Int = 0) -> JSONValue {
        if depth > 6 { return .null }
        switch type {
        case .string: return .string("fixture")
        case .integer: return .int(1)
        case .number: return .double(1.5)
        case .boolean: return .bool(false)
        case .null, .void, .json: return .null
        case .optional(let inner): return value(inner, depth: depth + 1)
        case .list(let inner): return depth > 3 ? .array([]) : .array([value(inner, depth: depth + 1)])
        case .ref(let name):
            guard let def = catalog.type(named: name) else { return .null }
            switch def.kind {
            case .alias:
                if name == "Int64String" { return .string("1024") }
                return value(def.aliasOf ?? .json, depth: depth + 1)
            case .enum:
                return .string(def.cases?.first ?? "")
            case .record:
                var obj = [String: JSONValue]()
                for f in def.fields ?? [] where !f.optional {
                    if name == "FileRef", f.name == "handle" { obj[f.name] = .string("fixture-handle"); continue }
                    obj[f.name] = value(f.type, depth: depth + 1)
                }
                return .object(obj)
            }
        }
    }
}
