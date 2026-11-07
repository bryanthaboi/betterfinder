import Foundation
import ModHostProtocol
import Security

public struct ModSigningInfo: Equatable, Sendable {
    public var identifier: String?
    public var teamIdentifier: String?
    public var isAdHoc: Bool

    public init(identifier: String?, teamIdentifier: String?, isAdHoc: Bool) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.isAdHoc = isAdHoc
    }
}

public enum ModPeerPolicy {
    public static func selfSigningInfo() -> ModSigningInfo? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return signingInfo(staticCode)
    }

    public static func signingInfo(pid: pid_t) -> ModSigningInfo? {
        guard let code = guestCode(pid: pid) else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return signingInfo(staticCode)
    }

    static func signingInfo(_ code: SecStaticCode) -> ModSigningInfo? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return ModSigningInfo(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & 0x0002 != 0
        )
    }

    public static func requirement(forPeerIdentifier identifier: String, selfInfo: ModSigningInfo? = selfSigningInfo(), lenient: Bool = isDebugBuild) -> String {
        let quoted = identifier.replacingOccurrences(of: "\"", with: "")
        if let team = selfInfo?.teamIdentifier, !team.isEmpty, selfInfo?.isAdHoc == false {
            return "identifier \"\(quoted)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team.replacingOccurrences(of: "\"", with: ""))\""
        }
        if lenient { return "identifier \"\(quoted)\"" }
        return "identifier \"\(quoted)\" and anchor apple generic"
    }

    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func guestCode(pid: pid_t) -> SecCode? {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess else { return nil }
        return code
    }

    public static func validate(pid: pid_t, requirement text: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        guard let code = guestCode(pid: pid) else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    public static func isValidRequirement(_ text: String) -> Bool {
        var req: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess && req != nil
    }
}

public final class ModHostXPCServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var engine: ModHostEngine?
    public let requirement: String
    public var onRejected: ((String) -> Void)?

    public init(peerIdentifier: String = "com.bryanthaboi.betterfinder", requirement: String? = nil) {
        self.requirement = requirement ?? ModPeerPolicy.requirement(forPeerIdentifier: peerIdentifier)
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connection == nil else {
            onRejected?("a second client tried to connect")
            return false
        }
        guard ModPeerPolicy.isValidRequirement(requirement) else {
            onRejected?("invalid peer requirement \(requirement)")
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)
        let interface = NSXPCInterface(with: ModHostXPCEndpoint.self)
        newConnection.exportedInterface = interface
        newConnection.remoteObjectInterface = interface
        let remote = newConnection.remoteObjectProxyWithErrorHandler { _ in exit(0) } as? ModHostXPCEndpoint
        let engine = ModHostEngine(exitOnHang: true) { message in
            guard let data = try? ModHostWire.encode(message) else { return }
            remote?.deliver(data)
        }
        newConnection.exportedObject = ModHostXPCInbound(engine: engine)
        newConnection.invalidationHandler = { exit(0) }
        newConnection.interruptionHandler = { exit(0) }
        connection = newConnection
        self.engine = engine
        newConnection.resume()
        engine.start()
        return true
    }
}

final class ModHostXPCInbound: NSObject, ModHostXPCEndpoint, @unchecked Sendable {
    let engine: ModHostEngine
    init(engine: ModHostEngine) { self.engine = engine }
    func deliver(_ message: Data) { engine.handle(data: message) }
}

public enum ModHostStdioServer {
    public static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let out = FileHandle.standardOutput
        let writeLock = NSLock()
        let engine = ModHostEngine(exitOnHang: true) { message in
            guard let data = try? ModHostWire.encode(message) else { return }
            writeLock.lock()
            out.write(ModHostFraming.frame(data))
            writeLock.unlock()
        }
        engine.start()
        let input = FileHandle.standardInput
        var buffer = Data()
        let thread = Thread {
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { exit(0) }
                buffer.append(chunk)
                do {
                    while let frame = try ModHostFraming.nextFrame(&buffer) { engine.handle(data: frame) }
                } catch {
                    exit(65)
                }
            }
        }
        thread.start()
        dispatchMain()
    }
}
