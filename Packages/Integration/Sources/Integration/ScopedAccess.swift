import AppKit
import Foundation

public enum ScopedAccessMode: String, Codable, Comparable, Sendable {
    case read
    case readWrite

    public static func < (lhs: ScopedAccessMode, rhs: ScopedAccessMode) -> Bool {
        lhs == .read && rhs == .readWrite
    }

    func satisfies(_ requested: ScopedAccessMode) -> Bool { self >= requested }
}

public struct ScopedRoot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var modID: String
    public var path: String
    public var purpose: String
    public var mode: ScopedAccessMode
    public var createdAt: Date

    public init(id: UUID = UUID(), modID: String, path: String, purpose: String, mode: ScopedAccessMode, createdAt: Date = Date()) {
        self.id = id
        self.modID = modID
        self.path = path
        self.purpose = purpose
        self.mode = mode
        self.createdAt = createdAt
    }
}

public struct SelectionToken: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var modID: String
    public var paths: [String]
    public var mode: ScopedAccessMode
    public var expiresAt: Date
}

public enum ScopedAccessDecision: Equatable, Sendable {
    public enum Via: Equatable, Sendable {
        case root(UUID)
        case selection(UUID)
    }

    public enum Reason: String, Equatable, Sendable {
        case invalidPath
        case noGrant
        case unknownToken
        case expiredToken
        case tokenBelongsToAnotherMod
        case insufficientMode
        case outsideScope
    }

    case allowed(Via)
    case denied(Reason)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

public enum ScopedAccessError: LocalizedError {
    case invalidRoot(String)
    case bookmarkFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let m): return "That folder can't be granted: \(m)"
        case .bookmarkFailed(let m): return "Couldn't remember the folder: \(m)"
        }
    }
}

public protocol ScopedAccessAuthorizing: AnyObject, Sendable {
    func roots(for modID: String) -> [ScopedRoot]
    func addRoot(_ url: URL, modID: String, purpose: String, mode: ScopedAccessMode) throws -> ScopedRoot
    func removeRoot(_ id: UUID)
    func removeAllGrants(for modID: String)
    func issueSelectionToken(modID: String, urls: [URL], mode: ScopedAccessMode, lifetime: TimeInterval) -> SelectionToken
    func revokeSelectionToken(_ id: UUID)
    func authorize(_ url: URL, mode: ScopedAccessMode, modID: String, token: UUID?) -> ScopedAccessDecision
}

public protocol BookmarkCoding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SecurityScopedBookmarkCoder: BookmarkCoding {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

public final class ScopedAccessAuthorizer: ScopedAccessAuthorizing, @unchecked Sendable {
    public static let shared = ScopedAccessAuthorizer()
    public static let defaultsKey = "scopedAccessGrants.v1"
    public static let maxTokenLifetime: TimeInterval = 300

    private struct Persisted: Codable {
        var root: ScopedRoot
        var bookmark: Data
    }

    private struct Active {
        var root: ScopedRoot
        var bookmark: Data
        var resolvedPath: String
        var accessedURL: URL?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let coder: BookmarkCoding
    private let now: @Sendable () -> Date
    private let permissions: PermissionsCenter
    private var active: [UUID: Active] = [:]
    private var tokens: [UUID: SelectionToken] = [:]

    public init(
        defaults: UserDefaults = .standard,
        coder: BookmarkCoding = SecurityScopedBookmarkCoder(),
        permissions: PermissionsCenter = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.coder = coder
        self.permissions = permissions
        self.now = now
        load()
    }

    deinit {
        for entry in active.values { if let url = entry.accessedURL { coder.stopAccessing(url) } }
    }

    public func roots(for modID: String) -> [ScopedRoot] {
        lock.lock()
        defer { lock.unlock() }
        return active.values.map(\.root).filter { $0.modID == modID }.sorted { $0.createdAt < $1.createdAt }
    }

    public var allRoots: [ScopedRoot] {
        lock.lock()
        defer { lock.unlock() }
        return active.values.map(\.root).sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func addRoot(_ url: URL, modID: String, purpose: String, mode: ScopedAccessMode = .read) throws -> ScopedRoot {
        guard !modID.isEmpty else { throw ScopedAccessError.invalidRoot("missing mod id") }
        guard url.isFileURL else { throw ScopedAccessError.invalidRoot("not a file location") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScopedAccessError.invalidRoot("not an existing folder")
        }
        let path = Self.canonicalPath(url)
        guard path != "/" else { throw ScopedAccessError.invalidRoot("the whole disk can't be granted") }
        let bookmark: Data
        do { bookmark = try coder.makeBookmark(for: url) } catch { throw ScopedAccessError.bookmarkFailed(error.localizedDescription) }

        lock.lock()
        defer { lock.unlock() }
        if let existing = active.values.first(where: { $0.root.modID == modID && $0.resolvedPath == path }) {
            if existing.root.mode.satisfies(mode) { return existing.root }
            var updated = existing
            updated.root.mode = mode
            active[existing.root.id] = updated
            persistLocked()
            return updated.root
        }
        let root = ScopedRoot(modID: modID, path: path, purpose: purpose, mode: mode, createdAt: now())
        let accessed = coder.startAccessing(url) ? url : nil
        active[root.id] = Active(root: root, bookmark: bookmark, resolvedPath: path, accessedURL: accessed)
        persistLocked()
        return root
    }

    @MainActor
    public func pickRoot(modID: String, purpose: String, mode: ScopedAccessMode = .read, message: String? = nil) throws -> ScopedRoot? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = message ?? purpose
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try addRoot(url, modID: modID, purpose: purpose, mode: mode)
    }

