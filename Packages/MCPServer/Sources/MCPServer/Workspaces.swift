import Foundation
import ModKit
import ModValidation

public struct ToolError: Error, Equatable, Sendable {
    public var code: String
    public var message: String
    public var diagnostics: [ModDiagnostic]?
    public var details: JSONValue?

    public init(_ code: String, _ message: String, diagnostics: [ModDiagnostic]? = nil, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.diagnostics = diagnostics
        self.details = details
    }
}

public struct WorkspaceFileInfo: Equatable, Sendable {
    public var path: String
    public var bytes: Int
}

public struct WorkspaceChange: Equatable, Sendable {
    public var path: String
    public var text: String?

    public init(path: String, text: String?) {
        self.path = path
        self.text = text
    }
}

public final class ModWorkspaces: @unchecked Sendable {
    public static let maxFileBytes = 1 << 20
    public static let maxReadBytes = 4 << 20
    public static let maxChanges = 256
    public static let maxReadPaths = 64

    public let root: URL
    private let lock = NSLock()

    public static var standardRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("betterfinder", isDirectory: true)
            .appendingPathComponent("ModWorkspaces", isDirectory: true)
    }

    public init(root: URL = ModWorkspaces.standardRoot) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func validateID(_ id: String) throws {
        guard ModPatterns.matches(id, ModPatterns.modID), !id.hasPrefix("."), !id.contains("..") else {
            throw ToolError("invalid_workspace", "'\(id)' is not a valid workspace id; use the mod id (author.name)")
        }
    }

    public func directory(for id: String) throws -> URL {
        try Self.validateID(id)
        return root.appendingPathComponent(id, isDirectory: true)
    }

    public func exists(_ id: String) -> Bool {
        guard let dir = try? directory(for: id) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    func requireExisting(_ id: String) throws -> URL {
        let dir = try directory(for: id)
        guard let st = Self.lstat(dir.path), Self.isDirectory(st) else {
            throw ToolError("unknown_workspace", "workspace '\(id)' does not exist; create it with mod_scaffold")
        }
        return dir
    }

    public func artifactsDirectory(_ id: String) throws -> URL {
        try Self.validateID(id)
        let dir = root.appendingPathComponent(".artifacts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public func indexDirectory(_ id: String) throws -> URL {
        try Self.validateID(id)
        let dir = root.appendingPathComponent(".index", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public func stagingDirectory() throws -> URL {
        let dir = root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public func metaFile(_ id: String) throws -> URL {
        try Self.validateID(id)
        let dir = root.appendingPathComponent(".meta", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("\(id).json")
    }

    public static func validateRelativePath(_ path: String) throws {
        guard ModPatterns.matches(path, ModPatterns.relativePath) else {
            throw ToolError("invalid_path", "'\(path.prefix(80))' is not an allowed workspace path: use a relative path with no '..', no leading '/', no backslashes and no control characters")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { throw ToolError("invalid_path", "'\(path.prefix(80))' contains an empty or dot path component") }
            if part == ".git" || part == ".artifacts" || part == ".meta" || part == ".index" || part == ".staging" {
                throw ToolError("invalid_path", "'\(path.prefix(80))' uses the reserved component '\(part)'")
            }
            if part.utf8.count > 128 { throw ToolError("invalid_path", "path component longer than 128 bytes") }
        }
    }

    func resolve(_ id: String, path: String) throws -> URL {
        try Self.validateRelativePath(path)
        let base = try requireExisting(id)
        let url = base.appendingPathComponent(path)
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(base.path + "/") else { throw ToolError("path_escape", "'\(path.prefix(80))' resolves outside the workspace") }
        return url
    }

    static func lstat(_ path: String) -> stat? {
        var st = stat()
        return Darwin.lstat(path, &st) == 0 ? st : nil
    }

    static func isSymlink(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFLNK }
    static func isRegular(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFREG }
    static func isDirectory(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFDIR }

    func checkChain(base: URL, path: String) throws {
        var current = base
        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            current = current.appendingPathComponent(part)
            guard let st = Self.lstat(current.path) else { return }
            if Self.isSymlink(st) { throw ToolError("path_escape", "'\(path.prefix(80))' passes through a symbolic link") }
            if i < parts.count - 1 {
                if !Self.isDirectory(st) { throw ToolError("invalid_path", "'\(path.prefix(80))' has a file where a folder is needed") }
            } else if Self.isDirectory(st) {
                throw ToolError("invalid_path", "'\(path.prefix(80))' is a folder")
            } else if !Self.isRegular(st) {
                throw ToolError("invalid_path", "'\(path.prefix(80))' is not a regular file")
            }
        }
    }

    public func revision(_ id: String) throws -> String {
        let dir = try requireExisting(id)
        return PackageLoader.loadDirectory(dir).treeHash
    }

    public func list(_ id: String) throws -> [WorkspaceFileInfo] {
        let dir = try requireExisting(id)
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else { return [] }
        var out = [WorkspaceFileInfo]()
        for case let url as URL in en {
            let rel = String(url.standardizedFileURL.path.dropFirst(dir.path.count + 1))
            if rel.split(separator: "/").contains(".git") { en.skipDescendants(); continue }
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if v?.isSymbolicLink == true { en.skipDescendants(); continue }
            guard v?.isRegularFile == true else { continue }
            out.append(WorkspaceFileInfo(path: rel, bytes: v?.fileSize ?? 0))
            if out.count >= 5000 { break }
        }
        return out.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }

    public func read(_ id: String, paths: [String]) throws -> [(path: String, text: String)] {
        guard paths.count <= Self.maxReadPaths else { throw ToolError("too_many_paths", "at most \(Self.maxReadPaths) paths per read") }
        let base = try requireExisting(id)
        var total = 0
        var out = [(path: String, text: String)]()
        for path in paths {
            let url = try resolve(id, path: path)
            try checkChain(base: base, path: path)
            guard let st = Self.lstat(url.path), Self.isRegular(st) else { throw ToolError("not_found", "'\(path.prefix(80))' does not exist in the workspace") }
            guard st.st_size <= Self.maxFileBytes else { throw ToolError("file_too_large", "'\(path.prefix(80))' is larger than \(Self.maxFileBytes) bytes") }
            total += Int(st.st_size)
            guard total <= Self.maxReadBytes else { throw ToolError("read_too_large", "requested files exceed \(Self.maxReadBytes) bytes together") }
            guard let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else {
                throw ToolError("not_text", "'\(path.prefix(80))' is not UTF-8 text")
            }
            out.append((path, text))
        }
        return out
    }

    public func create(_ id: String, files: [ScaffoldFile]) throws -> [String] {
        let dir = try directory(for: id)
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !existing.isEmpty {
            throw ToolError("workspace_exists", "workspace '\(id)' already exists; edit it with mod_files_write or pick another id")
        }
        do { return try ModScaffold.write(files, to: dir) }
        catch { throw ToolError("scaffold_failed", "\(error.localizedDescription)") }
    }

    public func write(_ id: String, expected: String, changes: [WorkspaceChange], limits: ModCatalogLimits = .v1) throws -> (revision: String, changed: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let base = try requireExisting(id)
        guard changes.count <= Self.maxChanges else { throw ToolError("too_many_changes", "at most \(Self.maxChanges) changes per call") }
        let current = PackageLoader.loadDirectory(base).treeHash
        guard current == expected else {
            throw ToolError("stale_revision", "the workspace changed since revision \(expected.prefix(12)); re-read it", details: obj(["currentRevision": current.j]))
        }
        var seen = Set<String>()
        var plans = [(path: String, url: URL, text: String?)]()
        var added = 0
        for change in changes {
            let key = change.path.lowercased()
            guard seen.insert(key).inserted else { throw ToolError("duplicate_path", "'\(change.path.prefix(80))' appears twice in one call") }
            let url = try resolve(id, path: change.path)
            try checkChain(base: base, path: change.path)
            if let text = change.text {
                let size = text.utf8.count
                guard size <= Self.maxFileBytes else { throw ToolError("file_too_large", "'\(change.path.prefix(80))' is larger than \(Self.maxFileBytes) bytes") }
                added += size
            }
            plans.append((change.path, url, change.text))
        }
        let existing = try list(id).reduce(0) { $0 + $1.bytes }
        guard existing + added <= limits.maxPackageBytes * 2 else {
            throw ToolError("workspace_too_large", "the workspace would exceed its size budget")
        }
        let fm = FileManager.default
        var temps = [(temp: URL, final: URL)]()
        var deletions = [URL]()
        var changed = [String]()
        func cleanup() { for t in temps { try? fm.removeItem(at: t.temp) } }
        for plan in plans {
            if let text = plan.text {
                let data = Data(text.utf8)
                if let st = Self.lstat(plan.url.path), Self.isRegular(st), let old = fm.contents(atPath: plan.url.path), old == data { continue }
                do {
                    try fm.createDirectory(at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try checkChain(base: base, path: plan.path)
                    let temp = plan.url.deletingLastPathComponent().appendingPathComponent(".mcp-\(UUID().uuidString).tmp")
                    guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                        throw ToolError("write_failed", "could not write '\(plan.path.prefix(80))'")
                    }
                    temps.append((temp, plan.url))
                    changed.append(plan.path)
                } catch {
                    cleanup()
                    throw error
                }
            } else if let st = Self.lstat(plan.url.path), Self.isRegular(st) {
                deletions.append(plan.url)
                changed.append(plan.path)
            }
        }
        for t in temps {
            if rename(t.temp.path, t.final.path) != 0 {
                cleanup()
                throw ToolError("write_failed", "could not replace '\(t.final.lastPathComponent)'")
            }
            chmod(t.final.path, 0o644)
        }
        for url in deletions { try? fm.removeItem(at: url) }
        var dirs = Set(deletions.map { $0.deletingLastPathComponent() })
        while let d = dirs.popFirst(), d.path != base.path, d.path.hasPrefix(base.path + "/") {
            if let items = try? fm.contentsOfDirectory(atPath: d.path), items.isEmpty {
                try? fm.removeItem(at: d)
                dirs.insert(d.deletingLastPathComponent())
            }
        }
        let newRevision = PackageLoader.loadDirectory(base).treeHash
        return (newRevision, changed.sorted())
    }
}
