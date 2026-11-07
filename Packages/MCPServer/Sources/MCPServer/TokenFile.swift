import Foundation

public struct MCPEndpointInfo: Codable, Equatable, Sendable {
    public var version: Int
    public var transport: String
    public var url: String
    public var token: String
    public var pid: Int32
    public var startedAt: String

    public init(url: String, token: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier, startedAt: String, version: Int = 1, transport: String = "streamable-http") {
        self.version = version
        self.transport = transport
        self.url = url
        self.token = token
        self.pid = pid
        self.startedAt = startedAt
    }

    public var baseURL: URL? {
        guard var comps = URLComponents(string: url), let host = comps.host, MCPTokenFile.isLoopback(host) else { return nil }
        comps.path = ""
        return comps.url
    }
}

public enum MCPTokenFile {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("betterfinder", isDirectory: true)
    }

    public static var standardURL: URL { supportDirectory.appendingPathComponent("mcp.json") }
    public static var cliURL: URL { supportDirectory.appendingPathComponent("mcp-cli.json") }

    public static func isLoopback(_ host: String) -> Bool { ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) }

    public static func write(_ info: MCPEndpointInfo, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(info)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        chmod(temp.path, 0o600)
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        chmod(url.path, 0o600)
    }

    public static func read(from url: URL) -> MCPEndpointInfo? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path), let info = try? JSONDecoder().decode(MCPEndpointInfo.self, from: data) else { return nil }
        guard info.version == 1, info.token.count >= 32 else { return nil }
        return info
    }

    public static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

public final class MCPTokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    public init(token: String? = nil) { current = token ?? Hex.random(bytes: 32) }

    public var token: String { lock.lock(); defer { lock.unlock() }; return current }

    public func rotate() -> String {
        lock.lock()
        defer { lock.unlock() }
        current = Hex.random(bytes: 32)
        return current
    }

    public func matches(_ candidate: String) -> Bool {
        let expected = Array(token.utf8)
        let given = Array(candidate.utf8)
        var diff = UInt8(truncatingIfNeeded: expected.count ^ given.count)
        for i in 0..<max(expected.count, given.count) {
            diff |= (i < expected.count ? expected[i] : 0) ^ (i < given.count ? given[i] : 0)
        }
        return diff == 0
    }
}
