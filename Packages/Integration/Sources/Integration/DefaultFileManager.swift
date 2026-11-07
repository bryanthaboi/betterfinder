import AppKit
import Foundation
import UniformTypeIdentifiers

public enum DefaultFileManager {
    public struct Status: Sendable, Hashable {
        public var isFileViewer: Bool
        public var isFolderHandler: Bool
        public var fileViewerValue: String?
        public var folderHandlerBundleID: String?
        public var hasRestorePoint: Bool
        public var isFullyDefault: Bool { isFileViewer && isFolderHandler }

        public init(
            isFileViewer: Bool,
            isFolderHandler: Bool,
            fileViewerValue: String? = nil,
            folderHandlerBundleID: String? = nil,
            hasRestorePoint: Bool = false
        ) {
            self.isFileViewer = isFileViewer
            self.isFolderHandler = isFolderHandler
            self.fileViewerValue = fileViewerValue
            self.folderHandlerBundleID = folderHandlerBundleID
            self.hasRestorePoint = hasRestorePoint
        }
    }

    public static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.bryanthaboi.betterfinder" }

    public static let controller = DefaultFileManagerController()

    public static func status() -> Status { controller.status() }

    @discardableResult
    public static func makeDefault() async throws -> DefaultFileManagerController.Report {
        try await controller.makeDefault()
    }

    @discardableResult
    public static func restoreFinder() async throws -> DefaultFileManagerController.Report {
        try await controller.restoreFinder()
    }

    static func setGlobalFileViewer(_ value: String?) {
        controller.preferences.setValue(value, forKey: DefaultFileManagerController.fileViewerKey, in: .global)
    }
}

public final class DefaultFileManagerController {
    public struct Report: Sendable, Equatable {
        public var warnings: [String]
        public init(warnings: [String] = []) { self.warnings = warnings }
    }

    public static let fileViewerKey = "NSFileViewer"
    public static let finderBundleID = "com.apple.finder"

    struct HandledType {
        var type: UTType
        var required: Bool
        var name: String
    }

    static var handledTypes: [HandledType] {
        var list = [
            HandledType(type: .folder, required: true, name: "public.folder"),
            HandledType(type: .directory, required: false, name: "public.directory"),
        ]
        if let mount = UTType("com.apple.mount-point") {
            list.append(HandledType(type: mount, required: false, name: "com.apple.mount-point"))
        }
        return list
    }

    public let bundleID: String
    public let appURL: URL
    public let preferences: PreferencesWriter
    public let handlers: FolderHandlerService
    let store: PreviousValueStore

    public init(
        bundleID: String? = nil,
        appURL: URL? = nil,
        preferences: PreferencesWriter = SystemPreferencesWriter(),
        handlers: FolderHandlerService = WorkspaceFolderHandlerService(),
        defaults: UserDefaults = .standard
    ) {
        self.bundleID = bundleID ?? Bundle.main.bundleIdentifier ?? "com.bryanthaboi.betterfinder"
        self.appURL = appURL ?? Bundle.main.bundleURL
        self.preferences = preferences
        self.handlers = handlers
        self.store = PreviousValueStore(defaults: defaults, prefix: "Integration.previous")
    }

    private static let viewerRecord = "NSFileViewer"

    private func handlerRecord(_ t: HandledType) -> String { "handler.\(t.name)" }

    private var currentViewer: String? {
        preferences.value(forKey: Self.fileViewerKey, in: .global) as? String
    }

    public func status() -> DefaultFileManager.Status {
        let viewer = currentViewer
        let handler = handlers.handlerBundleID(for: .folder)
        return DefaultFileManager.Status(
            isFileViewer: viewer == bundleID,
            isFolderHandler: handler == bundleID,
            fileViewerValue: viewer,
            folderHandlerBundleID: handler,
            hasRestorePoint: store.get(Self.viewerRecord) != nil || Self.handledTypes.contains { store.get(handlerRecord($0)) != nil }
        )
    }

    @discardableResult
    public func makeDefault() async throws -> Report {
        let names = [Self.viewerRecord] + Self.handledTypes.map(handlerRecord)
        let snapshot = Dictionary(uniqueKeysWithValues: names.map { ($0, store.raw($0)) })

        let viewer = currentViewer
        if viewer != bundleID { store.record(Self.viewerRecord, value: viewer) }
        for t in Self.handledTypes {
            let previous = handlers.handlerBundleID(for: t.type)
            if previous != bundleID { store.record(handlerRecord(t), value: previous) }
        }

        var report = Report()
        do {
            for t in Self.handledTypes {
                do {
                    try await handlers.setHandler(bundleID: bundleID, appURL: appURL, for: t.type)
                } catch {
                    if t.required {
                        throw IntegrationError.handlerChangeFailed(type: t.name, reason: error.localizedDescription)
                    }
                    report.warnings.append("\(t.name): \(error.localizedDescription)")
                }
            }
        } catch {
            for (name, raw) in snapshot { store.setRaw(name, raw) }
            throw error
        }
        preferences.setValue(bundleID, forKey: Self.fileViewerKey, in: .global)
        return report
    }

    @discardableResult
    public func restoreFinder() async throws -> Report {
        var report = Report()

        if let record = store.get(Self.viewerRecord) {
            preferences.setValue(record.present ? record.value : nil, forKey: Self.fileViewerKey, in: .global)
            store.clear(Self.viewerRecord)
        } else if currentViewer == bundleID {
            preferences.setValue(nil, forKey: Self.fileViewerKey, in: .global)
        }

        for t in Self.handledTypes {
            let record = store.get(handlerRecord(t))
            let current = handlers.handlerBundleID(for: t.type)
            var target: String?
            var fallback = false
            if let record, record.present, let id = record.value as? String {
                target = id
            } else if current == bundleID || (t.type == .folder && record != nil) {
                target = Self.finderBundleID
                fallback = !t.required
            }
            guard let target, current != target else {
                store.clear(handlerRecord(t))
                continue
            }
            do {
                try await handlers.setHandler(bundleID: target, appURL: nil, for: t.type)
                store.clear(handlerRecord(t))
                if fallback { report.warnings.append("\(t.name): no previous handler was recorded, so Finder now handles it") }
            } catch {
                if target != Self.finderBundleID, t.required {
                    do {
                        try await handlers.setHandler(bundleID: Self.finderBundleID, appURL: nil, for: t.type)
                        store.clear(handlerRecord(t))
                        report.warnings.append("\(t.name): previous handler \(target) unavailable, restored Finder instead")
                        continue
                    } catch {}
                }
                if t.required {
                    throw IntegrationError.handlerChangeFailed(type: t.name, reason: error.localizedDescription)
                }
                if record == nil { store.record(handlerRecord(t), value: nil) }
                report.warnings.append("\(t.name) couldn't be restored: \(error.localizedDescription). Try Restore again.")
            }
        }
        return report
    }
}

public enum IncomingOpenRequest: Equatable, Sendable {
    case openFolder(URL)
    case reveal(URL)

    public static func classify(_ url: URL) -> IncomingOpenRequest {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if v?.isDirectory == true && v?.isPackage != true { return .openFolder(url) }
        return .reveal(url)
    }
}
