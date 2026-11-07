import Foundation
import Security

public enum ModSettingValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)

    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var integerValue: Int? { if case .integer(let v) = self { return v } else { return nil } }
    public var numberValue: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }

    var defaultsObject: Any {
        switch self {
        case .bool(let v): return v
        case .integer(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        }
    }
}

public struct ModSettingsSchemaError: LocalizedError, Equatable {
    public var pointer: String
    public var message: String

    public var errorDescription: String? { "\(pointer): \(message)" }
}

public enum ModSettingsValueError: LocalizedError, Equatable {
    case unknownKey(String)
    case typeMismatch(key: String, expected: String)
    case belowMinimum(key: String, minimum: Double)
    case aboveMaximum(key: String, maximum: Double)
    case notFinite(key: String)
    case tooLong(key: String, maxLength: Int)
    case notAnOption(key: String)
    case notStoredHere(key: String)
    case invalidModID(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let k): return "There is no setting named \"\(k)\"."
        case .typeMismatch(let k, let e): return "\"\(k)\" expects \(e)."
        case .belowMinimum(let k, let m): return "\"\(k)\" must be at least \(ModSettingsSchema.format(m))."
        case .aboveMaximum(let k, let m): return "\"\(k)\" must be at most \(ModSettingsSchema.format(m))."
        case .notFinite(let k): return "\"\(k)\" must be a finite number."
        case .tooLong(let k, let n): return "\"\(k)\" can be at most \(n) characters."
        case .notAnOption(let k): return "That isn't one of the choices for \"\(k)\"."
        case .notStoredHere(let k): return "\"\(k)\" is stored in the Keychain."
        case .invalidModID(let id): return "\"\(id)\" isn't a valid mod id."
        }
    }
}

public struct ModSettingsSchema: Equatable, Sendable {
    public struct Option: Equatable, Hashable, Sendable {
        public var value: String
        public var title: String

        public init(value: String, title: String? = nil) {
            self.value = value
            self.title = title ?? value
        }
    }

    public enum Kind: Equatable, Sendable {
        case boolean(defaultValue: Bool?)
        case integer(minimum: Int?, maximum: Int?, step: Int?, defaultValue: Int?)
        case number(minimum: Double?, maximum: Double?, step: Double?, defaultValue: Double?)
        case string(maxLength: Int, placeholder: String?, multiline: Bool, defaultValue: String?)
        case enumeration(options: [Option], defaultValue: String?)
        case secret(placeholder: String?)
    }

    public struct Field: Identifiable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var description: String?
        public var kind: Kind
        public var id: String { key }

        public init(key: String, title: String, description: String? = nil, kind: Kind) {
            self.key = key
            self.title = title
            self.description = description
            self.kind = kind
        }

        public var isSecret: Bool {
            if case .secret = kind { return true }
            return false
        }

        public var defaultValue: ModSettingValue? {
            switch kind {
            case .boolean(let d): return .bool(d ?? false)
            case .integer(let lo, let hi, _, let d): return .integer(Self.clamp(d ?? lo ?? 0, lo, hi))
            case .number(let lo, let hi, _, let d): return .number(Self.clamp(d ?? lo ?? 0, lo, hi))
            case .string(_, _, _, let d): return .string(d ?? "")
            case .enumeration(let options, let d): return .string(d ?? options.first?.value ?? "")
            case .secret: return nil
            }
        }

