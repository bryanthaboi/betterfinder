import Darwin
import Foundation
import FSCore

public struct SFTPConfiguration: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var path: String
    public var identityFile: String?

    public init(host: String, port: Int = 22, username: String, path: String = "", identityFile: String? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identityFile = (id?.isEmpty ?? true) ? nil : id
    }

    public static func parse(_ raw: String, identityFile: String? = nil) -> SFTPConfiguration? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("sftp://") { s.removeFirst(7) } else if s.lowercased().hasPrefix("ssh://") { s.removeFirst(6) }
        guard let at = s.lastIndex(of: "@") else { return nil }
        let user = String(s[..<at]).removingPercentEncoding ?? String(s[..<at])
        var rest = String(s[s.index(after: at)...])
        var path = ""
        var host: String
        var port = 22
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])
        } else {
            let end = rest.firstIndex { $0 == ":" || $0 == "/" } ?? rest.endIndex
            host = String(rest[..<end])
            rest = String(rest[end...])
        }
        if rest.hasPrefix(":") {
            rest.removeFirst()
            let digits = rest.prefix { $0.isNumber }
            if !digits.isEmpty {
                guard let p = Int(digits) else { return nil }
                port = p
                rest = String(rest.dropFirst(digits.count))
            }
        }
        if !rest.isEmpty { path = rest.removingPercentEncoding ?? rest }
        if host.isEmpty { return nil }
        return SFTPConfiguration(host: host, port: port, username: user, path: path, identityFile: identityFile)
    }

    static func isValidHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253, !h.hasPrefix("-"), !h.hasPrefix(".") else { return false }
        if h.contains(":") {
            return h.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").contains($0) }
        }
        return h.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }
    }

    static func isValidUser(_ u: String) -> Bool {
        guard !u.isEmpty, u.count <= 64, !u.hasPrefix("-") else { return false }
        return u.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }

    public func validate() throws {
        guard Self.isValidHost(host) else { throw ResourceError.invalidName(host) }
        guard Self.isValidUser(username) else { throw ResourceError.invalidName(username) }
        guard (1...65535).contains(port) else { throw ResourceError.invalidName(String(port)) }
        if !path.isEmpty && path != "~" {
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { throw ResourceError.invalidName(path) }
            try SFTPCommand.validate(path)
        }
        if let identityFile {
            guard identityFile.hasPrefix("/") || identityFile.hasPrefix("~/") else { throw ResourceError.invalidName(identityFile) }
            guard !identityFile.contains("\""), !identityFile.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw ResourceError.invalidName(identityFile) }
        }
    }

    public var destinationHost: String { host.contains(":") ? "[\(host)]" : host }
    public var hostKeyPattern: String { HostKeyStore.hostPattern(host: host, port: port) }
    public var credentialScope: CredentialScope { CredentialScope(kind: .sftp, host: "\(host.lowercased()):\(port)", resource: username) }
    public var displayName: String { port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)" }
}

public struct SSHToolchain: Sendable {
    public var sftp: URL
    public var ssh: URL
    public var keyscan: URL
    public var supportDirectory: URL
    public var multiplex: Bool
    public var extraEnvironment: [String: String]

    public init(sftp: URL = URL(fileURLWithPath: "/usr/bin/sftp"), ssh: URL = URL(fileURLWithPath: "/usr/bin/ssh"), keyscan: URL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
                supportDirectory: URL, multiplex: Bool = true, extraEnvironment: [String: String] = [:]) {
        self.sftp = sftp
        self.ssh = ssh
        self.keyscan = keyscan
        self.supportDirectory = supportDirectory
        self.multiplex = multiplex
        self.extraEnvironment = extraEnvironment
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("betterfinder/Remote", isDirectory: true)
    }

    public var knownHostsURL: URL { supportDirectory.appendingPathComponent("known_hosts") }
    func configURL(for id: String) -> URL { supportDirectory.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("\(id).conf") }

    static func controlDirectory() -> URL? {
        let path = "/tmp/bf-ssh-\(getuid())"
        _ = mkdir(path, 0o700)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        for k in ["SSH_AUTH_SOCK", "USER", "LOGNAME", "TMPDIR"] { if let v = inherited[k] { env[k] = v } }
        for (k, v) in extraEnvironment { env[k] = v }
        return env
    }
}

