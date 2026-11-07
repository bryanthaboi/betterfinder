import AppKit
import Browser
import FSCore
import Foundation
import ModHost
import ModKit

final class ModColumnAdapter: ColumnProvider, @unchecked Sendable {
    let provider: ModColumnValuesProviding
    let valueType: ColumnValueType

    init(provider: ModColumnValuesProviding, valueType: ColumnValueType) {
        self.provider = provider
        self.valueType = valueType
    }

    static let maxDateSeconds: Double = 253_402_300_799

    static func bytes(_ n: Double) -> Int64? {
        guard n.isFinite, n >= 0 else { return nil }
        return Int64(exactly: n.rounded(.towardZero))
    }

    static func date(_ n: Double) -> Date? {
        guard n.isFinite, abs(n) <= maxDateSeconds else { return nil }
        return Date(timeIntervalSince1970: n)
    }

    static func value(_ c: ModCellValue, type: ColumnValueType) -> ColumnValue {
        let base = baseValue(c, type: type)
        guard let label = ModHost.ModUINode.normalizedLabel(c.accessibilityLabel) else { return base }
        return .described(base, accessibility: String(label.prefix(ModCellValue.maxAccessibilityLabelLength)))
    }

    static func baseValue(_ c: ModCellValue, type: ColumnValueType) -> ColumnValue {
        let number = c.number.flatMap { $0.isFinite ? $0 : nil }
        switch type {
        case .string:
            if let t = c.text { return .string(t) }
            return number.map { .number($0) } ?? .none
        case .number:
            if let n = number { return .number(n) }
            return c.text.map { .string($0) } ?? .none
        case .bytes:
            if let n = number { return bytes(n).map { .bytes($0) } ?? .none }
            if let t = c.text, let n = Int64(t) { return n >= 0 ? .bytes(n) : .none }
            return c.text.map { .string($0) } ?? .none
        case .date:
            if let n = number { return date(n).map { .date($0) } ?? .none }
            if let t = c.text, let d = ISO8601DateFormatter().date(from: t) { return .date(d) }
            return c.text.map { .string($0) } ?? .none
        case .boolean:
            if let t = c.text { return .string(t) }
            return number.map { .string($0 != 0 ? "Yes" : "No") } ?? .none
        }
    }

    func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue] {
        try await values(for: items, revision: context.generation)
    }

    func values(for items: [FileItem], revision: Int) async throws -> [URL: ColumnValue] {
        let urls = items.map(\.url)
        let cells = try await provider.values(for: urls, revision: revision)
        var out = [URL: ColumnValue]()
        for (url, cell) in cells { out[url] = Self.value(cell, type: valueType) }
        return out
    }
}

final class ModPreviewAdapter: PreviewProvider, @unchecked Sendable {
    let provider: ModPreviewProviding
    let environment: ModEnvironmentState
    let resolve: @Sendable (ModCommandReference) -> String

    init(provider: ModPreviewProviding, environment: ModEnvironmentState, resolve: @escaping @Sendable (ModCommandReference) -> String) {
        self.provider = provider
        self.environment = environment
        self.resolve = resolve
    }

    func render(_ item: FileItem, context: PreviewContext) async throws -> PreviewContent {
        try await render(item)
    }

    func render(_ item: FileItem) async throws -> PreviewContent {
        let content = try await provider.render(item.url, maxBytes: 512 * 1024, dark: environment.dark)
        if content.node.kind == .markdown { return .text(ModUIConversion.markdownText(content.node.text ?? "")) }
        let resolve = resolve
        let converted = await MainActor.run { ModUIConversion.convert(content.node, commandResolver: resolve) }
        if let issue = converted.issues.first { throw ModPreviewAccessibilityError(issue: issue) }
        return .native(converted.node)
    }
}

struct ModPreviewAccessibilityError: LocalizedError, Equatable {
    var issue: String
    var errorDescription: String? { "The preview wasn’t shown because a control has no accessible name (\(issue))." }
}

final class ModLocationAdapter: LocationProvider, @unchecked Sendable {
    let providerID: String
    let root: ProvidedLocation
    let provider: ModLocationProviding
    let readOnly: Bool
    static let maxPages = 8
    private let lock = NSLock()
    private var parents: [String: ProvidedLocation] = [:]

