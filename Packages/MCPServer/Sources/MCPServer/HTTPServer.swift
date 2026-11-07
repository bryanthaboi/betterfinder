import Foundation
import Network

public enum MCPHTTPError: Error, LocalizedError {
    case listenFailed(String)

    public var errorDescription: String? {
        switch self { case .listenFailed(let m): return "could not start the MCP HTTP listener: \(m)" }
    }
}

public final class MCPHTTPServer: @unchecked Sendable {
    static let maxHeaderBytes = 16 << 10
    static let maxConnections = 32
    static let connectionTimeout: TimeInterval = 60

    private let handler: MCPHTTPHandler
    private let requestedPort: UInt16
    private let portBox: PortBox
    private let queue = DispatchQueue(label: "betterfinder.mcp.http")
    private var listener: NWListener?
    private let lock = NSLock()
    private var connections = [ObjectIdentifier: HTTPConnection]()

    public init(handler: MCPHTTPHandler, port: PortBox, requestedPort: UInt16 = 0) {
        self.handler = handler
        self.portBox = port
        self.requestedPort = requestedPort
    }

    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        let port: NWEndpoint.Port = requestedPort == 0 ? .any : (NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw MCPHTTPError.listenFailed(error.localizedDescription) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let resumed = ResumeOnce()
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.take() { continuation.resume(throwing: MCPHTTPError.listenFailed(error.localizedDescription)) }
                case .cancelled:
                    if resumed.take() { continuation.resume(throwing: MCPHTTPError.listenFailed("cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard boundPort != 0 else { listener.cancel(); throw MCPHTTPError.listenFailed("no port was assigned") }
        portBox.port = boundPort
        lock.withLock { self.listener = listener }
        return boundPort
    }

    public func stop() {
        lock.lock()
        let l = listener
        listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        l?.cancel()
        open.forEach { $0.cancel() }
    }

    func accept(_ nw: NWConnection) {
        lock.lock()
        let tooMany = connections.count >= Self.maxConnections
        lock.unlock()
        if tooMany {
            nw.start(queue: queue)
            let c = HTTPConnection(connection: nw, handler: handler, queue: queue, onClose: { _ in })
            c.reject(503, "too many connections")
            return
        }
        let conn = HTTPConnection(connection: nw, handler: handler, queue: queue) { [weak self] id in
            self?.lock.lock()
            self?.connections.removeValue(forKey: id)
            self?.lock.unlock()
        }
        lock.lock()
        connections[ObjectIdentifier(conn)] = conn
        lock.unlock()
        conn.start()
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    let handler: MCPHTTPHandler
    let queue: DispatchQueue
    let onClose: @Sendable (ObjectIdentifier) -> Void
    var buffer = Data()
    var sentContinue = false
    var dispatched = false
    var timeout: DispatchWorkItem?

    init(connection: NWConnection, handler: MCPHTTPHandler, queue: DispatchQueue, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.handler = handler
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        let item = DispatchWorkItem { [weak self] in self?.cancel() }
        timeout = item
        queue.asyncAfter(deadline: .now() + MCPHTTPServer.connectionTimeout, execute: item)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        timeout?.cancel()
        connection.cancel()
        onClose(ObjectIdentifier(self))
    }

    func reject(_ status: Int, _ message: String) {
        send(.text(status, message))
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if error != nil { self.cancel(); return }
            self.process()
            if complete, !self.dispatched { self.cancel() }
            else if !self.dispatched { self.receive() }
        }
    }

    func process() {
        guard !dispatched else { return }
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > MCPHTTPServer.maxHeaderBytes { dispatched = true; reject(431, "headers too large") }
            return
        }
        guard range.lowerBound <= MCPHTTPServer.maxHeaderBytes else { dispatched = true; reject(431, "headers too large"); return }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ").map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { dispatched = true; reject(400, "bad request line"); return }
        var headers = [String: String]()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { dispatched = true; reject(400, "bad header"); return }
            let name = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, name == "content-length" || name == "host" || name == "authorization" { dispatched = true; reject(400, "duplicate header"); return }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { dispatched = true; reject(501, "chunked bodies are not supported"); return }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { dispatched = true; reject(400, "bad Content-Length"); return }
            length = n
        } else if first[0] == "POST" {
            dispatched = true
            reject(411, "Content-Length required")
            return
        }
        guard length <= MCPHTTPHandler.maxBodyBytes else { dispatched = true; reject(413, "body too large"); return }
        let bodyStart = range.upperBound
        let have = buffer.count - bodyStart
        if have < length {
            if headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                sentContinue = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            return
        }
        dispatched = true
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        let request = HTTPRequest(method: first[0], path: first[1], headers: headers, body: body)
        let handler = self.handler
        Task { [weak self] in
            let response = await handler.handle(request)
            self?.send(response)
        }
    }

    func send(_ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) where !v.contains("\r") && !v.contains("\n") { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if response.status != 204 { data.append(response.body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }
}
