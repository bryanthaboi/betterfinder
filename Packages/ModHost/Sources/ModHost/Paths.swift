import Foundation

public struct ModHostPaths: Sendable, Equatable {
    public var root: URL
    public var mods: URL
    public var data: URL
    public var development: URL
    public var staging: URL
    public var caches: URL

    public init(root: URL, caches: URL? = nil) {
        self.root = root
        self.mods = root.appendingPathComponent("Mods", isDirectory: true)
        self.data = root.appendingPathComponent("ModData", isDirectory: true)
        self.development = root.appendingPathComponent("ModDev", isDirectory: true)
        self.staging = mods.appendingPathComponent(".staging", isDirectory: true)
        self.caches = caches ?? root.appendingPathComponent("ModCaches", isDirectory: true)
    }

    public static var standard: ModHostPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("betterfinder", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("betterfinder/Mods", isDirectory: true)
        return ModHostPaths(root: support, caches: caches)
    }

    public func modDirectory(_ id: String) -> URL { mods.appendingPathComponent(id, isDirectory: true) }
    public func snapshot(_ id: String, folder: String) -> URL { modDirectory(id).appendingPathComponent(folder, isDirectory: true) }
    public func compiledCache(_ id: String) -> URL { modDirectory(id).appendingPathComponent(".compiled", isDirectory: true) }
    public func stateFile(_ id: String) -> URL { modDirectory(id).appendingPathComponent("state.json") }
    public func dataDirectory(_ id: String) -> URL { data.appendingPathComponent(id, isDirectory: true) }
    public var healthFile: URL { mods.appendingPathComponent("health.json") }

    func ensure() throws {
        let fm = FileManager.default
        for dir in [root, mods, data, development, staging, caches] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

enum ModFiles {
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        chmod(url.path, 0o600)
    }

    static func makeImmutable(_ dir: URL) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var dirs = [dir]
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(url) } else { chmod(url.path, 0o444) }
        }
        for d in dirs.reversed() { chmod(d.path, 0o555) }
    }

    static func makeMutable(_ dir: URL) {
        let fm = FileManager.default
        chmod(dir.path, 0o755)
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { chmod(url.path, 0o755) } else { chmod(url.path, 0o644) }
        }
    }

    static func removeTree(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        makeMutable(url)
        try? FileManager.default.removeItem(at: url)
    }
}
