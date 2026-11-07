import Foundation
import UniformTypeIdentifiers

public struct ResourceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let localProviderID = "file"
    public static let uriScheme = "bfres"

    public let providerID: String
    public let path: String

    public init(providerID: String, path: String) {
        self.providerID = providerID
        self.path = Self.normalize(path)
    }

    public static func local(_ url: URL) -> ResourceID {
        ResourceID(providerID: localProviderID, path: url.standardizedFileURL.path)
    }

    public static func normalize(_ raw: String) -> String {
        var parts: [Substring] = []
        for c in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    public var isLocal: Bool { providerID == Self.localProviderID }
    public var fileURL: URL? { isLocal ? URL(fileURLWithPath: path) : nil }
    public var isRoot: Bool { path == "/" }

    public var name: String {
        guard !isRoot else { return "" }
        return String(path[path.index(after: path.lastIndex(of: "/")!)...])
    }

    public var components: [String] { path.split(separator: "/").map(String.init) }

    public func appending(_ name: String) -> ResourceID {
        ResourceID(providerID: providerID, path: isRoot ? "/" + name : path + "/" + name)
    }

    public var lexicalParent: ResourceID? {
        guard !isRoot else { return nil }
        var c = components
        c.removeLast()
        return ResourceID(providerID: providerID, path: "/" + c.joined(separator: "/"))
    }

    public func isDescendant(of other: ResourceID) -> Bool {
        guard providerID == other.providerID else { return false }
        if other.isRoot { return true }
        return path == other.path || path.hasPrefix(other.path + "/")
    }

    public var uri: URL {
        if isLocal { return URL(fileURLWithPath: path) }
        var c = URLComponents()
        c.scheme = Self.uriScheme
        c.host = providerID
        c.path = path
        return c.url ?? URL(string: "\(Self.uriScheme)://invalid/")!
    }

    public init?(uri: URL) {
        if uri.isFileURL {
            self = .local(uri)
            return
        }
        guard uri.scheme == Self.uriScheme, let c = URLComponents(url: uri, resolvingAgainstBaseURL: false), let host = c.host, !host.isEmpty else { return nil }
        self.init(providerID: host, path: c.path.isEmpty ? "/" : c.path)
    }

    public var description: String { "\(providerID):\(path)" }
}

public struct ResourceCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let read = ResourceCapabilities(rawValue: 1 << 0)
    public static let write = ResourceCapabilities(rawValue: 1 << 1)
    public static let rename = ResourceCapabilities(rawValue: 1 << 2)
    public static let trash = ResourceCapabilities(rawValue: 1 << 3)
    public static let watch = ResourceCapabilities(rawValue: 1 << 4)
    public static let search = ResourceCapabilities(rawValue: 1 << 5)
    public static let delete = ResourceCapabilities(rawValue: 1 << 6)
    public static let makeDirectory = ResourceCapabilities(rawValue: 1 << 7)
    public static let serverSideCopy = ResourceCapabilities(rawValue: 1 << 8)
    public static let rangedRead = ResourceCapabilities(rawValue: 1 << 9)
    public static let undo = ResourceCapabilities(rawValue: 1 << 10)

    public var canWrite: Bool { contains(.write) }
    public var canRename: Bool { contains(.rename) }
    public var canTrash: Bool { contains(.trash) }
    public var canWatch: Bool { contains(.watch) }
    public var canSearch: Bool { contains(.search) }
    public var canDelete: Bool { contains(.delete) }
    public var canUndo: Bool { contains(.undo) }
}

public struct ResourceItem: Hashable, Sendable, Identifiable {
    public var id: ResourceID
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isHidden: Bool
    public var size: Int64?
    public var modified: Date?
    public var contentTypeIdentifier: String?
    public var etag: String?
    public var checksumSHA256: String?
    public var permissions: String?
    public var owner: String?

    public func isSameVersion(as other: ResourceItem) -> Bool {
        guard isDirectory == other.isDirectory else { return false }
        if isDirectory { return true }
        if size != other.size { return false }
        if let a = modified, let b = other.modified, a != b { return false }
        if let a = etag, let b = other.etag, a != b { return false }
        return true
    }

    public init(id: ResourceID, name: String? = nil, isDirectory: Bool, isSymlink: Bool = false, isHidden: Bool? = nil, size: Int64? = nil, modified: Date? = nil,
                contentTypeIdentifier: String? = nil, etag: String? = nil, checksumSHA256: String? = nil, permissions: String? = nil, owner: String? = nil) {
        let n = name ?? id.name
        self.id = id
        self.name = n
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden ?? n.hasPrefix(".")
        self.size = size
        self.modified = modified
        self.contentTypeIdentifier = contentTypeIdentifier ?? (isDirectory ? UTType.folder.identifier : Self.inferType(n))
        self.etag = etag
        self.checksumSHA256 = checksumSHA256
        self.permissions = permissions
        self.owner = owner
    }

