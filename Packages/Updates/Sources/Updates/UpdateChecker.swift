import Foundation

public enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(UpdateRelease)
    case skipped(UpdateRelease)
    case upToDate(latest: SemanticVersion)
    case noInfo(NoInfoReason)
}

public enum NoInfoReason: Equatable, Sendable {
    case notAccessible(Int)
    case noReleases
}

public struct UpdateCheckerConfiguration: Sendable {
    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/bryanthaboi/betterfinder/releases/latest")!

    public var feedURL: URL
    public var currentVersion: String
    public var tokenProvider: (@Sendable () -> String?)?
    public var sessionConfiguration: URLSessionConfiguration
    public var timeout: TimeInterval

    public init(
        feedURL: URL = UpdateCheckerConfiguration.defaultFeedURL,
        currentVersion: String = UpdateCheckerConfiguration.bundleVersion(),
        tokenProvider: (@Sendable () -> String?)? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = 20
    ) {
        self.feedURL = feedURL
        self.currentVersion = currentVersion
        self.tokenProvider = tokenProvider
        self.sessionConfiguration = sessionConfiguration
        self.timeout = timeout
    }

    public static func bundleVersion(_ bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

public final class UpdateChecker: @unchecked Sendable {
    public let configuration: UpdateCheckerConfiguration
    public let preferences: UpdatePreferences
    private let session: URLSession

    public init(configuration: UpdateCheckerConfiguration = UpdateCheckerConfiguration(), preferences: UpdatePreferences = UpdatePreferences()) {
        self.configuration = configuration
        self.preferences = preferences
        let config = configuration.sessionConfiguration
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public var currentVersion: SemanticVersion? { SemanticVersion(configuration.currentVersion) }

    public func makeRequest() -> URLRequest {
        var request = URLRequest(url: configuration.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("betterfinder-updater/\(configuration.currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token = configuration.tokenProvider?(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag = preferences.etag, preferences.cachedReleaseData != nil {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    public func check(userInitiated: Bool = false) async throws -> UpdateCheckResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeRequest())
        } catch {
            throw UpdateError.network((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200:
            let release = try UpdateRelease.parse(data)
            preferences.cachedReleaseData = data
            preferences.etag = http.value(forHTTPHeaderField: "ETag")
            preferences.lastChecked = Date()
            return evaluate(release, userInitiated: userInitiated)
        case 304:
            preferences.lastChecked = Date()
            guard let cached = preferences.cachedReleaseData else {
                preferences.clearFeedCache()
                throw UpdateError.invalidResponse("304 without a cached release")
            }
            return evaluate(try UpdateRelease.parse(cached), userInitiated: userInitiated)
        case 401, 404:
            preferences.clearFeedCache()
            preferences.lastChecked = Date()
            return .noInfo(.notAccessible(http.statusCode))
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.statusCode == 429 {
                throw UpdateError.rateLimited
            }
            preferences.clearFeedCache()
            preferences.lastChecked = Date()
            return .noInfo(.notAccessible(http.statusCode))
        default:
            throw UpdateError.invalidResponse("HTTP \(http.statusCode)")
        }
    }

    public func evaluate(_ release: UpdateRelease, userInitiated: Bool) -> UpdateCheckResult {
        guard let current = currentVersion else { return .upToDate(latest: release.version) }
        guard release.version > current else { return .upToDate(latest: release.version) }
        if !userInitiated, preferences.isSkipped(release.version) { return .skipped(release) }
        return .updateAvailable(release)
    }
}
