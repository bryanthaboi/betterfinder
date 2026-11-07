import Foundation
import FSCore
import Security

public struct CredentialScope: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable { case s3, sftp }

    public let kind: Kind
    public let host: String
    public let resource: String

    public init(kind: Kind, host: String, resource: String) {
        self.kind = kind
        self.host = host.lowercased()
        self.resource = resource
    }

    public var account: String { "\(kind.rawValue)://\(resource)@\(host)" }
    public var description: String { account }

    public func permits(host requestHost: String) -> Bool {
        requestHost.lowercased() == host
    }
}

public struct AWSCredentials: Sendable, Hashable, Codable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> AWSCredentials { try JSONDecoder().decode(AWSCredentials.self, from: data) }
}

public protocol CredentialStore: AnyObject, Sendable {
    func secret(for scope: CredentialScope) throws -> Data?
    func setSecret(_ data: Data, for scope: CredentialScope) throws
    func removeSecret(for scope: CredentialScope) throws
}

public struct CredentialStoreError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let shared = KeychainCredentialStore()

    public let service: String

    public init(service: String = "com.bryanthaboi.betterfinder.remote") {
        self.service = service
    }

    private func query(_ scope: CredentialScope) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: scope.account]
    }

    public func secret(for scope: CredentialScope) throws -> Data? {
        var q = query(scope)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        return out as? Data
    }

    public func setSecret(_ data: Data, for scope: CredentialScope) throws {
        let q = query(scope)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "betterfinder \(scope.kind.rawValue.uppercased()) \(scope.resource)@\(scope.host)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
    }

    public func removeSecret(for scope: CredentialScope) throws {
        let status = SecItemDelete(query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialScope: Data] = [:]
    public private(set) var reads: [CredentialScope] = []

    public init() {}

    public func secret(for scope: CredentialScope) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        reads.append(scope)
        return values[scope]
    }

    public func setSecret(_ data: Data, for scope: CredentialScope) throws {
        lock.lock(); values[scope] = data; lock.unlock()
    }

    public func removeSecret(for scope: CredentialScope) throws {
        lock.lock(); values[scope] = nil; lock.unlock()
    }
}

public struct BoundCredentials: Sendable {
    public let scope: CredentialScope
    let store: CredentialStore

    public init(scope: CredentialScope, store: CredentialStore) {
        self.scope = scope
        self.store = store
    }

    public func awsCredentials(forRequestHost host: String) throws -> AWSCredentials {
        guard scope.permits(host: host) else {
            throw ResourceError.destinationMismatch("credentials for \(scope.host) were requested for \(host)")
        }
        guard let data = try store.secret(for: scope) else { throw ResourceError.credentialsMissing(scope.description) }
        return try AWSCredentials.decode(data)
    }
}
