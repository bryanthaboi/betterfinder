import Foundation
import ModKit

public struct ModContributionID: Hashable, Sendable, CustomStringConvertible {
    public var modId: String
    public var localId: String
    public init(modId: String, localId: String) { self.modId = modId; self.localId = localId }
    public var qualified: String { "\(modId)/\(localId)" }
    public var description: String { qualified }

    public init?(qualified: String) {
        guard let slash = qualified.lastIndex(of: "/") else { return nil }
        modId = String(qualified[..<slash])
        localId = String(qualified[qualified.index(after: slash)...])
    }
}

public struct ModCommandReference: Hashable, Sendable {
    public var raw: String
    public var owner: String

    public init(raw: String, owner: String) { self.raw = raw; self.owner = owner }

    public var isBuiltIn: Bool { raw.hasPrefix("builtin.") }
    public var qualified: String { isBuiltIn ? raw : "\(owner)/\(raw)" }
}

public struct ModUIListItem: Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public init(id: String, title: String, subtitle: String? = nil) { self.id = id; self.title = title; self.subtitle = subtitle }
}

public struct ModUINode: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case vstack, hstack, text, markdown, button, list, progress, divider, textField, select, icon, spacer, card }
    public enum TextStyle: String, Sendable, CaseIterable { case body, title, secondary, monospaced }
    public enum ColorRole: String, Sendable, CaseIterable { case primary, secondary, accent, success, warning, danger }
    public enum Weight: String, Sendable, CaseIterable { case regular, medium, semibold, bold }
    public enum Alignment: String, Sendable, CaseIterable { case leading, center, trailing }
    public var kind: Kind
    public var id: String?
    public var text: String?
    public var accessibilityLabel: String?
    public var command: ModCommandReference?
    public var value: Double?
    public var children: [ModUINode]
    public var items: [ModUIListItem]
    public var placeholder: String?
    public var style: TextStyle?
    public var symbolName: String?
    public var selectedID: String?
    public var color: ColorRole?
    public var size: Double?
    public var weight: Weight?
    public var alignment: Alignment?
    public var spacing: Double?
    public var padding: Double?
    public var tinted = false

    public init(
        kind: Kind, id: String? = nil, text: String? = nil, accessibilityLabel: String? = nil, command: ModCommandReference? = nil,
        value: Double? = nil, children: [ModUINode] = [], items: [ModUIListItem] = [], placeholder: String? = nil,
        style: TextStyle? = nil, symbolName: String? = nil, selectedID: String? = nil
    ) {
        self.kind = kind; self.id = id; self.text = text; self.accessibilityLabel = accessibilityLabel; self.command = command
        self.value = value; self.children = children; self.items = items; self.placeholder = placeholder
        self.style = style; self.symbolName = symbolName; self.selectedID = selectedID
    }

    public static let maxNodes = 2048

    static func decode(_ v: JSONValue, owner: String, budget: inout Int) -> ModUINode? {
        guard budget > 0, case .object(let o) = v, let kindRaw = o["type"]?.stringValue, let kind = Kind(rawValue: kindRaw) else { return nil }
        budget -= 1
        var children = [ModUINode]()
        for c in o["children"]?.arrayValue ?? [] {
            guard let n = decode(c, owner: owner, budget: &budget) else { return nil }
            children.append(n)
        }
        let items = (o["items"]?.arrayValue ?? []).compactMap { i -> ModUIListItem? in
            guard let id = i["id"]?.stringValue, let title = i["title"]?.stringValue else { return nil }
            return ModUIListItem(id: id, title: title, subtitle: i["subtitle"]?.stringValue)
        }
        var node = ModUINode(
            kind: kind, id: o["id"]?.stringValue, text: o["text"]?.stringValue, accessibilityLabel: normalizedLabel(o["label"]?.stringValue),
            command: o["command"]?.stringValue.map { ModCommandReference(raw: $0, owner: owner) }, value: o["value"]?.numberValue.flatMap { $0.isFinite ? $0 : nil },
            children: children, items: items, placeholder: normalizedLabel(o["placeholder"]?.stringValue).map { String($0.prefix(256)) },
            style: o["style"]?.stringValue.flatMap(TextStyle.init(rawValue:)), symbolName: o["icon"]?.stringValue.flatMap(symbol),
            selectedID: o["selected"]?.stringValue
        )
        node.color = o["color"]?.stringValue.flatMap(ColorRole.init(rawValue:))
        node.size = o["size"]?.numberValue.flatMap { $0.isFinite ? min(max($0, 8), 96) : nil }
        node.weight = o["weight"]?.stringValue.flatMap(Weight.init(rawValue:))
        node.alignment = o["align"]?.stringValue.flatMap(Alignment.init(rawValue:))
        node.spacing = o["spacing"]?.numberValue.flatMap { $0.isFinite ? min(max($0, 0), 64) : nil }
        node.padding = o["padding"]?.numberValue.flatMap { $0.isFinite ? min(max($0, 0), 64) : nil }
        node.tinted = o["tinted"]?.boolValue ?? false
        return node
    }

    static func symbol(_ raw: String) -> String? {
        guard (1...64).contains(raw.utf8.count), raw.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") }) else { return nil }
        return raw
    }

    public static func normalizedLabel(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    public static func from(_ v: JSONValue, owner: String) -> ModUINode? {
        var budget = maxNodes
        return decode(v, owner: owner, budget: &budget)
    }
}