    init(providerID: String, root: ProvidedLocation, provider: ModLocationProviding, readOnly: Bool) {
        self.providerID = providerID
        self.root = root
        self.provider = provider
        self.readOnly = readOnly
    }

    var capabilities: LocationCapabilities { readOnly ? [.list, .read] : [.list, .read, .write] }

    func list(_ location: ProvidedLocation, context: LocationContext) async throws -> [ProvidedItem] {
        try await listAll(location)
    }

    func listAll(_ location: ProvidedLocation) async throws -> [ProvidedItem] {
        var out = [ProvidedItem]()
        var cursor: String?
        var children = [String: ProvidedLocation]()
        for _ in 0..<Self.maxPages {
            try Task.checkCancellation()
            let page = try await provider.list(path: location.id, limit: 128, cursor: cursor)
            for e in page.items {
                let container = e.kind == "folder"
                let child = container ? ProvidedLocation(providerID: providerID, id: e.id, title: e.name, symbolName: "folder") : nil
                if let child { children[child.id] = location }
                out.append(ProvidedItem(id: e.id, name: e.name, isContainer: container, symbolName: container ? "folder" : "doc", size: e.size, modified: e.modified, child: child))
            }
            cursor = page.cursor
            if cursor == nil { break }
        }
        lock.withLock { for (k, v) in children { parents[k] = v } }
        return out
    }

    func parent(of location: ProvidedLocation) -> ProvidedLocation? {
        if location.id.isEmpty { return nil }
        return lock.withLock { parents[location.id] } ?? root
    }
}

final class ModSearchAdapter: SearchProvider, @unchecked Sendable {
    let provider: ModSearchProviding

    init(provider: ModSearchProviding) { self.provider = provider }

    func search(_ query: String, context: SearchContext) -> AsyncThrowingStream<SearchBatch, Error> {
        let inner = provider.search(query, scope: context.location.scopeURL, limit: 128)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await batch in inner {
                        let results = batch.results.map { h in
                            SearchResult(id: h.id, title: h.title, subtitle: h.subtitle, symbolName: h.url == nil ? "puzzlepiece.extension" : nil, fileURL: h.url)
                        }
                        continuation.yield(SearchBatch(results: results))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
enum ModLocationView {
    static func build(_ ctx: BrowserViewContext, registries: BrowserRegistries, layout: ViewLayout) {
        guard let provided = ctx.destination.providedLocation, let provider = registries.locations.provider(for: provided.providerID) as? ModLocationAdapter else { return }
        ctx.setContent(.progress(id: "loading", value: nil, caption: "Loading…", accessibilityLabel: "Loading"))
        let task = Task { @MainActor [weak ctx] in
            guard let items = try? await provider.listAll(provided), let ctx, !ctx.isDisposed else { return }
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            ctx.onEvent = { [weak ctx] event in
                guard case .activated(let id) = event.kind, let child = byID[id]?.child else { return }
                ctx?.navigate(to: child)
            }
            switch layout {
            case .grid:
                ctx.setContent(.list(id: "items", items: items.map { Browser.ModUIListItem(id: $0.id, title: $0.name, subtitle: $0.detail, symbolName: $0.symbolName) }, accessibilityLabel: provided.title))
            case .list, .columns:
                let f = ByteCountFormatter()
                let d = DateFormatter()
                d.dateStyle = .medium
                d.timeStyle = .short
                let rows = items.map { i in
                    ModUITableRow(id: i.id, cells: [
                        "name": i.name, "kind": i.isContainer ? "Folder" : "File",
                        "size": i.size.map { f.string(fromByteCount: $0) } ?? "--", "modified": i.modified.map { d.string(from: $0) } ?? "--",
                    ], symbolName: i.symbolName)
                }
                let columns = [
                    ModUITableColumn(id: "name", title: "Name", width: 260), ModUITableColumn(id: "kind", title: "Kind", width: 80),
                    ModUITableColumn(id: "size", title: "Size", width: 90, isRightAligned: true), ModUITableColumn(id: "modified", title: "Date Modified", width: 160),
                ]
                ctx.setContent(.table(id: "items", columns: columns, rows: rows, accessibilityLabel: provided.title))
            }
        }
        ctx.onDispose { task.cancel() }
    }
}