        public func validate(_ value: ModSettingValue) throws -> ModSettingValue {
            switch (kind, value) {
            case (.boolean, .bool):
                return value
            case (.integer(let lo, let hi, _, _), .integer(let v)):
                if let lo, v < lo { throw ModSettingsValueError.belowMinimum(key: key, minimum: Double(lo)) }
                if let hi, v > hi { throw ModSettingsValueError.aboveMaximum(key: key, maximum: Double(hi)) }
                return value
            case (.number(let lo, let hi, _, _), .number(let v)):
                guard v.isFinite else { throw ModSettingsValueError.notFinite(key: key) }
                if let lo, v < lo { throw ModSettingsValueError.belowMinimum(key: key, minimum: lo) }
                if let hi, v > hi { throw ModSettingsValueError.aboveMaximum(key: key, maximum: hi) }
                return value
            case (.number, .integer(let v)):
                return try validate(.number(Double(v)))
            case (.string(let maxLength, _, _, _), .string(let v)):
                guard v.count <= maxLength else { throw ModSettingsValueError.tooLong(key: key, maxLength: maxLength) }
                return value
            case (.enumeration(let options, _), .string(let v)):
                guard options.contains(where: { $0.value == v }) else { throw ModSettingsValueError.notAnOption(key: key) }
                return value
            case (.secret, _):
                throw ModSettingsValueError.notStoredHere(key: key)
            case (.boolean, _): throw ModSettingsValueError.typeMismatch(key: key, expected: "on or off")
            case (.integer, _): throw ModSettingsValueError.typeMismatch(key: key, expected: "a whole number")
            case (.number, _): throw ModSettingsValueError.typeMismatch(key: key, expected: "a number")
            case (.string, _): throw ModSettingsValueError.typeMismatch(key: key, expected: "text")
            case (.enumeration, _): throw ModSettingsValueError.typeMismatch(key: key, expected: "one of the choices")
            }
        }

        private static func clamp<T: Comparable>(_ v: T, _ lo: T?, _ hi: T?) -> T {
            var out = v
            if let lo, out < lo { out = lo }
            if let hi, out > hi { out = hi }
            return out
        }
    }

    public static let maxFields = 64
    public static let maxOptions = 64
    public static let maxStringLength = 10_000
    public static let defaultStringLength = 1024
    public static let keyPattern = "^[A-Za-z][A-Za-z0-9_.-]{0,63}$"

    public var fields: [Field]

    public init(fields: [Field] = []) {
        self.fields = fields
    }

    public func field(_ key: String) -> Field? {
        fields.first { $0.key == key }
    }

    public var defaults: [String: ModSettingValue] {
        var out: [String: ModSettingValue] = [:]
        for f in fields { if let d = f.defaultValue { out[f.key] = d } }
        return out
    }

    public static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }
}

public extension ModSettingsSchema {
    static func decode(from data: Data) throws -> ModSettingsSchema {
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch {
            throw ModSettingsSchemaError(pointer: "", message: "not valid JSON")
        }
        guard let root = raw as? [String: Any] else { throw ModSettingsSchemaError(pointer: "", message: "expected an object") }
        try checkKeys(root, allowed: ["schemaVersion", "fields"], pointer: "")
        if let v = root["schemaVersion"] {
            guard let n = integer(v), n == 1 else { throw ModSettingsSchemaError(pointer: "/schemaVersion", message: "unsupported version") }
        }
        guard let list = root["fields"] as? [Any] else { throw ModSettingsSchemaError(pointer: "/fields", message: "expected an array") }
        guard list.count <= maxFields else { throw ModSettingsSchemaError(pointer: "/fields", message: "at most \(maxFields) fields") }
        var fields: [Field] = []
        var keys: Set<String> = []
        for (i, item) in list.enumerated() {
            let field = try decodeField(item, pointer: "/fields/\(i)")
            guard keys.insert(field.key).inserted else {
                throw ModSettingsSchemaError(pointer: "/fields/\(i)/key", message: "duplicate key \"\(field.key)\"")
            }
            fields.append(field)
        }
        return ModSettingsSchema(fields: fields)
    }

