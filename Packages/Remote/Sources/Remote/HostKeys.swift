import CryptoKit
import Foundation
import FSCore

public struct SSHHostKey: Sendable, Hashable {
    public let host: String
    public let type: String
    public let base64: String

    public var fingerprint: String {
        guard let blob = Data(base64Encoded: base64) else { return "SHA256:invalid" }
        var s = Data(SHA256.hash(data: blob)).base64EncodedString()
        while s.hasSuffix("=") { s.removeLast() }
        return "SHA256:" + s
    }

    public var displayType: String {
        switch type {
        case "ssh-ed25519": return "ED25519"
        case "ssh-rsa": return "RSA"
        case let t where t.hasPrefix("ecdsa-"): return "ECDSA"
        default: return type
        }
    }

    public var knownHostsLine: String { "\(host) \(type) \(base64)" }

    public static func parse(keyscanOutput: String) -> [SSHHostKey] {
        keyscanOutput.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { return nil }
            let type = String(parts[1])
            let key = String(parts[2])
            guard type.hasPrefix("ssh-") || type.hasPrefix("ecdsa-") || type.hasPrefix("sk-"), Data(base64Encoded: key) != nil else { return nil }
            return SSHHostKey(host: String(parts[0]), type: type, base64: key)
        }
    }
}

public struct HostKeyApprovalRequest: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let keys: [SSHHostKey]

    public var displayHost: String { port == 22 ? host : "\(host):\(port)" }
}

public protocol HostKeyApproving: AnyObject, Sendable {
    func approve(_ request: HostKeyApprovalRequest) async -> Bool
}

public final class HostKeyStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    public func lines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    public func contains(host: String, port: Int) -> Bool {
        let pattern = Self.hostPattern(host: host, port: port).lowercased()
        return lines().contains { $0.split(separator: " ").first.map { $0.lowercased().split(separator: ",").contains(Substring(pattern)) } ?? false }
    }

    public func trust(_ keys: [SSHHostKey], host: String, port: Int) throws {
        let pattern = Self.hostPattern(host: host, port: port)
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        for k in keys { text += "\(pattern) \(k.type) \(k.base64)\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func forget(host: String, port: Int) throws {
        let pattern = Self.hostPattern(host: host, port: port).lowercased()
        lock.lock(); defer { lock.unlock() }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let kept = text.split(separator: "\n").filter { line in
            !(line.split(separator: " ").first.map { $0.lowercased().split(separator: ",").contains(Substring(pattern)) } ?? false)
        }
        try (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}
