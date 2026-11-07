import Foundation
import ModKit

public struct IndexEntryOptions: Sendable {
    public var repo: String
    public var releaseURL: String
    public var commit: String?
    public var tag: String?
    public var keyID: String?
    public var signature: String?
    public var summary: String?
    public var categories: [ModIndexCategory]?
    public var tags: [String]?
    public var signingKey: Data?

    public init(
        repo: String, releaseURL: String, commit: String? = nil, tag: String? = nil, keyID: String? = nil, signature: String? = nil,
        summary: String? = nil, categories: [ModIndexCategory]? = nil, tags: [String]? = nil, signingKey: Data? = nil
    ) {
        self.repo = repo; self.releaseURL = releaseURL; self.commit = commit; self.tag = tag; self.keyID = keyID
        self.signature = signature; self.summary = summary; self.categories = categories; self.tags = tags
        self.signingKey = signingKey
    }
}

public struct IndexEntryResult: Sendable {
    public var listing: ModIndexListing
    public var json: String
    public var notes: [String]
}

public enum IndexEntryError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self { case .invalid(let m): return m }
    }
}

public enum ModIndexEntry {
    public static let placeholderCommit = String(repeating: "0", count: 40)
    public static let placeholderSignature = String(repeating: "A", count: 86) + "=="

    public static func normalizedRepo(_ repo: String) -> String {
        var r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        while r.hasSuffix("/") { r.removeLast() }
        if r.hasSuffix(".git") { r.removeLast(4) }
        return r
    }

    public static func tag(fromReleaseURL url: String) -> String? {
        let parts = url.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "download"), i >= 1, i + 1 < parts.count, parts[i - 1] == "releases" else { return nil }
        return parts[i + 1].removingPercentEncoding ?? parts[i + 1]
    }

    public static func categories(for m: ModManifest) -> [ModIndexCategory] {
        var out = Set<ModIndexCategory>()
        let c = m.contributes
        if !(c.toolbar.isEmpty && c.sidebarSections.isEmpty && c.contextMenu.isEmpty && c.columns.isEmpty && c.statusBar.isEmpty && c.panels.isEmpty && c.views.isEmpty) { out.insert(.UI) }
        if !c.previews.isEmpty { out.insert(.PREVIEW) }
        if !c.searchProviders.isEmpty { out.insert(.SEARCH) }
        if !c.locations.isEmpty { out.insert(.FILESYSTEM) }
        if !(c.themes.isEmpty && c.iconSets.isEmpty && c.sounds.isEmpty) { out.insert(.THEME) }
        if !c.commands.isEmpty { out.insert(.WORKFLOW) }
        for p in m.permissions {
            switch p.kind {
            case .fsWrite, .operationsObserve, .operationsIntercept: out.insert(.FILESYSTEM)
            case .processExec, .net: out.insert(.AUTOMATION)
            default: break
            }
        }
        if out.isEmpty { out.insert(.UI) }
        return ModIndexCategory.allCases.filter(out.contains)
    }

    public static func make(manifest m: ModManifest, archiveSHA256: String, archiveBytes: Int, options: IndexEntryOptions) throws -> IndexEntryResult {
        var notes = [String]()
        let repo = normalizedRepo(options.repo)
        let tag = options.tag ?? Self.tag(fromReleaseURL: options.releaseURL) ?? "v\(m.version)"
        var commit = options.commit?.lowercased()
        if commit == nil {
            commit = placeholderCommit
            notes.append("commit is a placeholder; pass --commit <40-hex sha> of the release tag")
        }
        let signature = options.signature ?? placeholderSignature
        if options.signature == nil, options.signingKey == nil { notes.append("signature is a placeholder; sign the payload with your author key and pass --key-id and --signature or --author-key") }
        let keyID = options.keyID ?? "\(m.author.lowercased()):unsigned"
        let categories = options.categories ?? categories(for: m)

        let permissionsData = try JSONEncoder().encode(m.permissions)
        let permissions = try JSONValue.parse(permissionsData)
        let release: [String: JSONValue] = [
            "tag": .string(tag), "commit": .string(commit!), "assetURL": .string(options.releaseURL),
            "bytes": .int(archiveBytes), "sha256": .string(archiveSHA256), "keyId": .string(keyID), "signature": .string(signature),
        ]
        var o: [String: JSONValue] = [
            "schemaVersion": .int(1), "id": .string(m.id), "title": .string(m.name), "author": .string(m.author),
            "version": .string(m.version.description), "api": .string(m.api.description), "app": .string(m.app.description),
            "categories": .array(categories.map { .string($0.rawValue) }), "repo": .string(repo),
            "release": .object(release), "permissions": permissions,
        ]
        if let s = options.summary { o["summary"] = .string(s) }
        if let t = options.tags, !t.isEmpty { o["tags"] = .array(t.map { .string($0) }) }
        let data = JSONValue.object(o).canonicalData()
        switch ModIndexListing.decode(data, file: "listing.json") {
        case .failure(let d):
            throw IndexEntryError.invalid("\(d.code.rawValue) \(d.message)" + (d.pointer.map { " at \($0)" } ?? ""))
        case .success(var listing):
            if let key = options.signingKey {
                do { listing.release.signature = try ModAuthorKeys.sign(payload: listing.signedPayload, privateKey: key) }
                catch { throw IndexEntryError.invalid("cannot sign with the author key: \(error)") }
            }
            let mismatches = listing.consistency(with: m)
            if let first = mismatches.first { throw IndexEntryError.invalid("listing disagrees with manifest: \(first.message)") }
            let json = String(decoding: listing.modKitJSON(pretty: true), as: UTF8.self) + "\n"
            notes.append("signed payload: " + String(decoding: listing.signedPayload, as: UTF8.self))
            return IndexEntryResult(listing: listing, json: json, notes: notes)
        }
    }
}
