import Foundation

public indirect enum ModTypeExpr: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    case string, integer, number, boolean, null, void, json
    case list(ModTypeExpr)
    case optional(ModTypeExpr)
    case ref(String)

    public static let primitiveNames: [String: ModTypeExpr] = [
        "string": .string, "integer": .integer, "number": .number, "boolean": .boolean,
        "null": .null, "void": .void, "json": .json,
    ]

    public var description: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .null: return "null"
        case .void: return "void"
        case .json: return "json"
        case .list(let t): return "\(t.parenthesizedIfOptional)[]"
        case .optional(let t): return "\(t)?"
        case .ref(let n): return n
        }
    }

    private var parenthesizedIfOptional: String {
        if case .optional = self { return "(\(self))" }
        return description
    }

    public static func parse(_ value: JSONValue) -> ModTypeExpr? {
        switch value {
        case .string(let s):
            if let p = primitiveNames[s] { return p }
            guard ModPatterns.matches(s, "^[A-Z][A-Za-z0-9]{0,47}$") else { return nil }
            return .ref(s)
        case .object(let o):
            guard o.count == 1, let (k, v) = o.first else { return nil }
            guard let inner = parse(v) else { return nil }
            switch k {
            case "list": return .list(inner)
            case "optional": return .optional(inner)
            default: return nil
            }
        default: return nil
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .list(let t): return .object(["list": t.jsonValue])
        case .optional(let t): return .object(["optional": t.jsonValue])
        default: return .string(description)
        }
    }

    public init(from decoder: Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let t = ModTypeExpr.parse(v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "BF2028|invalid type expression"))
        }
        self = t
    }

    public func encode(to encoder: Encoder) throws { try jsonValue.encode(to: encoder) }
}

public struct ModField: Codable, Equatable, Sendable {
    public var name: String
    public var type: ModTypeExpr
    public var optional: Bool
    public var doc: String

    public init(_ name: String, _ type: ModTypeExpr, optional: Bool = false, doc: String = "") {
        self.name = name; self.type = type; self.optional = optional; self.doc = doc
    }
}

public struct ModTypeDef: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case record, `enum`, alias }
    public var name: String
    public var kind: Kind
    public var doc: String
    public var fields: [ModField]?
    public var cases: [String]?
    public var aliasOf: ModTypeExpr?

    public static func record(_ name: String, _ doc: String, _ fields: [ModField]) -> ModTypeDef {
        ModTypeDef(name: name, kind: .record, doc: doc, fields: fields, cases: nil, aliasOf: nil)
    }

    public static func enumeration(_ name: String, _ doc: String, _ cases: [String]) -> ModTypeDef {
        ModTypeDef(name: name, kind: .enum, doc: doc, fields: nil, cases: cases, aliasOf: nil)
    }

    public static func alias(_ name: String, _ doc: String, _ of: ModTypeExpr) -> ModTypeDef {
        ModTypeDef(name: name, kind: .alias, doc: doc, fields: nil, cases: nil, aliasOf: of)
    }
}

public struct ModParam: Codable, Equatable, Sendable {
    public var name: String
    public var type: ModTypeExpr
    public var optional: Bool
    public var doc: String

    public init(_ name: String, _ type: ModTypeExpr, optional: Bool = false, doc: String = "") {
        self.name = name; self.type = type; self.optional = optional; self.doc = doc
    }
}

public enum ModFailurePolicy: String, Codable, Sendable {
    case reject, pause, ignore, degrade

    public var summary: String {
        switch self {
        case .reject: return "The call rejects with a BFError; an unhandled rejection fails the invoking hook."
        case .pause: return "Error or timeout pauses the operation before any mutation; only a native user decision may bypass."
        case .ignore: return "Failures are logged and ignored; the host never retries or repeats work because of them."
        case .degrade: return "Failures degrade the affected item (placeholder or empty) and mark the contribution unhealthy."
        }
    }
}

public struct GrantRequirement: Codable, Equatable, Sendable {
    public var kind: ModPermissionKind
    public var scopes: [String]?
    public var surfaces: [ModSurface]?
    public var brokerOperation: String?
    public var mode: ProcessMode?
    public var recursive: Bool?
    public var fileOperation: FileOperationName?
    public var note: String?

    public init(
        _ kind: ModPermissionKind, scopes: [String]? = nil, surfaces: [ModSurface]? = nil,
        brokerOperation: String? = nil, mode: ProcessMode? = nil, recursive: Bool? = nil,
        fileOperation: FileOperationName? = nil, note: String? = nil
    ) {
        self.kind = kind; self.scopes = scopes; self.surfaces = surfaces; self.brokerOperation = brokerOperation
        self.mode = mode; self.recursive = recursive; self.fileOperation = fileOperation; self.note = note
    }

