import Foundation
import FSCore

public struct RemoteServer: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        case s3(S3Configuration)
        case sftp(SFTPConfiguration)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind

    public init(id: UUID = UUID(), name: String? = nil, kind: Kind) {
        self.id = id
        self.kind = kind
        switch kind {
        case .s3(let c): self.name = name ?? c.displayName
        case .sftp(let c): self.name = name ?? c.displayName
        }
    }

    public var providerID: String {
        switch kind {
        case .s3: return "remote.s3.\(id.uuidString.lowercased())"
        case .sftp: return "remote.sftp.\(id.uuidString.lowercased())"
        }
    }

    public var credentialScope: CredentialScope {
        switch kind {
        case .s3(let c): return c.credentialScope
        case .sftp(let c): return c.credentialScope
        }
    }

    public var symbolName: String {
        switch kind {
        case .s3: return "externaldrive.connected.to.line.below"
        case .sftp: return "server.rack"
        }
    }

    public var kindDescription: String {
        switch kind {
        case .s3(let c): return c.endpoint == nil ? "Amazon S3" : "S3-compatible"
        case .sftp: return "SFTP"
        }
    }

    public var address: String {
        switch kind {
        case .s3(let c): return "s3://\(c.bucket)\(c.prefix.isEmpty ? "" : "/" + c.prefix) @ \(c.host)"
        case .sftp(let c): return "sftp://\(c.displayName)\(c.path)"
        }
    }
}

public final class RemoteServerStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL = SSHToolchain.defaultSupportDirectory.appendingPathComponent("servers.json")) {
        self.url = url
    }

    public func load() -> [RemoteServer] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteServer].self, from: data)) ?? []
    }

    public func save(_ servers: [RemoteServer]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(servers).write(to: url, options: .atomic)
    }
}

public extension Notification.Name {
    static let remoteServersDidChange = Notification.Name("RemoteServersDidChange")
    static let remoteConnectionStateDidChange = Notification.Name("RemoteConnectionStateDidChange")
}

public final class RemoteConnectionManager: @unchecked Sendable {
    public static let ownerID = "betterfinder.remote"

    public let store: RemoteServerStore
    public let credentials: CredentialStore
    public let registry: ResourceProviderRegistry
    public let toolchain: SSHToolchain
    public let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    public let retry: RetryPolicy
    private let lock = NSLock()
    private var serverList: [RemoteServer]
    private var live: [UUID: (provider: ResourceProvider, token: ResourceRegistrationToken)] = [:]
    private var states: [UUID: ConnectionState] = [:]
    private var disconnectedIDs: Set<UUID> = []
    private var approverRef: HostKeyApproving?

    public init(store: RemoteServerStore = RemoteServerStore(), credentials: CredentialStore = KeychainCredentialStore.shared, registry: ResourceProviderRegistry = .shared,
                toolchain: SSHToolchain = SSHToolchain(supportDirectory: SSHToolchain.defaultSupportDirectory), hostKeyApprover: HostKeyApproving? = nil,
                retry: RetryPolicy = RetryPolicy(), sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.store = store
        self.credentials = credentials
        self.registry = registry
        self.toolchain = toolchain
        self.retry = retry
        self.sessionConfiguration = sessionConfiguration
        self.serverList = store.load()
        self.approverRef = hostKeyApprover
    }

