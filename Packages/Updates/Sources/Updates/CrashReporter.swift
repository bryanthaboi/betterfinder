import AppKit
import Foundation

public struct CrashReport: Equatable, Sendable {
    public let url: URL
    public let modified: Date
    public let processName: String
}

public enum CrashDiscovery {
    public static let processPrefixes = ["betterfinder"]
    public static let extensions: Set<String> = ["ips", "crash"]

    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    public static func find(in directory: URL, newerThan date: Date?, fileManager: FileManager = .default) -> [CrashReport] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var reports: [CrashReport] = []
        for url in items {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard let process = processName(fromFileName: name) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true, let modified = values?.contentModificationDate else { continue }
            if let date, modified.timeIntervalSince(date) < 0.001 { continue }
            reports.append(CrashReport(url: url, modified: modified, processName: process))
        }
        return reports.sorted { $0.modified > $1.modified }
    }

    public static func processName(fromFileName name: String) -> String? {
        let lower = name.lowercased()
        guard processPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        let end = name.firstIndex(where: { $0 == "-" || $0 == " " }) ?? name.endIndex
        return String(name[..<end])
    }
}

public enum CrashRedactor {
    public static func redact(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var result = text
        if homeDirectory.count > 1 {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        let pattern = #"/Users/(?!Shared\b)[^/\s"'\\]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "~")
        }
        return result
    }
}

public enum CrashSummary {
    public static func summarize(_ text: String, maxFrames: Int = 20) -> [String] {
        guard let newline = text.firstIndex(of: "\n") else { return [] }
        let bodyText = text[text.index(after: newline)...]
        guard let data = bodyText.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var lines: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "?"
            let signal = (exception["signal"] as? String).map { " (\($0))" } ?? ""
            let subtype = (exception["subtype"] as? String).map { " \($0)" } ?? ""
            lines.append("Exception: \(type)\(signal)\(subtype)")
        }
        if let termination = body["termination"] as? [String: Any] {
            let namespace = termination["namespace"] as? String ?? ""
            let indicator = termination["indicator"] as? String ?? ""
            lines.append("Termination: \(namespace) \(indicator)".trimmingCharacters(in: .whitespaces))
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int
        let thread = threads.first(where: { ($0["triggered"] as? Bool) == true })
            ?? faulting.flatMap { $0 < threads.count ? threads[$0] : nil }
        if let thread, let frames = thread["frames"] as? [[String: Any]] {
            lines.append("Crashed thread \(faulting.map(String.init) ?? "?"):")
            for (index, frame) in frames.prefix(maxFrames).enumerated() {
                let imageIndex = frame["imageIndex"] as? Int
                let image = imageIndex.flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                let symbol = frame["symbol"] as? String ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16)
                let location = (frame["symbolLocation"] as? Int).map { "+\($0)" } ?? ""
                lines.append("\(index)  \(image)  \(symbol)\(location)")
            }
        }
        return lines
    }
}

public struct CrashIssue: Sendable {
    public let title: String
    public let body: String
    public let url: URL
}

public enum CrashIssueBuilder {
    public static let issuesURL = "https://github.com/bryanthaboi/betterfinder/issues/new"
    public static let maxURLLength = 7000

    public static func excerpt(from text: String, maxLines: Int = 60, maxLineLength: Int = 240, homeDirectory: String = NSHomeDirectory()) -> String {
        let summary = CrashSummary.summarize(text)
        let raw = text.components(separatedBy: .newlines)
        let budget = max(0, maxLines - summary.count)
        let combined = summary.isEmpty ? Array(raw.prefix(maxLines)) : summary + (budget > 0 ? ["---"] + raw.prefix(max(0, budget - 1)) : [])
        let lines = combined.prefix(maxLines).map { line -> String in
            let redacted = CrashRedactor.redact(line, homeDirectory: homeDirectory)
            return redacted.count > maxLineLength ? String(redacted.prefix(maxLineLength)) + "…" : redacted
        }
        return lines.joined(separator: "\n")
    }

