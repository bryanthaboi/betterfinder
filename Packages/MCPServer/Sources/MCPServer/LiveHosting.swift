import Foundation
import ModKit

public struct LiveWindow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LiveHostStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var developerMode: Bool
    public var appVersion: String?
    public var windows: [LiveWindow]
    public var reason: String?

    public init(available: Bool, developerMode: Bool = false, appVersion: String? = nil, windows: [LiveWindow] = [], reason: String? = nil) {
        self.available = available
        self.developerMode = developerMode
        self.appVersion = appVersion
        self.windows = windows
        self.reason = reason
    }

    public static func unavailable(_ reason: String) -> LiveHostStatus { LiveHostStatus(available: false, reason: reason) }
}

public struct LiveLoadRequest: Codable, Equatable, Sendable {
    public var modID: String
    public var workspacePath: String
    public var treeHash: String
    public var windowID: String
    public var approval: String?

    public init(modID: String, workspacePath: String, treeHash: String, windowID: String, approval: String? = nil) {
        self.modID = modID
        self.workspacePath = workspacePath
        self.treeHash = treeHash
        self.windowID = windowID
        self.approval = approval
    }
}

public struct LiveLoadResult: Codable, Equatable, Sendable {
    public var generation: Int
    public var diagnostics: [ModDiagnostic]

    public init(generation: Int, diagnostics: [ModDiagnostic] = []) {
        self.generation = generation
        self.diagnostics = diagnostics
    }
}

public struct LiveUIState: Codable, Equatable, Sendable {
    public var windows: [LiveWindow]
    public var surfaces: [JSONValue]
    public var generation: Int

    public init(windows: [LiveWindow], surfaces: [JSONValue], generation: Int) {
        self.windows = windows
        self.surfaces = surfaces
        self.generation = generation
    }
}

public struct LiveScreenshotRequest: Codable, Equatable, Sendable {
    public var modID: String
    public var windowID: String
    public var surfaceID: String?
    public var approval: String?

    public init(modID: String, windowID: String, surfaceID: String? = nil, approval: String? = nil) {
        self.modID = modID
        self.windowID = windowID
        self.surfaceID = surfaceID
        self.approval = approval
    }
}

public struct LiveLogEntry: Codable, Equatable, Sendable {
    public var time: String
    public var level: String
    public var message: String

    public init(time: String, level: String, message: String) {
        self.time = time
        self.level = level
        self.message = message
    }
}

public enum LiveHostError: Error, Equatable, Sendable {
    case unavailable(String)
    case developerModeRequired
    case approvalRequired(id: String, review: JSONValue)
    case rejected(String)
    case failed(String, [ModDiagnostic])

    var wireCode: String {
        switch self {
        case .unavailable: return "live_unavailable"
        case .developerModeRequired: return "developer_mode_required"
        case .approvalRequired: return "approval_required"
        case .rejected: return "rejected"
        case .failed: return "live_failed"
        }
    }

    var message: String {
        switch self {
        case .unavailable(let m): return m
        case .developerModeRequired: return "turn on Developer mode in betterfinder Settings > Mods to hot-load unsigned local mods"
        case .approvalRequired: return "betterfinder is waiting for native approval"
        case .rejected(let m): return m
        case .failed(let m, _): return m
        }
    }
}

public protocol LiveModHosting: Sendable {
    func status() async -> LiveHostStatus
    func load(_ request: LiveLoadRequest) async throws -> LiveLoadResult
    func unload(modID: String) async throws -> Bool
    func uiState(modID: String) async throws -> LiveUIState
    func screenshot(_ request: LiveScreenshotRequest) async throws -> Data
    func logs(modID: String) async throws -> [LiveLogEntry]
}

public struct UnavailableLiveHosting: LiveModHosting {
    public var reason: String

    public init(reason: String = "live mod tools need the betterfinder app; start it, choose Mods > Start MCP Server, and turn on Developer mode in Settings > Mods") {
        self.reason = reason
    }

    public func status() async -> LiveHostStatus { .unavailable(reason) }
    public func load(_ request: LiveLoadRequest) async throws -> LiveLoadResult { throw LiveHostError.unavailable(reason) }
    public func unload(modID: String) async throws -> Bool { throw LiveHostError.unavailable(reason) }
    public func uiState(modID: String) async throws -> LiveUIState { throw LiveHostError.unavailable(reason) }
    public func screenshot(_ request: LiveScreenshotRequest) async throws -> Data { throw LiveHostError.unavailable(reason) }
    public func logs(modID: String) async throws -> [LiveLogEntry] { throw LiveHostError.unavailable(reason) }
}

public struct ClosureLiveModHosting: LiveModHosting {
    public var statusHandler: @Sendable () async -> LiveHostStatus
    public var loadHandler: @Sendable (LiveLoadRequest) async throws -> LiveLoadResult
    public var unloadHandler: @Sendable (String) async throws -> Bool
    public var uiStateHandler: @Sendable (String) async throws -> LiveUIState
    public var screenshotHandler: @Sendable (LiveScreenshotRequest) async throws -> Data
    public var logsHandler: @Sendable (String) async throws -> [LiveLogEntry]

    public init(
        status: @escaping @Sendable () async -> LiveHostStatus,
        load: @escaping @Sendable (LiveLoadRequest) async throws -> LiveLoadResult,
        unload: @escaping @Sendable (String) async throws -> Bool,
        uiState: @escaping @Sendable (String) async throws -> LiveUIState,
        screenshot: @escaping @Sendable (LiveScreenshotRequest) async throws -> Data,
        logs: @escaping @Sendable (String) async throws -> [LiveLogEntry]
    ) {
        self.statusHandler = status
        self.loadHandler = load
        self.unloadHandler = unload
        self.uiStateHandler = uiState
        self.screenshotHandler = screenshot
        self.logsHandler = logs
    }

    public func status() async -> LiveHostStatus { await statusHandler() }
    public func load(_ request: LiveLoadRequest) async throws -> LiveLoadResult { try await loadHandler(request) }
    public func unload(modID: String) async throws -> Bool { try await unloadHandler(modID) }
    public func uiState(modID: String) async throws -> LiveUIState { try await uiStateHandler(modID) }
    public func screenshot(_ request: LiveScreenshotRequest) async throws -> Data { try await screenshotHandler(request) }
    public func logs(modID: String) async throws -> [LiveLogEntry] { try await logsHandler(modID) }
}
