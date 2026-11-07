import Foundation
import ModKit

public enum ModHostWire {
    public static let protocolVersion = 1
    public static let maxMessageBytes = 1 << 20
    public static let serviceName = embeddedIdentifier("BetterFinderModHost") ?? "com.bryanthaboi.betterfinder.modhost"
    public static let checkServiceName = embeddedIdentifier("BetterFinderModCheck") ?? "com.bryanthaboi.betterfinder.modcheck"

    static func embeddedIdentifier(_ name: String) -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(name).xpc")
        return Bundle(url: url)?.bundleIdentifier
    }
    public static let appIdentifier = "com.bryanthaboi.betterfinder"

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        let data = try e.encode(value)
        guard data.count <= maxMessageBytes else { throw ModHostWireError.messageTooLarge(data.count) }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxMessageBytes else { throw ModHostWireError.messageTooLarge(data.count) }
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum ModHostWireError: Error, Equatable, Sendable {
    case messageTooLarge(Int)
    case malformed(String)
}

public struct ModHostConfig: Codable, Equatable, Sendable {
    public var callbackBudgetMs: Int
    public var loadBudgetMs: Int
    public var hangGraceMs: Int
    public var memoryLimitMiB: Int
    public var statsIntervalMs: Int
    public var maxLoopIterations: Int

    public init(
        callbackBudgetMs: Int = ModCatalogLimits.v1.callbackWatchdogMs,
        loadBudgetMs: Int = 3000,
        hangGraceMs: Int = 750,
        memoryLimitMiB: Int = ModCatalogLimits.v1.hostRSSRestartMiB,
        statsIntervalMs: Int = 2000,
        maxLoopIterations: Int = ModCatalogLimits.v1.maxLoopIterations
    ) {
        self.callbackBudgetMs = callbackBudgetMs
        self.loadBudgetMs = loadBudgetMs
        self.hangGraceMs = hangGraceMs
        self.memoryLimitMiB = memoryLimitMiB
        self.statsIntervalMs = statsIntervalMs
        self.maxLoopIterations = maxLoopIterations
    }
}

public enum ModScriptKind: String, Codable, Sendable {
    case bfscript
    case module
}

public struct ModLoadRequest: Codable, Equatable, Sendable {
    public var modId: String
    public var generation: Int
    public var kind: ModScriptKind
    public var source: String
    public var handlers: [String]

    public init(modId: String, generation: Int, kind: ModScriptKind, source: String, handlers: [String]) {
        self.modId = modId
        self.generation = generation
        self.kind = kind
        self.source = source
        self.handlers = handlers
    }
}

public struct ModInvokeRequest: Codable, Equatable, Sendable {
    public var invocationId: String
    public var parentInvocationId: String?
    public var modId: String
    public var generation: Int
    public var handler: String
    public var context: JSONValue
    public var input: JSONValue
    public var deadlineMs: Int

    public init(invocationId: String, parentInvocationId: String? = nil, modId: String, generation: Int, handler: String, context: JSONValue, input: JSONValue, deadlineMs: Int) {
        self.invocationId = invocationId
        self.parentInvocationId = parentInvocationId
        self.modId = modId
        self.generation = generation
        self.handler = handler
        self.context = context
        self.input = input
        self.deadlineMs = deadlineMs
    }
}

public struct ModCallRequest: Codable, Equatable, Sendable {
    public var callId: String
    public var invocationId: String
    public var modId: String
    public var generation: Int
    public var name: String
    public var args: [JSONValue]

    public init(callId: String, invocationId: String, modId: String, generation: Int, name: String, args: [JSONValue]) {
        self.callId = callId
        self.invocationId = invocationId
        self.modId = modId
        self.generation = generation
        self.name = name
        self.args = args
    }
}

public struct ModCallError: Codable, Equatable, Sendable, Error {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public static func notGranted(_ m: String) -> ModCallError { ModCallError("notGranted", m) }
    public static func invalid(_ m: String) -> ModCallError { ModCallError("invalidArgument", m) }
    public static func notFound(_ m: String) -> ModCallError { ModCallError("notFound", m) }
    public static func stale(_ m: String = "handle is no longer valid") -> ModCallError { ModCallError("staleHandle", m) }
    public static func denied(_ m: String) -> ModCallError { ModCallError("denied", m) }
    public static func limit(_ m: String) -> ModCallError { ModCallError("limitExceeded", m) }
    public static func timeout(_ m: String = "timed out") -> ModCallError { ModCallError("timeout", m) }
    public static func cancelled(_ m: String = "cancelled") -> ModCallError { ModCallError("cancelled", m) }
    public static func internalError(_ m: String) -> ModCallError { ModCallError("internal", m) }
}

public enum ModCallOutcome: Codable, Equatable, Sendable {
    case value(JSONValue)
    case failure(ModCallError)

    public var value: JSONValue? { if case .value(let v) = self { return v }; return nil }
    public var error: ModCallError? { if case .failure(let e) = self { return e }; return nil }
}

public struct ModHostStats: Codable, Equatable, Sendable {
    public var residentBytes: UInt64
    public var footprintBytes: UInt64
    public var loadedMods: Int
    public var activeInvocations: Int

    public init(residentBytes: UInt64, footprintBytes: UInt64, loadedMods: Int, activeInvocations: Int) {
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.loadedMods = loadedMods
        self.activeInvocations = activeInvocations
    }
}

public struct ModHostInfo: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var pid: Int32
    public var sandboxed: Bool
    public var engine: String

    public init(protocolVersion: Int = ModHostWire.protocolVersion, pid: Int32, sandboxed: Bool, engine: String) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.sandboxed = sandboxed
        self.engine = engine
    }
}

public struct ModHangReport: Codable, Equatable, Sendable {
    public var modId: String
    public var generation: Int
    public var invocationId: String?
    public var handler: String?
    public var elapsedMs: Int

    public init(modId: String, generation: Int, invocationId: String?, handler: String?, elapsedMs: Int) {
        self.modId = modId
        self.generation = generation
        self.invocationId = invocationId
        self.handler = handler
        self.elapsedMs = elapsedMs
    }
}

public enum ModAppToHost: Codable, Equatable, Sendable {
    case configure(ModHostConfig)
    case load(ModLoadRequest)
    case unload(modId: String, generation: Int)
    case invoke(ModInvokeRequest)
    case cancel(invocationId: String)
    case callResult(callId: String, outcome: ModCallOutcome)
    case ping(UInt64)
    case benchmark(iterations: Int)
    case probe(paths: [String], hosts: [String], spawn: String?)
}

public enum ModHostToApp: Codable, Equatable, Sendable {
    case ready(ModHostInfo)
    case loaded(modId: String, generation: Int, error: ModCallError?)
    case result(invocationId: String, outcome: ModCallOutcome)
    case call(ModCallRequest)
    case hung(ModHangReport)
    case stats(ModHostStats)
    case pong(UInt64, ModHostStats)
    case benchmark(iterations: Int, nanoseconds: UInt64)
    case probeResult([String: String])
}

@objc public protocol ModHostXPCEndpoint {
    func deliver(_ message: Data)
}

public enum ModHostFraming {
    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    public static func nextFrame(_ buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        guard Int(length) <= ModHostWire.maxMessageBytes else { throw ModHostWireError.messageTooLarge(Int(length)) }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let payload = buffer.subdata(in: start + 4..<start + 4 + Int(length))
        buffer.removeSubrange(start..<start + 4 + Int(length))
        return payload
    }
}
