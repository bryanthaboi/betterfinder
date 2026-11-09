import Foundation
import FSCore

public enum BrowserLocation: Hashable, Sendable {
    case folder(URL)
    case computer
    case search(scope: URL, query: String)
    case recents
    case tag(String)

    public var url: URL? {
        if case .folder(let u) = self { return u }
        return nil
    }

    public var isVirtual: Bool {
        switch self {
        case .search, .recents, .tag: return true
        case .folder, .computer: return false
        }
    }

    public var scopeURL: URL? {
        switch self {
        case .folder(let u): return u
        case .search(let scope, _): return scope
        case .recents, .tag: return FileManager.default.homeDirectoryForCurrentUser
        case .computer: return nil
        }
    }

    public var searchQuery: String? {
        if case .search(_, let q) = self { return q }
        return nil
    }

    public var normalized: BrowserLocation {
        switch self {
        case .folder(let u): return .folder(URL(fileURLWithPath: DemoEnvironment.browseURL(u).standardizedFileURL.path, isDirectory: true))
        case .search(let scope, let q): return .search(scope: URL(fileURLWithPath: DemoEnvironment.searchURL(scope).standardizedFileURL.path, isDirectory: true), query: q)
        default: return self
        }
    }

    public func isSame(as other: BrowserLocation) -> Bool {
        normalized == other.normalized
    }

    public var displayName: String {
        switch self {
        case .computer: return DemoEnvironment.computerName
        case .folder(let u):
            if u.path == "/" { return (try? u.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/" }
            return FileManager.default.displayName(atPath: u.path)
        case .search(let scope, let q):
            let scopeName = scope.path == "/" ? "This Mac" : FileManager.default.displayName(atPath: scope.path)
            return "Searching “\(q)” in \(scopeName)"
        case .recents: return "Recents"
        case .tag(let t): return t
        }
    }

    public func parent(selected: URL?) -> (location: BrowserLocation, select: URL?)? {
        switch self {
        case .computer:
            return nil
        case .folder(let u):
            let std = u.standardizedFileURL
            if std.path == "/" { return (.computer, std) }
            if VolumeInfo.isVolumeRoot(std) { return (.computer, std) }
            return (.folder(std.deletingLastPathComponent()), std)
        case .search(let scope, _):
            if let s = selected?.standardizedFileURL { return (.folder(s.deletingLastPathComponent()), s) }
            return (.folder(scope.standardizedFileURL), nil)
        case .recents, .tag:
            if let s = selected?.standardizedFileURL { return (.folder(s.deletingLastPathComponent()), s) }
            return (.folder(FileManager.default.homeDirectoryForCurrentUser), nil)
        }
    }
}

extension URL {
    var pathKey: String {
        let raw = path
        if raw.isEmpty { return "/" }
        if URL.isCleanPath(raw) { return raw }
        let p = standardizedFileURL.path
        return p.isEmpty ? "/" : p
    }

    static func isCleanPath(_ p: String) -> Bool {
        var prev: UInt8 = 0
        var prev2: UInt8 = 0
        var first = true
        for b in p.utf8 {
            if first { if b != 0x2F { return false }; first = false }
            if b == 0x2F {
                if prev == 0x2F { return false }
                if prev == 0x2E && (prev2 == 0x2F || (prev2 == 0x2E)) { return false }
            }
            prev2 = prev
            prev = b
        }
        if prev == 0x2E && (prev2 == 0x2F || prev2 == 0x2E) { return false }
        return true
    }

    func isAncestor(of other: URL) -> Bool {
        let a = pathKey, b = other.pathKey
        if a == b { return false }
        return a == "/" ? b.hasPrefix("/") : b.hasPrefix(a + "/")
    }

    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