public struct ModCellValue: Hashable, Sendable {
    public var text: String?
    public var number: Double?
    public var sortKey: String?
    public var accessibilityLabel: String?
    public init(text: String? = nil, number: Double? = nil, sortKey: String? = nil) { self.text = text; self.number = number; self.sortKey = sortKey }
    public init(text: String? = nil, number: Double? = nil, sortKey: String? = nil, accessibilityLabel: String?) {
        self.init(text: text, number: number, sortKey: sortKey)
        self.accessibilityLabel = ModUINode.normalizedLabel(accessibilityLabel).map { String($0.prefix(Self.maxAccessibilityLabelLength)) }
    }

    public static let maxAccessibilityLabelLength = 512

    public static func from(_ v: JSONValue) -> ModCellValue {
        ModCellValue(
            text: v["text"]?.stringValue, number: v["number"]?.numberValue.flatMap { $0.isFinite ? $0 : nil }, sortKey: v["sortKey"]?.stringValue,
            accessibilityLabel: v["label"]?.stringValue
        )
    }
}

public struct ModPreviewContent: Hashable, Sendable {
    public var title: String?
    public var node: ModUINode
    public init(title: String? = nil, node: ModUINode) { self.title = title; self.node = node }
}

public struct ModResourceEntry: Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var size: Int64?
    public var modified: Date?
    public init(id: String, name: String, kind: String, size: Int64? = nil, modified: Date? = nil) { self.id = id; self.name = name; self.kind = kind; self.size = size; self.modified = modified }
}

public struct ModLocationPage: Hashable, Sendable {
    public var items: [ModResourceEntry]
    public var cursor: String?
    public init(items: [ModResourceEntry], cursor: String? = nil) { self.items = items; self.cursor = cursor }
}

public struct ModSearchHit: Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var url: URL?
    public init(id: String, title: String, subtitle: String? = nil, url: URL? = nil) { self.id = id; self.title = title; self.subtitle = subtitle; self.url = url }
}

public struct ModSearchBatch: Hashable, Sendable {
    public var results: [ModSearchHit]
    public var done: Bool
    public var cursor: String?
    public init(results: [ModSearchHit], done: Bool, cursor: String? = nil) { self.results = results; self.done = done; self.cursor = cursor }
}

public struct ModCommandOutcome: Hashable, Sendable {
    public var message: String?
    public var operationId: String?
    public init(message: String? = nil, operationId: String? = nil) { self.message = message; self.operationId = operationId }
}

public struct ModToolbarContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var symbolName: String?
    public var command: ModCommandReference
    public var replaces: String?
    public init(id: ModContributionID, title: String, symbolName: String? = nil, command: ModCommandReference, replaces: String? = nil) { self.id = id; self.title = title; self.symbolName = symbolName; self.command = command; self.replaces = replaces }
}

