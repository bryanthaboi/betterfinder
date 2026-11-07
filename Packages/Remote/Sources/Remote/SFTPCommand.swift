import Foundation
import FSCore

public enum SFTPCommand: Sendable, Hashable {
    case pwd
    case list(String)
    case get(remote: String, local: String)
    case put(local: String, remote: String)
    case rename(String, String)
    case remove(String)
    case removeDirectory(String)
    case makeDirectory(String)
    indirect case ignoringErrors(SFTPCommand)

    public static func lenient(_ c: SFTPCommand) -> SFTPCommand {
        if case .ignoringErrors = c { return c }
        return .ignoringErrors(c)
    }

    public var isIdempotent: Bool {
        switch self {
        case .pwd, .list, .get: return true
        case .ignoringErrors(let c): return c.isIdempotent
        default: return false
        }
    }

    public static func validate(_ path: String) throws {
        guard !path.isEmpty else { throw ResourceError.invalidName(path) }
        for s in path.unicodeScalars where s.value < 0x20 || s.value == 0x7F || s == "\\" {
            throw ResourceError.invalidName(path)
        }
    }

    public static func quote(_ path: String) throws -> String {
        try validate(path)
        var out = ""
        for ch in path {
            switch ch {
            case " ", "\"", "'", "*", "?", "[", "#": out += "\\" + String(ch)
            default: out.append(ch)
            }
        }
        return out
    }

    public func render() throws -> String {
        switch self {
        case .pwd: return "pwd"
        case .list(let p): return "ls -lan \(try Self.quote(p))"
        case .get(let r, let l): return "get \(try Self.quote(r)) \(try Self.quote(l))"
        case .put(let l, let r): return "put \(try Self.quote(l)) \(try Self.quote(r))"
        case .rename(let a, let b): return "rename \(try Self.quote(a)) \(try Self.quote(b))"
        case .remove(let p): return "rm \(try Self.quote(p))"
        case .removeDirectory(let p): return "rmdir \(try Self.quote(p))"
        case .makeDirectory(let p): return "mkdir \(try Self.quote(p))"
        case .ignoringErrors(let c):
            if case .ignoringErrors = c { return try c.render() }
            return "-" + (try c.render())
        }
    }

    public static func batch(_ commands: [SFTPCommand]) throws -> String {
        try commands.map { try $0.render() }.joined(separator: "\n") + "\n"
    }
}

public struct SFTPBatchOutput: Sendable {
    public let sections: [String]
    public let stderr: String

    static func parse(stdout: String, stderr: String) -> SFTPBatchOutput {
        var sections: [String] = []
        var current: [Substring]?
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("sftp> ") {
                if let current { sections.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let current { sections.append(current.joined(separator: "\n")) }
        return SFTPBatchOutput(sections: sections, stderr: stderr)
    }

    public var executedCount: Int { sections.count }
}
