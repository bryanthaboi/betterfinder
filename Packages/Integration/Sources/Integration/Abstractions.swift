import AppKit
import Foundation
import UniformTypeIdentifiers

public enum PreferencesDomain: Hashable, Sendable {
    case global
    case app(String)

    var cfName: CFString {
        switch self {
        case .global: return kCFPreferencesAnyApplication
        case .app(let id): return id as CFString
        }
    }
}

public protocol PreferencesWriter: AnyObject {
    func value(forKey key: String, in domain: PreferencesDomain) -> Any?
    func setValue(_ value: Any?, forKey key: String, in domain: PreferencesDomain)
}

public final class SystemPreferencesWriter: PreferencesWriter {
    public init() {}

    public func value(forKey key: String, in domain: PreferencesDomain) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain.cfName, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public func setValue(_ value: Any?, forKey key: String, in domain: PreferencesDomain) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain.cfName, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain.cfName, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

public final class InMemoryPreferencesWriter: PreferencesWriter {
    public struct Write: Equatable {
        public var key: String
        public var domain: PreferencesDomain
        public var valueDescription: String
    }

    public private(set) var storage: [PreferencesDomain: [String: Any]] = [:]
    public private(set) var writes: [Write] = []

    public init(storage: [PreferencesDomain: [String: Any]] = [:]) {
        self.storage = storage
    }

    public func value(forKey key: String, in domain: PreferencesDomain) -> Any? {
        storage[domain]?[key]
    }

    public func setValue(_ value: Any?, forKey key: String, in domain: PreferencesDomain) {
        var d = storage[domain] ?? [:]
        if let value { d[key] = value } else { d.removeValue(forKey: key) }
        storage[domain] = d
        writes.append(Write(key: key, domain: domain, valueDescription: value.map { "\($0)" } ?? "nil"))
    }
}

public protocol FolderHandlerService: AnyObject {
    func handlerBundleID(for type: UTType) -> String?
    func setHandler(bundleID: String, appURL: URL?, for type: UTType) async throws
}

public final class WorkspaceFolderHandlerService: FolderHandlerService {
    public init() {}

    public func handlerBundleID(for type: UTType) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    public func setHandler(bundleID: String, appURL: URL?, for type: UTType) async throws {
        guard let url = appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw IntegrationError.applicationNotFound(bundleID)
        }
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpen: type)
    }
}

public protocol SystemCommandRunner: AnyObject {
    func relaunchApplication(bundleID: String) async throws
}

public final class WorkspaceCommandRunner: SystemCommandRunner {
    public init() {}

    public func relaunchApplication(bundleID: String) async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let appURL = running.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        for app in running { app.terminate() }
        if !(await wait(timeout: 2.0) { running.allSatisfy { $0.isTerminated } }) {
            for app in running where !app.isTerminated { app.forceTerminate() }
            _ = await wait(timeout: 2.0) { running.allSatisfy { $0.isTerminated } }
        }
        let relaunched = await wait(timeout: 3.0) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
        if relaunched { return }
        guard let appURL else { throw IntegrationError.applicationNotFound(bundleID) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    private func wait(timeout: TimeInterval, until condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

public enum IntegrationError: LocalizedError {
    case applicationNotFound(String)
    case handlerChangeFailed(type: String, reason: String)
    case hotKeyRegistrationFailed(OSStatus)
    case loginItemFailed(String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let id):
            return "Couldn't find an installed application with bundle ID \(id)."
        case .handlerChangeFailed(let type, let reason):
            return "macOS didn't change the default handler for \(type): \(reason)"
        case .hotKeyRegistrationFailed(let status):
            return "The hotkey couldn't be registered (error \(status)). Another app may already use it."
        case .loginItemFailed(let reason):
            return "Couldn't update the login item: \(reason)"
        }
    }
}

struct PreviousValueStore {
    let defaults: UserDefaults
    let prefix: String

    struct Record {
        var present: Bool
        var value: Any?
    }

    func key(_ name: String) -> String { "\(prefix).\(name)" }

    func get(_ name: String) -> Record? {
        guard let dict = defaults.dictionary(forKey: key(name)), let present = dict["present"] as? Bool else { return nil }
        return Record(present: present, value: dict["value"])
    }

    func record(_ name: String, value: Any?) {
        var dict: [String: Any] = ["present": value != nil]
        if let value { dict["value"] = value }
        defaults.set(dict, forKey: key(name))
    }

    func raw(_ name: String) -> [String: Any]? { defaults.dictionary(forKey: key(name)) }

    func setRaw(_ name: String, _ dict: [String: Any]?) {
        if let dict { defaults.set(dict, forKey: key(name)) } else { defaults.removeObject(forKey: key(name)) }
    }

    func clear(_ name: String) { defaults.removeObject(forKey: key(name)) }
}

func boolValue(_ any: Any?) -> Bool? {
    switch any {
    case let b as Bool: return b
    case let n as NSNumber: return n.boolValue
    case let s as String:
        switch s.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    default: return nil
    }
}
