import Foundation

public struct ModTypeMismatch: Error, Equatable, Sendable, CustomStringConvertible {
    public var pointer: String
    public var message: String
    public var description: String { pointer.isEmpty ? message : "\(pointer): \(message)" }
}

public enum ModTypeConformance {
    public static func check(_ value: JSONValue, _ type: ModTypeExpr, catalog: ModCatalog = .v1, partial: Bool = false, pointer: String = "") -> ModTypeMismatch? {
        run(value, type, catalog, partial, pointer, 0)
    }

    public static func isStringLike(_ type: ModTypeExpr, catalog: ModCatalog = .v1, depth: Int = 0) -> Bool {
        if depth > 16 { return false }
        switch type {
        case .string, .json: return true
        case .optional(let inner): return isStringLike(inner, catalog: catalog, depth: depth + 1)
        case .ref(let name):
            guard let def = catalog.type(named: name) else { return false }
            switch def.kind {
            case .enum: return true
            case .alias: return def.aliasOf.map { isStringLike($0, catalog: catalog, depth: depth + 1) } ?? false
            case .record: return false
            }
        default: return false
        }
    }

    private static func run(_ value: JSONValue, _ type: ModTypeExpr, _ catalog: ModCatalog, _ partial: Bool, _ ptr: String, _ depth: Int) -> ModTypeMismatch? {
        func fail(_ m: String, _ p: String? = nil) -> ModTypeMismatch { ModTypeMismatch(pointer: p ?? ptr, message: m) }
        if depth > 48 { return fail("value nests too deeply") }
        switch type {
        case .json: return nil
        case .void, .null: return value.isNull ? nil : fail("expected null, got \(value.typeName)")
        case .string: return value.stringValue == nil ? fail("expected string, got \(value.typeName)") : nil
        case .integer:
            switch value {
            case .int: return nil
            case .double(let d) where d.rounded() == d && abs(d) <= 9_007_199_254_740_991: return nil
            default: return fail("expected integer, got \(value.typeName)")
            }
        case .number: return value.numberValue == nil ? fail("expected number, got \(value.typeName)") : nil
        case .boolean: return value.boolValue == nil ? fail("expected boolean, got \(value.typeName)") : nil
        case .optional(let inner): return value.isNull ? nil : run(value, inner, catalog, partial, ptr, depth + 1)
        case .list(let inner):
            guard case .array(let items) = value else { return fail("expected list, got \(value.typeName)") }
            for (i, item) in items.enumerated() {
                if let m = run(item, inner, catalog, partial, "\(ptr)/\(i)", depth + 1) { return m }
            }
            return nil
        case .ref(let name):
            guard let def = catalog.type(named: name) else { return fail("unknown type \(name)") }
            switch def.kind {
            case .alias: return run(value, def.aliasOf ?? .json, catalog, partial, ptr, depth + 1)
            case .enum:
                guard case .string(let s) = value else { return fail("expected \(name), got \(value.typeName)") }
                return (def.cases ?? []).contains(s) ? nil : fail("'\(s)' is not a \(name)")
            case .record:
                guard case .object(let obj) = value else { return fail("expected \(name), got \(value.typeName)") }
                let fields = def.fields ?? []
                let known = Set(fields.map(\.name))
                if let extra = obj.keys.sorted().first(where: { !known.contains($0) }) {
                    return fail("unknown field '\(extra)' in \(name)", "\(ptr)/\(extra)")
                }
                for f in fields {
                    let fp = "\(ptr)/\(f.name)"
                    guard let v = obj[f.name] else {
                        if f.optional || partial { continue }
                        return fail("missing field '\(f.name)' of \(name)", fp)
                    }
                    if f.optional, v.isNull { continue }
                    if let m = run(v, f.type, catalog, partial, fp, depth + 1) { return m }
                }
                return nil
            }
        }
    }
}
