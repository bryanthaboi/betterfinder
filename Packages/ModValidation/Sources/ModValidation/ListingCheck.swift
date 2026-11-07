import Foundation
import ModKit

public struct ListingCheck: Sendable {
    public var listing: ModIndexListing?
    public var authors: [ModAuthorFile]
    public var loadDiagnostics: [ModDiagnostic]
    public var file: String

    public init(listing: ModIndexListing?, authors: [ModAuthorFile], loadDiagnostics: [ModDiagnostic] = [], file: String = "listing.json") {
        self.listing = listing; self.authors = authors; self.loadDiagnostics = loadDiagnostics; self.file = file
    }

    public static func load(listing url: URL, authors authorsURL: URL?) throws -> ListingCheck {
        let file = url.lastPathComponent
        var diags = [ModDiagnostic]()
        var listing: ModIndexListing?
        let data = try Data(contentsOf: url)
        switch ModIndexListing.decode(data, file: file) {
        case .success(let l): listing = l
        case .failure(let d): diags.append(d)
        }
        var authors = [ModAuthorFile]()
        var candidates = [URL]()
        if let authorsURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: authorsURL.path, isDirectory: &isDir), isDir.boolValue {
                candidates = ((try? FileManager.default.contentsOfDirectory(at: authorsURL, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                candidates = [authorsURL]
            }
        } else if let l = listing {
            let guess = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("authors").appendingPathComponent("\(l.author).json")
            if FileManager.default.fileExists(atPath: guess.path) { candidates = [guess] }
        }
        for c in candidates {
            let name = c.lastPathComponent
            switch ModAuthorFile.decode((try? Data(contentsOf: c)) ?? Data(), file: name) {
            case .success(let a): authors.append(a)
            case .failure(let d): diags.append(d)
            }
        }
        return ListingCheck(listing: listing, authors: authors, loadDiagnostics: diags, file: file)
    }

    public func diagnostics(archive: Data, manifest: ModManifest?, at date: Date = Date()) -> [ModDiagnostic] {
        var out = loadDiagnostics
        guard let listing else { return out }
        if let manifest { out += listing.consistency(with: manifest, file: file) }
        else { out.append(ModDiagnostic(.indexMismatch, file: file, message: "the archive has no valid manifest to compare with the listing")) }
        out += ModAuthorKeys.verifyArtifact(archive, listing: listing, file: file)
        out += ModAuthorKeys.verifyRelease(listing, authors: authors, at: date, file: file)
        return out
    }

    public static func privateKey(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        if data.count == 32 { return data }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Data(base64Encoded: text), decoded.count == 32 { return decoded }
        throw CLIUsageError(message: "\(url.lastPathComponent) is not a 32-byte Ed25519 private key (raw or base64)")
    }
}

extension PreflightReceipt {
    func adding(_ extra: [ModDiagnostic]) -> PreflightReceipt {
        guard !extra.isEmpty else { return self }
        var checks = [PreflightCheck: PreflightCheckStatus]()
        for (k, v) in self.checks { if let c = PreflightCheck(rawValue: k) { checks[c] = v } }
        return PreflightReceipt(
            treeHash: treeHash, validator: validator, api: api, toolchain: toolchain, checks: checks,
            diagnostics: ModValidator.sorted(diagnostics + extra), archiveSHA256: archiveSHA256
        )
    }
}
