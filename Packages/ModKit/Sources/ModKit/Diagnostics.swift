import Foundation

public enum ModKitVersion {
    public static let validator = "1.0.0"
    public static let api = "1.0.0"
    public static let manifestVersion = 1
    public static let scriptFormat = 1
    public static let toolchain = "modkit/1.0.0 bfscript/1"
}

public enum ModSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case info, warning, error

    private var rank: Int { switch self { case .info: return 0; case .warning: return 1; case .error: return 2 } }
    public static func < (a: ModSeverity, b: ModSeverity) -> Bool { a.rank < b.rank }
}

public enum ModDiagnosticCode: String, Codable, CaseIterable, Sendable {
    case invalidJSON = "BF1001"
    case unknownKey = "BF1002"
    case missingKey = "BF1003"
    case wrongType = "BF1004"
    case invalidValue = "BF1005"
    case unsupportedManifestVersion = "BF1006"
    case invalidModID = "BF1007"
    case invalidVersionOrRange = "BF1008"
    case sizeBound = "BF1009"
    case schemaViolation = "BF1010"
    case duplicateID = "BF1011"
    case reservedNamespace = "BF1012"
    case idAuthorMismatch = "BF1013"

    case unknownConstruct = "BF2001"
    case malformedProgram = "BF2002"
    case unsupportedFormat = "BF2003"
    case invalidIdentifier = "BF2004"
    case literalOutOfRange = "BF2005"
    case unknownSignature = "BF2010"
    case unsupportedSignatureVersion = "BF2011"
    case unknownFunction = "BF2012"
    case argumentCount = "BF2013"
    case typeMismatch = "BF2014"
    case unknownVariable = "BF2015"
    case duplicateVariable = "BF2016"
    case unknownField = "BF2017"
    case callNotAwaited = "BF2018"
    case missingReturn = "BF2019"
    case unboundedLoop = "BF2020"
    case loopBoundExceeded = "BF2021"
    case recursion = "BF2022"
    case callDepthExceeded = "BF2023"
    case scriptSizeLimit = "BF2024"
    case optionalAccess = "BF2026"
    case unknownType = "BF2028"
    case notIterable = "BF2029"
    case reservedName = "BF2030"
    case readOnlyVariable = "BF2031"

    case unreachableCode = "BF3001"
    case unusedVariable = "BF3002"
    case missingCancellationCheck = "BF3003"
    case unusedFunction = "BF3004"

    case missingGrant = "BF4001"
    case unusedGrant = "BF4002"
    case duplicateGrant = "BF4003"
    case privateNetworkDenied = "BF4004"
    case insecureTransport = "BF4005"
    case highTrustExec = "BF4006"
    case unknownBrokerOperation = "BF4007"
    case invalidGrantShape = "BF4008"
    case secretInSettings = "BF4009"
    case undeclaredRoot = "BF4010"

    case forbiddenFileType = "BF5001"
    case missingManifest = "BF5002"
    case pathNotContained = "BF5003"
    case pathMissing = "BF5004"
    case duplicatePath = "BF5005"
    case packageTooLarge = "BF5006"
    case entryForbidden = "BF5010"
    case entryInvalid = "BF5011"
    case handlerInDataMod = "BF5012"
    case selfDependency = "BF5020"
    case dependencyConflict = "BF5021"
    case dependencyCycle = "BF5022"
    case installedConflict = "BF5023"
    case dependencyUnsatisfied = "BF5024"
    case archivePathTraversal = "BF5030"
    case archiveSymlink = "BF5031"
    case archiveDeviceEntry = "BF5032"
    case archiveExecutableBit = "BF5033"
    case archiveBombRatio = "BF5034"
    case archiveSizeCap = "BF5035"
    case archiveDuplicateEntry = "BF5036"
    case archiveEncrypted = "BF5037"
    case archiveZip64Unsupported = "BF5038"
    case archiveNameMismatch = "BF5039"

    case apiIncompatible = "BF6001"
    case appIncompatible = "BF6002"
    case unboundedRange = "BF6003"

    case unknownReference = "BF7001"
    case missingHandlerFunction = "BF7002"
    case handlerHookMismatch = "BF7003"
    case unusedHook = "BF7004"
    case unknownHook = "BF7005"
    case unsupportedHookVersion = "BF7006"
    case duplicateHook = "BF7007"
    case duplicateKeybinding = "BF7008"
    case keybindingNoModifier = "BF7009"
    case indexMismatch = "BF7010"
    case releaseSignatureInvalid = "BF7011"
    case untrustedAuthorKey = "BF7012"
    case artifactMismatch = "BF7013"

    case tsTypeError = "BF8001"
    case tsSyntaxError = "BF8002"
    case scriptPolicyViolation = "BF8003"
    case dynamicCatalogAccess = "BF8004"
    case dryRunFailure = "BF8005"
    case dryRunTimeout = "BF8006"
    case dryRunCrash = "BF8007"

    case internalMismatch = "BF9001"
    case checkNotRun = "BF9002"

