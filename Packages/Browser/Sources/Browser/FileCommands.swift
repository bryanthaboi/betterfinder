import AppKit
import FSCore
import FileOps

struct FileTemplate: Hashable, Sendable {
    let title: String
    let fileName: String
    let contents: Data

    static let text = FileTemplate(title: "Text Document", fileName: "untitled.txt", contents: Data())
    static let markdown = FileTemplate(title: "Markdown Document", fileName: "untitled.md", contents: Data("# Untitled\n".utf8))
    static let empty = FileTemplate(title: "Empty File", fileName: "untitled", contents: Data())
    static let primary: [FileTemplate] = [text, markdown, empty]

    static let all: [FileTemplate] = primary + [
        FileTemplate(title: "Shell Script", fileName: "untitled.sh", contents: Data("#!/bin/sh\n".utf8)),
        FileTemplate(title: "JSON File", fileName: "untitled.json", contents: Data("{}\n".utf8)),
        FileTemplate(title: "HTML File", fileName: "untitled.html", contents: Data("<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"><title>Untitled</title></head>\n<body>\n</body>\n</html>\n".utf8)),
    ]
}

enum TerminalApp {
    static let defaultBundleID = "com.apple.Terminal"
    static let fallbackPath = "/System/Applications/Utilities/Terminal.app"

    static func resolve(customPath: String?, bundleID: String?, exists: (String) -> Bool, lookup: (String) -> URL?) -> URL? {
        if let customPath, !customPath.isEmpty, exists(customPath) { return URL(fileURLWithPath: customPath, isDirectory: true) }
        if let bundleID, !bundleID.isEmpty, let url = lookup(bundleID) { return url }
        if let url = lookup(defaultBundleID) { return url }
        return exists(fallbackPath) ? URL(fileURLWithPath: fallbackPath, isDirectory: true) : nil
    }

    @MainActor
    static func current() -> URL? {
        resolve(
            customPath: BrowserDefaults.terminalAppPath,
            bundleID: BrowserDefaults.terminalBundleID,
            exists: { FileManager.default.fileExists(atPath: $0) },
            lookup: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        )
    }

    static func targetDirectory(selection: [FileItem], location: URL?) -> URL? {
        if selection.count == 1, selection[0].isBrowsableFolder { return selection[0].url }
        return location ?? selection.first?.url.deletingLastPathComponent()
    }
}

@MainActor
enum FileCommands {
    static func copyPaths(_ urls: [URL], format: PathFormat = .posix) {
        guard let text = format.string(for: urls) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func openInTerminal(_ dir: URL) {
        guard let app = TerminalApp.current() else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: config) { _, error in
            if let error { onMain { NSApp.presentError(error) } }
        }
    }

    static func tags(of url: URL) -> [String] {
        TagOps.tags(for: url)
    }

    static func setTags(_ tags: [String], on url: URL) async throws {
        defer { tagsChanged([url]) }
        try await TagOps.setTagsAsync(tags, for: url)
    }

    static func addTag(_ tag: String, to url: URL) async throws {
        guard !tags(of: url).contains(tag) else { return }
        defer { tagsChanged([url]) }
        try await TagOps.addTagsAsync([tag], to: url)
    }

    static func tagsChanged(_ urls: [URL]) {
        NotificationCenter.default.post(name: .browserTagsDidChange, object: nil, userInfo: ["urls": urls])
    }

    static func toggleTag(_ tag: String, on urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let allHave = urls.allSatisfy { tags(of: $0).contains(tag) }
        var firstError: Error?
        for u in urls {
            var t = tags(of: u)
            if allHave { t.removeAll { $0 == tag } } else if !t.contains(tag) { t.append(tag) }
            do { try await TagOps.setTagsAsync(t, for: u) } catch { if firstError == nil { firstError = error } }
        }
        BrowserDefaults.noteTags([tag])
        tagsChanged(urls)
        if let firstError { throw firstError }
    }
}
