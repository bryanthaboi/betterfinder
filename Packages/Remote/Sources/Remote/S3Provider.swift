import Foundation
import FSCore

public final class S3Provider: ResourceProvider, @unchecked Sendable {
    public let providerID: String
    public let displayName: String
    public let client: S3Client
    public let capabilities: ResourceCapabilities = [.read, .rangedRead, .write, .rename, .delete, .makeDirectory, .serverSideCopy]
    public var root: ResourceID { ResourceID(providerID: providerID, path: "/") }

    public init(providerID: String, displayName: String? = nil, client: S3Client) {
        self.providerID = providerID
        self.displayName = displayName ?? client.configuration.displayName
        self.client = client
    }

    private var basePrefix: String {
        let p = client.configuration.prefix
        return p.isEmpty ? "" : p + "/"
    }

    func key(for id: ResourceID) throws -> String {
        guard id.providerID == providerID else { throw ResourceError.providerUnavailable(id.providerID) }
        return basePrefix + id.path.dropFirst()
    }

    func folderPrefix(for id: ResourceID) throws -> String {
        id.isRoot ? basePrefix : try key(for: id) + "/"
    }

    func id(forKey key: String) -> ResourceID {
        var rel = key.hasPrefix(basePrefix) ? String(key.dropFirst(basePrefix.count)) : key
        if rel.hasSuffix("/") { rel.removeLast() }
        return ResourceID(providerID: providerID, path: "/" + rel)
    }

