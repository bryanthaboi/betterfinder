import Foundation
import ModKit

public struct CLIIO: @unchecked Sendable {
    public var out: (String) -> Void
    public var err: (String) -> Void

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void) { self.out = out; self.err = err }

    public static let standard = CLIIO(
        out: { FileHandle.standardOutput.write(Data($0.utf8)) },
        err: { FileHandle.standardError.write(Data($0.utf8)) }
    )
}

public typealias CLIExtension = @Sendable ([String], CLIIO, ModValidator, DryRunning) async throws -> Int32

struct CLIUsageError: Error { var message: String }

struct ParsedArgs {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static func parse(_ args: [String], values: Set<String>, flags allowedFlags: Set<String>) throws -> ParsedArgs {
        var out = ParsedArgs()
        var i = 0
        var onlyPositional = false
        while i < args.count {
            let a = args[i]
            i += 1
            if onlyPositional || !a.hasPrefix("-") || a == "-" { out.positionals.append(a); continue }
            if a == "--" { onlyPositional = true; continue }
            var name = a
            var inline: String?
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") {
                name = String(a[..<eq])
                inline = String(a[a.index(after: eq)...])
            }
            if allowedFlags.contains(name) {
                if inline != nil { throw CLIUsageError(message: "\(name) does not take a value") }
                out.flags.insert(name)
            } else if values.contains(name) {
                if let inline { out.options[name] = inline }
                else {
                    guard i < args.count else { throw CLIUsageError(message: "\(name) needs a value") }
                    out.options[name] = args[i]
                    i += 1
                }
            } else {
                throw CLIUsageError(message: "unknown option \(a)")
            }
        }
        return out
    }
}

public enum ModCLI {
    public static let toolVersion = ModKitVersion.validator

    public static let usage = """
    betterfinder-mod \(toolVersion)

    usage: betterfinder-mod <command> [options]

    commands:
      validate <path> [--json] [--strict] [--host-version x.y.z] [--api-version x.y.z] [--listing listing.json [--authors file|dir]]
          Run the shared preflight on a mod folder or .bfmod archive. Exits 1 when any error is reported;
          --strict also exits 1 when a required check did not run (for example the dry run).
          --listing also checks an index listing against the archive: manifest identity and permissions, archive
          size and sha256, and the author's Ed25519 signature using the key file from --authors (default: the
          index's authors/<author>.json next to the listing).
      scaffold <id> [--language bfscript|ts|js] [--template column|sidebar|toolbar|panel|preview|command|theme] [--out dir]
          Create a mod that passes validate. Defaults: --language bfscript, --template command, --out ./<id>.
          sidebar and theme are data-only and ignore --language.
      package <path> --out <file.bfmod>
          Validate, then write a reproducible archive, its sha256 and <file>.receipt.json.
      docs --out <dir>
          Write the wiki pages (API, manifest, diagnostics, CLI, getting started) and betterfinder.d.ts.
      dts [--out betterfinder.d.ts]
          Write the editor declarations for the virtual betterfinder module (stdout without --out).
      index-entry <path> --repo <github url> --release-url <url> [--commit sha] [--tag tag] [--key-id id]
                  [--signature base64 | --author-key file] [--summary text] [--categories UI,THEME,...] [--tags a,b] [--out file|dir]
          Generate the mod index listing.json for a release (stdout without --out; a directory gets listing.json).
          --author-key signs the release with a raw or base64 Ed25519 private key file.
      mcp [--stdio | --http] [--port n] [--token-file path] [--workspaces dir] [--allow-origin url] [--no-live]
          Run the MCP authoring server (stdio by default; --http listens on 127.0.0.1 behind a bearer token file).
      version [--json]
          Print tool, validator, API and toolchain versions.
      help
          Show this text.

    """

