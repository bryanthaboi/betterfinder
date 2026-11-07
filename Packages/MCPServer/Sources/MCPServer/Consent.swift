import Foundation
import ModKit

public final class ConsentLedger: @unchecked Sendable {
    struct Entry {
        var tool: String
        var digest: String
        var expires: Date
        var issued: Date
    }

    private let lock = NSLock()
    private var entries = [String: Entry]()
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let capacity = 64

    public init(ttl: TimeInterval = 600, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.clock = clock
    }

    public func issue(tool: String, digest: String) -> (token: String, expires: Date) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        entries = entries.filter { $0.value.expires > now }
        while entries.count >= capacity, let oldest = entries.min(by: { $0.value.issued < $1.value.issued })?.key { entries.removeValue(forKey: oldest) }
        let token = Hex.random(bytes: 24)
        let expires = now.addingTimeInterval(ttl)
        entries[token] = Entry(tool: tool, digest: digest, expires: expires, issued: now)
        return (token, expires)
    }

    public func consume(token: String?, tool: String, digest: String) throws {
        guard let token, !token.isEmpty else {
            throw ToolError("consent_required", "confirm:true needs the confirmationToken returned by a dry-run call of \(tool); call \(tool) without confirm first and show its review to the user")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: token) else {
            throw ToolError("consent_invalid", "the confirmationToken is unknown or was already used; run a new dry-run of \(tool) and get the user's approval again")
        }
        guard entry.expires > clock() else {
            throw ToolError("consent_expired", "the confirmationToken expired; run a new dry-run of \(tool) and get the user's approval again")
        }
        guard entry.tool == tool, entry.digest == digest else {
            throw ToolError("consent_mismatch", "the action changed since the dry-run was reviewed; run a new dry-run of \(tool) and show the user the new review")
        }
    }

    public var outstanding: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

enum Redactor {
    static let patterns: [(String, String)] = [
        ("gh[pousr]_[A-Za-z0-9]{20,}", "***"),
        ("github_pat_[A-Za-z0-9_]{20,}", "***"),
        ("(?i)bearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer ***"),
        ("https://[^/\\s:@]+:[^@\\s]+@", "https://***@"),
        ("(?i)((?:token|password|secret|authorization)[\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;]{6,}", "$1***"),
    ]

    static func redact(_ text: String) -> String {
        var out = text
        for (pattern, template) in patterns {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    static func clean(_ text: String, limit: Int = 2000) -> String {
        var scalars = String.UnicodeScalarView()
        for s in redact(text).unicodeScalars {
            if s == "\n" || s == "\t" || (s.value >= 0x20 && s.value != 0x7f) { scalars.append(s) }
            else { scalars.append("\u{FFFD}") }
        }
        let cleaned = String(scalars)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }
}
