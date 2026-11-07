import Foundation
import ModKit
import ModValidation

public struct MCPServerConfiguration: Sendable {
    public var validator: ModValidator
    public var dryRunner: DryRunning
    public var workspaces: ModWorkspaces
    public var live: LiveModHosting
    public var runner: CommandRunning
    public var hostInfo: HostInfo
    public var serverVersion: String
    public var pageSize: Int
    public var consentTTL: TimeInterval
    public var clock: @Sendable () -> Date
    public var indexRepository: String

    public init(
        validator: ModValidator = .shared,
        dryRunner: DryRunning = NotRunDryRunner(),
        workspaces: ModWorkspaces = ModWorkspaces(),
        live: LiveModHosting = UnavailableLiveHosting(),
        runner: CommandRunning = ProcessCommandRunner(),
        hostInfo: HostInfo = .current,
        serverVersion: String = ModKitVersion.validator,
        pageSize: Int = 100,
        consentTTL: TimeInterval = 600,
        clock: @escaping @Sendable () -> Date = { Date() },
        indexRepository: String = "bryanthaboi/betterfinder-mod-index"
    ) {
        self.validator = validator
        self.dryRunner = dryRunner
        self.workspaces = workspaces
        self.live = live
        self.runner = runner
        self.hostInfo = hostInfo
        self.serverVersion = serverVersion
        self.pageSize = pageSize
        self.consentTTL = consentTTL
        self.clock = clock
        self.indexRepository = indexRepository
    }
}

public struct ToolReturn: Sendable {
    public var data: JSONValue
    public var images: [(data: Data, mimeType: String)]
    public var notes: [String]

    public init(_ data: JSONValue, images: [(data: Data, mimeType: String)] = [], notes: [String] = []) {
        self.data = data
        self.images = images
        self.notes = notes
    }
}

public struct MCPToolDefinition: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue
    public var readOnly: Bool
    public var openWorld: Bool
    var handler: @Sendable (MCPServer, ToolArguments) async throws -> ToolReturn

    var schema: JSONSchema { JSONSchema(inputSchema) }

    var listing: JSONValue {
        obj([
            "name": name.j,
            "title": title.j,
            "description": description.j,
            "inputSchema": inputSchema,
            "outputSchema": outputSchema,
            "annotations": obj([
                "title": title.j,
                "readOnlyHint": readOnly.j,
                "destructiveHint": false,
                "idempotentHint": readOnly.j,
                "openWorldHint": openWorld.j,
            ]),
        ])
    }
}

public struct ToolArguments: Sendable {
    public let object: [String: JSONValue]

    init(_ value: JSONValue) { object = value.objectValue ?? [:] }

    func string(_ key: String) throws -> String {
        guard let s = object[key]?.stringValue else { throw ToolError("invalid_arguments", "'\(key)' is required") }
        return s
    }

    func optionalString(_ key: String) -> String? { object[key]?.stringValue }

    func int(_ key: String) -> Int? { object[key]?.intValue }

    func bool(_ key: String) -> Bool? { object[key]?.boolValue }

    func strings(_ key: String) -> [String] { (object[key]?.arrayValue ?? []).compactMap(\.stringValue) }
}

struct ReceiptRecord: Sendable {
    var workspace: String
    var treeHash: String
    var staticOK: Bool
    var created: Date
}

struct LiveSessionRecord: Sendable {
    var id: String
    var modID: String
    var workspace: String
    var generation: Int
}

struct ArtifactRecord: Sendable {
    var id: String
    var url: URL
    var sha256: String
    var bytes: Int
    var kind: String
    var workspace: String
    var treeHash: String?
    var modID: String?
    var version: String?
    var title: String?
}

struct IndexDraft: Sendable {
    var workspace: String
    var revision: String
    var modID: String
    var version: String
    var files: [String: String]
    var repo: String
    var tag: String
    var warnings: [String]
    var templateBody: String
}

final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var receipts = [String: ReceiptRecord]()
    private var sessions = [String: LiveSessionRecord]()
    private var artifacts = [String: ArtifactRecord]()
    private var drafts = [String: IndexDraft]()

    func addReceipt(_ r: ReceiptRecord) -> String {
        lock.lock()
        defer { lock.unlock() }
        if receipts.count > 256, let oldest = receipts.min(by: { $0.value.created < $1.value.created })?.key { receipts.removeValue(forKey: oldest) }
        let id = "rcpt-" + Hex.random(bytes: 12)
        receipts[id] = r
        return id
    }

    func receipt(_ id: String) -> ReceiptRecord? { lock.lock(); defer { lock.unlock() }; return receipts[id] }

    func session(_ id: String) -> LiveSessionRecord? { lock.lock(); defer { lock.unlock() }; return sessions[id] }

    func session(forWorkspace workspace: String) -> LiveSessionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.first { $0.workspace == workspace }
    }

    func setSession(_ s: LiveSessionRecord) { lock.lock(); sessions[s.id] = s; lock.unlock() }

    func removeSession(_ id: String) { lock.lock(); sessions.removeValue(forKey: id); lock.unlock() }

    func addArtifact(_ a: ArtifactRecord) { lock.lock(); artifacts[a.id] = a; lock.unlock() }

    func artifact(_ id: String) -> ArtifactRecord? { lock.lock(); defer { lock.unlock() }; return artifacts[id] }

    func setDraft(_ d: IndexDraft) { lock.lock(); drafts[d.workspace] = d; lock.unlock() }

    func draft(_ workspace: String) -> IndexDraft? { lock.lock(); defer { lock.unlock() }; return drafts[workspace] }
}

