import Foundation
import ModKit

struct ReleaseReference: Equatable, Sendable {
    var owner: String
    var name: String
    var tag: String
    var asset: String?

    var repoURL: String { "https://github.com/\(owner)/\(name)" }
    var slug: String { "\(owner)/\(name)" }
    var assetURL: String? { asset.map { "\(repoURL)/releases/download/\(tag)/\($0)" } }
}

struct ReleaseInfo: Equatable, Sendable {
    var url: String
    var assetURL: String
    var assetName: String
    var assetBytes: Int?
}

struct PublishedRelease: Equatable, Sendable {
    var releaseURL: String
    var commit: String
    var assetURL: String
    var sha256: String
    var assetBytes: Int?
}

struct GitHubPublisher: Sendable {
    static let ownerPattern = "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"
    static let repoNamePattern = "^(?!\\.{1,2}$)(?!-)[A-Za-z0-9._-]{1,100}$"
    static let tagPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
    static let assetPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    static let credentialConfig = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]
    static let gitBase = ["-c", "core.hooksPath=/dev/null"]

    var runner: CommandRunning
    var indexRepository: String

    func gh(_ args: [String], cwd: URL? = nil, timeout: TimeInterval = 120) async throws -> CommandResult {
        try await check(CommandInvocation("gh", args, workingDirectory: cwd, timeout: timeout))
    }

    func git(_ args: [String], cwd: URL, authenticated: Bool = false, timeout: TimeInterval = 120) async throws -> CommandResult {
        let argv = Self.gitBase + (authenticated ? Self.credentialConfig : []) + args
        return try await check(CommandInvocation("git", argv, workingDirectory: cwd, timeout: timeout))
    }

    func check(_ invocation: CommandInvocation) async throws -> CommandResult {
        let result = try await runner.run(invocation)
        guard result.succeeded else {
            let detail = Redactor.clean((result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines), limit: 400)
            let code = invocation.executable == "gh" ? "gh_failed" : "git_failed"
            throw ToolError(code, "\(invocation.executable) \(invocation.arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? "") failed: \(detail)")
        }
        return result
    }

    func login() async throws -> String {
        let result: CommandResult
        do { result = try await gh(["api", "user", "--jq", ".login"]) }
        catch let e as ToolError where e.code == "gh_failed" {
            throw ToolError("gh_not_authenticated", "gh could not read your GitHub account. Run `gh auth login` in a terminal, then retry. (\(e.message))")
        }
        let login = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModPatterns.matches(login, Self.ownerPattern) else { throw ToolError("gh_failed", "gh returned an unexpected account name") }
        return login
    }

    static func validateRepo(owner: String, name: String) throws {
        guard ModPatterns.matches(owner, ownerPattern) else { throw ToolError("invalid_arguments", "owner '\(owner.prefix(60))' is not a valid GitHub account name") }
        guard ModPatterns.matches(name, repoNamePattern) else { throw ToolError("invalid_arguments", "name '\(name.prefix(60))' is not a valid repository name") }
    }

    static func parseRepoURL(_ url: String) throws -> (owner: String, name: String) {
        let parts = url.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "https:", parts[1].isEmpty, parts[2] == "github.com" else {
            throw ToolError("invalid_arguments", "repoURL must look like https://github.com/<owner>/<name>")
        }
        try validateRepo(owner: parts[3], name: parts[4])
        return (parts[3], parts[4])
    }

    static func parseRelease(_ url: String) throws -> ReleaseReference {
        let parts = url.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 8, parts[0] == "https:", parts[1].isEmpty, parts[2] == "github.com", parts[5] == "releases" else {
            throw ToolError("invalid_arguments", "releaseURL must be a GitHub release asset or release page URL on github.com")
        }
        try validateRepo(owner: parts[3], name: parts[4])
        let tag = (parts[7].removingPercentEncoding ?? parts[7])
        guard ModPatterns.matches(tag, tagPattern) else { throw ToolError("invalid_arguments", "the release tag in releaseURL is not valid") }
        switch (parts[6], parts.count) {
        case ("download", 9):
            guard ModPatterns.matches(parts[8], assetPattern), parts[8].hasSuffix(".bfmod") else {
                throw ToolError("invalid_arguments", "the release asset must be a .bfmod file with a plain file name")
            }
            return ReleaseReference(owner: parts[3], name: parts[4], tag: tag, asset: parts[8])
        case ("tag", 8):
            return ReleaseReference(owner: parts[3], name: parts[4], tag: tag, asset: nil)
        default:
            throw ToolError("invalid_arguments", "releaseURL must be .../releases/download/<tag>/<file>.bfmod or .../releases/tag/<tag>")
        }
    }

    func createRepository(owner: String, name: String, visibility: String, description: String) async throws -> String {
        try Self.validateRepo(owner: owner, name: name)
        _ = try await gh(["repo", "create", "\(owner)/\(name)", visibility == "private" ? "--private" : "--public", "--description", description])
        return "https://github.com/\(owner)/\(name)"
    }

    func publishRelease(
        repo: (owner: String, name: String), tag: String, title: String, notes: String, commitMessage: String, sourceFiles: [String: Data],
        archive: URL, staging: URL
    ) async throws -> PublishedRelease {
        let repoURL = "https://github.com/\(repo.owner)/\(repo.name)"
        let source = staging.appendingPathComponent("source", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in sourceFiles.sorted(by: { $0.key < $1.key }) {
            try ModWorkspaces.validateRelativePath(path)
            let url = source.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        _ = try await git(["init", "--initial-branch", "main"], cwd: source)
        _ = try await git(["add", "--all"], cwd: source)
        _ = try await git(["-c", "commit.gpgsign=false", "commit", "--message", commitMessage], cwd: source)
        _ = try await git(["remote", "add", "origin", repoURL + ".git"], cwd: source)
        _ = try await git(["push", "--set-upstream", "origin", "main"], cwd: source, authenticated: true, timeout: 300)
        _ = try await git(["tag", "--annotate", tag, "--message", title], cwd: source)
        _ = try await git(["push", "origin", tag], cwd: source, authenticated: true, timeout: 300)
        let head = try await git(["rev-parse", "HEAD"], cwd: source).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModPatterns.matches(head, "^[0-9a-f]{40}$") else { throw ToolError("git_failed", "git returned an unexpected commit id") }
        let created = try await gh(
            ["release", "create", tag, archive.path, "--repo", "\(repo.owner)/\(repo.name)", "--title", title, "--notes", notes, "--verify-tag"], timeout: 300
        )
        let info = try await releaseInfo(owner: repo.owner, name: repo.name, tag: tag, asset: archive.lastPathComponent)
        let releaseURL = created.stdout.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("https://github.com/") }) ?? info.url
        return PublishedRelease(releaseURL: releaseURL, commit: head, assetURL: info.assetURL, sha256: "", assetBytes: info.assetBytes)
    }

    func releaseInfo(owner: String, name: String, tag: String, asset: String?) async throws -> ReleaseInfo {
        let result = try await gh(["release", "view", tag, "--repo", "\(owner)/\(name)", "--json", "url,isDraft,assets"])
        guard let json = try? JSONValue.parse(result.stdout), case .object = json else {
            throw ToolError("gh_failed", "gh returned an unreadable release description")
        }
        if json["isDraft"]?.boolValue == true { throw ToolError("release_not_published", "release \(tag) is still a draft; publish it first") }
        let assets = (json["assets"]?.arrayValue ?? []).compactMap { a -> (name: String, url: String, size: Int?)? in
            guard let n = a["name"]?.stringValue, n.hasSuffix(".bfmod") else { return nil }
            let url = a["url"]?.stringValue ?? "https://github.com/\(owner)/\(name)/releases/download/\(tag)/\(n)"
            return (n, url, a["size"]?.intValue)
        }
        let chosen: (name: String, url: String, size: Int?)?
        if let asset { chosen = assets.first { $0.name == asset } } else { chosen = assets.count == 1 ? assets[0] : nil }
        guard let chosen else {
            throw ToolError("asset_not_found", asset.map { "release \(tag) has no asset named \($0)" } ?? "release \(tag) must have exactly one .bfmod asset")
        }
        guard ModPatterns.matches(chosen.name, Self.assetPattern) else { throw ToolError("asset_not_found", "the release asset name is not acceptable") }
        let page = json["url"]?.stringValue ?? "https://github.com/\(owner)/\(name)/releases/tag/\(tag)"
        return ReleaseInfo(url: page, assetURL: "https://github.com/\(owner)/\(name)/releases/download/\(tag)/\(chosen.name)", assetName: chosen.name, assetBytes: chosen.size)
    }

    func downloadAsset(_ ref: ReleaseReference, asset: String, into directory: URL) async throws -> Data {
        _ = try await gh(["release", "download", ref.tag, "--repo", ref.slug, "--pattern", asset, "--dir", directory.path, "--clobber"], timeout: 300)
        let file = directory.appendingPathComponent(asset)
        guard let st = ModWorkspaces.lstat(file.path), ModWorkspaces.isRegular(st), st.st_size <= 64 << 20, let data = FileManager.default.contents(atPath: file.path) else {
            throw ToolError("asset_not_found", "the downloaded asset is missing or larger than 64 MiB")
        }
        return data
    }

    func commit(for ref: ReleaseReference) async throws -> String {
        let result = try await gh(["api", "repos/\(ref.slug)/commits/\(ref.tag)", "--jq", ".sha"])
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModPatterns.matches(sha, "^[0-9a-f]{40}$") else { throw ToolError("gh_failed", "could not resolve the release tag to a commit") }
        return sha
    }

    func openIndexPullRequest(login: String, branch: String, modID: String, listingText: String, title: String, body: String, staging: URL) async throws -> (url: String, head: String) {
        let parts = indexRepository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw ToolError("internal_error", "index repository is misconfigured") }
        let repoName = parts[1]
        let clone = staging.appendingPathComponent("index", isDirectory: true)
        _ = try await gh(["repo", "fork", indexRepository, "--clone=false", "--remote=false"])
        _ = try await gh(["repo", "clone", "\(login)/\(repoName)", clone.path, "--", "--depth", "1", "--no-tags"], timeout: 300)
        _ = try await git(["remote", "add", "upstream", "https://github.com/\(indexRepository).git"], cwd: clone)
        _ = try await git(["fetch", "--depth", "1", "upstream", "main"], cwd: clone, authenticated: true, timeout: 300)
        _ = try await git(["checkout", "-b", branch, "FETCH_HEAD"], cwd: clone)
        let relative = "mods/\(modID)/listing.json"
        let target = clone.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(listingText.utf8).write(to: target, options: .atomic)
        _ = try await git(["add", "--", relative], cwd: clone)
        _ = try await git(["-c", "commit.gpgsign=false", "commit", "--message", title], cwd: clone)
        _ = try await git(["push", "--set-upstream", "origin", branch], cwd: clone, authenticated: true, timeout: 300)
        let pr = try await gh(
            ["pr", "create", "--repo", indexRepository, "--head", "\(login):\(branch)", "--base", "main", "--title", title, "--body", body], timeout: 120
        )
        guard let url = pr.stdout.split(separator: "\n").map(String.init).last(where: { ModPatterns.matches($0, "^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$") }) else {
            throw ToolError("gh_failed", "gh did not report the pull request URL")
        }
        return (url, "\(login):\(branch)")
    }

    static func branchName(modID: String, version: String) -> String {
        let raw = "add-\(modID)-\(version)"
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
        return String(cleaned.prefix(100))
    }
}
