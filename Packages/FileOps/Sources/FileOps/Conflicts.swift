import AppKit
import Foundation

public enum ConflictChoice: Sendable, Hashable {
    case replace, skip, keepBoth, merge, stop
}

public struct ConflictItemInfo: Sendable, Hashable {
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64?
    public let modificationDate: Date?

    public init(url: URL, isDirectory: Bool, size: Int64?, modificationDate: Date?) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }

    static func read(_ url: URL) -> ConflictItemInfo {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return ConflictItemInfo(url: url, isDirectory: false, size: nil, modificationDate: nil)
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let date = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return ConflictItemInfo(url: url, isDirectory: isDir, size: isDir ? nil : Int64(st.st_size), modificationDate: date)
    }
}

public struct FileConflict: Sendable, Hashable {
    public let source: ConflictItemInfo
    public let destination: ConflictItemInfo
    public let isMove: Bool

    public init(source: ConflictItemInfo, destination: ConflictItemInfo, isMove: Bool) {
        self.source = source
        self.destination = destination
        self.isMove = isMove
    }

    public var allowsMerge: Bool { source.isDirectory && destination.isDirectory }
    public var name: String { destination.url.lastPathComponent }
}

public struct ConflictDecision: Sendable, Hashable {
    public var choice: ConflictChoice
    public var applyToAll: Bool

    public init(_ choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public protocol ConflictResolver: AnyObject, Sendable {
    func resolve(_ conflict: FileConflict) async -> ConflictDecision
}

public final class AlertConflictResolver: ConflictResolver, @unchecked Sendable {
    private let windowProvider: @MainActor @Sendable () -> NSWindow?

    public init(windowProvider: @escaping @MainActor @Sendable () -> NSWindow? = { NSApp.keyWindow }) {
        self.windowProvider = windowProvider
    }

    public func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        await withCheckedContinuation { (cont: CheckedContinuation<ConflictDecision, Never>) in
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { present(conflict, continuation: cont) }
            }
        }
    }

    @MainActor
    private func present(_ conflict: FileConflict, continuation: CheckedContinuation<ConflictDecision, Never>) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let kind = conflict.destination.isDirectory ? "folder" : "item"
        let verb = conflict.isMove ? "moving" : "copying"
        alert.messageText = "An \(kind) named “\(conflict.name)” already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you’re \(verb)?\n\n"
            + "Existing: \(Self.describe(conflict.destination))\n"
            + "New: \(Self.describe(conflict.source))"

        var choices: [ConflictChoice] = []
        if conflict.allowsMerge {
            alert.addButton(withTitle: "Merge")
            choices.append(.merge)
            alert.addButton(withTitle: "Keep Both")
            choices.append(.keepBoth)
            alert.addButton(withTitle: "Replace")
            choices.append(.replace)
        } else {
            alert.addButton(withTitle: "Keep Both")
            choices.append(.keepBoth)
            alert.addButton(withTitle: "Replace")
            choices.append(.replace)
        }
        alert.addButton(withTitle: "Skip")
        choices.append(.skip)
        alert.addButton(withTitle: "Stop")
        choices.append(.stop)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = choices.indices.contains(index) ? choices[index] : .stop
            let all = alert.suppressionButton?.state == .on
            continuation.resume(returning: ConflictDecision(choice, applyToAll: all))
        }

        if let window = windowProvider(), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            finish(alert.runModal())
        }
    }

    private static func describe(_ info: ConflictItemInfo) -> String {
        var parts: [String] = []
        if let size = info.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        else if info.isDirectory { parts.append("Folder") }
        if let date = info.modificationDate { parts.append("modified " + date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: ", ")
    }
}
