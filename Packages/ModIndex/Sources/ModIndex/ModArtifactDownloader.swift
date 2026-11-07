import Foundation
import ModKit

public struct ModVerifiedRelease: Sendable, Equatable {
    public let listing: ModIndexListing
    public let author: ModAuthorFile

    public init(listing: ModIndexListing, author: ModAuthorFile) throws {
        guard author.author == listing.author, ModAuthorKeys.verifyRelease(listing, authors: [author], at: nil).isEmpty else { throw ModIndexError.untrustedRelease }
        self.listing = listing
        self.author = author
    }
}

public struct ModArtifactDownloader {
    public let maximumBytes: Int
    private let session: URLSession

    public init(maximumBytes: Int = 67_108_864, session: URLSession = .shared) {
        self.maximumBytes = maximumBytes
        self.session = session
    }

    public func download(_ release: ModVerifiedRelease, directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        let url = try await download(release.listing, directory: directory)
        guard let data = try? Data(contentsOf: url), ModAuthorKeys.verifyArtifact(data, listing: release.listing).isEmpty else {
            try? FileManager.default.removeItem(at: url)
            throw ModIndexError.digestMismatch
        }
        return url
    }

    public func download(_ listing: ModIndexListing, directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        guard let url = URL(string: listing.release.assetURL), url.scheme == "https", url.user == nil, url.password == nil else { throw ModIndexError.insecureURL }
        guard listing.release.bytes > 0, listing.release.bytes <= maximumBytes else { throw ModIndexError.sizeLimit }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let (data, response) = try await boundedData(request, session: session, limit: min(maximumBytes, listing.release.bytes))
        guard response.statusCode == 200 else { throw ModIndexError.invalidResponse }
        guard data.count == listing.release.bytes, ModKit.SHA256.hex(data) == listing.release.sha256 else { throw ModIndexError.digestMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString + ".bfmod")
        try data.write(to: output, options: .withoutOverwriting)
        return output
    }
}