public actor SFTPConnection {
    public let id: String
    public let configuration: SFTPConfiguration
    let toolchain: SSHToolchain
    let hostKeys: HostKeyStore
    let retry: RetryPolicy
    let limiter: AsyncLimiter
    private var approver: HostKeyApproving?
    public private(set) var state: ConnectionState = .idle
    private var stateObserver: (@Sendable (ConnectionState) -> Void)?
    private var pendingApproval: Task<Void, Error>?
    private var resolvedHome: String?
    public private(set) var invocationCount = 0

    public init(id: String, configuration: SFTPConfiguration, toolchain: SSHToolchain, approver: HostKeyApproving?, retry: RetryPolicy = RetryPolicy(), maxConcurrent: Int = 3) {
        self.id = id
        self.configuration = configuration
        self.toolchain = toolchain
        self.hostKeys = HostKeyStore(url: toolchain.knownHostsURL)
        self.approver = approver
        self.retry = retry
        self.limiter = AsyncLimiter(maxConcurrent)
    }

    public func setApprover(_ a: HostKeyApproving?) { approver = a }

    public func observeState(_ f: @escaping @Sendable (ConnectionState) -> Void) {
        stateObserver = f
        f(state)
    }

    private func setState(_ s: ConnectionState) {
        guard s != state else { return }
        state = s
        stateObserver?(s)
    }

    static func escapeConfig(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "%", with: "%%") + "\""
    }

    static func controlPathValue(directory: String) -> String {
        "\"" + directory.replacingOccurrences(of: "%", with: "%%") + "/%C\""
    }

    func configText() -> String {
        configText(controlDirectory: toolchain.multiplex ? SSHToolchain.controlDirectory()?.path : nil)
    }

    func configText(controlDirectory: String?) -> String {
        var lines = [
            "IgnoreUnknown UseKeychain",
            "Host *",
            "  User \(configuration.username)",
            "  Port \(configuration.port)",
            "  BatchMode yes",
            "  StrictHostKeyChecking yes",
            "  UserKnownHostsFile \(Self.escapeConfig(toolchain.knownHostsURL.path)) \"~/.ssh/known_hosts\"",
            "  GlobalKnownHostsFile /etc/ssh/ssh_known_hosts",
            "  HashKnownHosts no",
            "  UpdateHostKeys no",
            "  CheckHostIP no",
            "  PasswordAuthentication no",
            "  KbdInteractiveAuthentication no",
            "  PubkeyAuthentication yes",
            "  PreferredAuthentications publickey",
            "  UseKeychain yes",
            "  AddKeysToAgent no",
            "  ProxyCommand none",
            "  ProxyJump none",
            "  PermitLocalCommand no",
            "  ForwardAgent no",
            "  ForwardX11 no",
            "  ClearAllForwardings yes",
            "  RequestTTY no",
            "  SendEnv -*",
            "  ConnectTimeout 15",
            "  ServerAliveInterval 15",
            "  ServerAliveCountMax 3",
            "  LogLevel ERROR",
        ]
        if let identity = configuration.identityFile {
            lines.append("  IdentityFile \(Self.escapeConfig(identity))")
            lines.append("  IdentitiesOnly yes")
        }
        if let dir = controlDirectory {
            lines.append("  ControlMaster auto")
            lines.append("  ControlPath \(Self.controlPathValue(directory: dir))")
            lines.append("  ControlPersist 60")
        } else {
            lines.append("  ControlMaster no")
            lines.append("  ControlPath none")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func writeConfig() throws -> URL {
        let url = toolchain.configURL(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = configText()
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public func removeConfiguration() {
        try? FileManager.default.removeItem(at: toolchain.configURL(for: id))
    }

    static func classify(stderr: String, status: Int32, host: String, executed: Int) -> ResourceError {
        let s = stderr
        let lower = s.lowercased()
        if s.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || (lower.contains("host key for") && lower.contains("has changed")) {
            return .hostKeyChanged(host: host)
        }
        if lower.contains("host key verification failed") || lower.contains("host key is known") {
            return .hostKeyUnknown(host: host, fingerprints: [])
        }
        if lower.contains("permission denied (") || lower.contains("too many authentication failures") || lower.contains("no supported authentication methods") {
            return .authenticationFailed(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let transient = ["could not resolve hostname", "connection refused", "operation timed out", "connection timed out", "connection closed", "connection reset",
                         "broken pipe", "no route to host", "network is unreachable", "kex_exchange_identification", "connection lost", "mux_client", "control socket"]
        if transient.contains(where: lower.contains) {
            return .connectionFailed(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let message = s.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if lower.contains("no such file") || lower.contains("not found") { return .notFound(message) }
        if lower.contains("permission denied") { return .permissionDenied(message) }
        if lower.contains("already exists") { return .alreadyExists(message) }
        if executed == 0 && status == 255 { return .connectionFailed(message.isEmpty ? "sftp exited with status \(status)" : message) }
        return .remote(code: "SFTPFailure", message: message.isEmpty ? "sftp exited with status \(status)" : message)
    }

    struct Failure: Error {
        let error: ResourceError
        let output: SFTPBatchOutput
    }

    private func execute(_ commands: [SFTPCommand]) async throws -> SFTPBatchOutput {
        try configuration.validate()
        let conf = try writeConfig()
        let batch = try SFTPCommand.batch(commands)
        invocationCount += 1
        let result = try await limiter.with {
            try await Subprocess.run(toolchain.sftp, arguments: ["-F", conf.path, "-b", "-", "--", configuration.destinationHost], stdin: Data(batch.utf8), environment: toolchain.environment())
        }
        try Task.checkCancellation()
        let out = SFTPBatchOutput.parse(stdout: result.stdoutString, stderr: result.stderrString)
        if result.status == 0 { return out }
        throw Failure(error: Self.classify(stderr: result.stderrString, status: result.status, host: configuration.hostKeyPattern, executed: out.executedCount), output: out)
    }

    public func run(_ commands: [SFTPCommand]) async throws -> SFTPBatchOutput {
        do {
            return try await runTracked(commands)
        } catch let f as Failure {
            throw f.error
        }
    }

    func runTracked(_ commands: [SFTPCommand]) async throws -> SFTPBatchOutput {
        var attempt = 1
        var approved = false
        let idempotent = commands.allSatisfy(\.isIdempotent)
        while true {
            try Task.checkCancellation()
            if state != .connected { setState(attempt > 1 ? .reconnecting(attempt: attempt - 1) : .connecting) }
            do {
                let out = try await execute(commands)
                setState(.connected)
                return out
            } catch let f as Failure {
                switch f.error {
                case .hostKeyUnknown where !approved:
                    approved = true
                    try await approveHostKey()
                    continue
                case let e where e.isTransient && attempt < retry.maxAttempts && (idempotent || f.output.executedCount == 0):
                    setState(.reconnecting(attempt: attempt))
                    await dropMaster()
                    let nanos = UInt64(retry.delay(afterAttempt: attempt) * 1_000_000_000)
                    if nanos > 0 { try await Task.sleep(nanoseconds: nanos) }
                    attempt += 1
                    continue
                case .connectionFailed, .authenticationFailed, .hostKeyChanged, .hostKeyUnknown, .hostKeyRejected:
                    setState(.failed(f.error.localizedDescription))
                    throw f
                default:
                    if f.output.executedCount > 0 { setState(.connected) }
                    throw f
                }
            } catch is CancellationError {
                throw CancellationError()
            }
        }
    }

    private func approveHostKey() async throws {
        if let pendingApproval { return try await pendingApproval.value }
        let task = Task { try await self.performApproval() }
        pendingApproval = task
        defer { pendingApproval = nil }
        try await task.value
    }

    private func performApproval() async throws {
        let host = configuration.host
        let port = configuration.port
        if hostKeys.contains(host: host, port: port) { throw ResourceError.hostKeyChanged(host: configuration.hostKeyPattern) }
        let scan = try await Subprocess.run(toolchain.keyscan, arguments: ["-T", "10", "-p", String(port), "-t", "ed25519,ecdsa,rsa", "--", host], stdin: Data(), environment: toolchain.environment())
        let keys = SSHHostKey.parse(keyscanOutput: scan.stdoutString)
        guard !keys.isEmpty else {
            throw ResourceError.connectionFailed("Couldn’t read the host key of \(configuration.hostKeyPattern). \(scan.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let approver else { throw ResourceError.hostKeyUnknown(host: configuration.hostKeyPattern, fingerprints: keys.map(\.fingerprint)) }
        let ok = await approver.approve(HostKeyApprovalRequest(host: host, port: port, keys: keys))
        try Task.checkCancellation()
        guard ok else { throw ResourceError.hostKeyRejected(host: configuration.hostKeyPattern) }
        try hostKeys.trust(keys, host: host, port: port)
    }

    public func connect() async throws -> String {
        let out = try await run([.pwd])
        let line = out.sections.first?.split(separator: "\n").first { $0.hasPrefix("Remote working directory:") }
        let home = line.map { $0.dropFirst("Remote working directory:".count).trimmingCharacters(in: .whitespaces) } ?? "/"
        resolvedHome = home
        return home
    }

    public func home() async throws -> String {
        if let resolvedHome { return resolvedHome }
        return try await connect()
    }

    public func dropMaster() async {
        guard toolchain.multiplex, let conf = try? writeConfig() else { return }
        _ = try? await Subprocess.run(toolchain.ssh, arguments: ["-F", conf.path, "-O", "exit", "--", configuration.destinationHost], stdin: Data(), environment: toolchain.environment())
    }

    public func disconnect() async {
        await dropMaster()
        setState(.disconnected)
    }
}