    public static func run(
        arguments: [String], io: CLIIO = .standard, validator: ModValidator = .shared, dryRunner: DryRunning = NotRunDryRunner(),
        extensions: [String: CLIExtension] = [:]
    ) async -> Int32 {
        guard let command = arguments.first else {
            io.err(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        do {
            if let ext = extensions[command] { return try await ext(rest, io, validator, dryRunner) }
            switch command {
            case "validate": return try await validate(rest, io, validator, dryRunner)
            case "scaffold": return try await scaffold(rest, io, validator, dryRunner)
            case "package": return try await package(rest, io, validator, dryRunner)
            case "docs": return try docs(rest, io, validator)
            case "dts": return try dts(rest, io, validator)
            case "index-entry": return try await indexEntry(rest, io, validator, dryRunner)
            case "version", "--version", "-v": return try version(rest, io, validator)
            case "help", "--help", "-h":
                io.out(usage)
                return 0
            default:
                io.err("unknown command '\(command)'\n\n" + usage)
                return 2
            }
        } catch let e as CLIUsageError {
            io.err("betterfinder-mod \(command): \(e.message)\n")
            return 2
        } catch {
            io.err("betterfinder-mod \(command): \(error)\n")
            return 1
        }
    }

    static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    static func requireExisting(_ path: String) throws -> URL {
        let u = url(path)
        guard FileManager.default.fileExists(atPath: u.path) else { throw CLIUsageError(message: "no such file or folder: \(path)") }
        return u
    }

    static func hostInfo(_ p: ParsedArgs) throws -> HostInfo {
        var host = HostInfo.current
        if let v = p.options["--host-version"] {
            guard let s = SemVer(v) else { throw CLIUsageError(message: "--host-version '\(v)' is not a semantic version") }
            host.app = s
        }
        if let v = p.options["--api-version"] {
            guard let s = SemVer(v) else { throw CLIUsageError(message: "--api-version '\(v)' is not a semantic version") }
            host.api = s
        }
        return host
    }

    static func validate(_ args: [String], _ io: CLIIO, _ validator: ModValidator, _ dry: DryRunning) async throws -> Int32 {
        let p = try ParsedArgs.parse(args, values: ["--host-version", "--api-version", "--listing", "--authors"], flags: ["--json", "--strict"])
        guard p.positionals.count == 1 else { throw CLIUsageError(message: "expected exactly one <path>") }
        let target = try requireExisting(p.positionals[0])
        let host = try hostInfo(p)
        let source = ModPackageSource.detect(target)
        var listingCheck: ListingCheck?
        if let listingPath = p.options["--listing"] {
            guard case .archive = source else { throw CLIUsageError(message: "--listing needs a .bfmod archive, not a folder") }
            listingCheck = try ListingCheck.load(listing: requireExisting(listingPath), authors: p.options["--authors"].map(requireExisting))
        } else if p.options["--authors"] != nil {
            throw CLIUsageError(message: "--authors needs --listing")
        }
        var result = await validator.run(source, host: host, dryRunner: dry)
        if let check = listingCheck {
            let data = (try? Data(contentsOf: target, options: .mappedIfSafe)) ?? Data()
            let extra = check.diagnostics(archive: data, manifest: result.manifest)
            result.receipt = result.receipt.adding(extra)
            if !extra.hasErrors, let l = check.listing {
                io.err("listing \(l.id) \(l.version): manifest, archive and signature by \(l.release.keyId) verified\n")
            }
        }
        if p.flags.contains("--json") { io.out(ModReportRenderer.json(result) + "\n") }
        else { io.out(ModReportRenderer.text(result, subject: p.positionals[0])) }
        if result.receipt.diagnostics.hasErrors { return 1 }
        if p.flags.contains("--strict"), !result.receipt.ok { return 1 }
        return 0
    }

    static func scaffold(_ args: [String], _ io: CLIIO, _ validator: ModValidator, _ dry: DryRunning) async throws -> Int32 {
        let p = try ParsedArgs.parse(args, values: ["--language", "--template", "--out"], flags: [])
        guard p.positionals.count == 1 else { throw CLIUsageError(message: "expected exactly one <id>") }
        let id = p.positionals[0]
        let languageName = p.options["--language"] ?? "bfscript"
        guard let language = ScaffoldLanguage(rawValue: languageName) else {
            throw CLIUsageError(message: "--language must be one of " + ScaffoldLanguage.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let templateName = p.options["--template"] ?? "command"
        guard let template = ScaffoldTemplate(rawValue: templateName) else {
            throw CLIUsageError(message: "--template must be one of " + ScaffoldTemplate.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let files: [ScaffoldFile]
        do { files = try ModScaffold.files(id: id, language: language, template: template, catalog: validator.catalog) }
        catch let e as ScaffoldError { throw CLIUsageError(message: e.description) }
        let out = url(p.options["--out"] ?? id)
        try ModScaffold.write(files, to: out)
        if template.isDataOnly, language != .bfscript || p.options["--language"] != nil {
            io.out("note: the \(template.rawValue) template is data-only; --language was ignored\n")
        }
        io.out("created \(files.count) files in \(out.path)\n")
        let result = await validator.run(.directory(out), dryRunner: dry)
        io.out(ModReportRenderer.text(result, subject: id))
        return result.receipt.diagnostics.hasErrors ? 1 : 0
    }

    static func package(_ args: [String], _ io: CLIIO, _ validator: ModValidator, _ dry: DryRunning) async throws -> Int32 {
        let p = try ParsedArgs.parse(args, values: ["--out"], flags: [])
        guard p.positionals.count == 1 else { throw CLIUsageError(message: "expected exactly one <path>") }
        let source = try requireExisting(p.positionals[0])
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw CLIUsageError(message: "package expects a mod folder")
        }
        guard let outPath = p.options["--out"] else { throw CLIUsageError(message: "--out <file.bfmod> is required") }
        guard outPath.hasSuffix(".bfmod") else { throw CLIUsageError(message: "--out must end in .bfmod") }

        let result = await validator.run(.directory(source), dryRunner: dry)
        guard !result.receipt.diagnostics.hasErrors, let package = result.package else {
            io.out(ModReportRenderer.text(result, subject: p.positionals[0]))
            io.err("not packaged: fix the errors above\n")
            return 1
        }
        let archive = ModPackaging.archive(package: package)
        let verify = await validator.run(.archiveData(archive, name: (outPath as NSString).lastPathComponent), dryRunner: dry)
        guard verify.receipt.treeHash == result.receipt.treeHash, !verify.receipt.diagnostics.hasErrors else {
            io.out(ModReportRenderer.text(verify, subject: outPath))
            io.err("not packaged: the archive does not validate identically to the folder\n")
            return 1
        }
        let outURL = url(outPath)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: outURL, options: .atomic)
        let receiptURL = URL(fileURLWithPath: outURL.path + ".receipt.json")
        try Data((ModReportRenderer.json(verify) + "\n").utf8).write(to: receiptURL, options: .atomic)
        io.out("packaged \(package.files.count) files into \(outURL.path)\n")
        io.out("sha256 \(verify.archiveSHA256 ?? "")  \(archive.count) bytes\n")
        io.out("receipt \(receiptURL.path)\n")
        let warnings = result.receipt.diagnostics.warnings
        if !warnings.isEmpty { io.out("\(warnings.count) warning\(warnings.count == 1 ? "" : "s") (run validate to see them)\n") }
        return 0
    }

    static func docs(_ args: [String], _ io: CLIIO, _ validator: ModValidator) throws -> Int32 {
        let p = try ParsedArgs.parse(args, values: ["--out"], flags: [])
        guard p.positionals.isEmpty else { throw CLIUsageError(message: "docs takes no positional arguments") }
        guard let out = p.options["--out"] else { throw CLIUsageError(message: "--out <dir> is required") }
        let written = try ModDocsGenerator.write(to: url(out), catalog: validator.catalog)
        for name in written { io.out("wrote \(name)\n") }
        return 0
    }

    static func dts(_ args: [String], _ io: CLIIO, _ validator: ModValidator) throws -> Int32 {
        let p = try ParsedArgs.parse(args, values: ["--out"], flags: [])
        guard p.positionals.isEmpty else { throw CLIUsageError(message: "dts takes no positional arguments") }
        let text = ModCatalogAdapter.declarations(from: validator.catalog)
        if let out = p.options["--out"] {
            let u = url(out)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u, options: .atomic)
            io.out("wrote \(u.path)\n")
        } else { io.out(text) }
        return 0
    }

    static func indexEntry(_ args: [String], _ io: CLIIO, _ validator: ModValidator, _ dry: DryRunning) async throws -> Int32 {
        let p = try ParsedArgs.parse(
            args, values: ["--repo", "--release-url", "--commit", "--tag", "--key-id", "--signature", "--author-key", "--summary", "--categories", "--tags", "--out"], flags: []
        )
        guard p.positionals.count == 1 else { throw CLIUsageError(message: "expected exactly one <path>") }
        guard let repo = p.options["--repo"] else { throw CLIUsageError(message: "--repo <github url> is required") }
        guard let release = p.options["--release-url"] else { throw CLIUsageError(message: "--release-url <url> is required") }
        let source = try requireExisting(p.positionals[0])
        var categories: [ModIndexCategory]?
        if let raw = p.options["--categories"] {
            categories = try raw.split(separator: ",").map {
                guard let c = ModIndexCategory(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased()) else {
                    throw CLIUsageError(message: "unknown category '\($0)'; use " + ModIndexCategory.allCases.map(\.rawValue).joined(separator: ", "))
                }
                return c
            }
        }
        let tags = p.options["--tags"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var signingKey: Data?
        if let keyPath = p.options["--author-key"] {
            guard p.options["--signature"] == nil else { throw CLIUsageError(message: "use --signature or --author-key, not both") }
            guard p.options["--key-id"] != nil else { throw CLIUsageError(message: "--author-key needs --key-id") }
            signingKey = try ListingCheck.privateKey(requireExisting(keyPath))
        }

        let psource = ModPackageSource.detect(source)
        let result = await validator.run(psource, dryRunner: dry)
        guard !result.receipt.diagnostics.hasErrors, let manifest = result.manifest, let package = result.package else {
            io.out(ModReportRenderer.text(result, subject: p.positionals[0]))
            io.err("no index entry: fix the errors above\n")
            return 1
        }
        var sha = result.archiveSHA256
        var bytes = result.archiveBytes
        if sha == nil {
            let archive = ModPackaging.archive(package: package)
            sha = ModValidator.sha256(archive)
            bytes = archive.count
        }
        var commit = p.options["--commit"]
        if commit == nil, case .directory(let dir) = psource { commit = gitHead(dir) }
        let options = IndexEntryOptions(
            repo: repo, releaseURL: release, commit: commit, tag: p.options["--tag"], keyID: p.options["--key-id"],
            signature: p.options["--signature"], summary: p.options["--summary"], categories: categories, tags: tags, signingKey: signingKey
        )
        let entry: IndexEntryResult
        do { entry = try ModIndexEntry.make(manifest: manifest, archiveSHA256: sha ?? "", archiveBytes: bytes ?? 0, options: options) }
        catch let e as IndexEntryError { throw CLIUsageError(message: e.description) }
        if let out = p.options["--out"] {
            var u = url(out)
            var isDir: ObjCBool = false
            if out.hasSuffix("/") || (FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue) {
                u = u.appendingPathComponent("listing.json")
            }
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(entry.json.utf8).write(to: u, options: .atomic)
            io.out("wrote \(u.path)\n")
        } else { io.out(entry.json) }
        for n in entry.notes { io.err("note: \(n)\n") }
        return 0
    }

    static func gitHead(_ dir: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", dir.path, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ModPatterns.matches(text, "^[0-9a-f]{40}$") ? text : nil
    }

    static func version(_ args: [String], _ io: CLIIO, _ validator: ModValidator) throws -> Int32 {
        let p = try ParsedArgs.parse(args, values: [], flags: ["--json"])
        guard p.positionals.isEmpty else { throw CLIUsageError(message: "version takes no positional arguments") }
        let c = validator.catalog
        let ts = validator.typeScriptVersion ?? "unavailable"
        if p.flags.contains("--json") {
            struct Info: Encodable {
                var tool: String, validator: String, api: String, manifestVersion: Int, scriptFormat: Int, toolchain: String, typescript: String, catalogDigest: String
            }
            let info = Info(tool: toolVersion, validator: ModKitVersion.validator, api: c.catalogVersion, manifestVersion: c.manifestVersion, scriptFormat: c.scriptFormat, toolchain: c.toolchain, typescript: ts, catalogDigest: c.digest)
            io.out(String(decoding: info.modKitJSON(pretty: true), as: UTF8.self) + "\n")
        } else {
            io.out("""
            betterfinder-mod \(toolVersion)
            validator \(ModKitVersion.validator)
            api \(c.catalogVersion)
            manifest version \(c.manifestVersion)
            script format \(c.scriptFormat)
            toolchain \(c.toolchain)
            typescript \(ts)
            catalog digest \(c.digest)

            """)
        }
        return 0
    }
}
