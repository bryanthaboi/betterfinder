import Foundation
import Integration
import ModKit

public struct ModGrantRecord: Codable, Equatable, Sendable {
    public var modId: String
    public var approved: [ModPermission]
    public var rootBindings: [String: UUID]
    public var approvedAt: Date?
    public var revision: Int

    public init(modId: String, approved: [ModPermission] = [], rootBindings: [String: UUID] = [:], approvedAt: Date? = nil, revision: Int = 0) {
        self.modId = modId
        self.approved = approved
        self.rootBindings = rootBindings
        self.approvedAt = approvedAt
        self.revision = revision
    }

    public var approvedIDs: Set<String> { Set(approved.map(ModPermissionID.make)) }
}

public enum ModGrantError: LocalizedError, Equatable {
    case notDeclared(String)
    case rootNotDeclared(String)
    case access(String)

    public var errorDescription: String? {
        switch self {
        case .notDeclared(let id): return "permission \(id) is not declared by the manifest"
        case .rootNotDeclared(let id): return "no fs grant declares root '\(id)'"
        case .access(let m): return m
        }
    }
}

public final class ModGrantStore: @unchecked Sendable {
    private let paths: ModHostPaths
    private let lock = NSLock()
    private var cache: [String: ModGrantRecord] = [:]
    public let scopedAccess: ScopedAccessAuthorizing

    public init(paths: ModHostPaths, scopedAccess: ScopedAccessAuthorizing) {
        self.paths = paths
        self.scopedAccess = scopedAccess
    }

    private func url(_ id: String) -> URL { paths.dataDirectory(id).appendingPathComponent("grants.json") }

    public func record(_ id: String) -> ModGrantRecord {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[id] { return r }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = (try? Data(contentsOf: url(id))).flatMap { try? d.decode(ModGrantRecord.self, from: $0) } ?? ModGrantRecord(modId: id)
        cache[id] = r
        return r
    }

    private func save(_ r: ModGrantRecord) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try ModFiles.writePrivate(try e.encode(r), to: url(r.modId))
        lock.lock(); cache[r.modId] = r; lock.unlock()
    }

    @discardableResult
    public func approve(_ manifest: ModManifest, permissionIDs: Set<String>) throws -> ModGrantRecord {
        let declared = Dictionary(manifest.permissions.map { (ModPermissionID.make($0), $0) }, uniquingKeysWith: { a, _ in a })
        if let unknown = permissionIDs.sorted().first(where: { declared[$0] == nil }) { throw ModGrantError.notDeclared(unknown) }
        var r = record(manifest.id)
        r.approved = manifest.permissions.filter { permissionIDs.contains(ModPermissionID.make($0)) }
        r.approvedAt = Date()
        r.revision += 1
        let liveRoots = Set(r.approved.compactMap(\.rootId))
        for (rootId, uuid) in r.rootBindings where !liveRoots.contains(rootId) {
            scopedAccess.removeRoot(uuid)
            r.rootBindings.removeValue(forKey: rootId)
        }
        try save(r)
        return r
    }

    @discardableResult
    public func approveAll(_ manifest: ModManifest) throws -> ModGrantRecord {
        try approve(manifest, permissionIDs: Set(manifest.permissions.map(ModPermissionID.make)))
    }

    public func reconcile(_ manifest: ModManifest) throws -> ModGrantRecord {
        var r = record(manifest.id)
        let kept = r.approved.filter { manifest.permissions.contains($0) }
        guard kept != r.approved else { return r }
        r.approved = kept
        r.revision += 1
        try save(r)
        return r
    }

    @discardableResult
    public func bindRoot(_ manifest: ModManifest, rootId: String, url: URL) throws -> ScopedRoot {
        let grants = manifest.permissions.filter { $0.rootId == rootId && ($0.kind == .fsRead || $0.kind == .fsWrite) }
        guard !grants.isEmpty else { throw ModGrantError.rootNotDeclared(rootId) }
        let mode: ScopedAccessMode = grants.contains { $0.kind == .fsWrite } ? .readWrite : .read
        let root: ScopedRoot
        do { root = try scopedAccess.addRoot(url, modID: manifest.id, purpose: "root:\(rootId)", mode: mode) } catch {
            throw ModGrantError.access(error.localizedDescription)
        }
        var r = record(manifest.id)
        if let old = r.rootBindings[rootId], old != root.id, !r.rootBindings.contains(where: { $0.key != rootId && $0.value == old }) {
            scopedAccess.removeRoot(old)
        }
        r.rootBindings[rootId] = root.id
        r.revision += 1
        try save(r)
        return root
    }

    public func boundRoot(_ modId: String, rootId: String) -> ScopedRoot? {
        guard let uuid = record(modId).rootBindings[rootId] else { return nil }
        return scopedAccess.roots(for: modId).first { $0.id == uuid }
    }

    public func revokeAll(_ modId: String) {
        scopedAccess.removeAllGrants(for: modId)
        lock.lock(); cache.removeValue(forKey: modId); lock.unlock()
        try? FileManager.default.removeItem(at: url(modId))
    }
}

extension Array where Element == ModPermission {
    func satisfies(_ r: GrantRequirement) -> Bool { contains { ModGrants.satisfies($0, r) } }

    func fs(_ kind: ModPermissionKind, scope: FSScope) -> [ModPermission] {
        filter { $0.kind == kind && $0.scope == scope }
    }

    var selectionLevel: SelectionLevel? {
        let levels = filter { $0.kind == .uiSelection }.compactMap(\.level)
        if levels.contains(.metadata) { return .metadata }
        if levels.contains(.paths) { return .paths }
        return levels.isEmpty ? nil : .names
    }
}
