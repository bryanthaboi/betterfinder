import Foundation
import ModHost
import ModIndex
import ModKit
import Security
import Settings

public enum GitHubTokenKeychain {
    public static let service = "betterfinder.github-token"

    public static func read(service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }
}

public final class ModIndexBridge: ModHost.ModIndexProviding, ModVerifiedPackageFetching, @unchecked Sendable {
    public static let defaultURL = URL(string: "https://github.com/bryanthaboi/betterfinder-mod-index/releases/latest/download/index.json")!

    public let client: ModIndexClient
    public let downloadDirectory: URL
    private let downloader: ModArtifactDownloader
    private let lock = NSLock()
    private var lastProblem: String?

    public init(client: ModIndexClient, downloadDirectory: URL, downloader: ModArtifactDownloader = ModArtifactDownloader()) {
        self.client = client
        self.downloadDirectory = downloadDirectory
        self.downloader = downloader
    }

    public convenience init(paths: ModHostPaths, url: URL = ModIndexBridge.defaultURL, tokenService: String = GitHubTokenKeychain.service) {
        let client = ModIndexClient(
            url: url, signatureURL: url.appendingPathExtension("sig"),
            stateDirectory: paths.root.appendingPathComponent("ModIndex", isDirectory: true),
            cacheDirectory: paths.caches.appendingPathComponent("Index", isDirectory: true),
            tokenProvider: { GitHubTokenKeychain.read(service: tokenService) }
        )
        self.init(client: client, downloadDirectory: paths.caches.appendingPathComponent("Downloads", isDirectory: true))
    }

    public var problem: String? { lock.withLock { lastProblem } }

    static func isUnavailable(_ error: Error) -> Bool {
        if let e = error as? ModIndexError {
            switch e {
            case .invalidResponse, .sizeLimit, .insecureURL: return true
            case .invalidFeed, .invalidSignature, .expired, .rollback, .digestMismatch, .untrustedRelease: return false
            }
        }
        return error is URLError
    }

    public func fetch() async throws -> ModIndexSnapshot {
        do {
            let snapshot = try await client.fetch()
            lock.withLock { lastProblem = nil }
            var listings = [ModListing]()
            for var listing in snapshot.listings {
                if let verified = try? await client.verifiedListing(id: listing.id) {
                    listing.permissions = verified.permissions.map(ModHostManagementController.summary)
                }
                listings.append(listing)
            }
            return ModIndexSnapshot(listings: listings, fetchedAt: snapshot.fetchedAt, isExpired: snapshot.isExpired, isOffline: snapshot.isOffline)
        } catch where Self.isUnavailable(error) {
            let token = GitHubTokenKeychain.read() != nil
            lock.withLock { lastProblem = token ? "The mod index isn't reachable right now." : "The mod index isn't reachable. It may be private: add a GitHub token to the Keychain item “\(GitHubTokenKeychain.service)”." }
            return ModIndexSnapshot(listings: [], fetchedAt: nil, isExpired: true, isOffline: true)
        }
    }

    public func fetchPackage(for listing: ModListing) async throws -> URL {
        try await fetchRelease(for: listing).archive
    }

    public func fetchRelease(for listing: ModListing) async throws -> ModReleaseArtifact {
        let release: ModVerifiedRelease
        do { release = try await client.verifiedRelease(id: listing.id) } catch ModIndexError.untrustedRelease {
            throw ModManagementError.installRefused("\(listing.title) isn't signed by a key the index trusts for \(listing.author).")
        }
        guard release.listing.version.description == listing.version else { throw ModManagementError.installRefused("The index changed while installing \(listing.title); refresh and try again.") }
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = try await downloader.download(release, directory: downloadDirectory)
        return ModReleaseArtifact(archive: url, listing: release.listing, author: release.author)
    }
}
