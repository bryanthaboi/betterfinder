import Foundation
import ModKit

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method
        self.path = path
        var h = [String: String]()
        for (k, v) in headers { h[k.lowercased()] = v }
        self.headers = h
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int, _ value: JSONValue, headers: [String: String] = [:]) -> HTTPResponse {
        var h = headers
        h["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: h, body: value.canonicalData())
    }

    static func text(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        var h = headers
        h["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: h, body: Data(message.utf8))
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

public final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0
    public init() {}
    public var port: UInt16 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

final class HTTPSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions = [String: (session: MCPSession, used: Date)]()
    private let limit = 32

    func add(_ s: MCPSession) {
        lock.lock()
        defer { lock.unlock() }
        if sessions.count >= limit, let oldest = sessions.min(by: { $0.value.used < $1.value.used })?.key {
            sessions[oldest]?.session.close()
            sessions.removeValue(forKey: oldest)
        }
        sessions[s.id] = (s, Date())
    }

    func get(_ id: String) -> MCPSession? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = sessions[id] else { return nil }
        entry.used = Date()
        sessions[id] = entry
        return entry.session
    }

    func remove(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let e = sessions.removeValue(forKey: id) else { return false }
        e.session.close()
        return true
    }
}

public final class MCPHTTPHandler: @unchecked Sendable {
    public static let maxBodyBytes = MCPSession.maxMessageBytes
    static let sessionHeader = "mcp-session-id"

    let server: MCPServer
    let tokens: MCPTokenStore
    let portBox: PortBox
    let extraOrigins: Set<String>
    let bridge: LiveBridge?
    let sessions = HTTPSessions()

    public init(server: MCPServer, tokens: MCPTokenStore, port: PortBox, allowedOrigins: [String] = [], exposeLiveBridge: Bool = true) {
        self.server = server
        self.tokens = tokens
        self.portBox = port
        self.extraOrigins = Set(allowedOrigins.map { $0.lowercased() })
        self.bridge = exposeLiveBridge ? LiveBridge(live: server.configuration.live, workspaces: server.configuration.workspaces) : nil
    }

    var allowedHosts: Set<String> {
        let p = portBox.port
        return ["127.0.0.1:\(p)", "localhost:\(p)", "[::1]:\(p)"]
    }

    var allowedOrigins: Set<String> {
        let p = portBox.port
        return extraOrigins.union(["http://127.0.0.1:\(p)", "http://localhost:\(p)", "http://[::1]:\(p)"])
    }

    func bearer(_ request: HTTPRequest) -> String? {
        guard let value = request.headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let host = request.headers["host"] else { return .text(400, "missing Host header") }
        guard allowedHosts.contains(host.lowercased()) else { return .text(403, "Host not allowed") }
        if let origin = request.headers["origin"], !allowedOrigins.contains(origin.lowercased()) {
            return .text(403, "Origin not allowed")
        }
        guard let token = bearer(request), tokens.matches(token) else {
            return .text(401, "missing or invalid bearer token", headers: ["WWW-Authenticate": "Bearer realm=\"betterfinder-mod\""])
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        if path == "/mcp" { return await handleMCP(request) }
        if path.hasPrefix("/live/"), let bridge {
            guard request.method == "POST" else { return .text(405, "use POST", headers: ["Allow": "POST"]) }
            return await bridge.handle(op: String(path.dropFirst("/live/".count)), body: request.body)
        }
        return .text(404, "not found")
    }

    func handleMCP(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.method {
        case "POST": break
        case "DELETE":
            guard let id = request.headers[Self.sessionHeader] else { return .text(400, "missing Mcp-Session-Id") }
            return sessions.remove(id) ? HTTPResponse(status: 204) : .text(404, "unknown session")
        case "GET": return .text(405, "this server does not offer a server-initiated stream", headers: ["Allow": "POST, DELETE"])
        default: return .text(405, "method not allowed", headers: ["Allow": "POST, DELETE"])
        }
        let type = request.headers["content-type"]?.lowercased() ?? ""
        guard type.hasPrefix("application/json") else { return .text(415, "Content-Type must be application/json") }
        guard request.body.count <= Self.maxBodyBytes else { return .text(413, "body too large") }
        if let version = request.headers["mcp-protocol-version"], !MCPServer.protocolVersions.contains(version) {
            return .text(400, "unsupported MCP-Protocol-Version")
        }
        guard let message = try? JSONValue.parse(request.body), case .object(let o) = message else {
            return .json(400, RPC.error(id: nil, code: RPCCode.parseError, message: "parse error"))
        }
        let isInitialize = o["method"]?.stringValue == "initialize" && o["id"] != nil
        let session: MCPSession
        var extra = [String: String]()
        if isInitialize {
            session = server.makeSession()
            sessions.add(session)
            extra["Mcp-Session-Id"] = session.id
        } else {
            guard let id = request.headers[Self.sessionHeader] else { return .text(400, "missing Mcp-Session-Id; send initialize first") }
            guard let existing = sessions.get(id) else { return .text(404, "unknown or expired session") }
            session = existing
        }
        guard let reply = await session.handle(message: message) else { return HTTPResponse(status: 202) }
        if isInitialize, case .object(let r) = reply, r["error"] != nil { _ = sessions.remove(session.id); extra.removeValue(forKey: "Mcp-Session-Id") }
        return .json(200, reply, headers: extra)
    }
}
