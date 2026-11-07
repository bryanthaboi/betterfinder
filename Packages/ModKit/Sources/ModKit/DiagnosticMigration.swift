import Foundation

public enum ModLegacyContext: Equatable, Sendable {
    case archive
    case typeScript(code: Int)
    case catalogAnalysis
    case dryRun
}

public extension ModDiagnosticCode {
    static func legacyMapping(_ code: ModDiagnosticCode, context: ModLegacyContext, message: String = "") -> ModDiagnosticCode {
        let text = message.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        switch context {
        case .archive:
            if has("zip64") { return .archiveZip64Unsupported }
            if has("local header name differs") { return .archiveNameMismatch }
            if has("encrypted") { return .archiveEncrypted }
            if has("symbolic link") { return .archiveSymlink }
            if has("device, socket or fifo") { return .archiveDeviceEntry }
            if has("executable permission bit") { return .archiveExecutableBit }
            if has(":1; limit", "zip quine", "overlap") { return .archiveBombRatio }
            if has("expansion bomb", "expands to more than", "expands beyond") { return .archiveSizeCap }
            switch code {
            case .pathNotContained: return .archivePathTraversal
            case .duplicatePath: return .archiveDuplicateEntry
            case .packageTooLarge: return .archiveSizeCap
            default: return code
            }
        case .typeScript(let ts):
            switch ts {
            case 90002, 90003: return .scriptPolicyViolation
            case 90001, 90004: return code
            case 1000..<2000: return .tsSyntaxError
            default: return code == .typeMismatch ? .tsTypeError : code
            }
        case .catalogAnalysis:
            return code == .unknownConstruct ? .dynamicCatalogAccess : code
        case .dryRun:
            guard code == .checkNotRun || code == .internalMismatch else { return code }
            if has("deadline", "timed out", "timeout") { return .dryRunTimeout }
            if has("crash", "terminated", "did not start", "failed to start", "exited") { return .dryRunCrash }
            return .dryRunFailure
        }
    }

    func migrated(_ context: ModLegacyContext, message: String = "") -> ModDiagnosticCode {
        ModDiagnosticCode.legacyMapping(self, context: context, message: message)
    }
}

public extension ModDiagnostic {
    func migrated(_ context: ModLegacyContext) -> ModDiagnostic {
        var copy = self
        copy.code = ModDiagnosticCode.legacyMapping(code, context: context, message: message)
        if copy.code != code, severity == .info { copy.severity = copy.code.defaultSeverity }
        return copy
    }
}