    public var summary: String {
        var parts = [kind.rawValue]
        if let s = scopes { parts.append("scope: " + s.joined(separator: "|")) }
        if let s = surfaces { parts.append("surfaces: " + s.map(\.rawValue).joined(separator: ",")) }
        if let b = brokerOperation { parts.append("operation: \(b)") }
        if let m = mode { parts.append("mode: \(m.rawValue)") }
        if recursive == true { parts.append("recursive") }
        if let f = fileOperation { parts.append("fileOperation: \(f.rawValue)") }
        return parts.count == 1 ? parts[0] : "\(parts[0]) (\(parts.dropFirst().joined(separator: "; ")))"
    }

    public static func fsRead(_ scopes: [String] = ["selection", "root"], recursive: Bool? = nil) -> GrantRequirement {
        GrantRequirement(.fsRead, scopes: scopes, recursive: recursive)
    }

    public static func fsWrite(_ scopes: [String] = ["selection", "root", "destination"]) -> GrantRequirement {
        GrantRequirement(.fsWrite, scopes: scopes)
    }

    public static func ui(_ surface: ModSurface) -> GrantRequirement { GrantRequirement(.ui, surfaces: [surface]) }
    public static func broker(_ op: String) -> GrantRequirement { GrantRequirement(.processExec, brokerOperation: op) }
}

public struct ModFunction: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
    public var params: [ModParam]
    public var returns: ModTypeExpr
    public var requires: [GrantRequirement]
    public var deadlineMs: Int
    public var cancellable: Bool
    public var failure: ModFailurePolicy
    public var errors: [String]
    public var gesture: Bool
    public var batchLimit: Int?

    public var namespace: String { String(name.split(separator: ".", maxSplits: 1)[0]) }
    public var member: String { String(name.split(separator: ".", maxSplits: 1)[1]) }
}

public struct ModHookSignature: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    public var summary: String
    public var input: ModTypeExpr
    public var output: ModTypeExpr
    public var requires: [GrantRequirement]
    public var deadlineMs: Int
    public var cancellable: Bool
    public var failure: ModFailurePolicy
    public var multiple: Bool
    public var contribution: String?

    public var signatureID: String { "\(name)@\(version)" }
}

public struct ModNamespaceDoc: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
}

public struct ModContributionDoc: Codable, Equatable, Sendable {
    public var key: String
    public var surface: ModSurface?
    public var hook: String?
    public var summary: String
}

public struct ModPermissionDoc: Codable, Equatable, Sendable {
    public var kind: ModPermissionKind
    public var required: [String]
    public var optional: [String]
    public var summary: String
}

public struct ModBrokerOperation: Codable, Equatable, Sendable {
    public var name: String
    public var function: String
    public var summary: String
}

public struct ModDiagnosticDoc: Codable, Equatable, Sendable {
    public var code: String
    public var severity: ModSeverity
    public var title: String
}

public struct ModCatalogLimits: Codable, Equatable, Sendable {
    public var manifestBytes: Int
    public var scriptBytes: Int
    public var callbackWatchdogMs: Int
    public var controlMessageBytes: Int
    public var batchItems: Int
    public var hostRSSRestartMiB: Int
    public var maxPermissions: Int
    public var maxContributionsPerKind: Int
    public var maxHooks: Int
    public var maxSettings: Int
    public var maxDependencies: Int
    public var maxConflicts: Int
    public var maxStringBytes: Int
    public var maxReasonBytes: Int
    public var maxPackageBytes: Int
    public var maxPackageFiles: Int
    public var maxFunctions: Int
    public var maxNesting: Int
    public var maxExprDepth: Int
    public var maxLoopBound: Int
    public var maxLoopIterations: Int
    public var maxLoopNesting: Int
    public var maxCallDepth: Int
    public var maxStatements: Int

    public static let v1 = ModCatalogLimits(
        manifestBytes: 256 * 1024, scriptBytes: 1024 * 1024, callbackWatchdogMs: 250, controlMessageBytes: 1024 * 1024,
        batchItems: 128, hostRSSRestartMiB: 128, maxPermissions: 64, maxContributionsPerKind: 64, maxHooks: 128,
        maxSettings: 128, maxDependencies: 16, maxConflicts: 16, maxStringBytes: 4096, maxReasonBytes: 400,
        maxPackageBytes: 64 * 1024 * 1024, maxPackageFiles: 2048, maxFunctions: 64, maxNesting: 16, maxExprDepth: 32,
        maxLoopBound: 10_000, maxLoopIterations: 1_000_000, maxLoopNesting: 3, maxCallDepth: 8, maxStatements: 2048
    )
}

public struct ModCatalog: Sendable {
    public var catalogVersion: String
    public var manifestVersion: Int
    public var scriptFormat: Int
    public var toolchain: String
    public var limits: ModCatalogLimits
    public var namespaces: [ModNamespaceDoc]
    public var types: [ModTypeDef]
    public var functions: [ModFunction]
    public var hooks: [ModHookSignature]
    public var permissions: [ModPermissionDoc]
    public var contributions: [ModContributionDoc]
    public var brokerOperations: [ModBrokerOperation]
    public var diagnostics: [ModDiagnosticDoc]

