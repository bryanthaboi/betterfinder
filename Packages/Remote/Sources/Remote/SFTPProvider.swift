import Foundation
import FSCore

public final class SFTPProvider: ResourceProvider, @unchecked Sendable {
    public let providerID: String
    public let displayName: String
    public let connection: SFTPConnection
    public let capabilities: ResourceCapabilities = [.read, .write, .rename, .delete, .makeDirectory]
    private let lock = NSLock()
    private var rootPath: String
    public var progressInterval: TimeInterval = 0.2

    public init(providerID: String, displayName: String? = nil, connection: SFTPConnection) {
        self.providerID = providerID
        self.displayName = displayName ?? connection.configuration.displayName
        self.connection = connection
        let p = connection.configuration.path
        self.rootPath = p.hasPrefix("/") ? ResourceID.normalize(p) : "/"
    }

    public var root: ResourceID {
        lock.lock(); defer { lock.unlock() }
        return ResourceID(providerID: providerID, path: rootPath)
    }

    @discardableResult
    public func resolveRoot() async throws -> ResourceID {
        let configured = connection.configuration.path
        let home = try await connection.connect()
        var path = configured
        if path.isEmpty || path == "~" { path = home } else if path.hasPrefix("~/") { path = home + "/" + path.dropFirst(2) }
        let normalized = ResourceID.normalize(path)
        lock.withLock { rootPath = normalized }
        return ResourceID(providerID: providerID, path: normalized)
    }

    public func parent(of id: ResourceID) -> ResourceID? {
        guard id.providerID == providerID else { return nil }
        return id.lexicalParent
    }

    func check(_ id: ResourceID) throws -> String {
        guard id.providerID == providerID else { throw ResourceError.providerUnavailable(id.providerID) }
        try SFTPCommand.validate(id.path)
        return id.path
    }

    func entries(_ dir: ResourceID) async throws -> [SFTPEntry] {
        let out = try await connection.run([.list(try check(dir))])
        return SFTPListingParser.parse(out.sections.first ?? "")
    }

    func item(_ e: SFTPEntry, in dir: ResourceID) -> ResourceItem {
        ResourceItem(id: dir.appending(e.name), name: e.name, isDirectory: e.isDirectory, isSymlink: e.isSymlink, size: e.isDirectory ? nil : e.size,
                     modified: e.modified, permissions: e.permissions, owner: e.owner)
    }

    public func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let all = try await self.entries(directory)
                        .filter { $0.name != "." && $0.name != ".." && (options.showHidden || !$0.name.hasPrefix(".")) }
                        .map { self.item($0, in: directory) }
                    var i = 0
                    while i < all.count {
                        try Task.checkCancellation()
                        continuation.yield(Array(all[i..<min(all.count, i + options.pageSize)]))
                        i += options.pageSize
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ id: ResourceID) async throws -> ResourceItem {
        _ = try check(id)
        guard let parent = id.lexicalParent else {
            _ = try await entries(id)
            return ResourceItem(id: id, name: "/", isDirectory: true)
        }
        let list: [SFTPEntry]
        do { list = try await entries(parent) } catch ResourceError.notFound { throw ResourceError.notFound(id.path) }
        guard let e = list.first(where: { $0.name == id.name }) else { throw ResourceError.notFound(id.path) }
        return item(e, in: parent)
    }

