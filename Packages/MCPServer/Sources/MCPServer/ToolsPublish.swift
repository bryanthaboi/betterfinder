import Foundation
import ModKit
import ModValidation

extension MCPServer {
    static func publishTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "github_create_repo", title: "Create the author's GitHub repository",
                description: "Create an empty GitHub repository for the mod with the installed gh. Needs the user's approval: the first call is a dry run that returns a review and a confirmationToken; repeat the call with confirm:true and that token only after the user approved the review.",
                inputSchema: S.object([
                    "workspace": S.workspace,
                    "owner": S.string("GitHub account or organization", pattern: GitHubPublisher.ownerPattern, min: 1, max: 39),
                    "name": S.string("repository name", pattern: GitHubPublisher.repoNamePattern, min: 1, max: 100),
                    "visibility": S.string("public or private", values: ["public", "private"]),
                    "confirm": S.confirmFields[0].1,
                    "confirmationToken": S.confirmFields[1].1,
                ], required: ["workspace", "owner", "name", "visibility"]),
                outputSchema: S.envelope(data: S.dataObject(["repoURL": S.string("repository URL")], withPending: true)),
                readOnly: false, openWorld: true, handler: { server, args in try await server.createRepo(args) }
            ),
            MCPToolDefinition(
                name: "github_publish_release", title: "Publish a release",
                description: "Push the validated source to the author's repository, tag it and create a release with the packaged .bfmod. Needs the user's approval through the same dry run then confirm flow as github_create_repo.",
                inputSchema: S.object([
                    "workspace": S.workspace, "revision": S.hash,
                    "repoURL": S.string("https://github.com/<owner>/<name>", pattern: "^https://github\\.com/[^/]+/[^/]+$", max: 200),
                    "tag": S.string("release tag", pattern: GitHubPublisher.tagPattern, min: 1, max: 64),
                    "archive": S.opaque("archive artifact id from mod_package"),
                    "confirm": S.confirmFields[0].1,
                    "confirmationToken": S.confirmFields[1].1,
                ], required: ["workspace", "revision", "repoURL", "tag", "archive"]),
                outputSchema: S.envelope(data: S.dataObject([
                    "releaseURL": S.string("release page"), "commit": S.string("commit the tag points at"),
                    "assetURL": S.string("download URL of the .bfmod"), "sha256": S.hash,
                ], withPending: true)),
                readOnly: false, openWorld: true, handler: { server, args in try await server.publishRelease(args) }
            ),
            MCPToolDefinition(
                name: "mod_index_entry", title: "Generate the index listing",
                description: "Verify a published release against the workspace and generate the mod index listing (mods/<id>/listing.json) locally. Nothing is uploaded.",
                inputSchema: S.object([
                    "workspace": S.workspace,
                    "releaseURL": S.string("release asset or release page URL", pattern: "^https://github\\.com/", max: 300),
                    "summary": S.string("one line description", min: 1, max: 200),
                    "categories": S.array(S.string("category", values: ModIndexCategory.allCases.map(\.rawValue)), "index categories", min: 1, max: 7),
                    "tags": S.array(S.string("tag", min: 1, max: 32), "optional tags", max: 8),
                    "keyId": S.string("author public key id", min: 1, max: 128),
                    "signature": S.string("detached Ed25519 signature, base64", min: 1, max: 200),
                ], required: ["workspace", "releaseURL", "summary", "categories"]),
                outputSchema: S.envelope(data: S.dataObject([
                    "files": S.array(S.object(["path": S.string("path in the index repository"), "text": S.string("file contents")], required: ["path", "text"]), "generated files"),
                    "revision": S.hash,
                    "warnings": S.array(S.string("warning"), "things to fix before publishing"),
                ], required: ["files", "revision"])),
                readOnly: false, openWorld: true, handler: { server, args in try await server.indexEntry(args) }
            ),
            MCPToolDefinition(
                name: "mod_index_pr", title: "Open the index pull request",
                description: "Fork the betterfinder mod index, add the generated listing on a branch and open a pull request with gh. Needs the user's approval through the dry run then confirm flow.",
                inputSchema: S.object([
                    "workspace": S.workspace, "revision": S.hash,
                    "title": S.string("pull request title", min: 1, max: 120),
                    "body": S.string("extra notes for the maintainers; the template fields are filled in for you", max: 6000),
                    "confirm": S.confirmFields[0].1,
                    "confirmationToken": S.confirmFields[1].1,
                ], required: ["workspace", "revision", "title", "body"]),
                outputSchema: S.envelope(data: S.dataObject(["prURL": S.string("pull request URL"), "head": S.string("fork:branch")], withPending: true)),
                readOnly: false, openWorld: true, handler: { server, args in try await server.indexPR(args) }
            ),
        ]
    }

    func consentFlow(
        tool: String, args: ToolArguments, digest: String, review: JSONValue, execute: () async throws -> ToolReturn
    ) async throws -> ToolReturn {
        if args.bool("confirm") == true {
            try ledger.consume(token: args.optionalString("confirmationToken"), tool: tool, digest: digest)
            return try await execute()
        }
        let issued = ledger.issue(tool: tool, digest: digest)
        return ToolReturn(
            obj([
                "pending": issued.token.j, "confirmationToken": issued.token.j, "review": review, "expiresAt": ISO8601.string(issued.expires).j,
            ]),
            notes: ["NOT DONE YET. Show the review to the user and ask whether to go ahead. Only after they say yes, call \(tool) again with the same arguments plus confirm:true and confirmationToken:\"\(issued.token)\". The token is single use and expires at \(ISO8601.string(issued.expires))."]
        )
    }

    func digest(_ tool: String, _ fields: JSONValue) -> String { Hex.sha256(obj(["tool": tool.j, "fields": fields]).canonicalString()) }

    func manifestName(_ workspace: String) -> String {
        guard let dir = try? workspaces.requireExisting(workspace), let data = FileManager.default.contents(atPath: dir.appendingPathComponent("manifest.json").path),
              let json = try? JSONValue.parse(data), let name = json["name"]?.stringValue else { return workspace }
        return String(Redactor.clean(name, limit: 80).prefix(80))
    }

    func createRepo(_ args: ToolArguments) async throws -> ToolReturn {
        let workspace = try args.string("workspace")
        let owner = try args.string("owner")
        let name = try args.string("name")
        let visibility = try args.string("visibility")
        try GitHubPublisher.validateRepo(owner: owner, name: name)
        _ = try workspaces.requireExisting(workspace)
        let login = try await publisher.login()
        let description = "\(manifestName(workspace)) - a betterfinder mod"
        let fields: JSONValue = obj([
            "workspace": workspace.j, "owner": owner.j, "name": name.j, "visibility": visibility.j, "login": login.j, "description": description.j,
        ])
        let review: JSONValue = obj([
            "action": "create an empty GitHub repository",
            "signedInAs": login.j,
            "owner": owner.j,
            "ownerIsSignedInAccount": (owner.lowercased() == login.lowercased()).j,
            "name": name.j,
            "visibility": visibility.j,
            "url": "https://github.com/\(owner)/\(name)".j,
            "description": description.j,
            "uploads": "nothing; the repository starts empty",
        ])
        return try await consentFlow(tool: "github_create_repo", args: args, digest: digest("github_create_repo", fields), review: review) {
            let url = try await publisher.createRepository(owner: owner, name: name, visibility: visibility, description: description)
            return ToolReturn(obj(["repoURL": url.j]))
        }
    }

    func publishRelease(_ args: ToolArguments) async throws -> ToolReturn {
        let workspace = try args.string("workspace")
        let revision = try args.string("revision")
        let repo = try GitHubPublisher.parseRepoURL(try args.string("repoURL"))
        let tag = try args.string("tag")
        try requireRevision(workspace, revision)
        guard let artifact = state.artifact(try args.string("archive")), artifact.kind == "package", artifact.workspace == workspace, artifact.treeHash == revision else {
            throw ToolError("archive_mismatch", "the archive does not belong to this workspace revision; run mod_package for it")
        }
        guard let bytes = FileManager.default.contents(atPath: artifact.url.path), Hex.sha256(bytes) == artifact.sha256 else {
            throw ToolError("archive_changed", "the archive file changed after mod_package; package again")
        }
        let (_, result) = try await validateWorkspace(workspace)
        guard result.receipt.treeHash == revision, !result.receipt.diagnostics.hasErrors, let package = result.package, let manifest = result.manifest else {
            throw ToolError("validation_failed", "the workspace revision no longer validates", diagnostics: result.receipt.diagnostics.filter { $0.severity == .error })
        }
        let login = try await publisher.login()
        let inventory: [JSONValue] = package.files.keys.sorted().map { path in
            obj(["path": path.j, "bytes": (package.files[path]?.count ?? 0).j, "sha256": Hex.sha256(package.files[path] ?? Data()).j])
        }
        let title = "\(manifest.name) \(manifest.version)"
        let notes = "betterfinder mod \(manifest.id) \(manifest.version)\n\nSHA-256 of the archive: \(artifact.sha256)"
        let fields: JSONValue = obj([
            "workspace": workspace.j, "revision": revision.j, "repo": "\(repo.owner)/\(repo.name)".j, "tag": tag.j, "archive": artifact.sha256.j, "login": login.j,
            "inventory": .array(inventory),
        ])
        let review: JSONValue = obj([
            "action": "push the source, tag it and create a GitHub release",
            "signedInAs": login.j,
            "repository": "https://github.com/\(repo.owner)/\(repo.name)".j,
            "ownerIsSignedInAccount": (repo.owner.lowercased() == login.lowercased()).j,
            "branch": "main",
            "commitMessage": "Release \(tag)".j,
            "tag": tag.j,
            "releaseTitle": title.j,
            "archive": obj(["name": artifact.url.lastPathComponent.j, "sha256": artifact.sha256.j, "bytes": artifact.bytes.j]),
            "sourceInventory": .array(inventory),
            "uploads": "exactly the files in sourceInventory as one commit, the tag, and the archive; screenshots and workspace files not listed are never uploaded",
        ])
        return try await consentFlow(tool: "github_publish_release", args: args, digest: digest("github_publish_release", fields), review: review) {
            let staging = try workspaces.stagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            var published = try await publisher.publishRelease(
                repo: repo, tag: tag, title: title, notes: notes, commitMessage: "Release \(tag)", sourceFiles: package.files, archive: artifact.url, staging: staging
            )
            published.sha256 = artifact.sha256
            if let size = published.assetBytes, size != artifact.bytes {
                throw ToolError("release_verify_failed", "the uploaded asset is \(size) bytes but the archive is \(artifact.bytes); delete the release on GitHub and retry")
            }
            return ToolReturn(obj([
                "releaseURL": published.releaseURL.j, "commit": published.commit.j, "assetURL": published.assetURL.j, "sha256": published.sha256.j,
            ]))
        }
    }

    func indexEntry(_ args: ToolArguments) async throws -> ToolReturn {
        let workspace = try args.string("workspace")
        _ = try manifestID(workspace)
        let reference = try GitHubPublisher.parseRelease(try args.string("releaseURL"))
        let revision = try currentRevision(workspace)
        let (_, local) = try await validateWorkspace(workspace)
        guard local.receipt.treeHash == revision, !local.receipt.diagnostics.hasErrors, let manifest = local.manifest else {
            throw ToolError("validation_failed", "the workspace does not validate; run mod_validate", diagnostics: local.receipt.diagnostics.filter { $0.severity == .error })
        }
        let info = try await publisher.releaseInfo(owner: reference.owner, name: reference.name, tag: reference.tag, asset: reference.asset)
        let staging = try workspaces.stagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let data = try await publisher.downloadAsset(reference, asset: info.assetName, into: staging)
        let remote = await configuration.validator.run(.archiveData(data, name: info.assetName), host: configuration.hostInfo, dryRunner: configuration.dryRunner)
        guard !remote.receipt.diagnostics.hasErrors else {
            throw ToolError("release_invalid", "the released archive does not validate", diagnostics: remote.receipt.diagnostics.filter { $0.severity == .error })
        }
        guard remote.receipt.treeHash == local.receipt.treeHash else {
            throw ToolError("release_mismatch", "the released archive is not the current workspace revision; package and publish the current revision, or revert local edits")
        }
        let commit = try await publisher.commit(for: reference)
        var categories = [ModIndexCategory]()
        for c in args.strings("categories") { if let cat = ModIndexCategory(rawValue: c), !categories.contains(cat) { categories.append(cat) } }
        let options = IndexEntryOptions(
            repo: reference.repoURL, releaseURL: info.assetURL, commit: commit, tag: reference.tag, keyID: args.optionalString("keyId"),
            signature: args.optionalString("signature"), summary: args.optionalString("summary"), categories: categories, tags: args.strings("tags").isEmpty ? nil : args.strings("tags")
        )
        let entry: IndexEntryResult
        do { entry = try ModIndexEntry.make(manifest: manifest, archiveSHA256: Hex.sha256(data), archiveBytes: data.count, options: options) }
        catch let e as IndexEntryError { throw ToolError("index_entry_invalid", e.description) }
        let path = "mods/\(manifest.id)/listing.json"
        var warnings = [String]()
        if args.optionalString("signature") == nil || args.optionalString("keyId") == nil {
            warnings.append("keyId/signature are placeholders: the index CI rejects them. Sign {id,version,sha256,api,app} with your author key and call mod_index_entry again with keyId and signature before opening a pull request.")
        }
        let files: [String: String] = [path: entry.json]
        let revisionHash = Hex.sha256(obj(["files": obj([path: entry.json.j])]).canonicalString())
        let body = Self.prBody(manifest: manifest, listing: entry.listing, reference: reference, assetBytes: data.count, assetSHA: Hex.sha256(data), signed: warnings.isEmpty)
        state.setDraft(IndexDraft(
            workspace: workspace, revision: revisionHash, modID: manifest.id, version: manifest.version.description, files: files, repo: reference.repoURL,
            tag: reference.tag, warnings: warnings, templateBody: body
        ))
        if let dir = try? workspaces.indexDirectory(workspace) {
            let target = dir.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(entry.json.utf8).write(to: target, options: .atomic)
        }
        return ToolReturn(obj([
            "files": .array([obj(["path": path.j, "text": entry.json.j])]), "revision": revisionHash.j, "warnings": warnings.j,
        ]))
    }

    static func prBody(manifest: ModManifest, listing: ModIndexListing, reference: ReleaseReference, assetBytes: Int, assetSHA: String, signed: Bool) -> String {
        let permissions: [String] = manifest.permissions.map { p in
            "- \(p.kind.rawValue): \(Redactor.clean(p.reason ?? p.kind.summary, limit: 200))"
        }
        let key = signed ? "key id \(listing.release.keyId); signature in listing.json" : "NOT SIGNED YET (placeholder), do not merge"
        return """
        mod, version, folder: \(manifest.id) \(manifest.version), mods/\(manifest.id)/
        source repo and license: \(reference.repoURL), \(Redactor.clean(manifest.license, limit: 60))
        release tag, source commit, asset url, byte size and sha256: \(listing.release.tag), \(listing.release.commit), \(listing.release.assetURL), \(assetBytes) bytes, \(assetSHA)
        author public key and provenance (or old-key endorsement for rotation): \(key)
        permission rationale:
        \(permissions.isEmpty ? "- none requested" : permissions.joined(separator: "\n"))
        validator report and screenshots: the released archive passed the betterfinder preflight when this listing was generated; no screenshots included

        - [ ] listing identity and permissions match the release manifest
        - [ ] code/assets are mine or licensed with provenance
        - [ ] immutable artifact passes `betterfinder-mod validate --listing`
        - [ ] this pr only changes my entry; no generated feed or workflow edits
        """
    }

    func indexPR(_ args: ToolArguments) async throws -> ToolReturn {
        let workspace = try args.string("workspace")
        let revision = try args.string("revision")
        guard let draft = state.draft(workspace), draft.revision == revision else {
            throw ToolError("no_index_entry", "no generated listing with that revision; call mod_index_entry first and use its revision")
        }
        let title = try args.string("title")
        guard !title.contains("\n"), !title.contains("\r") else { throw ToolError("invalid_arguments", "title must be one line") }
        let extra = Redactor.clean(try args.string("body"), limit: 6000)
        let body = draft.templateBody + (extra.isEmpty ? "" : "\n\n---\nauthor notes (free text):\n" + extra)
        let listing = draft.files.sorted { $0.key < $1.key }.first
        guard let listingPath = listing?.key, let listingText = listing?.value else { throw ToolError("no_index_entry", "the generated listing is empty") }
        let login = try await publisher.login()
        let branch = GitHubPublisher.branchName(modID: draft.modID, version: draft.version)
        let fields: JSONValue = obj(["workspace": workspace.j, "revision": revision.j, "title": title.j, "body": body.j, "login": login.j, "branch": branch.j])
        var review: [String: JSONValue] = [
            "action": "fork the index, push a branch and open a pull request",
            "signedInAs": login.j,
            "destination": configuration.indexRepository.j,
            "base": "main",
            "head": "\(login):\(branch)".j,
            "title": title.j,
            "body": body.j,
            "diff": .array([obj(["path": listingPath.j, "change": "add", "text": listingText.j])]),
            "uploads": "only the file in diff, to your fork, then a pull request to the fixed destination",
        ]
        if !draft.warnings.isEmpty { review["warnings"] = draft.warnings.j }
        return try await consentFlow(tool: "mod_index_pr", args: args, digest: digest("mod_index_pr", fields), review: .object(review)) {
            let staging = try workspaces.stagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            let result = try await publisher.openIndexPullRequest(
                login: login, branch: branch, modID: draft.modID, listingText: listingText, title: title, body: body, staging: staging
            )
            return ToolReturn(obj(["prURL": result.url.j, "head": result.head.j]))
        }
    }
}