public struct ModSidebarContribution: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public var id: String
        public var title: String
        public var symbolName: String?
        public var knownFolder: KnownFolder?
        public var location: ModContributionID?
        public init(id: String, title: String, symbolName: String? = nil, knownFolder: KnownFolder? = nil, location: ModContributionID? = nil) { self.id = id; self.title = title; self.symbolName = symbolName; self.knownFolder = knownFolder; self.location = location }
    }
    public var id: ModContributionID
    public var title: String
    public var symbolName: String?
    public var items: [Item]
    public var replaces: String?
    public init(id: ModContributionID, title: String, symbolName: String? = nil, items: [Item], replaces: String? = nil) { self.id = id; self.title = title; self.symbolName = symbolName; self.items = items; self.replaces = replaces }
}

public struct ModContextMenuContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var command: ModCommandReference
    public var target: MenuTarget
    public var replaces: String?
    public init(id: ModContributionID, title: String, command: ModCommandReference, target: MenuTarget, replaces: String? = nil) { self.id = id; self.title = title; self.command = command; self.target = target; self.replaces = replaces }
}

public struct ModColumnContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var valueType: ColumnValueType
    public var width: Int?
    public var sortable: Bool
    public var replaces: String?
    public init(id: ModContributionID, title: String, valueType: ColumnValueType, width: Int? = nil, sortable: Bool, replaces: String? = nil) { self.id = id; self.title = title; self.valueType = valueType; self.width = width; self.sortable = sortable; self.replaces = replaces }
}

public struct ModStatusBarContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var alignment: StatusAlignment
    public var command: ModCommandReference?
    public var replaces: String?
    public var panel: ModContributionID?
    public init(id: ModContributionID, title: String, alignment: StatusAlignment, command: ModCommandReference? = nil, replaces: String? = nil, panel: ModContributionID? = nil) { self.id = id; self.title = title; self.alignment = alignment; self.command = command; self.replaces = replaces; self.panel = panel }
}

public struct ModPanelContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var edge: PanelEdge
    public var presentation: PanelPresentation
    public var symbolName: String?
    public init(id: ModContributionID, title: String, edge: PanelEdge, presentation: PanelPresentation, symbolName: String? = nil) { self.id = id; self.title = title; self.edge = edge; self.presentation = presentation; self.symbolName = symbolName }
}

public struct ModPreviewContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var extensions: [String]
    public var replaces: String?
    public init(id: ModContributionID, title: String, extensions: [String], replaces: String? = nil) { self.id = id; self.title = title; self.extensions = extensions; self.replaces = replaces }
}

public struct ModViewContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var layout: ViewLayout
    public var columns: [ModContributionID]
    public var symbolName: String?
    public var replaces: String?
    public init(id: ModContributionID, title: String, layout: ViewLayout, columns: [ModContributionID], symbolName: String? = nil, replaces: String? = nil) { self.id = id; self.title = title; self.layout = layout; self.columns = columns; self.symbolName = symbolName; self.replaces = replaces }
}

public struct ModLocationContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var scheme: String
    public var readOnly: Bool
    public var symbolName: String?
    public init(id: ModContributionID, title: String, scheme: String, readOnly: Bool, symbolName: String? = nil) { self.id = id; self.title = title; self.scheme = scheme; self.readOnly = readOnly; self.symbolName = symbolName }
}

public struct ModSearchProviderContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var symbolName: String?
    public init(id: ModContributionID, title: String, symbolName: String? = nil) { self.id = id; self.title = title; self.symbolName = symbolName }
}

public struct ModCommandContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var title: String
    public var category: String?
    public var symbolName: String?
    public init(id: ModContributionID, title: String, category: String? = nil, symbolName: String? = nil) { self.id = id; self.title = title; self.category = category; self.symbolName = symbolName }
}

public struct ModKeybindingContribution: Sendable, Hashable {
    public var id: ModContributionID
    public var chord: String
    public var command: ModCommandReference
    public init(id: ModContributionID, chord: String, command: ModCommandReference) { self.id = id; self.chord = chord; self.command = command }
}

