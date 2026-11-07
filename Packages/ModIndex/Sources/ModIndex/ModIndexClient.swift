import Foundation
import ModKit
import Settings

public protocol ModIndexProviding {
    func fetch() async throws -> ModIndexSnapshot
}

public actor ModIndexClient: ModIndexProviding {
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/bryanthaboi/betterfinder-mod-index/main/index.json")!
    private let url: URL
    private let signatureURL: URL
    private let stateURL: URL
    private let keys: [TrustedIndexKey]
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String?
    private let now: @Sendable () -> Date
    private let cacheURL: URL
    private let appVersion: SemVer
    private let apiVersion: SemVer
    private var fetching = false

    private struct Cache: Codable {
        let data: Data
        let signature: Data
        let etag: String?
        let fetchedAt: Date
    }

    private struct Watermark: Codable {
        let serial: UInt64
        let generatedAt: Date
        let sha256: String
    }

    public init(url: URL = ModIndexClient.defaultURL, trustedKeys: [TrustedIndexKey] = TrustedIndexKey.pinned, signatureURL: URL? = nil,
                stateDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("betterfinder/ModIndex"),
                cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("betterfinder/ModIndex"),
                session: URLSession = .shared, appVersion: SemVer = SemVer(1, 0, 0), apiVersion: SemVer = SemVer(1, 0, 0),
                tokenProvider: @escaping @Sendable () async throws -> String? = { nil },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url; self.signatureURL = signatureURL ?? url.appendingPathExtension("sig")
        stateURL = stateDirectory.appendingPathComponent(ModKit.SHA256.hex(url.absoluteString) + ".watermark.json")
        keys = trustedKeys; self.session = session; self.tokenProvider = tokenProvider; self.now = now
        self.appVersion = appVersion; self.apiVersion = apiVersion
        cacheURL = cacheDirectory.appendingPathComponent(ModKit.SHA256.hex(url.absoluteString) + ".json")
    }

    public func fetch() async throws -> ModIndexSnapshot {
        guard !fetching else { throw ModIndexError.invalidResponse }
        fetching = true
        defer { fetching = false }
        let cache: Cache?
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
        } else { cache = nil }
        let oldFeed = try cache.map { try IndexVerifier.verify($0.data, signature: $0.signature, keys: keys, now: now(), allowExpired: true) }
        let watermark: Watermark?
        if FileManager.default.fileExists(atPath: stateURL.path) {
            watermark = try JSONDecoder().decode(Watermark.self, from: Data(contentsOf: stateURL))
        } else { watermark = nil }
        if let oldFeed, let cache { try checkWatermark(oldFeed, data: cache.data, watermark: watermark) }
        do {
            var request = try await authenticatedRequest(url)
            request.setValue(cache?.etag, forHTTPHeaderField: "If-None-Match")
            let (data, response) = try await boundedData(request, session: session, limit: 8_388_608)
            if response.statusCode == 304, let cache, let oldFeed {
                guard now() < oldFeed.expiresAt else { throw ModIndexError.expired }
                return snapshot(oldFeed, fetchedAt: cache.fetchedAt, offline: false)
            }
            guard response.statusCode == 200 else { throw ModIndexError.invalidResponse }
            let (signature, sigResponse) = try await boundedData(authenticatedRequest(signatureURL), session: session, limit: 64)
            guard sigResponse.statusCode == 200 else { throw ModIndexError.invalidResponse }
            let feed = try IndexVerifier.verify(data, signature: signature, keys: keys, now: now())
            try checkWatermark(feed, data: data, watermark: watermark)
            if let oldFeed, let cache {
                guard feed.serial >= oldFeed.serial, feed.generatedAt >= oldFeed.generatedAt,
                      (feed.serial > oldFeed.serial && feed.generatedAt > oldFeed.generatedAt) || data == cache.data
                else { throw ModIndexError.rollback }
            }
            let record = Cache(data: data, signature: signature, etag: response.value(forHTTPHeaderField: "ETag"), fetchedAt: now())
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Watermark(serial: feed.serial, generatedAt: feed.generatedAt, sha256: ModKit.SHA256.hex(data))).write(to: stateURL, options: .atomic)
            try JSONEncoder().encode(record).write(to: cacheURL, options: .atomic)
            return snapshot(feed, fetchedAt: record.fetchedAt, offline: false)
        } catch let error as URLError {
            guard [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code),
                  let cache, let oldFeed else { throw error }
            return snapshot(oldFeed, fetchedAt: cache.fetchedAt, offline: true)
        }
    }

    private func checkWatermark(_ feed: IndexFeed, data: Data, watermark: Watermark?) throws {
        guard let watermark else { return }
        guard feed.serial >= watermark.serial, feed.generatedAt >= watermark.generatedAt,
              (feed.serial > watermark.serial && feed.generatedAt > watermark.generatedAt) || ModKit.SHA256.hex(data) == watermark.sha256
        else { throw ModIndexError.rollback }
    }

    private func authenticatedRequest(_ url: URL) async throws -> URLRequest {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw ModIndexError.insecureURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if url.host == "api.github.com" { request.setValue("application/octet-stream", forHTTPHeaderField: "Accept") }
        if let token = try await tokenProvider() { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func snapshot(_ feed: IndexFeed, fetchedAt: Date, offline: Bool) -> ModIndexSnapshot {
        let listings = feed.mods.map { entry in
            let m = entry.listing
            let compatible = m.api.contains(apiVersion) && m.app.contains(appVersion)
            return ModListing(id: m.id, title: m.title, author: m.author, version: m.version.description,
                              summary: m.summary ?? "", categories: m.categories.map(\.rawValue), tags: m.tags ?? [],
                              permissions: m.permissions.map { p in
                                  PermissionSummary(id: ModPermissionID.make(p), title: p.kind.summary, reason: p.reason ?? p.kind.summary, risk: .high)
                              }, versions: [ModVersionInfo(version: m.version.description, isCompatible: compatible)],
                              repoURL: URL(string: m.repo), isCompatible: compatible,
                              compatibilityNote: compatible ? nil : "Requires API \(m.api) and app \(m.app)", updatedAt: feed.generatedAt)
        }
        return ModIndexSnapshot(listings: listings, fetchedAt: fetchedAt, isExpired: now() >= feed.expiresAt, isOffline: offline)
    }

    private func verifiedFeed() throws -> IndexFeed {
        let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
        let feed = try IndexVerifier.verify(cache.data, signature: cache.signature, keys: keys, now: now())
        let watermark = try JSONDecoder().decode(Watermark.self, from: Data(contentsOf: stateURL))
        try checkWatermark(feed, data: cache.data, watermark: watermark)
        return feed
    }

    public func verifiedListing(id: String) throws -> ModIndexListing {
        guard let listing = try verifiedFeed().mods.first(where: { $0.listing.id == id })?.listing else { throw ModIndexError.invalidFeed }
        return listing
    }

    public func verifiedAuthorKeys(author: String) throws -> ModAuthorFile {
        guard let file = try verifiedFeed().author(author) else { throw ModIndexError.untrustedRelease }
        return file
    }

    public func verifiedAuthors() throws -> [ModAuthorFile] { try verifiedFeed().authors }

    public func verifiedRelease(id: String) throws -> ModVerifiedRelease {
        let feed = try verifiedFeed()
        guard let listing = feed.mods.first(where: { $0.listing.id == id })?.listing else { throw ModIndexError.invalidFeed }
        guard let author = feed.author(listing.author) else { throw ModIndexError.untrustedRelease }
        return try ModVerifiedRelease(listing: listing, author: author)
    }
}

private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var request = request
        if request.url?.host != response.url?.host { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
}

func boundedData(_ request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
    let (bytes, response) = try await session.bytes(for: request, delegate: HTTPSRedirectDelegate())
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else { throw ModIndexError.invalidResponse }
    guard response.expectedContentLength <= Int64(limit) else { throw ModIndexError.sizeLimit }
    var data = Data()
    for try await byte in bytes {
        guard data.count < limit else { throw ModIndexError.sizeLimit }
        data.append(byte)
    }
    return (data, response)
}