public final class MCPServer: @unchecked Sendable {
    public static let protocolVersions = ["2025-11-25", "2025-06-18"]
    public static let serverName = "betterfinder-mod"

    public let configuration: MCPServerConfiguration
    public let ledger: ConsentLedger
    let state = ServerState()
    let tools: [MCPToolDefinition]
    let toolIndex: [String: MCPToolDefinition]
    let schemas: [String: JSONSchema]
    let publisher: GitHubPublisher

    static let toolAliases = ["mod_repo_create": "github_create_repo", "mod_release_publish": "github_publish_release", "mod_index_listing": "mod_index_entry"]

    public init(configuration: MCPServerConfiguration = MCPServerConfiguration()) {
        self.configuration = configuration
        self.ledger = ConsentLedger(ttl: configuration.consentTTL, clock: configuration.clock)
        self.publisher = GitHubPublisher(runner: configuration.runner, indexRepository: configuration.indexRepository)
        let defs = Self.makeTools()
        self.tools = defs
        self.toolIndex = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0) })
        self.schemas = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0.schema) })
    }

    public func makeSession() -> MCPSession { MCPSession(server: self) }

    public var toolNames: [String] { tools.map(\.name) }

    public func toolDefinition(_ name: String) -> MCPToolDefinition? { toolIndex[Self.toolAliases[name] ?? name] }

    public func callTool(name: String, arguments: JSONValue) async -> JSONValue {
        guard let tool = toolDefinition(name) else {
            return Self.toolResult(.failure(ToolError("unknown_tool", "no tool named '\(name.prefix(64))'")))
        }
        guard case .object = arguments else {
            return Self.toolResult(.failure(ToolError("invalid_arguments", "arguments must be an object")))
        }
        let violations = schemas[tool.name]!.validate(arguments, limit: 5)
        if !violations.isEmpty {
            let text = violations.map { "\($0.pointer.isEmpty ? "/" : $0.pointer): \($0.message)" }.joined(separator: "; ")
            return Self.toolResult(.failure(ToolError("invalid_arguments", text)))
        }
        do {
            let value = try await tool.handler(self, ToolArguments(arguments))
            return Self.toolResult(.success(value))
        } catch let e as ToolError {
            return Self.toolResult(.failure(e))
        } catch is CancellationError {
            return Self.toolResult(.failure(ToolError("cancelled", "the request was cancelled")))
        } catch let e as LiveHostError {
            return Self.toolResult(.failure(ToolError(e.wireCode, e.message, diagnostics: { if case .failed(_, let d) = e { return d }; return nil }())))
        } catch let e as CommandRunnerError {
            return Self.toolResult(.failure(Self.commandError(e)))
        } catch {
            return Self.toolResult(.failure(ToolError("internal_error", Redactor.clean("\(error.localizedDescription)", limit: 500))))
        }
    }

    static func commandError(_ e: CommandRunnerError) -> ToolError {
        switch e {
        case .notFound(let name):
            if name == "gh" {
                return ToolError("gh_unavailable", "the GitHub CLI (gh) was not found on this machine. Install it from https://cli.github.com and run `gh auth login`; betterfinder never downloads it for you")
            }
            return ToolError("tool_unavailable", "'\(name)' was not found on this machine")
        case .launchFailed(let m): return ToolError("command_failed", Redactor.clean(m, limit: 300))
        case .timedOut(let name): return ToolError("command_timeout", "\(name) did not finish in time")
        }
    }

    static func toolResult(_ result: Result<ToolReturn, ToolError>) -> JSONValue {
        switch result {
        case .success(let value):
            let structured: JSONValue = obj(["ok": true, "data": value.data])
            var content: [JSONValue] = [obj(["type": "text", "text": structured.compactString.j])]
            for note in value.notes { content.append(obj(["type": "text", "text": note.j])) }
            for image in value.images {
                content.append(obj(["type": "image", "data": image.data.base64EncodedString().j, "mimeType": image.mimeType.j]))
            }
            return obj(["content": .array(content), "structuredContent": structured, "isError": false])
        case .failure(let error):
            var err: [String: JSONValue] = ["code": error.code.j, "message": error.message.j]
            if let d = error.diagnostics, !d.isEmpty { err["diagnostics"] = JSONValue.from(d) }
            if let details = error.details { err["details"] = details }
            let structured: JSONValue = obj(["ok": false, "error": .object(err)])
            return obj([
                "content": .array([obj(["type": "text", "text": structured.compactString.j])]),
                "structuredContent": structured,
                "isError": true,
            ])
        }
    }
}