public protocol ModColumnValuesProviding: AnyObject, Sendable {
    func values(for items: [URL], revision: Int) async throws -> [URL: ModCellValue]
}

public protocol ModPreviewProviding: AnyObject, Sendable {
    func render(_ item: URL, maxBytes: Int, dark: Bool) async throws -> ModPreviewContent
}

public protocol ModLocationProviding: AnyObject, Sendable {
    func list(path: String, limit: Int, cursor: String?) async throws -> ModLocationPage
}

public protocol ModSearchProviding: AnyObject, Sendable {
    func search(_ query: String, scope: URL?, limit: Int) -> AsyncThrowingStream<ModSearchBatch, Error>
}

public protocol ModCommandRunning: AnyObject, Sendable {
    func run(selection: [URL], args: JSONValue?) async throws -> ModCommandOutcome
}

public enum ModUIUpdate: Sendable, Hashable {
    case panelContent(panel: ModContributionID, node: ModUINode)
    case statusText(item: ModContributionID, text: String)
    case toolbarItemState(item: ModContributionID, enabled: Bool, title: String?)
    case commandEnabled(command: ModContributionID, enabled: Bool)
    case notify(modId: String, message: String, level: String)
    case openLocation(location: ModContributionID, path: String)
    case refreshLocation(location: ModContributionID)
    case refreshPreview(provider: ModContributionID, item: URL)
    case invalidatePreviews(provider: ModContributionID)
    case showPanel(panel: ModContributionID)

    var stagingOwner: String? {
        switch self {
        case .panelContent(let id, _), .statusText(let id, _), .toolbarItemState(let id, _, _), .commandEnabled(let id, _): return id.modId
        case .notify, .openLocation, .refreshLocation, .refreshPreview, .invalidatePreviews, .showPanel: return nil
        }
    }
}

public final class ModRegistrationToken: @unchecked Sendable, Hashable {
    public let id = UUID()
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(onCancel: (@Sendable () -> Void)? = nil) { self.onCancel = onCancel }

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return onCancel != nil }

    public func cancel() {
        lock.lock()
        let c = onCancel
        onCancel = nil
        lock.unlock()
        c?()
    }

    public static func == (a: ModRegistrationToken, b: ModRegistrationToken) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
public protocol ModUIRegistrySink: AnyObject {
    func registerToolbarItem(_ item: ModToolbarContribution, owner: String) throws -> ModRegistrationToken
    func registerSidebarSection(_ section: ModSidebarContribution, owner: String) throws -> ModRegistrationToken
    func registerContextMenuItem(_ item: ModContextMenuContribution, owner: String) throws -> ModRegistrationToken
    func registerColumn(_ column: ModColumnContribution, provider: ModColumnValuesProviding, owner: String) throws -> ModRegistrationToken
    func registerStatusBarItem(_ item: ModStatusBarContribution, owner: String) throws -> ModRegistrationToken
    func registerPanel(_ panel: ModPanelContribution, owner: String) throws -> ModRegistrationToken
    func registerPreview(_ preview: ModPreviewContribution, provider: ModPreviewProviding, owner: String) throws -> ModRegistrationToken
    func registerView(_ view: ModViewContribution, owner: String) throws -> ModRegistrationToken
    func registerLocation(_ location: ModLocationContribution, provider: ModLocationProviding, owner: String) throws -> ModRegistrationToken
    func registerSearchProvider(_ provider: ModSearchProviderContribution, search: ModSearchProviding, owner: String) throws -> ModRegistrationToken
    func registerCommand(_ command: ModCommandContribution, runner: ModCommandRunning, owner: String) throws -> ModRegistrationToken
    func registerKeybinding(_ binding: ModKeybindingContribution, owner: String) throws -> ModRegistrationToken
    func apply(_ update: ModUIUpdate)
}

@MainActor
public final class ModRecordingSink: ModUIRegistrySink {
    public enum Kind: String, Sendable { case toolbar, sidebar, contextMenu, column, statusBar, panel, preview, view, location, search, command, keybinding }