    public func removeRoot(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let entry = active.removeValue(forKey: id), let url = entry.accessedURL { coder.stopAccessing(url) }
        persistLocked()
    }

    public func removeAllGrants(for modID: String) {
        lock.lock()
        defer { lock.unlock() }
        for (id, entry) in active where entry.root.modID == modID {
            if let url = entry.accessedURL { coder.stopAccessing(url) }
            active.removeValue(forKey: id)
        }
        tokens = tokens.filter { $0.value.modID != modID }
        persistLocked()
    }

    public func issueSelectionToken(modID: String, urls: [URL], mode: ScopedAccessMode = .read, lifetime: TimeInterval = 30) -> SelectionToken {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        tokens = tokens.filter { $0.value.expiresAt > current }
        let ttl = min(max(lifetime, 1), Self.maxTokenLifetime)
        let token = SelectionToken(
            id: UUID(),
            modID: modID,
            paths: urls.filter(\.isFileURL).map(Self.canonicalPath),
            mode: mode,
            expiresAt: current.addingTimeInterval(ttl)
        )
        tokens[token.id] = token
        return token
    }

    public func revokeSelectionToken(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeValue(forKey: id)
    }

    public func authorize(_ url: URL, mode: ScopedAccessMode, modID: String, token: UUID? = nil) -> ScopedAccessDecision {
        guard url.isFileURL, !url.path.isEmpty else { return .denied(.invalidPath) }
        let path = Self.canonicalPath(url)
        lock.lock()
        defer { lock.unlock() }

        if let token {
            guard let t = tokens[token] else { return .denied(.unknownToken) }
            guard t.modID == modID else { return .denied(.tokenBelongsToAnotherMod) }
            guard t.expiresAt > now() else {
                tokens.removeValue(forKey: token)
                return .denied(.expiredToken)
            }
            guard t.mode.satisfies(mode) else { return .denied(.insufficientMode) }
            guard t.paths.contains(where: { Self.contains($0, path) }) else { return .denied(.outsideScope) }
            return .allowed(.selection(token))
        }

        let mine = active.values.filter { $0.root.modID == modID }
        guard !mine.isEmpty else { return .denied(.noGrant) }
        let covering = mine.filter { Self.contains($0.resolvedPath, path) }
        guard !covering.isEmpty else { return .denied(.outsideScope) }
        guard let match = covering.first(where: { $0.root.mode.satisfies(mode) }) else { return .denied(.insufficientMode) }
        return .allowed(.root(match.root.id))
    }

    public func systemPermissionStatus(for url: URL) -> PermissionStatus? {
        let path = Self.canonicalPath(url)
        let home = Self.canonicalPath(permissions.home)
        let table: [(String, PermissionKind)] = [
            (home + "/Desktop", .desktop),
            (home + "/Documents", .documents),
            (home + "/Downloads", .downloads),
        ]
        if let hit = table.first(where: { Self.contains($0.0, path) }) { return permissions.status(for: hit.1) }
        if path.hasPrefix("/Volumes/") { return permissions.status(for: .removableVolumes) }
        return nil
    }

    static func canonicalPath(_ url: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().standardizedFileURL.path }
        let parent = url.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            return parent.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        }
        return url.standardizedFileURL.path
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([Persisted].self, from: data) else { return }
        var changed = false
        for item in saved {
            guard let resolved = try? coder.resolve(item.bookmark) else {
                changed = true
                continue
            }
            var root = item.root
            var bookmark = item.bookmark
            let path = Self.canonicalPath(resolved.url)
            if resolved.isStale, let fresh = try? coder.makeBookmark(for: resolved.url) {
                bookmark = fresh
                changed = true
            }
            if root.path != path {
                root.path = path
                changed = true
            }
            let accessed = coder.startAccessing(resolved.url) ? resolved.url : nil
            active[root.id] = Active(root: root, bookmark: bookmark, resolvedPath: path, accessedURL: accessed)
        }
        if changed { persistLocked() }
    }

    private func persistLocked() {
        let items = active.values.map { Persisted(root: $0.root, bookmark: $0.bookmark) }.sorted { $0.root.createdAt < $1.root.createdAt }
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