    public var defaultSeverity: ModSeverity {
        switch self {
        case .unusedGrant, .duplicateGrant, .insecureTransport, .highTrustExec, .secretInSettings,
             .unreachableCode, .unusedVariable, .missingCancellationCheck, .unusedFunction,
             .unboundedRange, .unusedHook, .keybindingNoModifier:
            return .warning
        case .checkNotRun:
            return .info
        default:
            return .error
        }
    }

    public var title: String {
        switch self {
        case .invalidJSON: return "Invalid JSON"
        case .unknownKey: return "Unknown key in closed object"
        case .missingKey: return "Missing required key"
        case .wrongType: return "Wrong JSON type"
        case .invalidValue: return "Invalid value"
        case .unsupportedManifestVersion: return "Unsupported manifest version"
        case .invalidModID: return "Invalid mod id"
        case .invalidVersionOrRange: return "Invalid semantic version or range"
        case .sizeBound: return "Size bound exceeded"
        case .schemaViolation: return "JSON Schema violation"
        case .duplicateID: return "Duplicate id"
        case .reservedNamespace: return "Reserved id namespace"
        case .idAuthorMismatch: return "Mod id is not namespaced by its author"
        case .unknownConstruct: return "Unknown script construct"
        case .malformedProgram: return "Malformed script program"
        case .unsupportedFormat: return "Unsupported script format version"
        case .invalidIdentifier: return "Invalid identifier"
        case .literalOutOfRange: return "Literal out of range"
        case .unknownSignature: return "Unknown hook signature"
        case .unsupportedSignatureVersion: return "Unsupported hook signature version"
        case .unknownFunction: return "Unknown function"
        case .argumentCount: return "Wrong number of arguments"
        case .typeMismatch: return "Type mismatch"
        case .unknownVariable: return "Unknown variable"
        case .duplicateVariable: return "Duplicate or shadowing variable"
        case .unknownField: return "Unknown record field"
        case .callNotAwaited: return "Async call not awaited"
        case .missingReturn: return "Missing return on some path"
        case .unboundedLoop: return "Loop without a valid bound"
        case .loopBoundExceeded: return "Loop bound exceeds limit"
        case .recursion: return "Recursive call"
        case .callDepthExceeded: return "Call depth exceeded"
        case .scriptSizeLimit: return "Script size or nesting limit exceeded"
        case .optionalAccess: return "Optional value used without unwrap"
        case .unknownType: return "Unknown type"
        case .notIterable: return "Value is not a list"
        case .reservedName: return "Reserved name"
        case .readOnlyVariable: return "Assignment to a read-only variable"
        case .unreachableCode: return "Unreachable code"
        case .unusedVariable: return "Unused variable"
        case .missingCancellationCheck: return "Loop without cancellation check"
        case .unusedFunction: return "Unused function"
        case .missingGrant: return "Required grant not declared"
        case .unusedGrant: return "Declared grant never used"
        case .duplicateGrant: return "Duplicate grant"
        case .privateNetworkDenied: return "Local or private network destination needs allowPrivate"
        case .insecureTransport: return "Plain HTTP endpoint"
        case .highTrustExec: return "Unrestricted process execution"
        case .unknownBrokerOperation: return "Unknown broker operation"
        case .invalidGrantShape: return "Invalid grant shape"
        case .secretInSettings: return "Secret-like setting should use credentials"
        case .undeclaredRoot: return "Root id not declared by any grant"
        case .forbiddenFileType: return "Forbidden file type in package"
        case .missingManifest: return "Package has no manifest.json"
        case .pathNotContained: return "Path escapes the package"
        case .pathMissing: return "Referenced path does not exist"
        case .duplicatePath: return "Duplicate or case-colliding path"
        case .packageTooLarge: return "Package too large"
        case .entryForbidden: return "data/1 mods must not declare an entry"
        case .entryInvalid: return "Entry missing or wrong extension for runtime"
        case .handlerInDataMod: return "data/1 mods cannot declare handlers or hooks"
        case .selfDependency: return "Mod depends on itself"
        case .dependencyConflict: return "Dependency listed as conflict"
        case .dependencyCycle: return "Dependency cycle"
        case .installedConflict: return "Conflicting mods installed together"
        case .dependencyUnsatisfied: return "Dependency missing or hash mismatch"
        case .archivePathTraversal: return "Archive entry path escapes the package"
        case .archiveSymlink: return "Archive entry is a symbolic link"
        case .archiveDeviceEntry: return "Archive entry is a device, socket or FIFO"
        case .archiveExecutableBit: return "Archive entry has an executable permission bit"
        case .archiveBombRatio: return "Archive expansion ratio exceeds limit"
        case .archiveSizeCap: return "Archive or entry size cap exceeded"
        case .archiveDuplicateEntry: return "Archive contains a duplicate entry"
        case .archiveEncrypted: return "Archive entry is encrypted"
        case .archiveZip64Unsupported: return "Archive uses unsupported ZIP64 structures"
        case .archiveNameMismatch: return "Archive entry name disagrees between headers"
        case .apiIncompatible: return "API range excludes host API"
        case .appIncompatible: return "App range excludes host app"
        case .unboundedRange: return "Version range has no upper bound"
        case .unknownReference: return "Unknown reference"
        case .missingHandlerFunction: return "Handler function not found in script"
        case .handlerHookMismatch: return "Handler is not bound to the right hook"
        case .unusedHook: return "Hook handler never referenced"
        case .unknownHook: return "Unknown hook"
        case .unsupportedHookVersion: return "Unsupported hook version"
        case .duplicateHook: return "Duplicate hook"
        case .duplicateKeybinding: return "Duplicate keybinding"
        case .keybindingNoModifier: return "Keybinding without command/control/option modifier"
        case .indexMismatch: return "Index listing does not match manifest"
        case .releaseSignatureInvalid: return "Release signature does not verify"
        case .untrustedAuthorKey: return "Release key is not a trusted key of the author"
        case .artifactMismatch: return "Release artifact does not match the listing"
        case .tsTypeError: return "TypeScript type error"
        case .tsSyntaxError: return "TypeScript syntax error"
        case .scriptPolicyViolation: return "Script violates the sandbox policy"
        case .dynamicCatalogAccess: return "Catalog accessed dynamically"
        case .dryRunFailure: return "Dry run failed"
        case .dryRunTimeout: return "Dry run timed out"
        case .dryRunCrash: return "Script host crashed during dry run"
        case .internalMismatch: return "Internal validator disagreement"
        case .checkNotRun: return "Check not run"
        }
    }
}

