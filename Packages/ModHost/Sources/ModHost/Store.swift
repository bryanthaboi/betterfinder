import Foundation
import ModKit
import ModValidation

public struct ModInstalledVersion: Codable, Equatable, Sendable {
    public var version: String
    public var folder: String
    public var treeHash: String
    public var installedAt: Date
    public var receipt: PreflightReceipt
}

public struct ModState: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var developer: Bool
    public var priority: Int
    public var active: ModInstalledVersion
    public var previous: ModInstalledVersion?
    public var lastError: String?
    public var suspendedReason: String?

    public init(id: String, enabled: Bool = false, developer: Bool = false, priority: Int = 0, active: ModInstalledVersion, previous: ModInstalledVersion? = nil) {
        self.id = id
        self.enabled = enabled
        self.developer = developer
        self.priority = priority
        self.active = active
        self.previous = previous
    }
}

public struct ModCompiledScript: Codable, Equatable, Sendable {
    public var treeHash: String
    public var toolchain: String
    public var kind: String
    public var source: String

    public init(treeHash: String, toolchain: String, kind: String, source: String) {
        self.treeHash = treeHash; self.toolchain = toolchain; self.kind = kind; self.source = source
    }
}

public enum ModStoreError: LocalizedError, Equatable {
    case notInstalled(String)
    case invalidPackage(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let id): return "\(id) is not installed"
        case .invalidPackage(let m): return m
        case .io(let m): return m
        }
    }
}

public final class ModStore: @unchecked Sendable {
    public let paths: ModHostPaths
    private let lock = NSLock()

    public init(paths: ModHostPaths) throws {
        self.paths = paths
        try paths.ensure()
    }