    public struct Entry {
        public var kind: Kind
        public var id: ModContributionID
        public var owner: String
        public var token: ModRegistrationToken
        public var column: ModColumnValuesProviding?
        public var preview: ModPreviewProviding?
        public var location: ModLocationProviding?
        public var search: ModSearchProviding?
        public var command: ModCommandRunning?
    }

    public private(set) var entries: [Entry] = []
    public private(set) var updates: [ModUIUpdate] = []
    public var failOn: Set<String> = []

    public init() {}

    public func ids(owner: String? = nil, kind: Kind? = nil) -> [String] {
        entries.filter { (owner == nil || $0.owner == owner) && (kind == nil || $0.kind == kind) }.map(\.id.qualified).sorted()
    }

    public func entry(_ qualified: String) -> Entry? { entries.first { $0.id.qualified == qualified } }

    private func add(_ kind: Kind, _ id: ModContributionID, _ owner: String, configure: (inout Entry) -> Void = { _ in }) throws -> ModRegistrationToken {
        if failOn.contains(id.qualified) { throw ModRegistrationError.rejected(id.qualified) }
        guard !entries.contains(where: { $0.id == id && $0.kind == kind }) else { throw ModRegistrationError.duplicate(id.qualified) }
        let token = ModRegistrationToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.entries.removeAll { $0.id == id && $0.kind == kind } }
            } else {
                Task { @MainActor in self?.entries.removeAll { $0.id == id && $0.kind == kind } }
            }
        }
        var e = Entry(kind: kind, id: id, owner: owner, token: token)
        configure(&e)
        entries.append(e)
        return token
    }

    public func removeNow(_ token: ModRegistrationToken) {
        entries.removeAll { $0.token == token }
        token.cancel()
    }

    public func registerToolbarItem(_ item: ModToolbarContribution, owner: String) throws -> ModRegistrationToken { try add(.toolbar, item.id, owner) }
    public func registerSidebarSection(_ section: ModSidebarContribution, owner: String) throws -> ModRegistrationToken { try add(.sidebar, section.id, owner) }
    public func registerContextMenuItem(_ item: ModContextMenuContribution, owner: String) throws -> ModRegistrationToken { try add(.contextMenu, item.id, owner) }
    public func registerColumn(_ column: ModColumnContribution, provider: ModColumnValuesProviding, owner: String) throws -> ModRegistrationToken {
        try add(.column, column.id, owner) { $0.column = provider }
    }
    public func registerStatusBarItem(_ item: ModStatusBarContribution, owner: String) throws -> ModRegistrationToken { try add(.statusBar, item.id, owner) }
    public func registerPanel(_ panel: ModPanelContribution, owner: String) throws -> ModRegistrationToken { try add(.panel, panel.id, owner) }
    public func registerPreview(_ preview: ModPreviewContribution, provider: ModPreviewProviding, owner: String) throws -> ModRegistrationToken {
        try add(.preview, preview.id, owner) { $0.preview = provider }
    }
    public func registerView(_ view: ModViewContribution, owner: String) throws -> ModRegistrationToken { try add(.view, view.id, owner) }
    public func registerLocation(_ location: ModLocationContribution, provider: ModLocationProviding, owner: String) throws -> ModRegistrationToken {
        try add(.location, location.id, owner) { $0.location = provider }
    }
    public func registerSearchProvider(_ provider: ModSearchProviderContribution, search: ModSearchProviding, owner: String) throws -> ModRegistrationToken {
        try add(.search, provider.id, owner) { $0.search = search }
    }
    public func registerCommand(_ command: ModCommandContribution, runner: ModCommandRunning, owner: String) throws -> ModRegistrationToken {
        try add(.command, command.id, owner) { $0.command = runner }
    }
    public func registerKeybinding(_ binding: ModKeybindingContribution, owner: String) throws -> ModRegistrationToken { try add(.keybinding, binding.id, owner) }
    public func apply(_ update: ModUIUpdate) { updates.append(update) }
}

public enum ModRegistrationError: LocalizedError, Equatable {
    case duplicate(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let id): return "\(id) is already registered"
        case .rejected(let id): return "\(id) was rejected by the registry"
        }
    }
}