public struct ModDiagnostic: Codable, Equatable, Sendable, Error {
    public var code: ModDiagnosticCode
    public var severity: ModSeverity
    public var file: String?
    public var pointer: String?
    public var line: Int?
    public var column: Int?
    public var message: String
    public var fix: String?

    public init(
        _ code: ModDiagnosticCode,
        severity: ModSeverity? = nil,
        file: String? = nil,
        pointer: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        message: String,
        fix: String? = nil
    ) {
        self.code = code
        self.severity = severity ?? code.defaultSeverity
        self.file = file
        self.pointer = pointer
        self.line = line
        self.column = column
        self.message = message
        self.fix = fix
    }

    public var isError: Bool { severity == .error }
}

public extension Array where Element == ModDiagnostic {
    var hasErrors: Bool { contains { $0.severity == .error } }
    var errors: [ModDiagnostic] { filter { $0.severity == .error } }
    var warnings: [ModDiagnostic] { filter { $0.severity == .warning } }
}

public enum PreflightCheck: String, Codable, CaseIterable, Sendable {
    case schema, manifest, grants, paths, types, lint, compile, dryRun

    public static let staticChecks: [PreflightCheck] = [.schema, .manifest, .grants, .paths, .types, .lint, .compile]
}

public enum PreflightCheckStatus: String, Codable, Sendable {
    case pass, fail, notRun
}

public struct PreflightReceipt: Codable, Equatable, Sendable {
    public var ok: Bool
    public var treeHash: String
    public var validator: String
    public var api: String
    public var toolchain: String
    public var checks: [String: PreflightCheckStatus]
    public var diagnostics: [ModDiagnostic]
    public var archiveSHA256: String?

    public init(
        treeHash: String,
        validator: String = ModKitVersion.validator,
        api: String = ModKitVersion.api,
        toolchain: String = ModKitVersion.toolchain,
        checks: [PreflightCheck: PreflightCheckStatus],
        diagnostics: [ModDiagnostic],
        archiveSHA256: String? = nil
    ) {
        var raw = [String: PreflightCheckStatus]()
        for check in PreflightCheck.allCases { raw[check.rawValue] = checks[check] ?? .notRun }
        self.treeHash = treeHash
        self.validator = validator
        self.api = api
        self.toolchain = toolchain
        self.checks = raw
        self.diagnostics = diagnostics
        self.archiveSHA256 = archiveSHA256
        self.ok = !diagnostics.hasErrors && PreflightCheck.allCases.allSatisfy { raw[$0.rawValue] == .pass }
    }

    public subscript(check: PreflightCheck) -> PreflightCheckStatus { checks[check.rawValue] ?? .notRun }

    public var staticOK: Bool {
        !diagnostics.hasErrors && PreflightCheck.staticChecks.allSatisfy { self[$0] != .fail && self[$0] != .notRun }
    }

    public func merging(check: PreflightCheck, status: PreflightCheckStatus, diagnostics extra: [ModDiagnostic]) -> PreflightReceipt {
        var all = checks.reduce(into: [PreflightCheck: PreflightCheckStatus]()) { acc, kv in
            if let c = PreflightCheck(rawValue: kv.key) { acc[c] = kv.value }
        }
        all[check] = status
        return PreflightReceipt(
            treeHash: treeHash, validator: validator, api: api, toolchain: toolchain,
            checks: all, diagnostics: diagnostics + extra, archiveSHA256: archiveSHA256
        )
    }
}

public extension Encodable {
    func modKitJSON(pretty: Bool = false) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
}
