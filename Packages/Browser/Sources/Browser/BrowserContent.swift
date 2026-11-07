import AppKit
import FSCore
import FileOps
import Theming

@MainActor
class BrowserContentController: NSViewController, ThemedSurface {
    weak var pane: BrowserPaneController?

    var selectedItems: [FileItem] { [] }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    func modelDidChange(_ change: FolderModel.Change) {}
    func locationDidChange() {}
    func select(_ urls: [URL], scroll: Bool) {}
    func sizeDidChange(_ key: String) {}
    func beginRename(_ url: URL) {}
    func focus() {}
    func previewSourceRect(for url: URL) -> NSRect? { nil }
    func previewImage(for url: URL) -> NSImage? { nil }
    func visibleFolderURLs() -> [URL] { [] }
    func applyTheme(_ theme: Theme) {}
    func refreshDisplay() {}
    func invalidateColumnValues(_ pathKeys: [String]) {}
    func childDirectoryEvents(_ dirs: Set<String>) {}
    var keyView: NSView? { nil }
    func usesModel(_ model: FolderModel) -> Bool { false }
    func teardown() {}
    func updateAccessibility(location: BrowserLocation) {
        keyView?.setAccessibilityLabel("Files in \(location.displayName)")
    }

    func notifySelection() { pane?.selectionDidChange() }
}

@MainActor
final class RenameSession: NSObject, NSTextFieldDelegate {
    let url: URL
    let originalName: String
    weak var field: NSTextField?
    var onFinish: ((URL?) -> Void)?
    private var finished = false
    private static var active: RenameSession?
    static var current: RenameSession? { active }
    var isFinished: Bool { finished }

    static func isEditing(in view: NSView) -> Bool {
        guard let s = active, !s.finished, let f = s.field else { return false }
        return f.isDescendant(of: view)
    }

    init(url: URL, field: NSTextField) {
        self.url = url
        self.originalName = url.lastPathComponent
        self.field = field
        super.init()
    }

    static func begin(url: URL, field: NSTextField, onFinish: @escaping (URL?) -> Void) {
        active?.cancel()
        let s = RenameSession(url: url, field: field)
        s.onFinish = onFinish
        active = s
        field.isEditable = true
        field.isSelectable = true
        field.delegate = s
        field.stringValue = s.originalName
        field.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let base = (s.originalName as NSString).deletingPathExtension
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
            let len = isFolder || base.isEmpty ? (s.originalName as NSString).length : (base as NSString).length
            editor.selectedRange = NSRange(location: 0, length: len)
        }
    }

    nonisolated static func validate(_ name: String, renaming url: URL) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A name is required." }
        if trimmed.contains("/") { return "Names can't contain “/”." }
        if trimmed.hasPrefix(".") && !url.lastPathComponent.hasPrefix(".") { return "Names starting with “.” are hidden. Press Return again to confirm." }
        if (trimmed as NSString).length > 255 { return "That name is too long." }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if trimmed.lowercased() != url.lastPathComponent.lowercased(), FileManager.default.fileExists(atPath: target.path) {
            return "The name “\(trimmed)” is already taken. Choose a different name."
        }
        return nil
    }

    private var confirmedDotName: String?

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard !finished else { return true }
        let name = fieldEditor.string
        if name == originalName { return true }
        if let problem = Self.validate(name, renaming: url) {
            if problem.hasPrefix("Names starting"), confirmedDotName == name { return true }
            if problem.hasPrefix("Names starting") { confirmedDotName = name }
            NSSound.beep()
            InlineWarning.show(problem, relativeTo: control)
            return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        InlineWarning.dismiss()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !finished, !inFlight, !restoringFocus, let field else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        InlineWarning.dismiss()
        guard name != originalName, !name.isEmpty else { finish(nil); return }
        commit(name)
    }

    private var inFlight = false
    private var restoringFocus = false
    private(set) var failureMessage: String?

    func commit(_ name: String) {
        guard !finished, !inFlight else { return }
        inFlight = true
        failureMessage = nil
        let url = url
        Task { [weak self] in
            do {
                let renamed = try await FileActions.renameAsync(url, to: name)
                guard let self else { return }
                self.inFlight = false
                self.finish(renamed)
            } catch {
                guard let self else { return }
                self.inFlight = false
                self.fail(error, typed: name)
            }
        }
    }

    private func fail(_ error: Error, typed: String) {
        guard !finished, let field else { finish(nil); return }
        NSSound.beep()
        let message = error.localizedDescription
        failureMessage = message
        field.stringValue = typed
        guard field.window != nil else { finish(nil); return }
        restoringFocus = true
        field.window?.makeFirstResponder(field)
        restoringFocus = false
        field.currentEditor()?.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
        InlineWarning.show(message, relativeTo: field)
    }

    func cancel() {
        guard !finished else { return }
        field?.stringValue = originalName
        field?.abortEditing()
        InlineWarning.dismiss()
        finish(nil)
    }

    private func finish(_ result: URL?) {
        guard !finished else { return }
        finished = true
        field?.isEditable = false
        field?.isSelectable = false
        field?.delegate = nil
        if Self.active === self { Self.active = nil }
        onFinish?(result)
        NotificationCenter.default.post(name: .browserRenameDidEnd, object: nil)
    }
}

