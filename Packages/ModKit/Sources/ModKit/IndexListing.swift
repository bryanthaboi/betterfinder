import Foundation

public enum ModIndexCategory: String, Codable, CaseIterable, Sendable {
    case UI, WORKFLOW, PREVIEW, SEARCH, FILESYSTEM, THEME, AUTOMATION
}

public struct ModIndexRelease: Codable, Equatable, Sendable {
    public var tag: String
    public var commit: String
    public var assetURL: String
    public var bytes: Int
    public var sha256: String
    public var keyId: String
    public var signature: String

    public init(tag: String, commit: String, assetURL: String, bytes: Int, sha256: String, keyId: String, signature: String) {
        self.tag = tag; self.commit = commit; self.assetURL = assetURL; self.bytes = bytes
        self.sha256 = sha256; self.keyId = keyId; self.signature = signature
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case tag, commit, assetURL, bytes, sha256, keyId, signature }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        tag = try r.string(.tag, pattern: "^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$", what: "tag")
        commit = try r.string(.commit, pattern: "^[0-9a-f]{40}$", what: "commit")
        assetURL = try r.string(.assetURL, pattern: "^https://[^\\s]{1,2000}$", what: "asset URL")
        bytes = try r.req(.bytes)
        if !(1...67_108_864).contains(bytes) { throw r.fail(.bytes, .invalidValue, "bytes out of range") }
        sha256 = try r.string(.sha256, pattern: ModPatterns.sha256, what: "sha256")
        keyId = try r.string(.keyId, pattern: "^[A-Za-z0-9._:-]{1,128}$", what: "keyId")
        signature = try r.string(.signature, pattern: "^[A-Za-z0-9+/]{86}==$", what: "signature")
    }
}

public struct ModIndexListing: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var author: String
    public var version: SemVer
    public var api: SemVerRange
    public var app: SemVerRange
    public var categories: [ModIndexCategory]
    public var repo: String
    public var release: ModIndexRelease
    public var permissions: [ModPermission]
    public var summary: String?
    public var tags: [String]?
    public var thumbnail: String?

    public init(
        schemaVersion: Int = 1, id: String, title: String, author: String, version: SemVer, api: SemVerRange, app: SemVerRange,
        categories: [ModIndexCategory], repo: String, release: ModIndexRelease, permissions: [ModPermission],
        summary: String? = nil, tags: [String]? = nil, thumbnail: String? = nil
    ) {
        self.schemaVersion = schemaVersion; self.id = id; self.title = title; self.author = author
        self.version = version; self.api = api; self.app = app; self.categories = categories; self.repo = repo
        self.release = release; self.permissions = permissions; self.summary = summary; self.tags = tags
        self.thumbnail = thumbnail
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, title, author, version, api, app, categories, repo, release, permissions, summary, tags, thumbnail
    }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        schemaVersion = try r.req(.schemaVersion)
        guard schemaVersion == 1 else { throw r.fail(.schemaVersion, .unsupportedManifestVersion, "schemaVersion \(schemaVersion) is not supported") }
        id = try r.string(.id, pattern: ModPatterns.modID, code: .invalidModID, what: "mod id")
        title = try r.req(.title)
        author = try r.string(.author, pattern: ModPatterns.author, what: "author")
        version = try r.req(.version)
        api = try r.req(.api)
        app = try r.req(.app)
        categories = try r.req(.categories)
        if categories.isEmpty { throw r.fail(.categories, .invalidValue, "at least one category is required") }
        repo = try r.string(.repo, pattern: "^https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$", what: "repo URL")
        release = try r.req(.release)
        permissions = try r.req(.permissions)
        summary = try r.opt(.summary)
        tags = try r.opt(.tags)
        thumbnail = try r.optString(.thumbnail, pattern: "^thumbnail\\.png$", what: "thumbnail")
    }

    public static func decode(_ data: Data, file: String = "listing.json") -> Result<ModIndexListing, ModDiagnostic> {
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch let e as JSONParseError {
            return .failure(ModDiagnostic(.invalidJSON, file: file, pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message))
        } catch { return .failure(ModDiagnostic(.invalidJSON, file: file, message: "\(error)")) }
        return ModDecoding.decode(ModIndexListing.self, from: value, file: file)
    }

    public var signedPayload: Data {
        JSONValue.object([
            "id": .string(id), "version": .string(version.description), "sha256": .string(release.sha256),
            "api": .string(api.description), "app": .string(app.description),
        ]).canonicalData()
    }

    public func consistency(with m: ModManifest, file: String = "listing.json") -> [ModDiagnostic] {
        var d = [ModDiagnostic]()
        func mismatch(_ ptr: String, _ what: String) { d.append(ModDiagnostic(.indexMismatch, file: file, pointer: ptr, message: "\(what) differs from the manifest")) }
        if id != m.id { mismatch("/id", "id") }
        if author != m.author { mismatch("/author", "author") }
        if version != m.version { mismatch("/version", "version") }
        if api != m.api { mismatch("/api", "api range") }
        if app != m.app { mismatch("/app", "app range") }
        if permissions != m.permissions { mismatch("/permissions", "permissions") }
        return d
    }
}