    private func postOnMain(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        let post = { NotificationCenter.default.post(name: name, object: self, userInfo: userInfo) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    public var hostKeyApprover: HostKeyApproving? {
        get { lock.lock(); defer { lock.unlock() }; return approverRef }
        set {
            lock.lock()
            approverRef = newValue
            let conns = live.values.compactMap { ($0.provider as? SFTPProvider)?.connection }
            lock.unlock()
            for c in conns { Task { await c.setApprover(newValue) } }
        }
    }

    public var servers: [RemoteServer] {
        lock.lock(); defer { lock.unlock() }
        return serverList
    }

    public func server(id: UUID) -> RemoteServer? { servers.first { $0.id == id } }
    public func server(providerID: String) -> RemoteServer? { servers.first { $0.providerID == providerID } }

    public func state(of server: RemoteServer) -> ConnectionState {
        lock.lock(); defer { lock.unlock() }
        if disconnectedIDs.contains(server.id) { return .disconnected }
        return states[server.id] ?? .idle
    }

    public func isDisconnected(_ server: RemoteServer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return disconnectedIDs.contains(server.id)
    }

    public func clearDisconnected(_ server: RemoteServer) {
        lock.lock()
        let was = disconnectedIDs.remove(server.id) != nil
        if was { states[server.id] = .idle }
        lock.unlock()
        if was { postOnMain(.remoteConnectionStateDidChange, userInfo: ["id": server.id]) }
    }

    private func setState(_ s: ConnectionState, for id: UUID) {
        lock.lock()
        if disconnectedIDs.contains(id), s != .disconnected {
            lock.unlock()
            return
        }
        let changed = states[id] != s
        states[id] = s
        lock.unlock()
        if changed { postOnMain(.remoteConnectionStateDidChange, userInfo: ["id": id]) }
    }

    public func makeProvider(for server: RemoteServer) -> ResourceProvider {
        switch server.kind {
        case .s3(let c):
            let client = S3Client(configuration: c, credentialStore: credentials, sessionConfiguration: sessionConfiguration(), retry: retry)
            return S3Provider(providerID: server.providerID, displayName: server.name, client: client)
        case .sftp(let c):
            let conn = SFTPConnection(id: server.id.uuidString.lowercased(), configuration: c, toolchain: toolchain, approver: hostKeyApprover, retry: retry)
            let id = server.id
            Task { await conn.observeState { [weak self] s in self?.setState(s, for: id) } }
            return SFTPProvider(providerID: server.providerID, displayName: server.name, connection: conn)
        }
    }

    @discardableResult
    public func provider(for server: RemoteServer) throws -> ResourceProvider {
        lock.lock()
        if let p = live[server.id]?.provider {
            lock.unlock()
            return p
        }
        lock.unlock()
        let p = makeProvider(for: server)
        let token = try registry.register(p, owner: Self.ownerID)
        lock.lock()
        if let existing = live[server.id]?.provider {
            lock.unlock()
            token.cancel()
            return existing
        }
        live[server.id] = (p, token)
        lock.unlock()
        return p
    }

    public func installAll() {
        for s in servers { _ = try? provider(for: s) }
    }

    @discardableResult
    public func connect(_ server: RemoteServer) async throws -> ResourceID {
        clearDisconnected(server)
        let p = try provider(for: server)
        setState(.connecting, for: server.id)
        do {
            let root: ResourceID
            if let sftp = p as? SFTPProvider {
                root = try await sftp.resolveRoot()
            } else {
                _ = try await p.stat(p.root)
                root = p.root
            }
            setState(.connected, for: server.id)
            return root
        } catch {
            setState(.failed(error.localizedDescription), for: server.id)
            throw error
        }
    }

    public func add(_ server: RemoteServer, secret: Data? = nil) async throws -> RemoteServer {
        switch server.kind {
        case .s3(let c): try c.validate()
        case .sftp(let c): try c.validate()
        }
        if let secret { try credentials.setSecret(secret, for: server.credentialScope) }
        var saved = server
        do {
            let root = try await connect(server)
            if case .sftp(var c) = server.kind, c.path != root.path {
                c.path = root.path
                saved.kind = .sftp(c)
                drop(server.id)
                _ = try provider(for: saved)
            }
        } catch {
            drop(server.id)
            if secret != nil, !servers.contains(where: { $0.credentialScope == server.credentialScope && $0.id != server.id }) {
                try? credentials.removeSecret(for: server.credentialScope)
            }
            throw error
        }
        let snapshot: [RemoteServer] = lock.withLock {
            serverList.removeAll { $0.id == saved.id }
            serverList.append(saved)
            return serverList
        }
        try store.save(snapshot)
        postOnMain(.remoteServersDidChange)
        return saved
    }

    private func drop(_ id: UUID) {
        lock.lock()
        let entry = live.removeValue(forKey: id)
        lock.unlock()
        entry?.token.cancel()
        if let sftp = entry?.provider as? SFTPProvider {
            Task { await sftp.connection.disconnect() }
        }
    }

    public func disconnect(_ server: RemoteServer) {
        lock.withLock {
            disconnectedIDs.insert(server.id)
            states[server.id] = .disconnected
        }
        drop(server.id)
        postOnMain(.remoteConnectionStateDidChange, userInfo: ["id": server.id])
        _ = try? provider(for: server)
    }

    public func remove(_ server: RemoteServer) throws {
        if let sftp = (lock.withLock { live[server.id]?.provider }) as? SFTPProvider {
            let conn = sftp.connection
            Task { await conn.removeConfiguration() }
        }
        drop(server.id)
        lock.lock()
        serverList.removeAll { $0.id == server.id }
        let snapshot = serverList
        states[server.id] = nil
        disconnectedIDs.remove(server.id)
        lock.unlock()
        if !snapshot.contains(where: { $0.credentialScope == server.credentialScope }) {
            try? credentials.removeSecret(for: server.credentialScope)
        }
        try store.save(snapshot)
        postOnMain(.remoteServersDidChange)
    }
}
