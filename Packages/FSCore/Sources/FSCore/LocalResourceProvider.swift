import Darwin
import Foundation

public final class LocalResourceProvider: ResourceProvider, @unchecked Sendable {
    public static let shared = LocalResourceProvider()

    public let providerID = ResourceID.localProviderID
    public let displayName = "This Mac"
    public let capabilities: ResourceCapabilities = [.read, .write, .rename, .trash, .watch, .delete, .makeDirectory, .serverSideCopy, .rangedRead, .undo]
    public let root = ResourceID(providerID: ResourceID.localProviderID, path: "/")

    public init() {}

    private func url(_ id: ResourceID) throws -> URL {
        guard let u = id.fileURL else { throw ResourceError.providerUnavailable(id.providerID) }
        return u
    }

    public func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        guard let dir = directory.fileURL else {
            return AsyncThrowingStream { $0.finish(throwing: ResourceError.providerUnavailable(directory.providerID)) }
        }
        let source = DirectoryLister.stream(dir, batchSize: options.pageSize, options: ListingOptions(showHidden: options.showHidden, fetchTags: false))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await batch in source { continuation.yield(batch.map(ResourceItem.init(fileItem:))) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ id: ResourceID) async throws -> ResourceItem {
        let u = try url(id)
        guard let f = DirectoryLister.item(for: u) else { throw ResourceError.notFound(id.path) }
        return ResourceItem(fileItem: f)
    }

    public func read(_ id: ResourceID, range: Range<Int64>?) async throws -> Data {
        let h = try FileHandle(forReadingFrom: try url(id))
        defer { try? h.close() }
        if let range {
            try h.seek(toOffset: UInt64(max(0, range.lowerBound)))
            return try h.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        }
        return try h.readToEnd() ?? Data()
    }

    public func watch(_ directory: ResourceID, handler: @escaping @Sendable () -> Void) -> ResourceWatchToken? {
        guard let dir = directory.fileURL else { return nil }
        let w = DirectoryWatcher(paths: [dir]) { _ in handler() }
        w.start()
        return ResourceWatchToken { w.stop() }
    }

    public func parent(of id: ResourceID) -> ResourceID? { id.lexicalParent }

    public func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        let src = try url(id)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: localFile)
        try FileManager.default.copyItem(at: src, to: localFile)
        let item = try await stat(id)
        progress(item.size ?? 0)
        return item
    }

    public func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        let dst = try url(id)
        try Task.checkCancellation()
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: dst.path)
        if exists && !options.overwrite { throw ResourceError.alreadyExists(id.name) }
        let temp = dst.deletingLastPathComponent().appendingPathComponent(".bfpart-" + UUID().uuidString.prefix(8))
        try fm.copyItem(at: localFile, to: temp)
        do {
            if exists {
                _ = try fm.replaceItemAt(dst, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: dst)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        let item = try await stat(id)
        progress(item.size ?? 0)
        return item
    }

    public func makeDirectory(_ id: ResourceID) async throws -> ResourceItem {
        try FileManager.default.createDirectory(at: try url(id), withIntermediateDirectories: false)
        return try await stat(id)
    }

    public func delete(_ id: ResourceID, recursive: Bool) async throws {
        let u = try url(id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw ResourceError.notFound(id.path) }
        if isDir.boolValue && !recursive, let c = try? FileManager.default.contentsOfDirectory(atPath: u.path), !c.isEmpty {
            throw ResourceError.unsupported("Deleting a non-empty folder without recursion")
        }
        try FileManager.default.removeItem(at: u)
    }

    public func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        let d = try url(destination)
        if FileManager.default.fileExists(atPath: d.path) { throw ResourceError.alreadyExists(destination.name) }
        try FileManager.default.moveItem(at: try url(id), to: d)
        return try await stat(destination)
    }

    public func copy(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        let d = try url(destination)
        if FileManager.default.fileExists(atPath: d.path) { throw ResourceError.alreadyExists(destination.name) }
        try FileManager.default.copyItem(at: try url(id), to: d)
        return try await stat(destination)
    }

    public func trash(_ id: ResourceID) async throws {
        try FileManager.default.trashItem(at: try url(id), resultingItemURL: nil)
    }
}
