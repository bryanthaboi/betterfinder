import AppKit
import Foundation

enum PathFormat: String, CaseIterable, Sendable {
    case posix, url, windows, unc, hfs, terminal

    struct Volume: Equatable, Sendable {
        var root: String
        var name: String
        var remote: URL?
    }

    var title: String {
        switch self {
        case .posix: return "POSIX Path"
        case .url: return "URL"
        case .windows: return "Windows Path"
        case .unc: return "UNC Path"
        case .hfs: return "HFS Path"
        case .terminal: return "Terminal Path"
        }
    }

    var commandID: String { "file.copyPath.\(rawValue)" }

    var separator: String { self == .terminal ? " " : "\n" }

    static func volume(of url: URL) -> Volume {
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeURLForRemountingKey])
        let root = values?.volume?.path ?? "/"
        let remote = values?.volumeURLForRemounting.flatMap { $0.isFileURL ? nil : $0 }
        return Volume(root: root, name: values?.volumeName ?? FileManager.default.displayName(atPath: root), remote: remote)
    }

    static func components(of path: String, under root: String) -> [String] {
        let all = (path as NSString).pathComponents.filter { $0 != "/" }
        let base = (root as NSString).pathComponents.filter { $0 != "/" }
        guard all.count >= base.count, Array(all.prefix(base.count)) == base else { return all }
        return Array(all.dropFirst(base.count))
    }

    static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        var out = ""
        for scalar in path.unicodeScalars {
            if !safe.contains(scalar) && scalar.isASCII { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private static func remoteParts(_ remote: URL) -> (host: String, share: [String])? {
        guard let host = remote.host(percentEncoded: false), !host.isEmpty else { return nil }
        return (host, remote.pathComponents.filter { $0 != "/" })
    }

    func string(path: String, isDirectory: Bool, volume: Volume) -> String? {
        let relative = Self.components(of: path, under: volume.root)
        switch self {
        case .posix:
            return path
        case .url:
            if let remote = volume.remote, let parts = Self.remoteParts(remote), var c = URLComponents(url: remote, resolvingAgainstBaseURL: false) {
                c.user = nil
                c.password = nil
                c.path = "/" + (parts.share + relative).joined(separator: "/") + (isDirectory && !relative.isEmpty ? "/" : "")
                return c.url?.absoluteString
            }
            return URL(fileURLWithPath: path, isDirectory: isDirectory).absoluteString
        case .windows:
            if let unc = PathFormat.unc.string(path: path, isDirectory: isDirectory, volume: volume) { return unc }
            return "\\" + (path as NSString).pathComponents.filter { $0 != "/" }.joined(separator: "\\")
        case .unc:
            guard let remote = volume.remote, let parts = Self.remoteParts(remote) else { return nil }
            return "\\\\" + ([parts.host] + parts.share + relative).joined(separator: "\\")
        case .hfs:
            let names = ([volume.name] + relative).map { $0.replacingOccurrences(of: ":", with: "/") }
            return names.joined(separator: ":") + (isDirectory ? ":" : "")
        case .terminal:
            return Self.shellEscaped(path)
        }
    }

    func string(for url: URL) -> String? {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        return string(path: url.path, isDirectory: isDirectory, volume: Self.volume(of: url))
    }

    func string(for urls: [URL]) -> String? {
        let parts = urls.compactMap { string(for: $0) }
        guard !parts.isEmpty, parts.count == urls.count else { return nil }
        return parts.joined(separator: separator)
    }
}

@MainActor
public enum CopyPathMenu {
    public static func submenuItem(target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "Copy Path As", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Copy Path As")
        for format in PathFormat.allCases {
            let entry = NSMenuItem(title: format.title, action: #selector(BrowserPaneController.copyPathAs(_:)), keyEquivalent: "")
            entry.representedObject = format.rawValue
            entry.target = target
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }
}