    public func allStates() -> [ModState] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: paths.mods.path) else { return [] }
        return ids.filter { !$0.hasPrefix(".") }.sorted().compactMap { readLocked($0) }
    }

    public func state(_ id: String) -> ModState? {
        lock.lock(); defer { lock.unlock() }
        return readLocked(id)
    }

    private func readLocked(_ id: String) -> ModState? {
        guard let data = try? Data(contentsOf: paths.stateFile(id)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ModState.self, from: data)
    }

    public func save(_ state: ModState) throws {
        lock.lock(); defer { lock.unlock() }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try ModFiles.writePrivate(try e.encode(state), to: paths.stateFile(state.id))
    }

    public func update(_ id: String, _ body: (inout ModState) -> Void) throws -> ModState {
        guard var s = state(id) else { throw ModStoreError.notInstalled(id) }
        body(&s)
        try save(s)
        return s
    }

    public func snapshotURL(_ id: String, _ version: ModInstalledVersion) -> URL {
        paths.snapshot(id, folder: version.folder)
    }

    public func loadPackage(_ id: String, _ version: ModInstalledVersion) -> ModPackage {
        ModPackage.load(directory: snapshotURL(id, version))
    }

    func installSnapshot(id: String, version: String, package: ModPackage, stagedDirectory: URL) throws -> (folder: String, url: URL) {
        let fm = FileManager.default
        let dir = paths.modDirectory(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hash = package.treeHash
        var folder = version
        var target = dir.appendingPathComponent(folder, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            if ModPackage.load(directory: target).treeHash == hash { return (folder, target) }
            folder = "\(version)+\(hash.prefix(12))"
            target = dir.appendingPathComponent(folder, isDirectory: true)
            if fm.fileExists(atPath: target.path) { return (folder, target) }
        }
        let tmp = dir.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (path, data) in package.files {
            let dest = tmp.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: dest.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                ModFiles.removeTree(tmp)
                throw ModStoreError.io("cannot write \(path)")
            }
        }
        guard ModPackage.load(directory: tmp).treeHash == hash else {
            ModFiles.removeTree(tmp)
            throw ModStoreError.io("snapshot verification failed for \(id)")
        }
        ModFiles.makeImmutable(tmp)
        chmod(tmp.path, 0o755)
        try fm.moveItem(at: tmp, to: target)
        chmod(target.path, 0o555)
        return (folder, target)
    }

    public func removeVersion(_ id: String, folder: String) {
        ModFiles.removeTree(paths.snapshot(id, folder: folder))
    }

    public func removeAll(_ id: String, deleteData: Bool) {
        ModFiles.removeTree(paths.modDirectory(id))
        if deleteData { ModFiles.removeTree(paths.dataDirectory(id)) }
    }

    public func compiled(_ id: String, treeHash: String, toolchain: String) -> ModCompiledScript? {
        let url = paths.compiledCache(id).appendingPathComponent("\(treeHash).json")
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(ModCompiledScript.self, from: data),
              c.treeHash == treeHash, c.toolchain == toolchain else { return nil }
        return c
    }

    public func saveCompiled(_ id: String, _ script: ModCompiledScript) {
        let url = paths.compiledCache(id).appendingPathComponent("\(script.treeHash).json")
        try? ModFiles.writePrivate(script.modKitJSON(), to: url)
    }

    public func stage(_ source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        let dest = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw ModStoreError.invalidPackage("\(source.path) does not exist") }
        if isDir.boolValue {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let pkg = ModPackage.load(directory: source)
            if let bad = pkg.inventoryDiagnostics.first(where: { $0.code == .forbiddenFileType && $0.message.contains("symbolic link") }) {
                throw ModStoreError.invalidPackage(bad.message)
            }
            for (path, data) in pkg.files {
                let out = dest.appendingPathComponent(path)
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: out.path, contents: data, attributes: [.posixPermissions: 0o644])
            }
            return dest
        }
        let ext = source.pathExtension.lowercased()
        guard ext == "bfmod" || ext == "zip" else {
            throw ModStoreError.invalidPackage("unsupported package type .\(ext); use a folder, .zip or .bfmod")
        }
        let limits = ModCatalogLimits.v1
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limits.maxPackageBytes * 2 else { throw ModStoreError.invalidPackage("\(source.lastPathComponent) is too large") }
        guard let data = try? Data(contentsOf: source) else { throw ModStoreError.invalidPackage("cannot read \(source.lastPathComponent)") }
        let loaded = PackageLoader.loadArchive(data, name: source.lastPathComponent, limits: limits)
        if loaded.fatal || loaded.package.inventoryDiagnostics.hasErrors {
            let d = loaded.package.inventoryDiagnostics.first { $0.severity == .error }
            throw ModStoreError.invalidPackage("\(source.lastPathComponent) is not a valid mod archive" + (d.map { ": \($0.code.rawValue) \($0.message)" } ?? ""))
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for (path, data) in loaded.package.files {
            let out = dest.appendingPathComponent(path)
            guard out.standardizedFileURL.path.hasPrefix(dest.standardizedFileURL.path + "/") else {
                ModFiles.removeTree(dest)
                throw ModStoreError.invalidPackage("archive entry \(path) escapes the package")
            }
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: out.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                ModFiles.removeTree(dest)
                throw ModStoreError.invalidPackage("cannot stage \(path)")
            }
        }
        let entries = (try? fm.contentsOfDirectory(atPath: dest.path))?.filter { !$0.hasPrefix(".") } ?? []
        if !fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path), entries.count == 1 {
            let inner = dest.appendingPathComponent(entries[0], isDirectory: true)
            var d: ObjCBool = false
            if fm.fileExists(atPath: inner.path, isDirectory: &d), d.boolValue { return inner }
        }
        return dest
    }

    public func discardStaging(_ url: URL) {
        var target = url
        while target.deletingLastPathComponent().standardizedFileURL != paths.staging.standardizedFileURL, target.pathComponents.count > paths.staging.pathComponents.count {
            target = target.deletingLastPathComponent()
        }
        if target.path.hasPrefix(paths.staging.path) { ModFiles.removeTree(target) }
    }
}

public struct ModHealth: Codable, Equatable, Sendable {
    public var failures: [Date] = []
    public var safeMode = false
    public var lastCleanShutdown: Date?

    public init() {}
}

final class ModHealthStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func read() -> ModHealth {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return ModHealth() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(ModHealth.self, from: data)) ?? ModHealth()
    }

    func write(_ h: ModHealth) {
        lock.lock(); defer { lock.unlock() }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(h) { try? ModFiles.writePrivate(data, to: url) }
    }

    func update(_ body: (inout ModHealth) -> Void) -> ModHealth {
        var h = read()
        body(&h)
        write(h)
        return h
    }
}
