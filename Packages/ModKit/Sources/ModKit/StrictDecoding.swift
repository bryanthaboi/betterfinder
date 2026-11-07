import Foundation

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    init(_ s: String) { stringValue = s; intValue = nil }
}

public enum ModPatterns {
    public static let modID = "^[a-z0-9][a-z0-9.-]{2,95}$"
    public static let localID = "^[a-z][a-z0-9-]{0,47}$"
    public static let author = "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"
    public static let handler = "^[a-zA-Z_][a-zA-Z0-9_]{0,63}$"
    public static let settingKey = "^[a-z][a-zA-Z0-9_]{0,47}$"
    public static let sha256 = "^[0-9a-f]{64}$"
    public static let builtinCommand = "^builtin\\.[a-z0-9][a-z0-9.-]{0,63}$"
    public static let commandRef = "^([a-z][a-z0-9-]{0,47}|builtin\\.[a-z0-9][a-z0-9.-]{0,63})$"
    public static let relativePath = "^(?!/)(?!.*(^|/)\\.\\.?(/|$))(?!.*//)(?!.*\\\\)[^\\u0000-\\u001f]{1,240}$"
    public static let extensionName = "^[a-z0-9]{1,16}$"
    public static let scheme = "^[a-z][a-z0-9-]{1,23}$"
    public static let keyChord = "^(?:(?:cmd|ctrl|opt|shift)\\+){0,4}(?:[a-z0-9]|f(?:[1-9]|1[0-9]|20)|space|return|tab|delete|escape|up|down|left|right|\\[|\\]|,|\\.|/|-|=)$"
    public static let host = "^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$"
    public static let rootID = "^[a-z][a-z0-9-]{0,31}$"
    public static let brokerOperation = "^[a-z][a-z0-9]*(\\.[a-z][a-zA-Z0-9]*)+$"
    public static let icon = "^[A-Za-z0-9.]{1,64}$"

    public static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ModDecodeFailure {
    static func corrupted(_ path: [CodingKey], _ code: ModDiagnosticCode, _ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: path, debugDescription: "\(code.rawValue)|\(message)"))
    }
}

struct StrictReader<K: CodingKey & CaseIterable & RawRepresentable> where K.RawValue == String {
    let c: KeyedDecodingContainer<K>
    let path: [CodingKey]

    init(_ decoder: Decoder, _: K.Type, extraAllowed: [String] = []) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        var allowed = Set(K.allCases.map(\.rawValue))
        for e in extraAllowed { allowed.insert(e) }
        for key in any.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) where !allowed.contains(key.stringValue) {
            throw ModDecodeFailure.corrupted(decoder.codingPath + [key], .unknownKey, "unknown key '\(key.stringValue)'")
        }
        c = try decoder.container(keyedBy: K.self)
        path = decoder.codingPath
    }

    func req<T: Decodable>(_ k: K) throws -> T { try c.decode(T.self, forKey: k) }

    func opt<T: Decodable>(_ k: K) throws -> T? {
        guard c.contains(k) else { return nil }
        return try c.decode(T.self, forKey: k)
    }

    func has(_ k: K) -> Bool { c.contains(k) }

    func string(_ k: K, pattern: String, code: ModDiagnosticCode = .invalidValue, what: String) throws -> String {
        let s: String = try req(k)
        guard ModPatterns.matches(s, pattern) else {
            throw ModDecodeFailure.corrupted(path + [AnyKey(k.rawValue)], code, "invalid \(what) '\(s)'")
        }
        return s
    }

    func optString(_ k: K, pattern: String, what: String) throws -> String? {
        guard c.contains(k) else { return nil }
        return try string(k, pattern: pattern, what: what)
    }

    func stringArray(_ k: K, pattern: String, what: String) throws -> [String] {
        let a: [String] = try req(k)
        for (i, s) in a.enumerated() where !ModPatterns.matches(s, pattern) {
            throw ModDecodeFailure.corrupted(path + [AnyKey(k.rawValue), AnyKey(intValue: i)!], .invalidValue, "invalid \(what) '\(s)'")
        }
        return a
    }

    func fail(_ k: K?, _ code: ModDiagnosticCode, _ message: String) -> DecodingError {
        ModDecodeFailure.corrupted(k.map { path + [AnyKey($0.rawValue)] } ?? path, code, message)
    }
}

public enum ModDecoding {
    public static func pointer(_ path: [CodingKey]) -> String {
        path.map { "/" + JSONPointer.escape($0.intValue.map(String.init) ?? $0.stringValue) }.joined()
    }

    public static func diagnostic(for error: Error, file: String? = nil) -> ModDiagnostic {
        guard let e = error as? DecodingError else {
            return ModDiagnostic(.invalidValue, file: file, message: "\(error)")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            return ModDiagnostic(.missingKey, file: file, pointer: pointer(ctx.codingPath + [key]),
                                 message: "missing required key '\(key.stringValue)'",
                                 fix: "Add the '\(key.stringValue)' key")
        case .typeMismatch(let type, let ctx):
            return ModDiagnostic(.wrongType, file: file, pointer: pointer(ctx.codingPath),
                                 message: "expected \(describe(type)): \(ctx.debugDescription)")
        case .valueNotFound(let type, let ctx):
            return ModDiagnostic(.wrongType, file: file, pointer: pointer(ctx.codingPath),
                                 message: "expected \(describe(type)), found null")
        case .dataCorrupted(let ctx):
            let d = ctx.debugDescription
            if d.hasPrefix("BF"), let bar = d.firstIndex(of: "|"),
               let code = ModDiagnosticCode(rawValue: String(d[..<bar])) {
                return ModDiagnostic(code, file: file, pointer: pointer(ctx.codingPath), message: String(d[d.index(after: bar)...]))
            }
            return ModDiagnostic(.invalidValue, file: file, pointer: pointer(ctx.codingPath), message: d)
        @unknown default:
            return ModDiagnostic(.invalidValue, file: file, message: "\(e)")
        }
    }

    static func describe(_ type: Any.Type) -> String {
        let n = String(describing: type)
        switch n {
        case "String": return "string"
        case "Int": return "integer"
        case "Double": return "number"
        case "Bool": return "boolean"
        case "Array<String>": return "array of strings"
        default: return n.hasPrefix("Array") ? "array" : (n.hasPrefix("Dictionary") ? "object" : n)
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue, file: String? = nil) -> Result<T, ModDiagnostic> {
        do {
            return .success(try JSONDecoder().decode(T.self, from: value.canonicalData()))
        } catch {
            return .failure(diagnostic(for: error, file: file))
        }
    }
}