    public static func build(
        report: CrashReport,
        crashText: String,
        appVersion: String,
        buildNumber: String?,
        osVersion: String,
        maxLines: Int = 60,
        homeDirectory: String = NSHomeDirectory()
    ) -> CrashIssue {
        let title = "Crash: \(report.processName) \(appVersion)"
        let build = buildNumber.map { " (\($0))" } ?? ""
        var lines = maxLines
        while true {
            let excerpt = excerpt(from: crashText, maxLines: lines, homeDirectory: homeDirectory)
            let body = """
            **What were you doing when it crashed?**


            **App:** betterfinder \(appVersion)\(build)
            **Process:** \(report.processName)
            **macOS:** \(osVersion)
            **Crash file:** \(report.url.lastPathComponent)

            ```
            \(excerpt)
            ```
            """
            let url = makeURL(title: title, body: body)
            if url.absoluteString.count <= maxURLLength || lines <= 5 {
                return CrashIssue(title: title, body: body, url: url)
            }
            lines = max(5, lines - 5)
        }
    }

    static func makeURL(title: String, body: String) -> URL {
        let url = "\(issuesURL)?title=\(encode(title))&body=\(encode(body))&labels=crash"
        return URL(string: url) ?? URL(string: issuesURL)!
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

@MainActor
public final class CrashReporter {
    public static let shared = CrashReporter()

    public var directory: URL
    public var preferences: UpdatePreferences
    public var openURL: (URL) -> Void
    public var present: (CrashReport, CrashIssue) async -> Bool
    public var appVersion: () -> String
    public var buildNumber: () -> String?
    public var osVersion: () -> String

    public init(
        directory: URL = CrashDiscovery.defaultDirectory(),
        preferences: UpdatePreferences = UpdatePreferences(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        present: ((CrashReport, CrashIssue) async -> Bool)? = nil,
        appVersion: @escaping () -> String = { UpdateCheckerConfiguration.bundleVersion() },
        buildNumber: @escaping () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String },
        osVersion: @escaping () -> String = { ProcessInfo.processInfo.operatingSystemVersionString }
    ) {
        self.directory = directory
        self.preferences = preferences
        self.openURL = openURL
        self.present = present ?? CrashReporter.defaultPresent
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
    }

    public var isEnabled: Bool {
        get { preferences.crashReportsEnabled }
        set { preferences.crashReportsEnabled = newValue }
    }

    public func checkOnLaunch(delay: TimeInterval = 2) {
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await self.checkNow()
        }
    }

    @discardableResult
    public func checkNow() async -> CrashReport? {
        guard preferences.crashReportsEnabled else { return nil }
        guard let baseline = preferences.lastSeenCrash else {
            let existing = CrashDiscovery.find(in: directory, newerThan: nil)
            preferences.lastSeenCrash = existing.map(\.modified).max() ?? Date()
            return nil
        }
        let reports = CrashDiscovery.find(in: directory, newerThan: baseline)
        guard let newest = reports.first else { return nil }
        preferences.lastSeenCrash = newest.modified
        let text = Self.readHead(of: newest.url)
        let issue = CrashIssueBuilder.build(
            report: newest,
            crashText: text,
            appVersion: appVersion(),
            buildNumber: buildNumber(),
            osVersion: osVersion()
        )
        if await present(newest, issue) { openURL(issue.url) }
        return newest
    }

    static func readHead(of url: URL, limit: Int = 512 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func defaultPresent(_ report: CrashReport, _ issue: CrashIssue) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "betterfinder crashed last time"
        alert.informativeText = "Send a crash report? This opens a prefilled GitHub issue in your browser so you can read and edit it first. Your home folder is shown as ~. Nothing is sent unless you submit it there."
        alert.addButton(withTitle: "Send Report…")
        alert.addButton(withTitle: "Don't Send")
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