    private static func decodeField(_ item: Any, pointer p: String) throws -> Field {
        guard let obj = item as? [String: Any] else { throw ModSettingsSchemaError(pointer: p, message: "expected an object") }
        guard let type = obj["type"] as? String else { throw ModSettingsSchemaError(pointer: p + "/type", message: "missing field type") }
        let common: Set<String> = ["key", "type", "title", "description"]
        let key = try requiredString(obj, "key", p, maxLength: 64)
        guard key.range(of: keyPattern, options: .regularExpression) != nil else {
            throw ModSettingsSchemaError(pointer: p + "/key", message: "keys start with a letter and use letters, digits, . _ -")
        }
        let title = try requiredString(obj, "title", p, maxLength: 80)
        var description: String?
        if let d = obj["description"] {
            guard let s = d as? String, s.count <= 500 else { throw ModSettingsSchemaError(pointer: p + "/description", message: "expected text up to 500 characters") }
            description = s
        }
        let kind: Kind
        switch type {
        case "boolean":
            try checkKeys(obj, allowed: common.union(["default"]), pointer: p)
            var d: Bool?
            if let v = obj["default"] {
                guard isBool(v), let b = v as? Bool else { throw ModSettingsSchemaError(pointer: p + "/default", message: "expected true or false") }
                d = b
            }
            kind = .boolean(defaultValue: d)
        case "integer":
            try checkKeys(obj, allowed: common.union(["default", "min", "max", "step"]), pointer: p)
            let lo = try optionalInt(obj, "min", p), hi = try optionalInt(obj, "max", p)
            let step = try optionalInt(obj, "step", p), d = try optionalInt(obj, "default", p)
            if let lo, let hi, lo > hi { throw ModSettingsSchemaError(pointer: p + "/min", message: "min is greater than max") }
            if let step, step <= 0 { throw ModSettingsSchemaError(pointer: p + "/step", message: "step must be positive") }
            if let d {
                if let lo, d < lo { throw ModSettingsSchemaError(pointer: p + "/default", message: "default is below min") }
                if let hi, d > hi { throw ModSettingsSchemaError(pointer: p + "/default", message: "default is above max") }
            }
            kind = .integer(minimum: lo, maximum: hi, step: step, defaultValue: d)
        case "number":
            try checkKeys(obj, allowed: common.union(["default", "min", "max", "step"]), pointer: p)
            let lo = try optionalNumber(obj, "min", p), hi = try optionalNumber(obj, "max", p)
            let step = try optionalNumber(obj, "step", p), d = try optionalNumber(obj, "default", p)
            if let lo, let hi, lo > hi { throw ModSettingsSchemaError(pointer: p + "/min", message: "min is greater than max") }
            if let step, step <= 0 { throw ModSettingsSchemaError(pointer: p + "/step", message: "step must be positive") }
            if let d {
                if let lo, d < lo { throw ModSettingsSchemaError(pointer: p + "/default", message: "default is below min") }
                if let hi, d > hi { throw ModSettingsSchemaError(pointer: p + "/default", message: "default is above max") }
            }
            kind = .number(minimum: lo, maximum: hi, step: step, defaultValue: d)
        case "string":
            try checkKeys(obj, allowed: common.union(["default", "maxLength", "placeholder", "multiline"]), pointer: p)
            var maxLength = defaultStringLength
            if let m = try optionalInt(obj, "maxLength", p) {
                guard (1...maxStringLength).contains(m) else { throw ModSettingsSchemaError(pointer: p + "/maxLength", message: "between 1 and \(maxStringLength)") }
                maxLength = m
            }
            var d: String?
            if let v = obj["default"] {
                guard let s = v as? String else { throw ModSettingsSchemaError(pointer: p + "/default", message: "expected text") }
                guard s.count <= maxLength else { throw ModSettingsSchemaError(pointer: p + "/default", message: "default is longer than maxLength") }
                d = s
            }
            var multiline = false
            if let v = obj["multiline"] {
                guard isBool(v), let b = v as? Bool else { throw ModSettingsSchemaError(pointer: p + "/multiline", message: "expected true or false") }
                multiline = b
            }
            kind = .string(maxLength: maxLength, placeholder: try optionalString(obj, "placeholder", p), multiline: multiline, defaultValue: d)
        case "enum":
            try checkKeys(obj, allowed: common.union(["default", "options"]), pointer: p)
            guard let rawOptions = obj["options"] as? [Any], !rawOptions.isEmpty, rawOptions.count <= maxOptions else {
                throw ModSettingsSchemaError(pointer: p + "/options", message: "expected 1 to \(maxOptions) options")
            }
            var options: [Option] = []
            for (i, o) in rawOptions.enumerated() {
                let op = p + "/options/\(i)"
                if let s = o as? String, !s.isEmpty, s.count <= 80 {
                    options.append(Option(value: s))
                } else if let dict = o as? [String: Any] {
                    try checkKeys(dict, allowed: ["value", "title"], pointer: op)
                    let value = try requiredString(dict, "value", op, maxLength: 80)
                    let t = try optionalString(dict, "title", op)
                    options.append(Option(value: value, title: t))
                } else {
                    throw ModSettingsSchemaError(pointer: op, message: "expected a string or {value,title}")
                }
            }
            guard Set(options.map(\.value)).count == options.count else { throw ModSettingsSchemaError(pointer: p + "/options", message: "duplicate option values") }
            var d: String?
            if let v = obj["default"] {
                guard let s = v as? String, options.contains(where: { $0.value == s }) else {
                    throw ModSettingsSchemaError(pointer: p + "/default", message: "default must be one of the options")
                }
                d = s
            }
            kind = .enumeration(options: options, defaultValue: d)
        case "secret":
            try checkKeys(obj, allowed: common.union(["placeholder"]), pointer: p)
            kind = .secret(placeholder: try optionalString(obj, "placeholder", p))
        default:
            throw ModSettingsSchemaError(pointer: p + "/type", message: "unknown field type \"\(type)\"")
        }
        return Field(key: key, title: title, description: description, kind: kind)
    }

