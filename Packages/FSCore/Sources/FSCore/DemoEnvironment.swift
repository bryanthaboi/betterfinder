import Foundation

public enum DemoEnvironment {
    public static var isEnabled: Bool { ProcessInfo.processInfo.environment["BETTERFINDER_DEMO"] == "1" }

    public static var home: URL {
        if isEnabled {
            guard let path = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], path.hasPrefix("/"), path != "/" else {
                preconditionFailure("Demo mode requires an absolute CFFIXED_USER_HOME")
            }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var computerName: String {
        isEnabled ? ProcessInfo.processInfo.environment["BETTERFINDER_DEMO_COMPUTER"] ?? "Studio Mac" : Host.current().localizedName ?? "Computer"
    }

    public static var userName: String {
        isEnabled ? ProcessInfo.processInfo.environment["BETTERFINDER_DEMO_USER"] ?? "alex" : NSUserName()
    }

    public static var volumes: [URL] {
        if isEnabled {
            return (ProcessInfo.processInfo.environment["BETTERFINDER_DEMO_VOLUMES"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") && $0 != "/" }.map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL }.filter { $0.resolvingSymlinksInPath().path != "/" }
        }
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    }

    public static func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    public static func browseURL(_ url: URL) -> URL {
        guard isEnabled else { return url }
        return volumes.contains { contains(url, in: $0) } ? url : home
    }

    public static func searchURL(_ url: URL) -> URL {
        guard isEnabled else { return url }
        return contains(url, in: home) ? url : home
    }
}