    private var typeIndex: [String: Int] = [:]
    private var functionIndex: [String: Int] = [:]
    private var hookIndex: [String: Int] = [:]

    public init(
        catalogVersion: String, manifestVersion: Int, scriptFormat: Int, toolchain: String, limits: ModCatalogLimits,
        namespaces: [ModNamespaceDoc], types: [ModTypeDef], functions: [ModFunction], hooks: [ModHookSignature],
        permissions: [ModPermissionDoc], contributions: [ModContributionDoc], brokerOperations: [ModBrokerOperation],
        diagnostics: [ModDiagnosticDoc]
    ) {
        self.catalogVersion = catalogVersion; self.manifestVersion = manifestVersion; self.scriptFormat = scriptFormat
        self.toolchain = toolchain; self.limits = limits; self.namespaces = namespaces; self.types = types
        self.functions = functions; self.hooks = hooks; self.permissions = permissions
        self.contributions = contributions; self.brokerOperations = brokerOperations; self.diagnostics = diagnostics
        rebuildIndexes()
    }

    private mutating func rebuildIndexes() {
        typeIndex = Dictionary(uniqueKeysWithValues: types.enumerated().map { ($1.name, $0) })
        functionIndex = Dictionary(uniqueKeysWithValues: functions.enumerated().map { ($1.name, $0) })
        hookIndex = Dictionary(uniqueKeysWithValues: hooks.enumerated().map { ($1.signatureID, $0) })
    }

    public func type(named name: String) -> ModTypeDef? { typeIndex[name].map { types[$0] } }
    public func function(named name: String) -> ModFunction? { functionIndex[name].map { functions[$0] } }
    public func hook(named name: String, version: Int) -> ModHookSignature? { hookIndex["\(name)@\(version)"].map { hooks[$0] } }
    public func hook(signature: String) -> ModHookSignature? { hookIndex[signature].map { hooks[$0] } }
    public func hooks(named name: String) -> [ModHookSignature] { hooks.filter { $0.name == name } }
    public var hookNames: [String] { Array(Set(hooks.map(\.name))).sorted() }
    public var latestHookVersions: [String: Int] {
        var out = [String: Int]()
        for h in hooks { out[h.name] = max(out[h.name] ?? 0, h.version) }
        return out
    }
    public func brokerOperation(named name: String) -> ModBrokerOperation? { brokerOperations.first { $0.name == name } }
    public func functions(in namespace: String) -> [ModFunction] { functions.filter { $0.namespace == namespace } }
}

extension ModCatalog: Codable {
    enum CodingKeys: String, CodingKey {
        case catalogVersion, manifestVersion, scriptFormat, toolchain, limits, namespaces, types, functions, hooks
        case permissions, contributions, brokerOperations, diagnostics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            catalogVersion: try c.decode(String.self, forKey: .catalogVersion),
            manifestVersion: try c.decode(Int.self, forKey: .manifestVersion),
            scriptFormat: try c.decode(Int.self, forKey: .scriptFormat),
            toolchain: try c.decode(String.self, forKey: .toolchain),
            limits: try c.decode(ModCatalogLimits.self, forKey: .limits),
            namespaces: try c.decode([ModNamespaceDoc].self, forKey: .namespaces),
            types: try c.decode([ModTypeDef].self, forKey: .types),
            functions: try c.decode([ModFunction].self, forKey: .functions),
            hooks: try c.decode([ModHookSignature].self, forKey: .hooks),
            permissions: try c.decode([ModPermissionDoc].self, forKey: .permissions),
            contributions: try c.decode([ModContributionDoc].self, forKey: .contributions),
            brokerOperations: try c.decode([ModBrokerOperation].self, forKey: .brokerOperations),
            diagnostics: try c.decode([ModDiagnosticDoc].self, forKey: .diagnostics)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(catalogVersion, forKey: .catalogVersion)
        try c.encode(manifestVersion, forKey: .manifestVersion)
        try c.encode(scriptFormat, forKey: .scriptFormat)
        try c.encode(toolchain, forKey: .toolchain)
        try c.encode(limits, forKey: .limits)
        try c.encode(namespaces, forKey: .namespaces)
        try c.encode(types, forKey: .types)
        try c.encode(functions, forKey: .functions)
        try c.encode(hooks, forKey: .hooks)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(contributions, forKey: .contributions)
        try c.encode(brokerOperations, forKey: .brokerOperations)
        try c.encode(diagnostics, forKey: .diagnostics)
    }

    public static func decode(jsonData: Data) throws -> ModCatalog { try JSONDecoder().decode(ModCatalog.self, from: jsonData) }

    public var jsonData: Data { modKitJSON(pretty: true) }

    public var digest: String { SHA256.hex(modKitJSON(pretty: false)) }
}

extension ModCatalog: Equatable {
    public static func == (a: ModCatalog, b: ModCatalog) -> Bool { a.jsonData == b.jsonData }
}
