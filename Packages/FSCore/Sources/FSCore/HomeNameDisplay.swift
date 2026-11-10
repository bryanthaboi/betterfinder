import Foundation

public enum HomeNameStyle: String, CaseIterable, Identifiable, Sendable {
    case real
    case tilde
    case custom
    case redacted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .real: return "Real name"
        case .tilde: return "~"
        case .custom: return "Custom"
        case .redacted: return "Redacted"
        }
    }
}

public struct HomeNameDisplay: Hashable, Sendable {
    public static let styleKey = "homeFolderNameStyle"
    public static let customKey = "homeFolderNameCustom"
    public static let redactedPlaceholder = "████████"
    public static let redactedAccessibilityName = "Home"

    public var style: HomeNameStyle
    public var custom: String
    public var homePath: String

    public init(style: HomeNameStyle = .real, custom: String = "", home: URL) {
        self.init(style: style, custom: custom, homePath: home.path)
    }

    public init(style: HomeNameStyle = .real, custom: String = "", homePath: String) {
        self.style = style
        self.custom = custom
        self.homePath = Self.clean(homePath)
    }

    private static let processHomePath = DemoEnvironment.home.standardizedFileURL.path

    public static func current(defaults: UserDefaults = .standard) -> HomeNameDisplay {
        HomeNameDisplay(
            style: HomeNameStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .real,
            custom: defaults.string(forKey: customKey) ?? "",
            homePath: processHomePath
        )
    }

    static func clean(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public var realName: String { (homePath as NSString).lastPathComponent }

    public var isActive: Bool { style != .real && homePath != "/" && !homePath.isEmpty }

    public var isRedacted: Bool { style == .redacted && isActive }

    public var replacementName: String? {
        guard isActive else { return nil }
        switch style {
        case .real: return nil
        case .tilde: return "~"
        case .redacted: return Self.redactedPlaceholder
        case .custom:
            let cleaned = custom.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "~" : cleaned
        }
    }

    public func isHome(_ path: String) -> Bool {
        Self.clean(path) == homePath
    }

    public func isHome(_ url: URL) -> Bool { isHome(url.path) }

    public func contains(_ path: String) -> Bool {
        let p = Self.clean(path)
        return p == homePath || p.hasPrefix(homePath + "/")
    }

    public func contains(_ url: URL) -> Bool { contains(url.path) }

    public func name(_ name: String, forPath path: String) -> String {
        guard let replacement = replacementName, isHome(path) else { return name }
        return replacement
    }

    public func name(_ name: String, for url: URL) -> String { self.name(name, forPath: url.path) }

    public func accessibilityName(_ name: String, forPath path: String) -> String {
        guard isActive, isHome(path) else { return name }
        return isRedacted ? Self.redactedAccessibilityName : self.name(name, forPath: path)
    }

    public func path(_ path: String) -> String {
        guard let replacement = replacementName else { return path }
        let p = Self.clean(path)
        guard contains(p) else { return path }
        let rest = String(p.dropFirst(homePath.count))
        if replacement == "~" { return "~" + rest }
        let parent = (homePath as NSString).deletingLastPathComponent
        return (parent == "/" ? "/" : parent + "/") + replacement + rest
    }

    public func path(_ url: URL) -> String { path(url.path) }
}
