import Darwin
import Foundation

public struct IndexedFolder: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let allocatedBytes: Int64
    public let items: Int
    public let ownItems: Int
    public let isCounting: Bool
    public let isPending: Bool
    public let isUnreadable: Bool
    public let isHidden: Bool

    public init(id: Int64, name: String, allocatedBytes: Int64, items: Int, ownItems: Int = 0, isCounting: Bool = false, isPending: Bool = false, isUnreadable: Bool = false, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.allocatedBytes = allocatedBytes
        self.items = items
        self.ownItems = ownItems
        self.isCounting = isCounting
        self.isPending = isPending
        self.isUnreadable = isUnreadable
        self.isHidden = isHidden
    }
}

public struct IndexedFile: Sendable, Hashable {
    public let name: String
    public let allocatedBytes: Int64

    public init(name: String, allocatedBytes: Int64) {
        self.name = name
        self.allocatedBytes = allocatedBytes
    }
}

public struct IndexStatistics: Sendable, Equatable {
    public var roots: [String] = []
    public var folders = 0
    public var items = 0
    public var allocatedBytes: Int64 = 0
    public var pendingFolders = 0
    public var unscannedFolders = 0
    public var unreadableFolders = 0
    public var databaseBytes: Int64 = 0

    public init() {}

    public var isComplete: Bool { !roots.isEmpty && pendingFolders == 0 && unscannedFolders == 0 }
}

public struct EmptyFolderCluster: Sendable, Hashable {
    public let parent: Int64
    public let count: Int
}

public final class SizeIndexTree: @unchecked Sendable {
    private static let columns = "id,name,alloc+multi_alloc,items,pending,fresh,partial,flags,parent,own_items"
    private static let settledMask = IndexFlag.scan | IndexFlag.fresh | IndexFlag.detached | IndexFlag.denied | IndexFlag.deferred

    private let db: IndexDatabase
    private let lock = NSLock()
    private let databaseURL: URL

    public init(databaseURL: URL = SizeIndexLocation.database) throws {
        db = try IndexDatabase(databaseURL, readOnly: true, cacheKiB: 4096)
        self.databaseURL = databaseURL
    }

    private static func folder(_ s: OpaquePointer) -> IndexedFolder {
        let flags = IndexDatabase.int(s, 7)
        let stored = IndexDatabase.text(s, 1) ?? ""
        let name = IndexDatabase.int(s, 8) == 0 ? (stored == "/" ? "/" : (stored as NSString).lastPathComponent) : stored
        return IndexedFolder(id: IndexDatabase.int(s, 0), name: name, allocatedBytes: max(0, IndexDatabase.int(s, 2)), items: Int(max(0, IndexDatabase.int(s, 3))),
                             ownItems: Int(max(0, IndexDatabase.int(s, 9))), isCounting: IndexDatabase.int(s, 5) > 0, isPending: IndexDatabase.int(s, 4) > 0,
                             isUnreadable: IndexDatabase.int(s, 6) > 0, isHidden: flags & IndexFlag.hidden != 0)
    }

    private func locked<T>(_ body: () throws -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return try? body()
    }

    public func folder(at url: URL) -> IndexedFolder? {
        let path = SizeIndexLocation.canonical(url).path
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, let uuid = IndexVolume.identifier(forPath: path) else { return nil }
        return locked {
            guard let vol = try db.first("SELECT id FROM volumes WHERE uuid=?", args: [.text(uuid)], { IndexDatabase.int($0, 0) }) else { return nil }
            return try db.first("SELECT \(Self.columns) FROM dirs WHERE vol=? AND inode=?", args: [.int(vol), .int(Int64(bitPattern: UInt64(st.st_ino)))], Self.folder)
        } ?? nil
    }

    public func folder(id: Int64) -> IndexedFolder? {
        locked { try db.first("SELECT \(Self.columns) FROM dirs WHERE id=?", args: [.int(id)], Self.folder) } ?? nil
    }

    public func children(of id: Int64) -> [IndexedFolder] {
        var out: [IndexedFolder] = []
        _ = locked { try db.each("SELECT \(Self.columns) FROM dirs WHERE parent=?", args: [.int(id)]) { out.append(Self.folder($0)) } }
        return out.sorted { $0.allocatedBytes != $1.allocatedBytes ? $0.allocatedBytes > $1.allocatedBytes : $0.name < $1.name }
    }

