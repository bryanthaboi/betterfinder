import Foundation
import ModKit
import ModValidation

public struct MCPServerHostConfiguration: Sendable {
    public var server: MCPServerConfiguration
    public var tokenFile: URL
    public var port: UInt16
    public var allowedOrigins: [String]
    public var exposeLiveBridge: Bool

    public init(
        server: MCPServerConfiguration = MCPServerConfiguration(), tokenFile: URL = MCPTokenFile.standardURL, port: UInt16 = 0,
        allowedOrigins: [String] = [], exposeLiveBridge: Bool = true
    ) {
        self.server = server
        self.tokenFile = tokenFile
        self.port = port
        self.allowedOrigins = allowedOrigins
        self.exposeLiveBridge = exposeLiveBridge
    }
}

public final class MCPServerHost: @unchecked Sendable {
    public let server: MCPServer
    private let configuration: MCPServerHostConfiguration
    private let tokens = MCPTokenStore()
    private let portBox = PortBox()
    private let lock = NSLock()
    private var http: MCPHTTPServer?
    private var info: MCPEndpointInfo?

    public init(_ configuration: MCPServerHostConfiguration = MCPServerHostConfiguration()) {
        self.configuration = configuration
        self.server = MCPServer(configuration: configuration.server)
    }

    public var endpoint: MCPEndpointInfo? { lock.lock(); defer { lock.unlock() }; return info }
    public var isRunning: Bool { endpoint != nil }

    @discardableResult
    public func start() async throws -> MCPEndpointInfo {
        if let existing = endpoint { return existing }
        let handler = MCPHTTPHandler(
            server: server, tokens: tokens, port: portBox, allowedOrigins: configuration.allowedOrigins, exposeLiveBridge: configuration.exposeLiveBridge
        )
        let listener = MCPHTTPServer(handler: handler, port: portBox, requestedPort: configuration.port)
        let port = try await listener.start()
        let endpoint = MCPEndpointInfo(url: "http://127.0.0.1:\(port)/mcp", token: tokens.token, startedAt: ISO8601.string(configuration.server.clock()))
        do { try MCPTokenFile.write(endpoint, to: configuration.tokenFile) }
        catch {
            listener.stop()
            throw error
        }
        lock.withLock {
            http = listener
            info = endpoint
        }
        return endpoint
    }

    public func stop() {
        lock.lock()
        let listener = http
        http = nil
        info = nil
        lock.unlock()
        listener?.stop()
        MCPTokenFile.remove(configuration.tokenFile)
    }

    @discardableResult
    public func rotateToken() throws -> MCPEndpointInfo {
        guard var current = endpoint else { throw MCPHTTPError.listenFailed("the server is not running") }
        current.token = tokens.rotate()
        try MCPTokenFile.write(current, to: configuration.tokenFile)
        lock.withLock { info = current }
        return current
    }
}
