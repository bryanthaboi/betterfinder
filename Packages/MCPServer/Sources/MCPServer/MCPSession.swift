import Foundation
import ModKit

enum RPCCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let resourceNotFound = -32002
}

struct RPCFailure: Error {
    var code: Int
    var message: String
    var data: JSONValue?
}

enum RPC {
    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        obj(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: JSONValue?, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var e: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { e["data"] = data }
        return obj(["jsonrpc": "2.0", "id": id ?? .null, "error": .object(e)])
    }

    static func encode(_ value: JSONValue) -> Data { value.canonicalData() }
}

public final class MCPSession: @unchecked Sendable {
    public static let maxMessageBytes = 1 << 20

    private let server: MCPServer
    private let lock = NSLock()
    private var initialized = false
    private var closed = false
    private var negotiated: String?
    private var inflight = [String: Task<JSONValue?, Never>]()
    private var cancelled = Set<String>()
    public let id = Hex.random(bytes: 16)
    public private(set) var clientName: String?
    public private(set) var clientCapabilities: JSONValue = .null

    init(server: MCPServer) { self.server = server }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    public var protocolVersion: String? { lock.lock(); defer { lock.unlock() }; return negotiated }
    public var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initialized }

    public func handle(_ data: Data) async -> Data? {
        guard data.count <= Self.maxMessageBytes else {
            return RPC.encode(RPC.error(id: nil, code: RPCCode.invalidRequest, message: "message larger than \(Self.maxMessageBytes) bytes"))
        }
        let message: JSONValue
        do { message = try JSONValue.parse(data) } catch {
            return RPC.encode(RPC.error(id: nil, code: RPCCode.parseError, message: "parse error"))
        }
        guard let reply = await handle(message: message) else { return nil }
        return RPC.encode(reply)
    }

    public func handle(message: JSONValue) async -> JSONValue? {
        if case .array = message {
            return RPC.error(id: nil, code: RPCCode.invalidRequest, message: "JSON-RPC batches are not supported")
        }
        guard case .object(let o) = message, o["jsonrpc"]?.stringValue == "2.0" else {
            return RPC.error(id: nil, code: RPCCode.invalidRequest, message: "not a JSON-RPC 2.0 message")
        }
        guard let method = o["method"]?.stringValue else {
            if o["result"] != nil || o["error"] != nil { return nil }
            return RPC.error(id: o["id"], code: RPCCode.invalidRequest, message: "missing method")
        }
        let params = o["params"] ?? .object([:])
        guard let id = o["id"] else {
            await notification(method, params)
            return nil
        }
        switch id {
        case .string, .int: break
        default: return RPC.error(id: nil, code: RPCCode.invalidRequest, message: "id must be a string or integer")
        }
        guard case .object = params else {
            return RPC.error(id: id, code: RPCCode.invalidParams, message: "params must be an object")
        }
        let key = id.canonicalString()
        let task = Task<JSONValue?, Never> { [self] in
            do {
                let result = try await request(method, params)
                return RPC.response(id: id, result: result)
            } catch let e as RPCFailure {
                return RPC.error(id: id, code: e.code, message: e.message, data: e.data)
            } catch {
                return RPC.error(id: id, code: RPCCode.internalError, message: "internal error")
            }
        }
        lock.withLock { inflight[key] = task }
        let reply = await task.value
        let wasCancelled = lock.withLock { () -> Bool in
            inflight.removeValue(forKey: key)
            return cancelled.remove(key) != nil
        }
        return wasCancelled ? nil : reply
    }

    func notification(_ method: String, _ params: JSONValue) async {
        switch method {
        case "notifications/cancelled":
            guard let rid = params["requestId"] else { return }
            let key = rid.canonicalString()
            let task = lock.withLock { () -> Task<JSONValue?, Never>? in
                let t = inflight[key]
                if t != nil { cancelled.insert(key) }
                return t
            }
            task?.cancel()
        default: break
        }
    }

    func requireInitialized() throws {
        let ok = lock.withLock { initialized }
        guard ok else { throw RPCFailure(code: RPCCode.invalidRequest, message: "server not initialized; send initialize first") }
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize": return try initialize(params)
        case "ping": return obj([:])
        case "shutdown":
            lock.withLock { closed = true }
            return obj([:])
        case "tools/list":
            try requireInitialized()
            let (items, next) = try Pagination.page(server.tools.map(\.listing), cursor: params["cursor"]?.stringValue, size: server.configuration.pageSize)
            return obj(["tools": .array(items)]).merging(next)
        case "tools/call":
            try requireInitialized()
            guard let name = params["name"]?.stringValue else { throw RPCFailure(code: RPCCode.invalidParams, message: "name is required") }
            guard server.toolDefinition(name) != nil else { throw RPCFailure(code: RPCCode.invalidParams, message: "unknown tool '\(name.prefix(64))'") }
            let args = params["arguments"] ?? .object([:])
            return await server.callTool(name: name, arguments: args)
        case "resources/list":
            try requireInitialized()
            let (items, next) = try Pagination.page(MCPResources.list(server), cursor: params["cursor"]?.stringValue, size: server.configuration.pageSize)
            return obj(["resources": .array(items)]).merging(next)
        case "resources/templates/list":
            try requireInitialized()
            return obj(["resourceTemplates": .array(MCPResources.templates())])
        case "resources/read":
            try requireInitialized()
            guard let uri = params["uri"]?.stringValue else { throw RPCFailure(code: RPCCode.invalidParams, message: "uri is required") }
            guard let contents = MCPResources.read(server, uri: uri) else {
                throw RPCFailure(code: RPCCode.resourceNotFound, message: "resource not found", data: obj(["uri": uri.j]))
            }
            return obj(["contents": .array([contents])])
        case "prompts/list":
            try requireInitialized()
            let (items, next) = try Pagination.page(MCPPrompts.list(), cursor: params["cursor"]?.stringValue, size: server.configuration.pageSize)
            return obj(["prompts": .array(items)]).merging(next)
        case "prompts/get":
            try requireInitialized()
            guard let name = params["name"]?.stringValue else { throw RPCFailure(code: RPCCode.invalidParams, message: "name is required") }
            return try MCPPrompts.get(server, name: name, arguments: params["arguments"]?.objectValue ?? [:])
        default:
            throw RPCFailure(code: RPCCode.methodNotFound, message: "method not found: \(method.prefix(64))")
        }
    }

    func initialize(_ params: JSONValue) throws -> JSONValue {
        guard let requested = params["protocolVersion"]?.stringValue else {
            throw RPCFailure(code: RPCCode.invalidParams, message: "protocolVersion is required")
        }
        let version = MCPServer.protocolVersions.contains(requested) ? requested : MCPServer.protocolVersions[0]
        let fresh = lock.withLock { () -> Bool in
            if initialized { return false }
            initialized = true
            negotiated = version
            clientName = params["clientInfo"]?["name"]?.stringValue.map { String($0.prefix(80)) }
            clientCapabilities = params["capabilities"] ?? .null
            return true
        }
        guard fresh else { throw RPCFailure(code: RPCCode.invalidRequest, message: "already initialized") }
        return obj([
            "protocolVersion": version.j,
            "capabilities": obj([
                "tools": obj(["listChanged": false]),
                "resources": obj(["subscribe": false, "listChanged": false]),
                "prompts": obj(["listChanged": false]),
            ]),
            "serverInfo": obj([
                "name": MCPServer.serverName.j,
                "title": "betterfinder mod authoring".j,
                "version": server.configuration.serverVersion.j,
            ]),
            "instructions": MCPPrompts.instructions.j,
        ])
    }

    public func close() {
        let tasks = lock.withLock { () -> [Task<JSONValue?, Never>] in
            closed = true
            return Array(inflight.values)
        }
        tasks.forEach { $0.cancel() }
    }
}

extension JSONValue {
    func merging(_ extra: [String: JSONValue]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
}

enum Pagination {
    static func page(_ items: [JSONValue], cursor: String?, size: Int) throws -> ([JSONValue], [String: JSONValue]) {
        var offset = 0
        if let cursor {
            guard cursor.hasPrefix("o"), let n = Int(cursor.dropFirst()), n >= 0, n <= items.count else {
                throw RPCFailure(code: RPCCode.invalidParams, message: "invalid cursor")
            }
            offset = n
        }
        let size = max(1, size)
        let end = min(items.count, offset + size)
        let slice = Array(items[offset..<end])
        return (slice, end < items.count ? ["nextCursor": .string("o\(end)")] : [:])
    }

    static func offset(_ cursor: String?, count: Int) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.hasPrefix("o"), let n = Int(cursor.dropFirst()), n >= 0, n <= count else {
            throw ToolError("invalid_cursor", "the cursor is not valid for this listing")
        }
        return n
    }
}
