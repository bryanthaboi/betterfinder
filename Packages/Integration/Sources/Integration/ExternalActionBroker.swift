import AppKit
import Foundation

public struct ExternalOpenRequest: Equatable, Sendable {
    public var modID: String
    public var url: URL
    public var reason: String?
    public var scopeKey: String
    public var isInsecure: Bool

    public init(modID: String, url: URL, reason: String?, scopeKey: String, isInsecure: Bool) {
        self.modID = modID
        self.url = url
        self.reason = reason
        self.scopeKey = scopeKey
        self.isInsecure = isInsecure
    }
}

public enum ExternalApprovalChoice: Sendable {
    case allowOnce
    case allowAlways
    case deny
}

public protocol ExternalActionPrompting: AnyObject, Sendable {
    func requestApproval(_ request: ExternalOpenRequest) async -> ExternalApprovalChoice
}

public protocol URLOpening: AnyObject, Sendable {
    func open(_ url: URL) async -> Bool
}

public final class WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

public final class AlertExternalActionPrompter: ExternalActionPrompting {
    public let modTitle: @Sendable (String) -> String

    public init(modTitle: @escaping @Sendable (String) -> String = { $0 }) {
        self.modTitle = modTitle
    }

    public func requestApproval(_ request: ExternalOpenRequest) async -> ExternalApprovalChoice {
        let title = modTitle(request.modID)
        return await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = request.isInsecure ? .critical : .warning
            alert.messageText = "\"\(title)\" wants to open a link"
            var info = request.url.absoluteString
            if let reason = request.reason, !reason.isEmpty { info += "\n\n\(reason)" }
            if request.isInsecure { info += "\n\nThis link isn't encrypted." }
            alert.informativeText = info
            alert.addButton(withTitle: "Open Once")
            alert.addButton(withTitle: "Always Allow \(request.scopeKey)")
            alert.addButton(withTitle: "Don't Open")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .allowOnce
            case .alertSecondButtonReturn: return .allowAlways
            default: return .deny
            }
        }
    }
}

public enum ExternalActionError: LocalizedError, Equatable {
    case invalidURL(String)
    case disallowedScheme(String)
    case notPermitted(String)
    case userDenied
    case openFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let m): return "That link can't be opened: \(m)"
        case .disallowedScheme(let s): return "Mods can't open \"\(s)\" links."
        case .notPermitted(let id): return "\"\(id)\" doesn't have permission to open links."
        case .userDenied: return "You declined to open the link."
        case .openFailed: return "macOS couldn't open the link."
        }
    }
}

public final class ExternalActionBroker: @unchecked Sendable {
    public static let shared = ExternalActionBroker()
    public static let defaultsKey = "externalActionApprovals.v1"
    public static let maxURLLength = 2048

    public let allowedSchemes: Set<String>
    private let defaults: UserDefaults
    private let prompter: ExternalActionPrompting
    private let opener: URLOpening
    private let isPermitted: @Sendable (String) -> Bool
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        prompter: ExternalActionPrompting = AlertExternalActionPrompter(),
        opener: URLOpening = WorkspaceURLOpener(),
        allowedSchemes: Set<String> = ["https", "http", "mailto"],
        isPermitted: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.defaults = defaults
        self.prompter = prompter
        self.opener = opener
        self.allowedSchemes = allowedSchemes
        self.isPermitted = isPermitted
    }

    public func open(_ url: URL, modID: String, reason: String? = nil) async throws {
        guard isPermitted(modID) else { throw ExternalActionError.notPermitted(modID) }
        let request = try Self.validate(url, modID: modID, reason: reason, allowedSchemes: allowedSchemes)
        if !isApproved(request) {
            switch await prompter.requestApproval(request) {
            case .deny: throw ExternalActionError.userDenied
            case .allowOnce: break
            case .allowAlways: approve(request)
            }
        }
        guard await opener.open(url) else { throw ExternalActionError.openFailed }
    }

    public func isApproved(_ request: ExternalOpenRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[request.modID]?.contains(request.scopeKey) == true
    }

    public func approvals(for modID: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (loadLocked()[modID] ?? []).sorted()
    }

    public func revokeApprovals(for modID: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        all.removeValue(forKey: modID)
        saveLocked(all)
    }

    public func revokeApproval(_ scopeKey: String, for modID: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        all[modID]?.removeAll { $0 == scopeKey }
        if all[modID]?.isEmpty == true { all.removeValue(forKey: modID) }
        saveLocked(all)
    }

    public static func validate(_ url: URL, modID: String, reason: String?, allowedSchemes: Set<String>) throws -> ExternalOpenRequest {
        let text = url.absoluteString
        guard text.count <= maxURLLength else { throw ExternalActionError.invalidURL("too long") }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { throw ExternalActionError.invalidURL("no scheme") }
        guard allowedSchemes.contains(scheme) else { throw ExternalActionError.disallowedScheme(scheme) }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ExternalActionError.invalidURL("malformed") }
        guard comps.user == nil, comps.password == nil else { throw ExternalActionError.invalidURL("embedded credentials") }
        let scopeKey: String
        if scheme == "mailto" {
            scopeKey = "mailto:"
        } else {
            guard let host = comps.host?.lowercased(), !host.isEmpty else { throw ExternalActionError.invalidURL("no host") }
            scopeKey = "\(scheme)://\(host)"
        }
        return ExternalOpenRequest(modID: modID, url: url, reason: reason, scopeKey: scopeKey, isInsecure: scheme == "http")
    }

    private func approve(_ request: ExternalOpenRequest) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        var set = all[request.modID] ?? []
        if !set.contains(request.scopeKey) { set.append(request.scopeKey) }
        all[request.modID] = set
        saveLocked(all)
    }

    private func loadLocked() -> [String: [String]] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded
    }

    private func saveLocked(_ value: [String: [String]]) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
