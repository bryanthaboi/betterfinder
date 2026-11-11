import Foundation
import Darwin

struct IndexWork {
    var id: Int64
    var path: String
    var inode: Int64?
}

struct IndexListing {
    enum Status { case ok, gone, unreadable, cancelled }

    struct Child {
        var name: String
        var inode: Int64
        var hidden: Bool
    }

    struct Shared {
        var alloc: Int64
        var logical: Int64
        var count: Int64
    }

    var status = Status.ok
    var device: Int32 = 0
    var partial = false
    var children: [Child] = []
    var names: [String] = []
    var items: Int64 = 0
    var alloc: Int64 = 0
    var logical: Int64 = 0
    var shared: [Int64: Shared] = [:]
    var signature: Int64 = 0
}

enum IndexScanner {
    static func open(_ path: String) -> Int32 {
        let direct = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if direct >= 0 { return direct }
        let failure = errno
        guard failure == EINVAL || failure == ENAMETOOLONG else { errno = failure; return -1 }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let reason = errno
            close(fd)
            guard next >= 0 else { errno = reason; return -1 }
            fd = next
        }
        return fd
    }

    static func withoutMaterializing<T>(_ body: () -> T) -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous < 0 ? IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT : previous) }
        return body()
    }

    static func split(_ path: String) -> (parent: String, name: String)? {
        guard path.count > 1, let slash = path.lastIndex(of: "/") else { return nil }
        let parent = slash == path.startIndex ? "/" : String(path[path.startIndex..<slash])
        return (parent, String(path[path.index(after: slash)...]))
    }

    static func read(_ work: IndexWork, bulk: BulkDirectory, skipping excluded: Set<String>, parents: [String: Int32] = [:]) -> IndexListing {
        var listing = IndexListing()
        var fd: Int32 = -1
        if !parents.isEmpty, let parts = split(work.path), let anchor = parents[parts.parent] {
            fd = openat(anchor, parts.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            fd = open(work.path)
        }
        guard fd >= 0 else {
            listing.status = errno == ENOENT || errno == ENOTDIR || errno == ELOOP ? .gone : .unreadable
            return listing
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { listing.status = .unreadable; return listing }
        if let expected = work.inode, Int64(bitPattern: UInt64(st.st_ino)) != expected { listing.status = .gone; return listing }
        listing.device = st.st_dev
        let device = st.st_dev
        var signature: UInt64 = 0
        let prefix = work.path == "/" ? "/" : work.path + "/"
        do {
            try bulk.read(fd: fd) { entry in
                guard let id = entry.inode, let type = entry.type, let entryDevice = entry.device else { listing.partial = true; return }
                if entryDevice != device || (entry.realDevice.map { $0 != UInt32(bitPattern: device) } ?? false) || (entry.mount ?? 0) != 0 || (entry.flags ?? 0) & UInt32(SF_FIRMLINK) != 0 { return }
                if !excluded.isEmpty, excluded.contains(prefix + entry.name) { return }
                let inode = Int64(bitPattern: id)
                if type == 2 {
                    let hidden = entry.name.hasPrefix(".") || (entry.flags ?? 0) & UInt32(UF_HIDDEN) != 0
                    listing.children.append(.init(name: entry.name, inode: inode, hidden: hidden))
                    listing.items += 1
                    return
                }
                listing.names.append(entry.name)
                var hash: UInt64 = 0xcbf29ce484222325
                for byte in entry.name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                signature = signature &+ hash &+ 0x9e3779b97f4a7c15
                if type == 5 { return }
                listing.items += 1
                let alloc = entry.allocated ?? 0
                let logical = entry.logical ?? 0
                if type == 1, entry.allocated == nil || entry.logical == nil { listing.partial = true }
                if (entry.links ?? 1) > 1 {
                    listing.shared[inode, default: .init(alloc: alloc, logical: logical, count: 0)].count += 1
                } else {
                    listing.alloc += alloc
                    listing.logical += logical
                }
            }
        } catch is CancellationError {
            listing.status = .cancelled
        } catch {
            listing.status = .unreadable
        }
        listing.signature = Int64(bitPattern: signature)
        return listing
    }

    static func readAll(_ work: [IndexWork], width: Int, pool: [BulkDirectory], skipping excluded: Set<String>) -> [IndexListing] {
        var siblings: [String: Int] = [:]
        if work.count > 1 {
            for item in work { if let parts = split(item.path) { siblings[parts.parent, default: 0] += 1 } }
        }
        var parents: [String: Int32] = [:]
        for (path, count) in siblings where count > 1 {
            let fd = open(path)
            if fd >= 0 { parents[path] = fd }
        }
        defer { for fd in parents.values { close(fd) } }
        guard work.count > 1, width > 1, pool.count > 1 else {
            return withoutMaterializing { work.map { read($0, bulk: pool[0], skipping: excluded, parents: parents) } }
        }
        var results = [IndexListing](repeating: IndexListing(), count: work.count)
        let lock = NSLock()
        var cursor = 0
        results.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeMutablePointer<IndexListing>(buffer.baseAddress!)
            let sendable = UnsafeSendable(out)
            DispatchQueue.concurrentPerform(iterations: min(width, pool.count, work.count)) { worker in
                let bulk = pool[worker]
                withoutMaterializing {
                    while true {
                        lock.lock()
                        let index = cursor
                        cursor += 1
                        lock.unlock()
                        guard index < work.count else { return }
                        sendable.value[index] = read(work[index], bulk: bulk, skipping: excluded, parents: parents)
                    }
                }
            }
        }
        return results
    }
}

struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
