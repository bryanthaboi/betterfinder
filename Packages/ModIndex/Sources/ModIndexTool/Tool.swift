import Foundation
import CryptoKit
import ModKit
import ModIndex
import Darwin

struct ToolFailure: Error { let message: String }

func fail(_ message: String) -> ToolFailure { ToolFailure(message: message) }

func isLink(_ url: URL) throws -> Bool { try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true }

func loadListings(_ root: URL) throws -> [IndexEntry] {
    let mods = root.appendingPathComponent("mods")
    let folders = try FileManager.default.contentsOfDirectory(at: mods, includingPropertiesForKeys: [.isSymbolicLinkKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard folders.count <= 10_000 else { throw fail("more than 10000 mods") }
    var entries = [IndexEntry]()
    for folder in folders {
        guard try !isLink(folder) else { throw fail("mods/\(folder.lastPathComponent) is a symbolic link") }
        let file = folder.appendingPathComponent("listing.json")
        guard try !isLink(file) else { throw fail("mods/\(folder.lastPathComponent)/listing.json is a symbolic link") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1_048_576 else { throw fail("mods/\(folder.lastPathComponent)/listing.json is empty or larger than 1 MiB") }
        let allowed = Set(["listing.json", "icon.png", "screenshots"])
        let extra = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !allowed.contains($0) }
        guard extra.isEmpty else { throw fail("mods/\(folder.lastPathComponent) has unexpected files: \(extra.sorted().joined(separator: ", "))") }
        let listing: ModIndexListing
        switch ModIndexListing.decode(try Data(contentsOf: file), file: "mods/\(folder.lastPathComponent)/listing.json") {
        case .success(let l): listing = l
        case .failure(let d): throw fail("\(d.file ?? "listing.json"): \(d.code.rawValue) \(d.message)" + (d.pointer.map { " at \($0)" } ?? ""))
        }
        guard listing.id == folder.lastPathComponent else { throw fail("mods/\(folder.lastPathComponent)/listing.json has id \(listing.id)") }
        entries.append(try IndexEntry(listing: listing))
    }
    guard Set(entries.map { $0.listing.id }).count == entries.count else { throw fail("duplicate mod ids") }
    return entries
}

func loadAuthors(_ root: URL) throws -> [String: ModAuthorFile] {
    let dir = root.appendingPathComponent("authors")
    guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }
    guard try !isLink(dir) else { throw fail("authors is a symbolic link") }
    var out = [String: ModAuthorFile]()
    for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = file.lastPathComponent
        guard name.hasSuffix(".json"), try !isLink(file) else { throw fail("authors/\(name) is not a plain .json file") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 65_536 else { throw fail("authors/\(name) is empty or larger than 64 KiB") }
        switch ModAuthorFile.decode(try Data(contentsOf: file), file: "authors/\(name)") {
        case .success(let a):
            guard a.author + ".json" == name else { throw fail("authors/\(name) declares author \(a.author)") }
            out[a.author] = a
        case .failure(let d): throw fail("authors/\(name): \(d.code.rawValue) \(d.message)" + (d.pointer.map { " at \($0)" } ?? ""))
        }
    }
    guard out.count <= 10_000 else { throw fail("more than 10000 authors") }
    return out
}

func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw fail("usage: mod-index-tool keygen|verify|build|validate-artifacts ...") }
    if command == "keygen" {
        let path = args.count > 1 ? args[1] : NSHomeDirectory() + "/.config/betterfinder-index/signing.key"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw fail("cannot create \(path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: key.rawRepresentation)
        try handle.close()
        print(key.publicKey.rawRepresentation.base64EncodedString())
        return
    }
    guard args.count >= 2 else { throw fail("\(command) needs the index root") }
    let root = URL(fileURLWithPath: args[1])
    if command == "verify" {
        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let signature = try Data(contentsOf: root.appendingPathComponent("index.json.sig"))
        let feed = try IndexVerifier.verify(data, signature: signature, keys: TrustedIndexKey.pinned, now: Date())
        for entry in feed.mods {
            guard let author = feed.author(entry.listing.author), (try? ModVerifiedRelease(listing: entry.listing, author: author)) != nil else {
                throw fail("\(entry.listing.id): release signature does not verify against the feed's author keys")
            }
        }
        print("verified \(feed.mods.count) listings, \(feed.authors.count) authors")
        return
    }
    let entries = try loadListings(root)
    let authors = try loadAuthors(root)
    if command == "validate-artifacts" {
        guard args.count == 4 || args.count == 5 else { throw fail("usage: mod-index-tool validate-artifacts <submission> <betterfinder-mod> <changed.txt> [<trusted index>]") }
        let changed = Set(try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").map(String.init))
        let trusted = args.count == 5 ? try loadAuthors(URL(fileURLWithPath: args[4])) : [:]
        for name in changed.sorted() where name.hasPrefix("authors/") {
            let author = String(name.dropFirst("authors/".count).dropLast(".json".count))
            guard let submitted = authors[author] else { continue }
            if let base = trusted[author], base != submitted {
                print("note: \(name) changes the keys of an existing author; a maintainer must review it. Listings here are checked against the current trusted keys.")
            } else if trusted[author] == nil {
                print("note: \(name) binds a new author key; a maintainer must review the binding before merging.")
            }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bf-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var failed = [String]()
        for entry in entries where changed.contains("mods/\(entry.listing.id)/listing.json") {
            let id = entry.listing.id
            guard let author = trusted[entry.listing.author] ?? authors[entry.listing.author] else {
                print("\(id): no authors/\(entry.listing.author).json; add the author's public key file")
                failed.append(id)
                continue
            }
            let authorURL = scratch.appendingPathComponent("\(author.author).json")
            try author.canonicalData.write(to: authorURL, options: .atomic)
            let file: URL
            do { file = try await ModArtifactDownloader().download(entry.listing, directory: scratch) } catch {
                print("\(id): cannot download \(entry.listing.release.assetURL) with the listed size and sha256: \(error)")
                failed.append(id)
                continue
            }
            print("== \(id) \(entry.listing.version)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = [
                "-p", "(version 1)(allow default)(deny network*)", args[2], "validate", file.path,
                "--listing", root.appendingPathComponent("mods/\(id)/listing.json").path, "--authors", authorURL.path, "--strict",
            ]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": scratch.path + "/"]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { failed.append(id) }
        }
        guard failed.isEmpty else { throw fail("validation failed: " + failed.joined(separator: ", ")) }
        print("validated \(changed.filter { $0.hasPrefix("mods/") }.count) changed listing files")
        return
    }
    guard command == "build", args.count == 5,
          let generatedAt = ISO8601DateFormatter().date(from: args[3]), let serial = UInt64(args[4]) else {
        throw fail("usage: mod-index-tool build <root> <signing.key> <ISO8601 generatedAt> <serial>")
    }
    for entry in entries {
        guard let author = authors[entry.listing.author] else { throw fail("\(entry.listing.id): no authors/\(entry.listing.author).json") }
        guard (try? ModVerifiedRelease(listing: entry.listing, author: author)) != nil else {
            throw fail("\(entry.listing.id): release signature does not verify with authors/\(author.author).json key \(entry.listing.release.keyId)")
        }
    }
    let keyURL = URL(fileURLWithPath: args[2])
    let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
    guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw fail("signing key must be mode 0600") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
    let used = Set(entries.map(\.listing.author))
    let feed = IndexFeed(generatedAt: generatedAt, expiresAt: generatedAt.addingTimeInterval(7 * 86400), serial: serial,
                         apiVersions: ["1.0.0"], mods: entries, authors: authors.values.filter { used.contains($0.author) }.sorted { $0.author < $1.author })
    let data = try feed.encoded()
    guard data.count <= 8_388_608 else { throw fail("feed larger than 8 MiB") }
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { throw fail("signature self-check failed") }
    try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    try signature.write(to: root.appendingPathComponent("index.json.sig"), options: .atomic)
    print("built \(entries.count) listings, \(feed.authors.count) authors; public key \(key.publicKey.rawRepresentation.base64EncodedString())")
}

@main enum Tool {
    static func main() async {
        do {
            try await run()
        } catch let e as ToolFailure {
            FileHandle.standardError.write(Data("mod-index-tool: \(e.message)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("mod-index-tool: \(error)\n".utf8))
            exit(1)
        }
    }
}
