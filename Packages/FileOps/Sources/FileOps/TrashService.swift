import AppKit
import Foundation

public protocol TrashProvider: Sendable {
    func trashItem(at url: URL) throws -> URL?
    func trashContents() -> [URL]
}

public struct SystemTrashProvider: TrashProvider {
    public init() {}

    public func trashItem(at url: URL) throws -> URL? {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    public func trashContents() -> [URL] {
        var dirs = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
        let uid = getuid()
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path != "/" {
            let t = v.appendingPathComponent(".Trashes/\(uid)")
            if FS.isDirectory(t) { dirs.append(t) }
        }
        var items: [URL] = []
        for d in dirs {
            let children = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [])) ?? []
            items.append(contentsOf: children)
        }
        return items
    }
}

public struct FinderTrashProvider: TrashProvider {
    public let fallback: TrashProvider

    public init(fallback: TrashProvider = SystemTrashProvider()) {
        self.fallback = fallback
    }

    public func trashItem(at url: URL) throws -> URL? {
        if let result = try? FinderScript.trash(url) { return result }
        return try fallback.trashItem(at: url)
    }

    public func trashContents() -> [URL] { fallback.trashContents() }
}

public struct DirectoryTrashProvider: TrashProvider {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func trashItem(at url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = FileOperationQueue.uniqueDestination(for: url.lastPathComponent, in: directory)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    public func trashContents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
    }
}

enum FinderScript {
    private static let queue = DispatchQueue(label: "betterfinder.fileops.applescript")

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) throws -> String? {
        try queue.sync {
            guard let script = NSAppleScript(source: source) else { throw CocoaError(.fileWriteUnknown) }
            var info: NSDictionary?
            let result = script.executeAndReturnError(&info)
            if let info {
                let code = (info[NSAppleScript.errorNumber] as? Int) ?? -1
                let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
                throw NSError(domain: "FileOps.AppleScript", code: code, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return result.stringValue
        }
    }

    static func trash(_ url: URL) throws -> URL? {
        let path = escape(url.path)
        let source = """
        tell application "Finder"
            set r to delete (POSIX file "\(path)" as alias)
            return POSIX path of (r as alias)
        end tell
        """
        guard let out = try run(source), !out.isEmpty else { return nil }
        return URL(fileURLWithPath: out)
    }

    static func emptyTrash() throws {
        _ = try run("tell application \"Finder\" to empty trash")
    }
}

public struct EmptyTrashReport: Sendable {
    public var removedCount = 0
    public var failures: [FileOperationItemError] = []
    public init() {}
}

public final class TrashService: @unchecked Sendable {
    public static let shared = TrashService()

    public let journal: TrashJournal
    private let lock = NSLock()
    private var providerOverride: TrashProvider?

    public init(journal: TrashJournal = .shared, provider: TrashProvider? = nil) {
        self.journal = journal
        self.providerOverride = provider
    }

    public var provider: TrashProvider {
        get {
            lock.lock(); defer { lock.unlock() }
            if let providerOverride { return providerOverride }
            return UserDefaults.standard.bool(forKey: "trashViaFinder") ? FinderTrashProvider() : SystemTrashProvider()
        }
        set {
            lock.lock(); providerOverride = newValue; lock.unlock()
        }
    }

    @discardableResult
    public func trash(_ url: URL) throws -> URL {
        let original = url
        let p = provider
        let result = try p.trashItem(at: url)
        let trashed = result ?? p.trashContents().first { $0.lastPathComponent == url.lastPathComponent } ?? url
        _ = try? journal.record(originalURL: original, trashedURL: trashed)
        return trashed
    }

    public func putBack(_ trashedURLs: [URL]) -> PutBackReport {
        journal.putBack(trashedURLs)
    }

    func restore(_ trashed: URL, to destination: URL) throws {
        guard FS.exists(trashed) else { throw PutBackError.missing(trashed) }
        if FS.exists(destination) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let parent = destination.deletingLastPathComponent()
        if !FS.exists(parent) { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        try FileManager.default.moveItem(at: trashed, to: destination)
        journal.remove(trashedURL: trashed)
    }

    public func emptyTrash() throws -> EmptyTrashReport {
        var report = EmptyTrashReport()
        let items = provider.trashContents()
        if UserDefaults.standard.bool(forKey: "trashViaFinder"), providerOverride == nil, (try? FinderScript.emptyTrash()) != nil {
            report.removedCount = items.count
            journal.removeAll()
            return report
        }
        for item in items {
            do {
                try FileManager.default.removeItem(at: item)
                journal.remove(trashedURL: item)
                report.removedCount += 1
            } catch {
                report.failures.append(.from(error, url: item))
            }
        }
        return report
    }

    public func trashItemCount() -> Int { provider.trashContents().count }
}

@MainActor
public enum TrashUI {
    public static func confirmEmptyTrash(itemCount: Int, window: NSWindow? = nil) async -> Bool {
        let window = window ?? NSApp.keyWindow
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can’t undo this action. \(itemCount) item\(itemCount == 1 ? "" : "s") will be erased."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if let window, window.isVisible {
            return await withCheckedContinuation { cont in
                alert.beginSheetModal(for: window) { cont.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    public static func confirmAndEmptyTrash(service: TrashService = .shared, window: NSWindow? = nil) async -> EmptyTrashReport? {
        let count = service.trashItemCount()
        guard count > 0 else { return EmptyTrashReport() }
        guard await confirmEmptyTrash(itemCount: count, window: window) else { return nil }
        return try? service.emptyTrash()
    }
}
