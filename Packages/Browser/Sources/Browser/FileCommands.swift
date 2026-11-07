import AppKit
import FileOps

struct FileTemplate: Hashable, Sendable {
    let title: String
    let fileName: String
    let contents: Data

    static let all: [FileTemplate] = [
        FileTemplate(title: "Text File", fileName: "untitled.txt", contents: Data()),
        FileTemplate(title: "Markdown File", fileName: "untitled.md", contents: Data("# Untitled\n".utf8)),
        FileTemplate(title: "Empty File", fileName: "untitled", contents: Data()),
        FileTemplate(title: "Shell Script", fileName: "untitled.sh", contents: Data("#!/bin/sh\n".utf8)),
        FileTemplate(title: "JSON File", fileName: "untitled.json", contents: Data("{}\n".utf8)),
        FileTemplate(title: "HTML File", fileName: "untitled.html", contents: Data("<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"><title>Untitled</title></head>\n<body>\n</body>\n</html>\n".utf8)),
    ]
}

@MainActor
enum FileCommands {
    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func openInTerminal(_ dir: URL) {
        let bundleIDs = [UserDefaults.standard.string(forKey: "terminalBundleID"), "com.apple.Terminal"].compactMap { $0 }
        for id in bundleIDs {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: config) { _, error in
                    if let error { onMain { NSApp.presentError(error) } }
                }
                return
            }
        }
        NSSound.beep()
    }

    static func tags(of url: URL) -> [String] {
        TagOps.tags(for: url)
    }

    static func setTags(_ tags: [String], on url: URL) async throws {
        try await TagOps.setTagsAsync(tags, for: url)
    }

    static func addTag(_ tag: String, to url: URL) async throws {
        guard !tags(of: url).contains(tag) else { return }
        try await TagOps.addTagsAsync([tag], to: url)
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
        if let firstError { throw firstError }
    }
}
