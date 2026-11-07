import Foundation
import ModKit

public struct ModValidationReport: Codable, Equatable, Sendable {
    public struct ModInfo: Codable, Equatable, Sendable {
        public var id: String
        public var version: String
        public var runtime: String
    }

    public var ok: Bool
    public var staticOK: Bool
    public var treeHash: String
    public var archiveSHA256: String?
    public var validator: String
    public var api: String
    public var toolchain: String
    public var checks: [String: PreflightCheckStatus]
    public var diagnostics: [ModDiagnostic]
    public var mod: ModInfo?

    public init(_ result: ModValidationResult) {
        let r = result.receipt
        ok = r.ok
        staticOK = r.staticOK
        treeHash = r.treeHash
        archiveSHA256 = result.archiveSHA256
        validator = r.validator
        api = r.api
        toolchain = r.toolchain
        checks = r.checks
        diagnostics = r.diagnostics
        mod = result.manifest.map { ModInfo(id: $0.id, version: $0.version.description, runtime: $0.runtime.rawValue) }
    }

    public init(receipt r: PreflightReceipt) {
        ok = r.ok
        staticOK = r.staticOK
        treeHash = r.treeHash
        archiveSHA256 = nil
        validator = r.validator
        api = r.api
        toolchain = r.toolchain
        checks = r.checks
        diagnostics = r.diagnostics
        mod = nil
    }
}

public enum ModReportRenderer {
    public static func json(_ result: ModValidationResult, pretty: Bool = true) -> String {
        String(decoding: ModValidationReport(result).modKitJSON(pretty: pretty), as: UTF8.self)
    }

    public static func json(receipt: PreflightReceipt, pretty: Bool = true) -> String {
        String(decoding: ModValidationReport(receipt: receipt).modKitJSON(pretty: pretty), as: UTF8.self)
    }

    public static func location(_ d: ModDiagnostic) -> String {
        var s = d.file ?? "<package>"
        if let line = d.line {
            s += ":\(line)"
            if let col = d.column { s += ":\(col)" }
        }
        if let p = d.pointer, !p.isEmpty { s += " (\(p))" }
        return s
    }

    public static func text(_ result: ModValidationResult, subject: String? = nil) -> String {
        let r = result.receipt
        var lines = [String]()
        let errors = r.diagnostics.filter { $0.severity == .error }.count
        let warnings = r.diagnostics.filter { $0.severity == .warning }.count
        let infos = r.diagnostics.filter { $0.severity == .info }.count
        let name = result.manifest.map { "\($0.id) \($0.version)" } ?? subject ?? "package"
        let verdict: String
        if errors > 0 { verdict = "FAIL" } else if r.ok { verdict = "PASS" } else { verdict = "INCOMPLETE" }
        lines.append("\(verdict) \(name)")
        for d in r.diagnostics {
            lines.append("\(location(d)): \(d.severity.rawValue) \(d.code.rawValue): \(d.message)")
            if let fix = d.fix { lines.append("    fix: \(fix)") }
        }
        if !r.diagnostics.isEmpty { lines.append("") }
        lines.append("checks: " + PreflightCheck.allCases.map { "\($0.rawValue)=\(r[$0].rawValue)" }.joined(separator: " "))
        lines.append("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")" + (infos > 0 ? ", \(infos) note\(infos == 1 ? "" : "s")" : ""))
        lines.append("tree sha256: \(r.treeHash)")
        if let a = result.archiveSHA256 { lines.append("archive sha256: \(a)") }
        lines.append("validator \(r.validator), api \(r.api), \(r.toolchain)")
        return lines.joined(separator: "\n") + "\n"
    }
}
