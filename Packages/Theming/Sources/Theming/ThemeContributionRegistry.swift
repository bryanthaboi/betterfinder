import Foundation

public struct ThemeRegistrationToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum ThemeContributionError: LocalizedError, Equatable {
    case emptyOwner
    case invalidTheme(index: Int, message: String)
    case duplicateID(String)
    case idCollision(String)
    case readOnly(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOwner: return "A theme contribution needs an owner id."
        case .invalidTheme(let i, let m): return "Theme #\(i + 1) is invalid: \(m)"
        case .duplicateID(let id): return "The contribution contains theme id \"\(id)\" more than once."
        case .idCollision(let id): return "A theme with id \"\(id)\" already exists."
        case .readOnly(let id): return "\"\(id)\" is provided by a mod and can't be edited. Duplicate it first."
        }
    }
}

public struct ThemeSource {
    public var json: Data
    public var assetRoot: URL?

    public init(json: Data, assetRoot: URL? = nil) {
        self.json = json
        self.assetRoot = assetRoot
    }

    public init(fileURL: URL) throws {
        self.json = try Data(contentsOf: fileURL)
        self.assetRoot = fileURL.deletingLastPathComponent()
    }
}

struct ContributedTheme {
    var theme: Theme
    var ownerID: String
    var assetRoot: URL?
}

public struct ThemeContributionInfo: Hashable, Sendable {
    public var token: ThemeRegistrationToken
    public var ownerID: String
    public var themeIDs: [String]
}

@MainActor
public final class ThemeContributionRegistry {
    public static let shared = ThemeContributionRegistry(manager: .shared)

    public let manager: ThemeManager
    private var entries: [ThemeRegistrationToken: ThemeContributionInfo] = [:]
    private var order: [ThemeRegistrationToken] = []

    public init(manager: ThemeManager) {
        self.manager = manager
    }

    @discardableResult
    public func register(_ sources: [ThemeSource], owner ownerID: String) throws -> ThemeRegistrationToken {
        guard !ownerID.isEmpty else { throw ThemeContributionError.emptyOwner }
        var staged: [ContributedTheme] = []
        var seen: Set<String> = []
        let takenIDs = Set(manager.available.map(\.id)).union(manager.contributed.keys)
        for (index, source) in sources.enumerated() {
            var theme: Theme
            do {
                theme = try JSONDecoder().decode(Theme.self, from: source.json)
            } catch {
                throw ThemeContributionError.invalidTheme(index: index, message: error.localizedDescription)
            }
            if theme.id.isEmpty { theme.id = ThemeManager.slug(theme.name) }
            guard !theme.id.isEmpty else { throw ThemeContributionError.invalidTheme(index: index, message: "missing id and name") }
            guard theme.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
                throw ThemeContributionError.invalidTheme(index: index, message: "id \"\(theme.id)\" has unsupported characters")
            }
            guard seen.insert(theme.id).inserted else { throw ThemeContributionError.duplicateID(theme.id) }
            guard !takenIDs.contains(theme.id), !manager.userThemeExists(theme.id) else {
                throw ThemeContributionError.idCollision(theme.id)
            }
            theme.normalize()
            staged.append(ContributedTheme(theme: theme, ownerID: ownerID, assetRoot: source.assetRoot?.standardizedFileURL))
        }
        let token = ThemeRegistrationToken()
        entries[token] = ThemeContributionInfo(token: token, ownerID: ownerID, themeIDs: staged.map(\.theme.id))
        order.append(token)
        manager.installContributed(staged)
        return token
    }

    @discardableResult
    public func register(themeFiles: [URL], owner ownerID: String) throws -> ThemeRegistrationToken {
        let sources = try themeFiles.map { try ThemeSource(fileURL: $0) }
        return try register(sources, owner: ownerID)
    }

    @discardableResult
    public func remove(_ token: ThemeRegistrationToken) -> Bool {
        guard let info = entries.removeValue(forKey: token) else { return false }
        order.removeAll { $0 == token }
        manager.removeContributed(ids: Set(info.themeIDs))
        return true
    }

    @discardableResult
    public func removeAll(owner ownerID: String) -> Int {
        let tokens = order.filter { entries[$0]?.ownerID == ownerID }
        for t in tokens { remove(t) }
        return tokens.count
    }

    public func registrations(owner ownerID: String? = nil) -> [ThemeContributionInfo] {
        order.compactMap { entries[$0] }.filter { ownerID == nil || $0.ownerID == ownerID }
    }

    public func owner(ofTheme id: String) -> String? {
        manager.contributionOwner(of: id)
    }
}
