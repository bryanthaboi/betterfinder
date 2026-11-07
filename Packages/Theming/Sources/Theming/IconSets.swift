import AppKit
import Foundation
import UniformTypeIdentifiers

public extension Notification.Name {
    static let iconSetDidChange = Notification.Name("BetterFinderIconSetDidChange")
}

public enum IconFileKind: String, CaseIterable, Sendable {
    case file, folder, package, application, symlink, alias, volume
}

public enum SpecialFolder: String, CaseIterable, Sendable {
    case home, desktop, documents, downloads, applications, pictures, music, movies, library, trash, publicFolder, utilities

    public static func detect(url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SpecialFolder? {
        let path = url.standardizedFileURL.path
        let h = home.standardizedFileURL.path
        let table: [(String, SpecialFolder)] = [
            (h, .home),
            (h + "/Desktop", .desktop),
            (h + "/Documents", .documents),
            (h + "/Downloads", .downloads),
            (h + "/Pictures", .pictures),
            (h + "/Music", .music),
            (h + "/Movies", .movies),
            (h + "/Library", .library),
            (h + "/Public", .publicFolder),
            (h + "/.Trash", .trash),
            ("/Applications", .applications),
            ("/Applications/Utilities", .utilities),
            ("/System/Applications/Utilities", .utilities),
        ]
        return table.first { $0.0 == path }?.1
    }
}

public struct IconRequest: Hashable, Sendable {
    public var contentTypeIdentifier: String?
    public var kind: IconFileKind
    public var specialFolder: SpecialFolder?

    public init(contentTypeIdentifier: String? = nil, kind: IconFileKind = .file, specialFolder: SpecialFolder? = nil) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kind = kind
        self.specialFolder = specialFolder
    }

    public init(url: URL, isDirectory: Bool, isPackage: Bool = false, isSymlink: Bool = false, contentTypeIdentifier: String? = nil) {
        var kind: IconFileKind = isDirectory ? .folder : .file
        if isSymlink { kind = .symlink }
        if isPackage { kind = contentTypeIdentifier.flatMap { UTType($0)?.conforms(to: .applicationBundle) } == true ? .application : .package }
        self.init(
            contentTypeIdentifier: contentTypeIdentifier,
            kind: kind,
            specialFolder: isDirectory ? SpecialFolder.detect(url: url) : nil
        )
    }
}

public protocol IconSetProvider: AnyObject, Sendable {
    var setID: String { get }
    func icon(for request: IconRequest, size: CGFloat) -> NSImage?
}

public final class StaticIconSetProvider: IconSetProvider, @unchecked Sendable {
    public let setID: String
    private let specialFolders: [SpecialFolder: NSImage]
    private let contentTypes: [String: NSImage]
    private let kinds: [IconFileKind: NSImage]

    public init(
        setID: String,
        specialFolders: [SpecialFolder: NSImage] = [:],
        contentTypes: [String: NSImage] = [:],
        kinds: [IconFileKind: NSImage] = [:]
    ) {
        self.setID = setID
        self.specialFolders = specialFolders
        self.contentTypes = contentTypes
        self.kinds = kinds
    }

    public func icon(for request: IconRequest, size: CGFloat) -> NSImage? {
        if let special = request.specialFolder, let image = specialFolders[special] { return sized(image, size) }
        if let id = request.contentTypeIdentifier, let image = contentTypeImage(for: id) { return sized(image, size) }
        if let image = kinds[request.kind] { return sized(image, size) }
        return nil
    }

    private func contentTypeImage(for id: String) -> NSImage? {
        if let exact = contentTypes[id] { return exact }
        guard let type = UTType(id) else { return nil }
        let conforming = contentTypes.keys.compactMap { UTType($0) }.filter { type.conforms(to: $0) }
        guard !conforming.isEmpty else { return nil }
        let mostSpecific = conforming.first { candidate in
            !conforming.contains { $0 != candidate && $0.conforms(to: candidate) }
        } ?? conforming[0]
        return contentTypes[mostSpecific.identifier]
    }

    private func sized(_ image: NSImage, _ size: CGFloat) -> NSImage {
        guard size > 0, image.size.width != size || image.size.height != size else { return image }
        guard let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}

public struct IconProviderToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public final class IconSetRegistry: @unchecked Sendable {
    public static let shared = IconSetRegistry()

    private struct Entry {
        var token: IconProviderToken
        var owner: String
        var provider: IconSetProvider
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var active = "system"

    public init() {}

    public var activeSetID: String {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public func setActiveSetID(_ id: String) {
        lock.lock()
        let changed = active != id
        active = id
        lock.unlock()
        if changed { Self.postChange(self) }
    }

    @discardableResult
    public func register(_ provider: IconSetProvider, owner: String) -> IconProviderToken {
        let token = IconProviderToken()
        lock.lock()
        entries.append(Entry(token: token, owner: owner, provider: provider))
        lock.unlock()
        Self.postChange(self)
        return token
    }

    @discardableResult
    public func remove(_ token: IconProviderToken) -> Bool {
        lock.lock()
        let before = entries.count
        entries.removeAll { $0.token == token }
        let removed = entries.count != before
        lock.unlock()
        if removed { Self.postChange(self) }
        return removed
    }

    @discardableResult
    public func removeAll(owner: String) -> Int {
        lock.lock()
        let before = entries.count
        entries.removeAll { $0.owner == owner }
        let removed = before - entries.count
        lock.unlock()
        if removed > 0 { Self.postChange(self) }
        return removed
    }

    public func providers(forSet setID: String) -> [IconSetProvider] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed().filter { $0.provider.setID == setID }.map(\.provider)
    }

    public var registeredSetIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen: [String] = []
        for e in entries where !seen.contains(e.provider.setID) { seen.append(e.provider.setID) }
        return seen
    }

    public var providerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private static func postChange(_ registry: IconSetRegistry) {
        let post = { NotificationCenter.default.post(name: .iconSetDidChange, object: registry) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

public enum IconResolver {
    public static func icon(for request: IconRequest, size: CGFloat, registry: IconSetRegistry = .shared) -> NSImage? {
        for provider in registry.providers(forSet: registry.activeSetID) {
            if let image = provider.icon(for: request, size: size) { return image }
        }
        return nil
    }

    public static func icon(
        for url: URL,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        contentTypeIdentifier: String? = nil,
        size: CGFloat,
        registry: IconSetRegistry = .shared
    ) -> NSImage? {
        let request = IconRequest(url: url, isDirectory: isDirectory, isPackage: isPackage, isSymlink: isSymlink, contentTypeIdentifier: contentTypeIdentifier)
        return icon(for: request, size: size, registry: registry)
    }
}
