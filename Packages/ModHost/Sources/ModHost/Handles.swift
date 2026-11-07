import Darwin
import Foundation
import Integration
import ModHostProtocol
import ModKit
import Security

enum ModHandleScope: Equatable, Sendable {
    case selection(token: UUID, recursive: Bool, base: String)
    case root(rootId: String, path: String)
    case destination(token: UUID, base: String)
    case reference
}

struct ModHandleEntry: Sendable {
    var path: String
    var scope: ModHandleScope
    var device: UInt64
    var inode: UInt64
    var generation: Int
    var created: Date
}

struct ModFileIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
    var isDirectory: Bool
    var isSymlink: Bool
    var size: Int64
    var modified: Date

    static func lstat(_ path: String) -> ModFileIdentity? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return ModFileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), isDirectory: mode == S_IFDIR, isSymlink: mode == S_IFLNK, size: Int64(st.st_size), modified: mtime)
    }

    var kind: String { isSymlink ? "symlink" : isDirectory ? "folder" : "file" }
}

final class ModHandleTable: @unchecked Sendable {
    static let maxEntries = 50_000
    static let lifetime: TimeInterval = 600

    private let lock = NSLock()
    private var entries: [String: ModHandleEntry] = [:]
    private var order: [String] = []
    private let modId: String

    init(modId: String) { self.modId = modId }

    func mint(path: String, scope: ModHandleScope, generation: Int) -> String? {
        guard let id = ModFileIdentity.lstat(path) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let handle = "h_" + bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        entries[handle] = ModHandleEntry(path: path, scope: scope, device: id.device, inode: id.inode, generation: generation, created: Date())
        order.append(handle)
        if order.count > Self.maxEntries {
            let drop = order.prefix(order.count - Self.maxEntries)
            for h in drop { entries.removeValue(forKey: h) }
            order.removeFirst(drop.count)
        }
        lock.unlock()
        return handle
    }

    func lookup(_ handle: String, generation: Int) -> ModHandleEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[handle], e.generation == generation, Date().timeIntervalSince(e.created) < Self.lifetime else { return nil }
        return e
    }

    func revokeAll() {
        lock.lock(); entries.removeAll(); order.removeAll(); lock.unlock()
    }
}

enum ModPathRules {
    static func realpath(_ path: String) -> String? {
        guard let r = Darwin.realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
            && !name.unicodeScalars.contains { $0.value < 0x20 }
    }
}

public enum ModAccessNeed: Sendable { case read, write, list, walk }

struct ModResolvedItem {
    var path: String
    var real: String
    var identity: ModFileIdentity
    var entry: ModHandleEntry
}