@MainActor
enum DropSupport {
    static var types: [NSPasteboard.PasteboardType] {
        [.fileURL, Clipboard.resourceType] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func volume(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    static func operation(for info: NSDraggingInfo, destination: URL) -> NSDragOperation {
        let resources = Clipboard.resources(from: info.draggingPasteboard)
        if !resources.isEmpty {
            return resources.contains(where: \.isLocal) ? [] : .copy
        }
        let urls = fileURLs(info)
        if urls.isEmpty {
            let hasPromise = info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            return hasPromise ? .copy : []
        }
        let destKey = destination.pathKey
        for u in urls {
            if u.pathKey == destKey || u.isAncestor(of: destination) { return [] }
        }
        if urls.allSatisfy({ $0.deletingLastPathComponent().pathKey == destKey }) && info.draggingSourceOperationMask != .copy { return [] }
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .link { return .link }
        if mask == .generic || mask == .move { return .move }
        let destVol = volume(of: destination)
        let same = urls.allSatisfy { volume(of: $0) == destVol }
        return same ? .move : .copy
    }

    static func perform(_ info: NSDraggingInfo, destination: URL) -> Bool {
        let op = operation(for: info, destination: destination)
        guard !op.isEmpty else { return false }
        let resources = Clipboard.resources(from: info.draggingPasteboard)
        if !resources.isEmpty {
            onMain { RemoteTransfers.enqueue(resources, into: .local(destination), move: false) }
            return true
        }
        let urls = fileURLs(info)
        if urls.isEmpty {
            guard let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }
            for r in receivers {
                r.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { _, error in
                    if let error {
                        onMain { NSApp.presentError(error) }
                    }
                }
            }
            return true
        }
        if op == .link {
            for u in urls {
                let target = FileOperationQueue.uniqueDestination(for: u.lastPathComponent, in: destination)
                try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: u)
            }
            return true
        }
        FileOperationQueue.shared.enqueue(op == .copy ? .copy(sources: urls, destination: destination) : .move(sources: urls, destination: destination))
        return true
    }
}

@MainActor
final class SpringLoader {
    private var target: String?
    private var timer: Timer?
    var delay: TimeInterval = 0.9

    func hover(_ url: URL?, fire: @escaping () -> Void) {
        let key = url?.pathKey
        guard key != target else { return }
        cancel()
        target = key
        guard key != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.target = nil
                self?.timer = nil
                fire()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}

final class TypeSelectBuffer {
    private var buffer = ""
    private var last = Date.distantPast

    func append(_ s: String) -> String {
        if Date().timeIntervalSince(last) > 1.0 { buffer = "" }
        last = Date()
        buffer += s
        return buffer
    }
}
