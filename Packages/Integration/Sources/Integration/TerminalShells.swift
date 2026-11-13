import Foundation

public struct TerminalShellProfile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum TerminalShells {
    public static let shellPathKey = "visorTerminalShell"

    public static let knownNames = ["zsh", "bash", "fish", "nu", "elvish", "xonsh", "pwsh", "tcsh", "ksh", "dash", "sh", "csh"]

    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin", "~/.nix-profile/bin", "~/.cargo/bin", "~/.local/bin"]

    public static func loginShellPath() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: s) { return s }
        return "/bin/zsh"
    }

    public static func displayName(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        if dir == "/bin" || dir == "/usr/bin" { return name }
        return "\(name) (\((dir as NSString).abbreviatingWithTildeInPath))"
    }

    public static func detect(
        etcShells: String? = try? String(contentsOfFile: "/etc/shells", encoding: .utf8),
        directories: [String] = searchDirectories,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [TerminalShellProfile] {
        var paths: [String] = []
        for line in (etcShells ?? "").split(whereSeparator: \.isNewline) {
            let p = line.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("/") { paths.append(p) }
        }
        for dir in directories {
            let base = (dir as NSString).expandingTildeInPath
            for name in knownNames { paths.append("\(base)/\(name)") }
        }
        var seen = Set<String>()
        var out: [TerminalShellProfile] = []
        for p in paths where isExecutable(p) && seen.insert(p).inserted {
            out.append(TerminalShellProfile(name: displayName(path: p), path: p))
        }
        return out.sorted { a, b in
            let ra = knownNames.firstIndex(of: (a.path as NSString).lastPathComponent) ?? knownNames.count
            let rb = knownNames.firstIndex(of: (b.path as NSString).lastPathComponent) ?? knownNames.count
            return ra == rb ? a.path < b.path : ra < rb
        }
    }

    public static func configuredPath(in store: UserDefaults = .standard) -> String {
        if let p = store.string(forKey: shellPathKey), !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { return p }
        return loginShellPath()
    }
}
