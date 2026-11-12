import Darwin
import Foundation

public struct JunkItem: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        case trash
        case removeEmptyFolders(Int)
        case emptyTrash
    }

    public let id: String
    public let url: URL
    public let title: String
    public let detail: String
    public let bytes: Int64
    public let action: Action

    public init(url: URL, title: String, detail: String, bytes: Int64, action: Action = .trash) {
        self.id = "\(action)|\(url.path)"
        self.url = url
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.action = action
    }

    public var emptyFolderCount: Int {
        if case .removeEmptyFolders(let count) = action { return count }
        return 0
    }
}

public struct JunkGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let explanation: String
    public var items: [JunkItem]

    public init(id: String, title: String, explanation: String, items: [JunkItem]) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.items = items
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

public struct JunkScanner: Sendable {
    public static let rebuildableNames = ["node_modules", "DerivedData", ".build", "__pycache__", ".dart_tool", ".next", ".turbo", ".parcel-cache", "Pods", ".pytest_cache", "target"]
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let perChild = [
        ("caches", "Library/Caches"),
        ("logs", "Library/Logs"),
        ("developer", "Library/Developer/Xcode/DerivedData"),
        ("developer", "Library/Developer/Xcode/iOS DeviceSupport"),
        ("developer", "Library/Developer/Xcode/watchOS DeviceSupport"),
        ("developer", "Library/Developer/Xcode/tvOS DeviceSupport"),
        ("packages", ".cache"),
    ]
    static let whole = [
        ("developer", "Library/Developer/CoreSimulator/Caches", "Simulator caches"),
        ("packages", ".npm/_cacache", "npm cache"),
        ("packages", ".gradle/caches", "Gradle caches"),
        ("packages", ".pub-cache/hosted", "Dart and Flutter packages"),
        ("packages", ".nuget/packages", "NuGet packages"),
        ("packages", ".cargo/registry", "Cargo registry"),
        ("packages", ".m2/repository", "Maven repository"),
        ("packages", ".android/cache", "Android SDK cache"),
        ("packages", "Library/pnpm/store", "pnpm store"),
    ]
    static let groups: [(id: String, title: String, explanation: String)] = [
        ("leftovers", "Leftover empty folders", "Folders that hold hundreds of empty folders and nothing else in them. Only folders that are still empty get removed."),
        ("trash", "Trash", "Everything already in the Trash."),
        ("caches", "App caches", "Apps rebuild these when they need them."),
        ("developer", "Developer leftovers", "Xcode build products, device support files and simulator caches. Xcode recreates them."),
        ("packages", "Package manager caches", "Downloaded packages that get fetched again on the next install."),
        ("projects", "Rebuildable project folders", "Dependencies and build output inside your projects. A fresh install or build brings them back."),
        ("logs", "Logs", "Old log files."),
        ("installers", "Installers in Downloads", "Disk images and installer packages you have probably already used."),
    ]

    public var home: URL
    public var minimumBytes: Int64 = 20 * 1024 * 1024
    public var emptyClusterMinimum = 300

    public init(home: URL = DemoEnvironment.home) {
        self.home = SizeIndexLocation.canonical(home)
    }

    public func scan(_ tree: SizeIndexTree) -> [JunkGroup] {
        var found: [String: [JunkItem]] = [:]
        let homePath = home.path
        let prefix = homePath == "/" ? "/" : homePath + "/"

        for cluster in tree.emptyFolderClusters(minimum: emptyClusterMinimum) {
            guard let path = tree.path(of: cluster.parent), path == homePath || path.hasPrefix(prefix) else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            found["leftovers", default: []].append(JunkItem(url: url, title: url.lastPathComponent, detail: "\(cluster.count.formatted()) empty folders in \(Self.abbreviated(path, home: homePath))",
                                                            bytes: 0, action: .removeEmptyFolders(cluster.count)))
        }

        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        if let node = tree.folder(at: trash), node.items > 0 {
            found["trash", default: []].append(JunkItem(url: trash, title: "Trash", detail: "\(node.items.formatted()) items", bytes: node.allocatedBytes, action: .emptyTrash))
        }

        for (group, relative) in Self.perChild {
            let base = home.appendingPathComponent(relative, isDirectory: true)
            guard let node = tree.folder(at: base) else { continue }
            for child in tree.children(of: node.id) where child.allocatedBytes >= minimumBytes {
                let url = base.appendingPathComponent(child.name, isDirectory: true)
                found[group, default: []].append(JunkItem(url: url, title: child.name, detail: Self.abbreviated(url.path, home: homePath), bytes: child.allocatedBytes))
            }
        }

        for (group, relative, title) in Self.whole {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            guard let node = tree.folder(at: url), node.allocatedBytes >= minimumBytes else { continue }
            found[group, default: []].append(JunkItem(url: url, title: title, detail: Self.abbreviated(url.path, home: homePath), bytes: node.allocatedBytes))
        }

        let names = Set(Self.rebuildableNames)
        var projects: [(path: String, item: JunkItem)] = []
        for node in tree.folders(named: Self.rebuildableNames, minimumBytes: minimumBytes) {
            guard let path = tree.path(of: node.id), path.hasPrefix(prefix) else { continue }
            let parts = path.dropFirst(prefix.count).split(separator: "/")
            guard parts.count >= 2, let first = parts.first, !first.hasPrefix("."), first != "Library" else { continue }
            guard !parts.dropLast().contains(where: { names.contains(String($0)) || $0.hasSuffix(".app") || $0.hasSuffix(".framework") }) else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let project = url.deletingLastPathComponent()
            if node.name == "target", !FileManager.default.fileExists(atPath: project.appendingPathComponent("Cargo.toml").path) { continue }
            projects.append((path, JunkItem(url: url, title: "\(node.name) in \(project.lastPathComponent)", detail: Self.abbreviated(path, home: homePath), bytes: node.allocatedBytes)))
        }
        found["projects"] = projects.map(\.item)

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        for file in SizeIndexTree.files(in: downloads, limit: 2000) where file.allocatedBytes >= minimumBytes {
            let url = downloads.appendingPathComponent(file.name)
            guard Self.installerExtensions.contains(url.pathExtension.lowercased()) else { continue }
            found["installers", default: []].append(JunkItem(url: url, title: file.name, detail: Self.abbreviated(url.path, home: homePath), bytes: file.allocatedBytes))
        }

        return Self.groups.compactMap { group in
            guard let items = found[group.id], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                if $0.emptyFolderCount != $1.emptyFolderCount { return $0.emptyFolderCount > $1.emptyFolderCount }
                return $0.url.path < $1.url.path
            }
            return JunkGroup(id: group.id, title: group.title, explanation: group.explanation, items: sorted)
        }
    }

    static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    @discardableResult
    public static func removeEmptyFolders(in parent: URL, tree: SizeIndexTree, isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) -> Int {
        guard let node = tree.folder(at: parent) else { return 0 }
        let base = SizeIndexLocation.canonical(parent).path
        var removed = 0
        for (index, name) in tree.emptyChildren(of: node.id).enumerated() {
            if isCancelled() { break }
            guard !name.contains("/"), name != ".", name != ".." else { continue }
            if rmdir(base + "/" + name) == 0 { removed += 1 }
            if index % 64 == 63 { progress(removed) }
        }
        progress(removed)
        return removed
    }
}