    func validateName(_ id: ResourceID) throws {
        for c in id.components where c.isEmpty || c.utf8.count > 1024 || c.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw ResourceError.invalidName(c)
        }
    }

    public func list(_ directory: ResourceID, options: ResourceListOptions) -> AsyncThrowingStream<[ResourceItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prefix = try self.folderPrefix(for: directory)
                    var token: String?
                    repeat {
                        try Task.checkCancellation()
                        let page = try await self.client.list(prefix: prefix, continuationToken: token, maxKeys: options.pageSize)
                        var items: [ResourceItem] = []
                        for p in page.commonPrefixes where p != prefix {
                            let id = self.id(forKey: p)
                            guard options.showHidden || !id.name.hasPrefix(".") else { continue }
                            items.append(ResourceItem(id: id, isDirectory: true))
                        }
                        for o in page.objects where o.key != prefix && !o.key.hasSuffix("/") {
                            let id = self.id(forKey: o.key)
                            guard options.showHidden || !id.name.hasPrefix(".") else { continue }
                            items.append(ResourceItem(id: id, isDirectory: false, size: o.size, modified: o.lastModified, etag: o.etag))
                        }
                        if !items.isEmpty { continuation.yield(items) }
                        token = page.isTruncated ? page.nextContinuationToken : nil
                    } while token != nil
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ id: ResourceID) async throws -> ResourceItem {
        if id.isRoot {
            _ = try await client.list(prefix: basePrefix, maxKeys: 1)
            return ResourceItem(id: id, name: displayName, isDirectory: true)
        }
        let k = try key(for: id)
        do {
            let h = try await client.head(key: k)
            return ResourceItem(id: id, isDirectory: false, size: h.size, modified: h.lastModified, etag: h.etag, checksumSHA256: h.sha256)
        } catch ResourceError.notFound {
            let page = try await client.list(prefix: k + "/", maxKeys: 1)
            if page.keyCount > 0 || !page.objects.isEmpty || !page.commonPrefixes.isEmpty {
                return ResourceItem(id: id, isDirectory: true)
            }
            throw ResourceError.notFound(id.path)
        }
    }

    public func read(_ id: ResourceID, range: Range<Int64>?) async throws -> Data {
        try await client.get(key: try key(for: id), range: range).0
    }

    public func download(_ id: ResourceID, to localFile: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        let info = try await client.download(key: try key(for: id), to: localFile, progress: progress)
        return ResourceItem(id: id, isDirectory: false, size: info.size, modified: info.lastModified, etag: info.etag, checksumSHA256: info.sha256)
    }

    public func upload(from localFile: URL, to id: ResourceID, options: ResourceUploadOptions, progress: @escaping @Sendable (Int64) -> Void) async throws -> ResourceItem {
        try validateName(id)
        let k = try key(for: id)
        if !options.overwrite, try await exists(id) != nil { throw ResourceError.alreadyExists(id.name) }
        _ = try await client.upload(file: localFile, key: k, contentType: options.contentType, sha256: options.sha256, progress: progress)
        return try await stat(id)
    }

    public func makeDirectory(_ id: ResourceID) async throws -> ResourceItem {
        try validateName(id)
        if try await exists(id) != nil { throw ResourceError.alreadyExists(id.name) }
        _ = try await client.put(key: try key(for: id) + "/", data: Data(), contentType: "application/x-directory")
        return ResourceItem(id: id, isDirectory: true)
    }

    public func allKeys(under id: ResourceID) async throws -> [S3Object] {
        let prefix = try folderPrefix(for: id)
        var token: String?
        var out: [S3Object] = []
        repeat {
            try Task.checkCancellation()
            let page = try await client.list(prefix: prefix, delimiter: nil, continuationToken: token)
            out.append(contentsOf: page.objects)
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return out
    }

    public func delete(_ id: ResourceID, recursive: Bool) async throws {
        guard !id.isRoot else { throw ResourceError.unsupported("Deleting the bucket root") }
        let item = try await stat(id)
        if !item.isDirectory {
            try await client.delete(key: try key(for: id))
            return
        }
        let keys = try await allKeys(under: id)
        let marker = try folderPrefix(for: id)
        if !recursive && keys.contains(where: { $0.key != marker }) { throw ResourceError.unsupported("Deleting a non-empty folder without recursion") }
        for o in keys.sorted(by: { $0.key.count > $1.key.count }) {
            try Task.checkCancellation()
            try await client.delete(key: o.key)
        }
    }

    struct CopiedObject: Sendable {
        let source: S3Object
        let destinationKey: String
        let copyETag: String?
    }

    public func copy(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        try await copyRecording(id, to: destination).item
    }

    func copyRecording(_ id: ResourceID, to destination: ResourceID, beforeCopying: (() async throws -> Void)? = nil) async throws -> (item: ResourceItem, source: ResourceItem, copied: [CopiedObject]) {
        try validateName(destination)
        if try await exists(destination) != nil { throw ResourceError.alreadyExists(destination.name) }
        let item = try await stat(id)
        try await beforeCopying?()
        if item.isDirectory {
            let srcPrefix = try folderPrefix(for: id)
            let dstPrefix = try folderPrefix(for: destination)
            let manifest = try await allKeys(under: id)
            if manifest.contains(where: { $0.size > client.maxSinglePartCopy }) { throw ResourceError.unsupported("Server-side copy of objects over 5 GB") }
            var copied: [CopiedObject] = []
            for o in manifest {
                try Task.checkCancellation()
                let target = dstPrefix + o.key.dropFirst(srcPrefix.count)
                let etag = try await client.copy(from: o.key, to: target, ifMatch: o.etag)
                copied.append(CopiedObject(source: o, destinationKey: target, copyETag: etag))
            }
            try await verifyCopies(copied, under: destination)
            return (ResourceItem(id: destination, isDirectory: true), item, copied)
        }
        if (item.size ?? 0) > client.maxSinglePartCopy { throw ResourceError.unsupported("Server-side copy of objects over 5 GB") }
        let source = S3Object(key: try key(for: id), size: item.size ?? 0, lastModified: item.modified, etag: item.etag)
        let target = try key(for: destination)
        let etag = try await client.copy(from: source.key, to: target, ifMatch: source.etag)
        let copied = CopiedObject(source: source, destinationKey: target, copyETag: etag)
        let result = try await stat(destination)
        try Self.verify(copied, against: result.size.map { S3Object(key: target, size: $0, lastModified: result.modified, etag: result.etag) })
        return (result, item, [copied])
    }

    static func verify(_ c: CopiedObject, against found: S3Object?) throws {
        let name = (c.destinationKey as NSString).lastPathComponent
        guard let found else { throw ResourceError.verificationFailed("\(name) is missing after the copy") }
        guard found.size == c.source.size else {
            throw ResourceError.verificationFailed("\(name) has \(found.size) bytes after the copy, expected \(c.source.size)")
        }
        if let written = c.copyETag, let seen = found.etag, written != seen {
            throw ResourceError.verificationFailed("\(name) changed after the copy")
        }
    }

    func verifyCopies(_ copied: [CopiedObject], under destination: ResourceID) async throws {
        var found: [String: S3Object] = [:]
        for o in try await allKeys(under: destination) { found[o.key] = o }
        for c in copied { try Self.verify(c, against: found[c.destinationKey]) }
    }

    func requireSafeDelete(moving id: ResourceID) async throws {
        let parent = id.lexicalParent ?? root
        let probe = try folderPrefix(for: parent) + ".bfcheck-\(UUID().uuidString.prefix(8).lowercased())"
        guard try await client.enforcesConditionalDelete(probeKey: probe) else {
            throw ResourceError.remote(code: "SafeMoveUnavailable", message: "“\(id.name)” wasn’t moved because \(displayName) can’t delete an original only if it’s unchanged, so a move could lose newer data. Copy it instead, then delete the original.")
        }
    }

    @discardableResult
    public func deleteIfUnchanged(_ id: ResourceID, from expected: ResourceItem) async throws -> Bool {
        guard !id.isRoot else { throw ResourceError.unsupported("Deleting the bucket root") }
        if expected.isDirectory {
            guard try await stat(id).isDirectory else { return false }
            try await delete(id, recursive: false)
            return true
        }
        guard let etag = expected.etag, !etag.isEmpty else { return false }
        try await requireSafeDelete(moving: id)
        switch try await client.delete(key: try key(for: id), ifMatch: etag) {
        case .deleted: return true
        case .changed: return false
        case .refused:
            client.noteConditionalDeleteRefused()
            throw ResourceError.remote(code: "SafeMoveUnavailable", message: "The original “\(id.name)” was kept because \(displayName) can’t delete it only if it’s unchanged.")
        }
    }

    public func move(_ id: ResourceID, to destination: ResourceID) async throws -> ResourceItem {
        let (moved, source, copied) = try await copyRecording(id, to: destination, beforeCopying: { try await self.requireSafeDelete(moving: id) })
        var changed: [String] = []
        var refused: [String] = []
        var removed = Set<String>()
        var stopped = false
        for c in copied.sorted(by: { $0.source.key.count > $1.source.key.count }) {
            try Task.checkCancellation()
            guard !stopped, let etag = c.source.etag, !etag.isEmpty else {
                refused.append(c.source.key)
                continue
            }
            switch try await client.delete(key: c.source.key, ifMatch: etag) {
            case .deleted: removed.insert(c.source.key)
            case .changed: changed.append(c.source.key)
            case .refused:
                client.noteConditionalDeleteRefused()
                stopped = true
                refused.append(c.source.key)
            }
        }
        if !refused.isEmpty {
            let what = source.isDirectory ? "\(refused.count) original item\(refused.count == 1 ? " was" : "s were") kept in “\(id.name)”" : "the original was kept"
            throw ResourceError.remote(code: "SafeMoveUnavailable", message: "“\(id.name)” was copied to “\(destination.name)”, but \(what) because \(displayName) can’t delete an original only if it’s unchanged.")
        }
        guard source.isDirectory else {
            if !changed.isEmpty { throw ResourceError.verificationFailed("“\(id.name)” changed while it was being moved, so the original was kept") }
            return moved
        }
        let prefix = try folderPrefix(for: id)
        let left = try await allKeys(under: id).map(\.key).filter { !removed.contains($0) }
        if !left.isEmpty {
            let names = left.prefix(5).map { String($0.dropFirst(prefix.count)) }.filter { !$0.isEmpty }
            let more = left.count > names.count && !names.isEmpty ? ", and \(left.count - names.count) more" : ""
            let list = names.isEmpty ? "" : ": " + names.joined(separator: ", ") + more
            throw ResourceError.verificationFailed("“\(id.name)” changed while it was being moved. \(left.count) item\(left.count == 1 ? " was" : "s were") left in place\(list)")
        }
        return moved
    }
}
