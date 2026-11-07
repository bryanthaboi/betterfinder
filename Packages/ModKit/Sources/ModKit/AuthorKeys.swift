import CryptoKit
import Foundation

public struct ModAuthorKey: Codable, Equatable, Sendable {
    public var keyId: String
    public var publicKey: String
    public var validFrom: Date
    public var validUntil: Date

    public init(keyId: String, publicKey: String, validFrom: Date, validUntil: Date) {
        self.keyId = keyId; self.publicKey = publicKey; self.validFrom = validFrom; self.validUntil = validUntil
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case keyId, publicKey, validFrom, validUntil }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        keyId = try r.string(.keyId, pattern: ModAuthorKeys.keyIDPattern, what: "keyId")
        publicKey = try r.string(.publicKey, pattern: "^[A-Za-z0-9+/]{43}=$", what: "Ed25519 public key")
        guard let raw = Data(base64Encoded: publicKey), raw.count == 32, (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else {
            throw r.fail(.publicKey, .invalidValue, "publicKey is not a 32-byte Ed25519 key")
        }
        let from: String = try r.req(.validFrom)
        let until: String = try r.req(.validUntil)
        guard let f = ModAuthorKeys.date(from) else { throw r.fail(.validFrom, .invalidValue, "validFrom must be an ISO-8601 UTC timestamp") }
        guard let u = ModAuthorKeys.date(until) else { throw r.fail(.validUntil, .invalidValue, "validUntil must be an ISO-8601 UTC timestamp") }
        guard f < u else { throw r.fail(.validUntil, .invalidValue, "validUntil must be after validFrom") }
        validFrom = f
        validUntil = u
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyId, forKey: .keyId)
        try c.encode(publicKey, forKey: .publicKey)
        try c.encode(ModAuthorKeys.string(validFrom), forKey: .validFrom)
        try c.encode(ModAuthorKeys.string(validUntil), forKey: .validUntil)
    }

    public var rawPublicKey: Data? { Data(base64Encoded: publicKey) }

    public func isValid(at date: Date) -> Bool { validFrom <= date && date < validUntil }
}

public struct ModAuthorFile: Codable, Equatable, Sendable {
    public var author: String
    public var keys: [ModAuthorKey]

    public init(author: String, keys: [ModAuthorKey]) { self.author = author; self.keys = keys }

    enum CodingKeys: String, CodingKey, CaseIterable { case author, keys }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        author = try r.string(.author, pattern: ModPatterns.author, what: "author")
        keys = try r.req(.keys)
        if keys.isEmpty { throw r.fail(.keys, .invalidValue, "at least one key is required") }
        if keys.count > 16 { throw r.fail(.keys, .sizeBound, "at most 16 keys") }
        if Set(keys.map(\.keyId)).count != keys.count { throw r.fail(.keys, .duplicateID, "keyId values must be unique") }
        for k in keys where !k.keyId.hasPrefix(author.lowercased() + ":") && !k.keyId.hasPrefix(author + ":") {
            throw r.fail(.keys, .invalidValue, "keyId '\(k.keyId)' must start with '\(author):'")
        }
    }

    public static func decode(_ data: Data, file: String = "author.json") -> Result<ModAuthorFile, ModDiagnostic> {
        guard data.count <= 65_536 else { return .failure(ModDiagnostic(.sizeBound, file: file, message: "author file is larger than 64 KiB")) }
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch let e as JSONParseError {
            return .failure(ModDiagnostic(.invalidJSON, file: file, pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message))
        } catch { return .failure(ModDiagnostic(.invalidJSON, file: file, message: "\(error)")) }
        return ModDecoding.decode(ModAuthorFile.self, from: value, file: file)
    }

    public func key(_ keyId: String) -> ModAuthorKey? { keys.first { $0.keyId == keyId } }

    public var canonicalData: Data {
        (try? JSONValue.parse(JSONEncoder().encode(self)).canonicalData()) ?? Data()
    }
}

public enum ModAuthorKeys {
    public static let keyIDPattern = "^[A-Za-z0-9._:-]{1,128}$"

    static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    public static func date(_ s: String) -> Date? { formatter().date(from: s) }
    public static func string(_ d: Date) -> String { formatter().string(from: d) }

    public static func verify(signature: String, payload: Data, publicKey: Data) -> Bool {
        guard let sig = Data(base64Encoded: signature), sig.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(sig, for: payload)
    }

    public static func sign(payload: Data, privateKey: Data) throws -> String {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: payload).base64EncodedString()
    }

    public static func verifyRelease(_ listing: ModIndexListing, authors: [ModAuthorFile], at date: Date? = Date(), file: String = "listing.json") -> [ModDiagnostic] {
        let ptr = "/release/keyId"
        guard let author = authors.first(where: { $0.author == listing.author }) else {
            return [ModDiagnostic(.untrustedAuthorKey, file: file, pointer: "/author", message: "no trusted author file for '\(listing.author)'",
                                  fix: "Add authors/\(listing.author).json with the public key in the index")]
        }
        guard let key = author.key(listing.release.keyId) else {
            return [ModDiagnostic(.untrustedAuthorKey, file: file, pointer: ptr, message: "key '\(listing.release.keyId)' is not listed for author '\(listing.author)'",
                                  fix: "Sign with one of: " + author.keys.map(\.keyId).joined(separator: ", "))]
        }
        if let date, !key.isValid(at: date) {
            return [ModDiagnostic(.untrustedAuthorKey, file: file, pointer: ptr, message: "key '\(key.keyId)' is valid \(string(key.validFrom)) to \(string(key.validUntil)), not now")]
        }
        guard let raw = key.rawPublicKey, verify(signature: listing.release.signature, payload: listing.signedPayload, publicKey: raw) else {
            return [ModDiagnostic(.releaseSignatureInvalid, file: file, pointer: "/release/signature",
                                  message: "signature does not verify over " + String(decoding: listing.signedPayload, as: UTF8.self) + " with key '\(key.keyId)'")]
        }
        return []
    }

    public static func verifyArtifact(_ data: Data, listing: ModIndexListing, file: String = "listing.json") -> [ModDiagnostic] {
        var out = [ModDiagnostic]()
        if data.count != listing.release.bytes {
            out.append(ModDiagnostic(.artifactMismatch, file: file, pointer: "/release/bytes", message: "archive is \(data.count) bytes; listing says \(listing.release.bytes)"))
        }
        let digest = SHA256.hex(data)
        if digest != listing.release.sha256 {
            out.append(ModDiagnostic(.artifactMismatch, file: file, pointer: "/release/sha256", message: "archive sha256 is \(digest); listing says \(listing.release.sha256)"))
        }
        return out
    }
}