    public func path(of id: Int64) -> String? {
        locked {
            var parts: [String] = []
            var current = id
            for _ in 0..<512 {
                guard let (parent, name, flags) = try db.first("SELECT parent,name,flags FROM dirs WHERE id=?", args: [.int(current)], {
                    (IndexDatabase.int($0, 0), IndexDatabase.text($0, 1) ?? "", IndexDatabase.int($0, 2))
                }) else { return nil }
                if parent == 0 {
                    guard flags & IndexFlag.detached == 0 else { return nil }
                    let tail = parts.reversed().joined(separator: "/")
                    if tail.isEmpty { return name }
                    return name == "/" ? "/" + tail : name + "/" + tail
                }
                parts.append(name)
                current = parent
            }
            return nil
        } ?? nil
    }

    public func statistics() -> IndexStatistics {
        var stats = IndexStatistics()
        _ = locked {
            try db.each("SELECT name,items,alloc+multi_alloc,pending,fresh,partial FROM dirs WHERE parent=0 AND flags&?=0 ORDER BY name", args: [.int(IndexFlag.detached)]) { s in
                stats.roots.append(IndexDatabase.text(s, 0) ?? "")
                stats.items += Int(max(0, IndexDatabase.int(s, 1)))
                stats.allocatedBytes += max(0, IndexDatabase.int(s, 2))
                stats.pendingFolders += Int(max(0, IndexDatabase.int(s, 3)))
                stats.unscannedFolders += Int(max(0, IndexDatabase.int(s, 4)))
                stats.unreadableFolders += Int(max(0, IndexDatabase.int(s, 5)))
            }
            stats.folders = Int(try db.first("SELECT count(*) FROM dirs", args: []) { IndexDatabase.int($0, 0) } ?? 0)
        }
        for suffix in ["", "-wal"] {
            var st = stat()
            if stat(databaseURL.path + suffix, &st) == 0 { stats.databaseBytes += Int64(st.st_size) }
        }
        return stats
    }

    public func emptyFolderClusters(minimum: Int) -> [EmptyFolderCluster] {
        var out: [EmptyFolderCluster] = []
        _ = locked {
            try db.each("SELECT parent,count(*) FROM dirs WHERE parent!=0 AND items=0 AND own_items=0 AND flags&?=0 GROUP BY parent HAVING count(*)>=?",
                        args: [.int(Self.settledMask), .int(Int64(max(1, minimum)))]) {
                out.append(EmptyFolderCluster(parent: IndexDatabase.int($0, 0), count: Int(IndexDatabase.int($0, 1))))
            }
        }
        return out
    }

    public func emptyChildren(of id: Int64) -> [String] {
        var out: [String] = []
        _ = locked {
            try db.each("SELECT name FROM dirs WHERE parent=? AND items=0 AND own_items=0 AND flags&?=0", args: [.int(id), .int(Self.settledMask)]) {
                if let name = IndexDatabase.text($0, 0) { out.append(name) }
            }
        }
        return out
    }

    public func folders(named names: [String], minimumBytes: Int64) -> [IndexedFolder] {
        guard !names.isEmpty else { return [] }
        var out: [IndexedFolder] = []
        let marks = names.map { _ in "?" }.joined(separator: ",")
        _ = locked {
            try db.each("SELECT \(Self.columns) FROM dirs WHERE name IN (\(marks)) AND parent!=0 AND alloc+multi_alloc>=?",
                        args: names.map { .text($0) } + [.int(minimumBytes)]) { out.append(Self.folder($0)) }
        }
        return out
    }

    public static func files(in url: URL, limit: Int = 400) -> [IndexedFile] {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var found: [IndexedFile] = []
        try? BulkDirectory().read(fd: fd) { entry in
            guard entry.type == UInt32(VREG.rawValue), let size = entry.allocated, size > 0 else { return }
            found.append(IndexedFile(name: entry.name, allocatedBytes: size))
        }
        found.sort { $0.allocatedBytes != $1.allocatedBytes ? $0.allocatedBytes > $1.allocatedBytes : $0.name < $1.name }
        return Array(found.prefix(max(0, limit)))
    }
}