    private static func checkKeys(_ obj: [String: Any], allowed: Set<String>, pointer: String) throws {
        if let extra = obj.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ModSettingsSchemaError(pointer: pointer + "/" + extra, message: "unexpected property")
        }
    }

    private static func requiredString(_ obj: [String: Any], _ key: String, _ p: String, maxLength: Int) throws -> String {
        guard let s = obj[key] as? String, !s.isEmpty else { throw ModSettingsSchemaError(pointer: p + "/" + key, message: "required text") }
        guard s.count <= maxLength else { throw ModSettingsSchemaError(pointer: p + "/" + key, message: "at most \(maxLength) characters") }
        return s
    }

    private static func optionalString(_ obj: [String: Any], _ key: String, _ p: String) throws -> String? {
        guard let v = obj[key] else { return nil }
        guard let s = v as? String, s.count <= 200 else { throw ModSettingsSchemaError(pointer: p + "/" + key, message: "expected text up to 200 characters") }
        return s
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func integer(_ v: Any) -> Int? {
        guard !isBool(v), let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d == d.rounded(), abs(d) < 9e15 else { return nil }
        return n.intValue
    }

    private static func optionalInt(_ obj: [String: Any], _ key: String, _ p: String) throws -> Int? {
        guard let v = obj[key] else { return nil }
        guard let i = integer(v) else { throw ModSettingsSchemaError(pointer: p + "/" + key, message: "expected a whole number") }
        return i
    }

    private static func optionalNumber(_ obj: [String: Any], _ key: String, _ p: String) throws -> Double? {
        guard let v = obj[key] else { return nil }
        guard !isBool(v), let n = v as? NSNumber, n.doubleValue.isFinite else { throw ModSettingsSchemaError(pointer: p + "/" + key, message: "expected a number") }
        return n.doubleValue
    }
}

public protocol SecretStore: AnyObject, Sendable {
    func hasSecret(modID: String, key: String) -> Bool
    func readSecret(modID: String, key: String) throws -> String?
    func writeSecret(_ value: String, modID: String, key: String) throws
    func deleteSecret(modID: String, key: String) throws
    func deleteAllSecrets(modID: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    private func slot(_ modID: String, _ key: String) -> String { "\(modID)\u{0}\(key)" }

    public func hasSecret(modID: String, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[slot(modID, key)] != nil
    }

    public func readSecret(modID: String, key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[slot(modID, key)]
    }

    public func writeSecret(_ value: String, modID: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[slot(modID, key)] = value
    }

    public func deleteSecret(modID: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: slot(modID, key))
    }

    public func deleteAllSecrets(modID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items = items.filter { !$0.key.hasPrefix(modID + "\u{0}") }
    }
}

