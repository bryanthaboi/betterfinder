import Foundation
import Darwin
import UniformTypeIdentifiers

public struct ListingOptions: Sendable, Hashable {
    public var showHidden: Bool
    public var fetchTags: Bool

    public init(showHidden: Bool = false, fetchTags: Bool = true) {
        self.showHidden = showHidden
        self.fetchTags = fetchTags
    }
}

public enum DirectoryLister {
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        .creationDateKey, .addedToDirectoryDateKey, .contentTypeKey, .tagNamesKey,
        .fileResourceIdentifierKey, .linkCountKey, .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    public static func list(_ directory: URL, options: ListingOptions = .init()) throws -> [FileItem] {
        var items: [FileItem] = []
        try enumerate(directory, options: options) { items.append($0) }
        return items
    }

    public static func stream(_ directory: URL, batchSize: Int = 500, options: ListingOptions = .init()) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    var batch: [FileItem] = []
                    try enumerate(directory, options: options) {
                        batch.append($0)
                        if batch.count >= max(1, batchSize) { continuation.yield(batch); batch.removeAll(keepingCapacity: true) }
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func enumerate(_ directory: URL, options: ListingOptions, consume: (FileItem) -> Void) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        func date(_ value: timespec?) -> Date? {
            value.map { Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_nsec) / 1e9) }
        }
        var types: [String: UTType] = [:]
        var missingTypes: Set<String> = []
        try BulkDirectory().read(fd: fd) { entry in
            let hidden = entry.name.hasPrefix(".") || (entry.flags ?? 0) & UInt32(UF_HIDDEN) != 0
            if hidden && !options.showHidden { return }
            let url = directory.appendingPathComponent(entry.name, isDirectory: entry.type == 2)
            let ext: String
            if let dot = entry.name.lastIndex(of: "."), dot != entry.name.startIndex {
                ext = String(entry.name[entry.name.index(after: dot)...])
            } else { ext = "" }
            if types[ext] == nil && !missingTypes.contains(ext) {
                if let type = UTType(filenameExtension: ext) { types[ext] = type } else { missingTypes.insert(ext) }
            }
            let type = types[ext]
            var item = FileItem(url: url, name: entry.name, isDirectory: entry.type == 2,
                isPackage: entry.type == 2 && ((try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true),
                isSymlink: entry.type == 5, isHidden: hidden, logicalSize: entry.logical, allocatedSize: entry.allocated,
                dateModified: date(entry.modified), dateCreated: date(entry.created), dateAdded: date(entry.added),
                contentTypeIdentifier: type?.identifier, tagNames: [], fileID: entry.inode, deviceID: entry.device,
                linkCount: entry.links.map(Int.init))
            item.deferredTags = options.fetchTags
            item.deferredCloudMetadata = true
            consume(item)
        }
    }

    static func tagNames(_ url: URL) -> [String] {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length <= 65536 else { return [] }
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        guard count == length, let tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [] }
        return tags.map { $0.components(separatedBy: "\n").first ?? $0 }
    }

    public static func item(for url: URL) -> FileItem? {
        guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        var fileID: UInt64?
        var deviceID: Int32?
        var st = stat()
        if lstat(url.path, &st) == 0 {
            fileID = UInt64(st.st_ino)
            deviceID = st.st_dev
        }
        return FileItem(
            url: url,
            name: v.name ?? url.lastPathComponent,
            isDirectory: v.isDirectory ?? false,
            isPackage: v.isPackage ?? false,
            isSymlink: v.isSymbolicLink ?? false,
            isHidden: v.isHidden ?? false,
            logicalSize: v.fileSize.map(Int64.init),
            allocatedSize: v.totalFileAllocatedSize.map(Int64.init),
            dateModified: v.contentModificationDate,
            dateCreated: v.creationDate,
            dateAdded: v.addedToDirectoryDate,
            contentTypeIdentifier: v.contentType?.identifier,
            tagNames: v.tagNames ?? [],
            fileID: fileID,
            deviceID: deviceID,
            linkCount: v.linkCount,
            isUbiquitous: v.isUbiquitousItem ?? false,
            ubiquitousStatus: v.ubiquitousItemDownloadingStatus?.rawValue
        )
    }
}