    public init(fileItem f: FileItem) {
        self.init(id: .local(f.url), name: f.name, isDirectory: f.isBrowsableFolder, isSymlink: f.isSymlink, isHidden: f.isHidden,
                  size: f.isDirectory ? nil : f.logicalSize, modified: f.dateModified, contentTypeIdentifier: f.contentTypeIdentifier)
    }

    static func inferType(_ name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return UTType.data.identifier }
        return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
    }

    public var contentType: UTType? { contentTypeIdentifier.flatMap(UTType.init) }

    public var kindDescription: String {
        if isDirectory { return "Folder" }
        return contentType?.localizedDescription ?? "Document"
    }
}

public struct ResourceListOptions: Sendable, Hashable {
    public var showHidden: Bool
    public var pageSize: Int

    public init(showHidden: Bool = false, pageSize: Int = 1000) {
        self.showHidden = showHidden
        self.pageSize = max(1, pageSize)
    }
}

public struct ResourceUploadOptions: Sendable, Hashable {
    public var overwrite: Bool
    public var sha256: String?
    public var contentType: String?

    public init(overwrite: Bool = false, sha256: String? = nil, contentType: String? = nil) {
        self.overwrite = overwrite
        self.sha256 = sha256
        self.contentType = contentType
    }
}

public enum ResourceError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case notFound(String)
    case alreadyExists(String)
    case notADirectory(String)
    case isADirectory(String)
    case invalidName(String)
    case permissionDenied(String)
    case authenticationFailed(String)
    case hostKeyUnknown(host: String, fingerprints: [String])
    case hostKeyChanged(host: String)
    case hostKeyRejected(host: String)
    case connectionFailed(String)
    case remote(code: String, message: String)
    case verificationFailed(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case providerUnavailable(String)
    case credentialsMissing(String)
    case destinationMismatch(String)
    case cancelled

    public var isTransient: Bool {
        switch self {
        case .connectionFailed: return true
        case .remote(let code, _): return ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout", "HTTP500", "HTTP502", "HTTP503", "HTTP504"].contains(code)
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "\(what) isn’t supported here."
        case .notFound(let p): return "“\(p)” couldn’t be found."
        case .alreadyExists(let p): return "An item named “\(p)” already exists."
        case .notADirectory(let p): return "“\(p)” isn’t a folder."
        case .isADirectory(let p): return "“\(p)” is a folder."
        case .invalidName(let n): return "“\(n)” isn’t a valid name for this server."
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .authenticationFailed(let m): return "Authentication failed: \(m)"
        case .hostKeyUnknown(let h, _): return "The identity of “\(h)” hasn’t been verified."
        case .hostKeyChanged(let h): return "The host key for “\(h)” has changed. This could mean someone is intercepting the connection. Remove the old key from known_hosts only if you’re sure the change is legitimate."
        case .hostKeyRejected(let h): return "You chose not to trust “\(h)”."
        case .connectionFailed(let m): return "The connection failed: \(m)"
        case .remote(let code, let message): return message.isEmpty ? "The server returned \(code)." : "\(message) (\(code))"
        case .verificationFailed(let m): return "Verification failed: \(m)"
        case .insufficientSpace(let needed, let available): return "Not enough space to stage the transfer (\(SizeFormatter.string(needed)) needed, \(SizeFormatter.string(available)) available)."
        case .providerUnavailable(let p): return "The location “\(p)” isn’t connected."
        case .credentialsMissing(let s): return "No saved credentials for \(s)."
        case .destinationMismatch(let m): return "Refused to send credentials: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}

public final class ResourceWatchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    public func cancel() {
        lock.lock()
        let c = onCancel
        onCancel = nil
        lock.unlock()
        c?()
    }

    deinit { cancel() }
}

public protocol ResourceProvider: AnyObject, Sendable {
    var providerID: String { get }
    var displayName: String { get }
    var capabilities: ResourceCapabilities { get }
    var root: ResourceID { get }
    func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error>
    func stat(_ id: ResourceID) async throws -> ResourceItem
    func read(_ id: ResourceID, range: Range<Int64>?) async throws -> Data
    func watch(_ directory: ResourceID, handler: @escaping @Sendable () -> Void) -> ResourceWatchToken?
    func parent(of id: ResourceID) -> ResourceID?
    func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem
    func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem
    func makeDirectory(_ id: ResourceID) async throws -> ResourceItem
    func delete(_ id: ResourceID, recursive: Bool) async throws
    @discardableResult
    func deleteIfUnchanged(_ id: ResourceID, from expected: ResourceItem) async throws -> Bool
    func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem
    func copy(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem
    func trash(_ id: ResourceID) async throws
}

public extension ResourceProvider {
    func watch(_ directory: ResourceID, handler: @escaping @Sendable () -> Void) -> ResourceWatchToken? { nil }

    func parent(of id: ResourceID) -> ResourceID? {
        guard id.providerID == providerID, id != root, id.isDescendant(of: root) else { return nil }
        return id.lexicalParent
    }

    func read(_ id: ResourceID, range: Range<Int64>?) async throws -> Data { throw ResourceError.unsupported("Reading") }
    func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem { throw ResourceError.unsupported("Downloading") }
    func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem { throw ResourceError.unsupported("Uploading") }
    func makeDirectory(_ id: ResourceID) async throws -> ResourceItem { throw ResourceError.unsupported("Creating folders") }
    func delete(_ id: ResourceID, recursive: Bool) async throws { throw ResourceError.unsupported("Deleting") }

    @discardableResult
    func deleteIfUnchanged(_ id: ResourceID, from expected: ResourceItem) async throws -> Bool {
        let now = try await stat(id)
        guard now.isSameVersion(as: expected) else { return false }
        try await delete(id, recursive: false)
        return true
    }
    func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem { throw ResourceError.unsupported("Renaming") }
    func copy(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem { throw ResourceError.unsupported("Server-side copy") }
    func trash(_ id: ResourceID) async throws { throw ResourceError.unsupported("Moving to the Trash") }

    func listAll(_ directory: ResourceID, options: ResourceListOptions = .init(showHidden: true)) async throws -> [ResourceItem] {
        var all: [ResourceItem] = []
        for try await page in list(directory, options: options) { all.append(contentsOf: page) }
        try Task.checkCancellation()
        return all
    }

    func exists(_ id: ResourceID) async throws -> ResourceItem? {
        do { return try await stat(id) } catch ResourceError.notFound { return nil }
    }
}

public extension Notification.Name {
    static let resourceProvidersDidChange = Notification.Name("ResourceProvidersDidChange")
}

public final class ResourceRegistrationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return onCancel != nil
    }

    public func cancel() {
        lock.lock()
        let c = onCancel
        onCancel = nil
        lock.unlock()
        c?()
    }
}

public struct ResourceProviderRegistrationError: Error, LocalizedError, Sendable, Equatable {
    public let providerID: String
    public let existingOwner: String
    public var errorDescription: String? { "Resource provider “\(providerID)” is already registered by \(existingOwner)." }
}

public final class ResourceProviderRegistry: @unchecked Sendable {
    public static let shared: ResourceProviderRegistry = {
        let r = ResourceProviderRegistry()
        _ = try? r.register(LocalResourceProvider.shared, owner: "betterfinder")
        return r
    }()

    private struct Entry {
        let seq: UInt64
        let provider: ResourceProvider
        let owner: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextSeq: UInt64 = 0

    public init() {}

    @discardableResult
    public func register(_ provider: ResourceProvider, owner: String) throws -> ResourceRegistrationToken {
        lock.lock()
        if let existing = entries.first(where: { $0.provider.providerID == provider.providerID }) {
            lock.unlock()
            throw ResourceProviderRegistrationError(providerID: provider.providerID, existingOwner: existing.owner)
        }
        nextSeq += 1
        let seq = nextSeq
        entries.append(Entry(seq: seq, provider: provider, owner: owner))
        lock.unlock()
        NotificationCenter.default.post(name: .resourceProvidersDidChange, object: self)
        return ResourceRegistrationToken { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.entries.removeAll { $0.seq == seq }
            self.lock.unlock()
            NotificationCenter.default.post(name: .resourceProvidersDidChange, object: self)
        }
    }

    public func provider(for providerID: String) -> ResourceProvider? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.provider.providerID == providerID }?.provider
    }

    public func provider(for id: ResourceID) -> ResourceProvider? { provider(for: id.providerID) }

    public var providers: [ResourceProvider] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.provider)
    }

    public var providerIDs: [String] { providers.map(\.providerID) }

    public func owner(of providerID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.provider.providerID == providerID }?.owner
    }

    public func removeAll(owner: String) {
        lock.lock()
        let before = entries.count
        entries.removeAll { $0.owner == owner }
        let changed = before != entries.count
        lock.unlock()
        if changed { NotificationCenter.default.post(name: .resourceProvidersDidChange, object: self) }
    }
}
