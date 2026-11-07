import AppKit
import Foundation

public extension Notification.Name {
    static let themeDidChange = Notification.Name("BetterFinderThemeDidChange")
    static let themeContributionsDidChange = Notification.Name("BetterFinderThemeContributionsDidChange")
}

public enum ThemeError: LocalizedError {
    case notFound(String)
    case invalidPackage(URL)
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Theme \"\(id)\" was not found."
        case .invalidPackage(let url): return "\(url.lastPathComponent) does not contain a theme.json."
        case .archiveFailed(let msg): return "Could not process theme archive: \(msg)"
        }
    }
}

public enum ThemeIDError: LocalizedError, Equatable {
    case unsafe(String)
    case outsideThemesFolder(String)

    public var errorDescription: String? {
        switch self {
        case .unsafe(let id): return "\"\(id)\" isn't a valid theme id."
        case .outsideThemesFolder(let id): return "Theme \"\(id)\" points outside the themes folder."
        }
    }
}

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared: ThemeManager = {
        let manager = ThemeManager()
        manager.publishesIconSet = true
        manager.publishActiveIconSet()
        return manager
    }()

    @Published public private(set) var current: Theme {
        didSet { publishActiveIconSet() }
    }
    @Published public private(set) var available: [Theme] = []

    public let userThemesDirectory: URL
    public var appliesAppAppearance = true

    nonisolated public static let packageExtension = "bftheme"
    nonisolated public static let themeFileName = "theme.json"

    private static let selectedKey = "selectedThemeID"
    private let defaults: UserDefaults
    var publishesIconSet = false
    private(set) var contributed: [String: ContributedTheme] = [:]

    public convenience init(userThemesDirectory: URL? = nil) {
        self.init(userThemesDirectory: userThemesDirectory, defaults: .standard)
    }

    public init(userThemesDirectory: URL?, defaults: UserDefaults) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.userThemesDirectory = userThemesDirectory ?? support.appendingPathComponent("betterfinder/Themes", isDirectory: true)
        self.defaults = defaults
        self.current = ThemeManager.fallback
        reload()
        let selected = defaults.string(forKey: Self.selectedKey) ?? "modern"
        if let t = available.first(where: { $0.id == selected }) ?? available.first(where: { $0.id == "modern" }) {
            current = t
        }
        applyAppearance()
    }

    public func reload() {
        var byID: [String: Theme] = [:]
        for t in Self.builtIns { byID[t.id] = t }
        for (id, c) in contributed { byID[id] = c.theme }
        for t in loadUserThemes() { byID[t.id] = t }
        available = byID.values.sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    public func select(_ id: String) {
        guard let t = available.first(where: { $0.id == id }) else { return }
        current = t
        defaults.set(id, forKey: Self.selectedKey)
        applyAppearance()
        NotificationCenter.default.post(name: .themeDidChange, object: t)
    }

    public var density: Density? {
        get { defaults.string(forKey: Density.defaultsKey).flatMap(Density.init(rawValue:)) }
        set {
            guard newValue != density else { return }
            if let newValue { defaults.set(newValue.rawValue, forKey: Density.defaultsKey) } else { defaults.removeObject(forKey: Density.defaultsKey) }
            objectWillChange.send()
            NotificationCenter.default.post(name: .themeDidChange, object: current)
        }
    }

    public var effectiveDensity: Density { density ?? current.defaultDensity }

    public var layout: ThemeLayout { current.layout(density: density) }

    public func theme(withID id: String) -> Theme? {
        available.first { $0.id == id }
    }

    public func applyLive(_ theme: Theme) {
        if let i = available.firstIndex(where: { $0.id == theme.id }) { available[i] = theme }
        guard current != theme else { return }
        if current.id != theme.id { defaults.set(theme.id, forKey: Self.selectedKey) }
        current = theme
        applyAppearance()
        NotificationCenter.default.post(name: .themeDidChange, object: theme)
    }

    public func applyAppearance() {
        guard appliesAppAppearance, let app = NSApp else { return }
        app.appearance = current.appearance
    }

    public func isBuiltIn(_ id: String) -> Bool {
        Self.builtIns.contains { $0.id == id }
    }

    public func isContributed(_ id: String) -> Bool {
        contributed[id] != nil && !userThemeExists(id)
    }

    public func contributionOwner(of id: String) -> String? {
        isContributed(id) ? contributed[id]?.ownerID : nil
    }

    var restorableSelectionID: String? {
        defaults.string(forKey: Self.selectedKey)
    }

    func publishActiveIconSet() {
        guard publishesIconSet else { return }
        IconSetRegistry.shared.setActiveSetID(current.icons.set)
    }

    func userThemeExists(_ id: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: userThemeURL(id).path) || fm.fileExists(atPath: userThemeFolderFile(id).path)
    }

    func installContributed(_ items: [ContributedTheme]) {
        for item in items { contributed[item.theme.id] = item }
        reload()
        if let saved = restorableSelectionID, current.id != saved, items.contains(where: { $0.theme.id == saved }),
           let t = theme(withID: saved) {
            current = t
            applyAppearance()
            NotificationCenter.default.post(name: .themeDidChange, object: t)
        }
        NotificationCenter.default.post(name: .themeContributionsDidChange, object: self)
    }

    func removeContributed(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let removedCurrent = ids.contains(current.id) && isContributed(current.id)
        for id in ids { contributed.removeValue(forKey: id) }
        reload()
        if removedCurrent {
            let fallback = theme(withID: "modern") ?? Self.fallback
            current = fallback
            applyAppearance()
            NotificationCenter.default.post(name: .themeDidChange, object: fallback)
        }
        NotificationCenter.default.post(name: .themeContributionsDidChange, object: self)
    }

    @discardableResult
    public func forkContributed(_ id: String, applying draft: Theme? = nil) throws -> Theme {
        guard contributed[id] != nil else { throw ThemeError.notFound(id) }
        let original = theme(withID: id) ?? Self.fallback
        var source = draft ?? original
        let newName = uniqueName(source.name == original.name ? "\(source.name) Copy" : source.name)
        source.name = newName
        source.id = uniqueID(Self.slug(newName))
        if let assets = assetFolder(for: id) {
            let dest = userThemeFolder(source.id)
            try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: assets, to: dest)
            let stale = dest.appendingPathComponent(Self.themeFileName)
            if FileManager.default.fileExists(atPath: stale.path) { try FileManager.default.removeItem(at: stale) }
        }
        try save(source)
        return source
    }

    public func original(_ id: String) -> Theme? {
        Self.builtIns.first { $0.id == id }
    }

    public func hasUserOverride(_ id: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: userThemeURL(id).path) || fm.fileExists(atPath: userThemeFolderFile(id).path)
    }

    public func isModified(_ id: String) -> Bool {
        guard isBuiltIn(id), hasUserOverride(id), let orig = original(id), let mine = theme(withID: id) else { return false }
        var a = orig, b = mine
        a.normalize()
        b.normalize()
        return a != b
    }

    public func save(_ theme: Theme) throws {
        if isContributed(theme.id) { throw ThemeContributionError.readOnly(theme.id) }
        var theme = theme
        theme.normalize()
        try Self.requireSafeID(theme.id)
        try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
        let url = FileManager.default.fileExists(atPath: userThemeFolder(theme.id).path) ? userThemeFolderFile(theme.id) : userThemeURL(theme.id)
        try requireContained(url, id: theme.id)
        try Self.encoder.encode(theme).write(to: url, options: .atomic)
        reload()
        if current.id == theme.id {
            current = theme
            applyAppearance()
            NotificationCenter.default.post(name: .themeDidChange, object: theme)
        }
    }

    public func resetToOriginal(_ id: String) throws {
        let fm = FileManager.default
        try Self.requireSafeID(id)
        let targets = [userThemeURL(id), userThemeFolder(id)].filter { fm.fileExists(atPath: $0.path) || Self.isSymlink($0) }
        for url in targets { try requireContained(url, id: id, allowingSymlinkLeaf: true) }
        for url in targets {
            try fm.removeItem(at: url)
        }
        reload()
        if current.id == id { select(id) }
    }

    public func delete(_ id: String) throws {
        try resetToOriginal(id)
        if current.id == id, !available.contains(where: { $0.id == id }) { select("modern") }
    }

    @discardableResult
    public func duplicate(_ id: String, name: String? = nil) throws -> Theme {
        guard var t = theme(withID: id) else { throw ThemeError.notFound(id) }
        let newName = name ?? uniqueName("\(t.name) Copy")
        t.name = newName
        t.id = uniqueID(Self.slug(newName))
        if let assets = assetFolder(for: id) {
            let dest = userThemeFolder(t.id)
            try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: assets, to: dest)
            let stale = dest.appendingPathComponent(Self.themeFileName)
            if FileManager.default.fileExists(atPath: stale.path) { try FileManager.default.removeItem(at: stale) }
        }
        try save(t)
        return t
    }

    public func assetFolder(for id: String) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let user = userThemeFolder(id)
        if Self.isSafeThemeID(id), fm.fileExists(atPath: user.path, isDirectory: &isDir), isDir.boolValue, isContained(user) { return user }
        if let root = contributed[id]?.assetRoot,
           fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue { return root }
        if let dir = Self.builtInDirectory?.appendingPathComponent(id, isDirectory: true),
           fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return dir }
        return nil
    }

    public func assetURL(_ relativePath: String, for id: String) -> URL? {
        let sandboxed = isContributed(id)
        if relativePath.hasPrefix("/") {
            if sandboxed { return nil }
            return FileManager.default.fileExists(atPath: relativePath) ? URL(fileURLWithPath: relativePath) : nil
        }
        guard let folder = assetFolder(for: id) else { return nil }
        let url = folder.appendingPathComponent(relativePath)
        if sandboxed {
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func importAsset(from source: URL, for id: String, subdirectory: String = "assets") throws -> String {
        let fm = FileManager.default
        try Self.requireSafeID(id)
        guard subdirectory.isEmpty || subdirectory.split(separator: "/").allSatisfy({ Self.isSafeThemeID(String($0)) }) else { throw ThemeIDError.unsafe(subdirectory) }
        try fm.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
        let folder = userThemeFolder(id)
        try requireContained(folder, id: id)
        if !fm.fileExists(atPath: folder.path) {
            if let bundled = Self.builtInDirectory?.appendingPathComponent(id, isDirectory: true), fm.fileExists(atPath: bundled.path) {
                try fm.copyItem(at: bundled, to: folder)
            } else {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let flat = userThemeURL(id)
            let file = userThemeFolderFile(id)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            if fm.fileExists(atPath: flat.path) {
                try fm.moveItem(at: flat, to: file)
            } else if var t = theme(withID: id) {
                t.normalize()
                try Self.encoder.encode(t).write(to: file, options: .atomic)
            }
        }
        let dir = subdirectory.isEmpty ? folder : folder.appendingPathComponent(subdirectory, isDirectory: true)
        try requireContained(dir, id: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        try requireContained(dest, id: id, allowingSymlinkLeaf: true)
        if dest.standardizedFileURL != source.standardizedFileURL {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
        }
        return subdirectory.isEmpty ? source.lastPathComponent : "\(subdirectory)/\(source.lastPathComponent)"
    }

    public func exportTheme(_ id: String, to destination: URL) throws {
        guard var theme = theme(withID: id) else { throw ThemeError.notFound(id) }
        theme.normalize()
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("bftheme-\(UUID().uuidString)", isDirectory: true)
        let folderName = !Self.slug(theme.name).isEmpty ? Self.slug(theme.name) : (Self.isSafeThemeID(theme.id) ? theme.id : "theme")
        let folder = staging.appendingPathComponent(folderName, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if let assets = assetFolder(for: id) {
            try fm.copyItem(at: assets, to: folder)
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Self.encoder.encode(theme).write(to: folder.appendingPathComponent(Self.themeFileName), options: .atomic)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try Self.runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path])
    }

    @discardableResult
    public func importTheme(from source: URL) throws -> Theme {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw ThemeError.invalidPackage(source) }

        if !isDir.boolValue, source.pathExtension.lowercased() == "json" {
            var theme = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: source))
            theme = renamedForImport(theme)
            try save(theme)
            return theme
        }

        let staging = fm.temporaryDirectory.appendingPathComponent("bftheme-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let root: URL
        if isDir.boolValue {
            root = source
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try Self.runDitto(["-x", "-k", source.path, staging.path])
            root = staging
        }
        guard let themeFile = Self.findThemeFile(in: root) else { throw ThemeError.invalidPackage(source) }
        var theme = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: themeFile))
        theme = renamedForImport(theme)
        try Self.requireSafeID(theme.id)
        try fm.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
        let dest = userThemeFolder(theme.id)
        try requireContained(dest, id: theme.id, allowingSymlinkLeaf: true)
        let incoming = userThemesDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: incoming) }
        try fm.copyItem(at: themeFile.deletingLastPathComponent(), to: incoming)
        for junk in ["__MACOSX", ".DS_Store"] {
            try? fm.removeItem(at: incoming.appendingPathComponent(junk))
        }
        var normalized = theme
        normalized.normalize()
        try Self.encoder.encode(normalized).write(to: incoming.appendingPathComponent(Self.themeFileName), options: .atomic)
        try commitStaged(incoming, to: dest)
        try save(theme)
        return theme
    }

    private func commitStaged(_ staged: URL, to dest: URL) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: dest.path) || Self.isSymlink(dest)
        guard exists else {
            try fm.moveItem(at: staged, to: dest)
            return
        }
        let backup = userThemesDirectory.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: dest, to: backup)
        do {
            try fm.moveItem(at: staged, to: dest)
        } catch {
            try? fm.moveItem(at: backup, to: dest)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    func userThemeURL(_ id: String) -> URL {
        userThemesDirectory.appendingPathComponent("\(id).json")
    }

    func userThemeFolder(_ id: String) -> URL {
        userThemesDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func userThemeFolderFile(_ id: String) -> URL {
        userThemeFolder(id).appendingPathComponent(Self.themeFileName)
    }

    private func renamedForImport(_ theme: Theme) -> Theme {
        var t = theme
        if t.id.isEmpty { t.id = Self.slug(t.name) }
        if !Self.isSafeThemeID(t.id) {
            let fromName = Self.slug(t.name)
            t.id = uniqueID(fromName.isEmpty ? Self.slug(t.id) : fromName)
        }
        if available.contains(where: { $0.id == t.id }) || hasUserOverride(t.id) || isContributed(t.id) {
            t.name = uniqueName(t.name)
            t.id = uniqueID(Self.slug(t.name))
        }
        return t
    }

    private func uniqueName(_ name: String) -> String {
        let names = Set(available.map(\.name))
        if !names.contains(name) { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    private func uniqueID(_ base: String) -> String {
        let base = base.isEmpty ? "theme" : base
        let ids = Set(available.map(\.id))
        if !ids.contains(base) && !hasUserOverride(base) { return base }
        var n = 2
        while ids.contains("\(base)-\(n)") || hasUserOverride("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func loadUserThemes() -> [Theme] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: userThemesDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [Theme] = []
        func accept(_ theme: Theme, stem: String) {
            var t = theme
            if !Self.isSafeThemeID(t.id) {
                guard Self.isSafeThemeID(stem) else { return }
                t.id = stem
            }
            out.append(t)
        }
        for url in entries {
            if url.pathExtension == "json" {
                if let t = try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: url)) { accept(t, stem: url.deletingPathExtension().lastPathComponent) }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let file = url.appendingPathComponent(Self.themeFileName)
                if let t = try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: file)) { accept(t, stem: url.lastPathComponent) }
            }
        }
        return out
    }

    nonisolated public static func isSafeThemeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 200, !id.hasPrefix("."), id != "~" else { return false }
        for scalar in id.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":" { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: return false
            default: continue
            }
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines) == id
    }

    nonisolated private static func requireSafeID(_ id: String) throws {
        guard isSafeThemeID(id) else { throw ThemeIDError.unsafe(id) }
    }

    nonisolated private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    nonisolated static func canonicalPath(of url: URL) -> String? {
        let fm = FileManager.default
        var existing = url.standardizedFileURL.path
        var rest: [String] = []
        while (try? fm.attributesOfItem(atPath: existing)) == nil, existing != "/" {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return nil }
        defer { free(resolved) }
        var path = String(cString: resolved)
        for component in rest { path = (path as NSString).appendingPathComponent(component) }
        return path
    }

    private func isContained(_ url: URL, allowingSymlinkLeaf: Bool = false) -> Bool {
        guard let root = Self.canonicalPath(of: userThemesDirectory) else { return false }
        let path: String?
        if allowingSymlinkLeaf, Self.isSymlink(url) {
            path = Self.canonicalPath(of: url.deletingLastPathComponent()).map { ($0 as NSString).appendingPathComponent(url.lastPathComponent) }
        } else {
            path = Self.canonicalPath(of: url)
        }
        guard let path else { return false }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func requireContained(_ url: URL, id: String, allowingSymlinkLeaf: Bool = false) throws {
        guard isContained(url, allowingSymlinkLeaf: allowingSymlinkLeaf) else { throw ThemeIDError.outsideThemesFolder(id) }
    }

    nonisolated private static func sortKey(_ t: Theme) -> String {
        let order = ["modern", "modern-light", "modern-dark", "platinum", "system7", "aqua", "classic-windows", "luna", "high-contrast"]
        if let i = order.firstIndex(of: t.id) { return String(format: "0%02d", i) }
        return "1" + t.name.lowercased()
    }

    nonisolated static var builtInDirectory: URL? {
        Bundle.module.url(forResource: "BuiltInThemes", withExtension: nil)
    }

    nonisolated public static let builtIns: [Theme] = loadBuiltIns()

    nonisolated public static func loadBuiltIns() -> [Theme] {
        guard let dir = builtInDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [fallback] }
        let themes = files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: $0)) }
        return themes.isEmpty ? [fallback] : themes
    }

    nonisolated public static let fallback = Theme.modernDefault

    nonisolated static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    nonisolated public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var out = ""
        var lastDash = false
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    nonisolated private static func findThemeFile(in root: URL) -> URL? {
        let direct = root.appendingPathComponent(themeFileName)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == themeFileName && !url.path.contains("__MACOSX") {
            return url
        }
        return nil
    }

    nonisolated private static func runDitto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto exited \(p.terminationStatus)"
            throw ThemeError.archiveFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
