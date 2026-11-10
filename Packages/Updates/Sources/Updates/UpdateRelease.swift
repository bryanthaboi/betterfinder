import Foundation

public struct UpdateAsset: Equatable, Sendable {
    public let name: String
    public let size: Int
    public let downloadURL: URL
    public let apiURL: URL?
    public let sha256: String?

    public init(name: String, size: Int, downloadURL: URL, apiURL: URL?, sha256: String?) {
        self.name = name
        self.size = size
        self.downloadURL = downloadURL
        self.apiURL = apiURL
        self.sha256 = sha256
    }
}

public struct UpdateRelease: Equatable, Sendable {
    public let tag: String
    public let version: SemanticVersion
    public let name: String
    public let notes: String
    public let pageURL: URL?
    public let publishedAt: Date?
    public let zipAsset: UpdateAsset?
    public let dmgAsset: UpdateAsset?

    public init(tag: String, version: SemanticVersion, name: String, notes: String, pageURL: URL?, publishedAt: Date?, zipAsset: UpdateAsset?, dmgAsset: UpdateAsset?) {
        self.tag = tag
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.zipAsset = zipAsset
        self.dmgAsset = dmgAsset
    }

    public var versionString: String { version.description }

    public static func parse(_ data: Data) throws -> UpdateRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.invalidResponse("release JSON could not be decoded")
        }
        if payload.draft == true { throw UpdateError.invalidResponse("release is a draft") }
        guard let version = SemanticVersion(payload.tagName) else {
            throw UpdateError.invalidResponse("tag \(payload.tagName) is not a version")
        }
        let assets = (payload.assets ?? []).compactMap { $0.asset }
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let zip = zips.first { $0.name.lowercased().hasSuffix("-macos.zip") } ?? zips.first
        let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return UpdateRelease(
            tag: payload.tagName,
            version: version,
            name: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
            notes: payload.body ?? "",
            pageURL: payload.htmlURL.flatMap(URL.init(string:)),
            publishedAt: payload.publishedAt.flatMap(parseDate),
            zipAsset: zip,
            dmgAsset: dmg
        )
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String?
        let publishedAt: String?
        let draft: Bool?
        let assets: [AssetPayload]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, draft, assets
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    private struct AssetPayload: Decodable {
        let name: String
        let size: Int?
        let browserDownloadURL: String
        let url: String?
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, url, digest
            case browserDownloadURL = "browser_download_url"
        }

        var asset: UpdateAsset? {
            guard let download = URL(string: browserDownloadURL) else { return nil }
            var sha: String?
            if let digest, digest.lowercased().hasPrefix("sha256:") {
                sha = String(digest.dropFirst(7)).lowercased()
            }
            return UpdateAsset(name: name, size: size ?? 0, downloadURL: download, apiURL: url.flatMap(URL.init(string:)), sha256: sha)
        }
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case invalidResponse(String)
    case network(String)
    case rateLimited
    case noZipAsset
    case downloadFailed(String)
    case checksumMismatch
    case extractionFailed(String)
    case verificationFailed(String)
    case notInstallable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let m): return "The update server sent something unexpected (\(m))."
        case .network(let m): return "Couldn't reach the update server: \(m)"
        case .rateLimited: return "GitHub is rate limiting update checks. Try again later."
        case .noZipAsset: return "This release has no downloadable app archive."
        case .downloadFailed(let m): return "The update download failed: \(m)"
        case .checksumMismatch: return "The downloaded update didn't match its published checksum."
        case .extractionFailed(let m): return "Couldn't unpack the update: \(m)"
        case .verificationFailed(let m): return "The update failed verification and was not installed: \(m)"
        case .notInstallable(let m): return m
        case .installFailed(let m): return "Couldn't install the update: \(m)"
        }
    }
}
