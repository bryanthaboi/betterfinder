import Foundation
import CryptoKit
import ModKit

public enum ModIndexError: Error {
    case invalidFeed, invalidSignature, expired, rollback, invalidResponse, sizeLimit, digestMismatch, insecureURL, untrustedRelease
}

public struct IndexEntry: Codable, Sendable {
    public let listing: ModIndexListing
    public let sha256: String

    public init(listing: ModIndexListing) throws {
        self.listing = listing
        sha256 = ModKit.SHA256.hex(try JSONValue.parse(JSONEncoder().encode(listing)).canonicalData())
    }
}

public struct IndexFeed: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let expiresAt: Date
    public let serial: UInt64
    public let apiVersions: [String]
    public let mods: [IndexEntry]
    public let authors: [ModAuthorFile]

    public init(generatedAt: Date, expiresAt: Date, serial: UInt64, apiVersions: [String], mods: [IndexEntry], authors: [ModAuthorFile] = []) {
        schemaVersion = 1
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.serial = serial
        self.apiVersions = apiVersions
        self.mods = mods
        self.authors = authors
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, expiresAt, serial, apiVersions, mods, authors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        serial = try c.decode(UInt64.self, forKey: .serial)
        apiVersions = try c.decode([String].self, forKey: .apiVersions)
        mods = try c.decode([IndexEntry].self, forKey: .mods)
        authors = try c.decodeIfPresent([ModAuthorFile].self, forKey: .authors) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(serial, forKey: .serial)
        try c.encode(apiVersions, forKey: .apiVersions)
        try c.encode(mods, forKey: .mods)
        if !authors.isEmpty { try c.encode(authors, forKey: .authors) }
    }

    public func author(_ name: String) -> ModAuthorFile? { authors.first { $0.author == name } }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct TrustedIndexKey: Sendable {
    public let publicKey: Data
    public let validFrom: Date
    public let validUntil: Date

    public init(publicKey: Data, validFrom: Date, validUntil: Date) {
        self.publicKey = publicKey
        self.validFrom = validFrom
        self.validUntil = validUntil
    }

    public static let pinned: [TrustedIndexKey] = [
        TrustedIndexKey(publicKey: Data(base64Encoded: "2WqfV3c7gUA9GSpZOyH6U/n0vlGHSg56QewaHsgSnjA=")!,
                        validFrom: Date(timeIntervalSince1970: 1793923200),
                        validUntil: Date(timeIntervalSince1970: 1825545600))
    ]
}

public enum IndexVerifier {
    public static func verify(_ data: Data, signature: Data, keys: [TrustedIndexKey], now: Date,
                              allowExpired: Bool = false) throws -> IndexFeed {
        let validKeys = keys.filter { $0.validFrom <= now && now < $0.validUntil }
        guard validKeys.contains(where: {
            (try? Curve25519.Signing.PublicKey(rawRepresentation: $0.publicKey).isValidSignature(signature, for: data)) == true
        }) else { throw ModIndexError.invalidSignature }
        let feed = try IndexFeed.decoder().decode(IndexFeed.self, from: data)
        guard feed.schemaVersion == 1, feed.generatedAt <= now, feed.expiresAt > feed.generatedAt,
              Set(feed.mods.map { $0.listing.id }).count == feed.mods.count,
              Set(feed.authors.map(\.author)).count == feed.authors.count,
              feed.mods.allSatisfy({ (try? IndexEntry(listing: $0.listing).sha256) == $0.sha256 })
        else { throw ModIndexError.invalidFeed }
        guard allowExpired || now < feed.expiresAt else { throw ModIndexError.expired }
        return feed
    }
}