    public func read(_ id: ResourceID, range: Range<Int64>?) async throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bf-sftp-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await download(id, to: temp, progress: { _ in })
        let h = try FileHandle(forReadingFrom: temp)
        defer { try? h.close() }
        guard let range else { return try h.readToEnd() ?? Data() }
        try h.seek(toOffset: UInt64(max(0, range.lowerBound)))
        return try h.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
    }

    private func pollSize(of file: URL, progress: @escaping @Sendable (Int64) -> Void) -> Task<Void, Never> {
        let interval = UInt64(progressInterval * 1_000_000_000)
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let s = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber { progress(s.int64Value) }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        let remote = try check(id)
        let meta = try await stat(id)
        guard !meta.isDirectory else { throw ResourceError.isADirectory(id.name) }
        try? FileManager.default.removeItem(at: localFile)
        let poll = pollSize(of: localFile, progress: progress)
        defer { poll.cancel() }
        do {
            _ = try await connection.run([.get(remote: remote, local: localFile.path)])
        } catch {
            try? FileManager.default.removeItem(at: localFile)
            throw error
        }
        let got = Int64((try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.int64Value ?? -1)
        if let expected = meta.size, got != expected {
            throw ResourceError.verificationFailed("\(id.name): expected \(expected) bytes, received \(got)")
        }
        progress(got)
        return meta
    }

    public func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        let remote = try check(id)
        guard let parent = id.lexicalParent else { throw ResourceError.invalidName(id.path) }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let existing = try await exists(id)
        if existing != nil && !options.overwrite { throw ResourceError.alreadyExists(id.name) }
        if existing?.isDirectory == true { throw ResourceError.isADirectory(id.name) }
        let token = UUID().uuidString.prefix(8).lowercased()
        let temp = parent.appending(".bfpart-\(token)").path
        do {
            _ = try await connection.run([.put(local: localFile.path, remote: temp)])
            try Self.verifyUpload(try await stat(ResourceID(providerID: providerID, path: temp)), name: id.name, expected: size)
        } catch {
            await discard(temp)
            throw error
        }
        var replaced: ResourceItem?
        do {
            _ = try await connection.runTracked([.rename(temp, remote)])
        } catch let f as SFTPConnection.Failure where existing != nil && f.output.executedCount >= 1 {
            replaced = try await replaceViaBackup(temp: temp, remote: remote, backup: parent.appending(".bfold-\(token)").path, id: id, expected: size, failure: f.error)
        } catch {
            await discard(temp)
            throw Self.unwrap(error)
        }
        let result: ResourceItem
        if let replaced { result = replaced } else { result = try await stat(id) }
        try Self.verifyUpload(result, name: id.name, expected: size)
        progress(size)
        return result
    }

    static func verifyUpload(_ item: ResourceItem, name: String, expected: Int64) throws {
        guard !item.isDirectory, item.size == expected else {
            throw ResourceError.verificationFailed("\(name): uploaded \(item.size ?? -1) bytes, expected \(expected)")
        }
    }

    static func unwrap(_ error: Error) -> Error {
        (error as? SFTPConnection.Failure)?.error ?? error
    }

    static func describe(_ error: Error) -> String {
        error is CancellationError ? ResourceError.cancelled.localizedDescription : unwrap(error).localizedDescription
    }

    private func discard(_ path: String) async {
        let connection = connection
        await Task.detached { _ = try? await connection.run([.lenient(.remove(path))]) }.value
    }

    private func restoreBackup(_ backup: String, to remote: String) async -> Bool? {
        let connection = connection
        let backupID = ResourceID(providerID: providerID, path: backup)
        return await Task.detached { [self] () -> Bool? in
            if (try? await connection.run([.rename(backup, remote)])) != nil { return true }
            do { return try await self.exists(backupID) == nil ? false : nil } catch { return nil }
        }.value
    }

    private func restoreCommitted(backup: String, remote: String, aside: String) async -> Bool {
        let connection = connection
        return await Task.detached { () -> Bool in
            guard (try? await connection.run([.rename(remote, aside)])) != nil else { return false }
            if (try? await connection.run([.rename(backup, remote)])) != nil { return true }
            _ = try? await connection.run([.rename(aside, remote)])
            return false
        }.value
    }

    private func incomplete(_ name: String, _ error: Error, backup: String) -> ResourceError {
        let kept = (backup as NSString).lastPathComponent
        return .remote(code: "ReplaceIncomplete", message: "Couldn’t replace “\(name)”: \(Self.describe(error)) The previous version was kept as “\(kept)” in the same folder.")
    }

    private func replaceViaBackup(temp: String, remote: String, backup: String, id: ResourceID, expected: Int64, failure: ResourceError) async throws -> ResourceItem {
        let staged = ResourceID(providerID: providerID, path: temp)
        let stillStaged: Bool
        do {
            stillStaged = try await exists(staged) != nil
        } catch {
            await discard(temp)
            throw failure
        }
        guard stillStaged else { return try await stat(id) }
        do {
            _ = try await connection.runTracked([.rename(remote, backup), .rename(temp, remote)])
        } catch {
            let restored = await restoreBackup(backup, to: remote)
            await discard(temp)
            if restored == nil { throw incomplete(id.name, error, backup: backup) }
            throw Self.unwrap(error)
        }
        do {
            let result = try await stat(id)
            try Self.verifyUpload(result, name: id.name, expected: expected)
            await discard(backup)
            return result
        } catch {
            guard await restoreCommitted(backup: backup, remote: remote, aside: temp) else { throw incomplete(id.name, error, backup: backup) }
            await discard(temp)
            throw error
        }
    }

    public func makeDirectory(_ id: ResourceID) async throws -> ResourceItem {
        let p = try check(id)
        if try await exists(id) != nil { throw ResourceError.alreadyExists(id.name) }
        _ = try await connection.run([.makeDirectory(p)])
        return ResourceItem(id: id, isDirectory: true)
    }

    func collect(_ dir: ResourceID, files: inout [String], dirs: inout [String]) async throws {
        try Task.checkCancellation()
        for e in try await entries(dir) where e.name != "." && e.name != ".." {
            let child = dir.appending(e.name)
            if e.isDirectory {
                try await collect(child, files: &files, dirs: &dirs)
            } else {
                files.append(try check(child))
            }
        }
        dirs.append(try check(dir))
    }

    public func delete(_ id: ResourceID, recursive: Bool) async throws {
        let p = try check(id)
        guard !id.isRoot else { throw ResourceError.unsupported("Deleting the server root") }
        let meta = try await stat(id)
        if !meta.isDirectory {
            _ = try await connection.run([.remove(p)])
            return
        }
        var files: [String] = []
        var dirs: [String] = []
        if recursive {
            try await collect(id, files: &files, dirs: &dirs)
        } else {
            dirs = [p]
        }
        let commands = files.map(SFTPCommand.remove) + dirs.map(SFTPCommand.removeDirectory)
        var i = 0
        while i < commands.count {
            try Task.checkCancellation()
            _ = try await connection.run(Array(commands[i..<min(commands.count, i + 200)]))
            i += 200
        }
    }

    public func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        let a = try check(id)
        let b = try check(destination)
        if try await exists(destination) != nil { throw ResourceError.alreadyExists(destination.name) }
        _ = try await connection.run([.rename(a, b)])
        return try await stat(destination)
    }
}