public struct KeychainError: LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let shared = KeychainSecretStore()

    private let servicePrefix: String

    public init(servicePrefix: String = "betterfinder.mod.") {
        self.servicePrefix = servicePrefix
    }

    private func query(_ modID: String, _ key: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + modID,
        ]
        if let key { q[kSecAttrAccount as String] = key }
        return q
    }

    public func hasSecret(modID: String, key: String) -> Bool {
        var q = query(modID, key)
        q[kSecReturnData as String] = false
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func readSecret(modID: String, key: String) throws -> String? {
        var q = query(modID, key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func writeSecret(_ value: String, modID: String, key: String) throws {
        let data = Data(value.utf8)
        let q = query(modID, key)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func deleteSecret(modID: String, key: String) throws {
        let status = SecItemDelete(query(modID, key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func deleteAllSecrets(modID: String) throws {
        let status = SecItemDelete(query(modID, nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public final class ModSettingsStore: @unchecked Sendable {
    public static let suitePrefix = "betterfinder.mod."
    public static let modIDPattern = "^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$"

    public let modID: String
    public let schema: ModSettingsSchema
    private let defaults: UserDefaults
    private let secrets: SecretStore

    public static func suiteName(for modID: String) -> String { suitePrefix + modID }

    public static func isValidModID(_ id: String) -> Bool {
        id.range(of: modIDPattern, options: .regularExpression) != nil
    }

    public init(modID: String, schema: ModSettingsSchema, defaults: UserDefaults? = nil, secrets: SecretStore = KeychainSecretStore.shared) throws {
        guard Self.isValidModID(modID) else { throw ModSettingsValueError.invalidModID(modID) }
        guard let suite = defaults ?? UserDefaults(suiteName: Self.suiteName(for: modID)) else { throw ModSettingsValueError.invalidModID(modID) }
        self.modID = modID
        self.schema = schema
        self.defaults = suite
        self.secrets = secrets
    }

    public func value(for key: String) -> ModSettingValue? {
        guard let field = schema.field(key), !field.isSecret else { return nil }
        guard let stored = defaults.object(forKey: key), let candidate = Self.decode(stored, as: field.kind),
              let valid = try? field.validate(candidate) else { return field.defaultValue }
        return valid
    }

    public var values: [String: ModSettingValue] {
        var out: [String: ModSettingValue] = [:]
        for f in schema.fields { if let v = value(for: f.key) { out[f.key] = v } }
        return out
    }

    public func isModified(_ key: String) -> Bool {
        guard let field = schema.field(key), !field.isSecret else { return false }
        return value(for: key) != field.defaultValue
    }

    @discardableResult
    public func set(_ value: ModSettingValue, for key: String) throws -> ModSettingValue {
        guard let field = schema.field(key) else { throw ModSettingsValueError.unknownKey(key) }
        let valid = try field.validate(value)
        defaults.set(valid.defaultsObject, forKey: key)
        return valid
    }

    public func reset(_ key: String) {
        defaults.removeObject(forKey: key)
    }

    public func resetAll() {
        for f in schema.fields { defaults.removeObject(forKey: f.key) }
    }

    public func hasSecret(_ key: String) -> Bool {
        guard schema.field(key)?.isSecret == true else { return false }
        return secrets.hasSecret(modID: modID, key: key)
    }

    public func setSecret(_ value: String, for key: String) throws {
        guard schema.field(key)?.isSecret == true else { throw ModSettingsValueError.unknownKey(key) }
        if value.isEmpty { try secrets.deleteSecret(modID: modID, key: key) } else { try secrets.writeSecret(value, modID: modID, key: key) }
    }

    public func clearSecret(_ key: String) throws {
        guard schema.field(key)?.isSecret == true else { throw ModSettingsValueError.unknownKey(key) }
        try secrets.deleteSecret(modID: modID, key: key)
    }

    public func eraseAllData() throws {
        defaults.removePersistentDomain(forName: Self.suiteName(for: modID))
        for f in schema.fields { defaults.removeObject(forKey: f.key) }
        try secrets.deleteAllSecrets(modID: modID)
    }

    private static func decode(_ stored: Any, as kind: ModSettingsSchema.Kind) -> ModSettingValue? {
        switch kind {
        case .boolean: return (stored as? Bool).map(ModSettingValue.bool)
        case .integer:
            guard let n = stored as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded() else { return nil }
            return .integer(n.intValue)
        case .number:
            guard let n = stored as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return .number(n.doubleValue)
        case .string, .enumeration: return (stored as? String).map(ModSettingValue.string)
        case .secret: return nil
        }
    }
}
