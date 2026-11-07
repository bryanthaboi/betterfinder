import Foundation

public enum ModRuntime: String, Codable, CaseIterable, Sendable {
    case data = "data/1"
    case jscIR = "jsc-ir/1"
    case js = "js/1"
    case ts = "ts/1"

    public var allowedEntryExtensions: [String] {
        switch self {
        case .data: return []
        case .jscIR: return [".bfscript.json"]
        case .js: return [".js", ".mjs"]
        case .ts: return [".ts"]
        }
    }

    public var requiresEntry: Bool { self != .data }
}

public enum ModSurface: String, Codable, CaseIterable, Sendable {
    case toolbar, sidebar, contextMenu, column, statusBar, panel, preview, view, location, search
}

public enum FSScope: String, Codable, CaseIterable, Sendable { case selection, root, destination }
public enum ProcessMode: String, Codable, CaseIterable, Sendable { case broker, unrestricted }
public enum SelectionLevel: String, Codable, CaseIterable, Sendable { case names, paths, metadata }
public enum HTTPMethod: String, Codable, CaseIterable, Sendable { case GET, HEAD, POST, PUT, PATCH, DELETE }
public enum NetScheme: String, Codable, CaseIterable, Sendable { case https, http }
public enum KnownFolder: String, Codable, CaseIterable, Sendable { case home, desktop, documents, downloads, applications, pictures, movies, music }
public enum ColumnValueType: String, Codable, CaseIterable, Sendable { case string, number, bytes, date, boolean }
public enum MenuTarget: String, Codable, CaseIterable, Sendable { case items, background }
public enum PanelEdge: String, Codable, CaseIterable, Sendable { case left, right, bottom }
public enum PanelPresentation: String, Codable, CaseIterable, Sendable { case docked, slideOut }
public enum ViewLayout: String, Codable, CaseIterable, Sendable { case list, grid, columns }
public enum ThemeAppearance: String, Codable, CaseIterable, Sendable { case light, dark, any }
public enum StatusAlignment: String, Codable, CaseIterable, Sendable { case leading, trailing }
public enum SettingType: String, Codable, CaseIterable, Sendable { case boolean, integer, number, string, `enum` }

public enum FileOperationName: String, Codable, CaseIterable, Sendable { case copy, move, trash, rename }

public enum ModPermissionKind: String, Codable, CaseIterable, Sendable {
    case fsRead = "fs.read"
    case fsWrite = "fs.write"
    case net
    case processExec = "process.exec"
    case ui
    case uiOverride = "ui.override"
    case uiSelection = "ui.selection"
    case credentials
    case storage
    case operationsObserve = "operations.observe"
    case operationsIntercept = "operations.intercept"

    public var fieldSpec: (required: [String], optional: [String]) {
        switch self {
        case .fsRead, .fsWrite: return (["scope", "reason"], ["recursive", "rootId"])
        case .net: return (["endpoints", "reason"], ["allowPrivate", "maxBytes"])
        case .processExec: return (["mode", "reason"], ["operations"])
        case .ui: return (["surfaces"], [])
        case .uiOverride: return (["surfaces", "reason"], [])
        case .uiSelection: return (["level", "reason"], [])
        case .credentials: return (["destinations", "reason"], [])
        case .storage: return ([], ["quotaBytes"])
        case .operationsObserve, .operationsIntercept: return (["operations", "reason"], [])
        }
    }

    public var summary: String {
        switch self {
        case .fsRead: return "Read files via gesture-scoped selection handles or a user-picked root."
        case .fsWrite: return "Write files into a user-chosen destination, root or selection."
        case .net: return "HTTP(S) to listed scheme/host/port/method endpoints; private networks denied unless allowed."
        case .processExec: return "Curated broker operations, or unrestricted full user-account execution (high trust)."
        case .ui: return "Register UI contributions on the listed surfaces."
        case .uiOverride: return "Reorder, hide or replace host built-ins on the listed surfaces."
        case .uiSelection: return "Receive passive selection metadata at the declared level."
        case .credentials: return "Use Keychain credentials as opaque handles bound to listed destinations."
        case .storage: return "Mod-private key/value storage."
        case .operationsObserve: return "Observe committed file operation outcomes."
        case .operationsIntercept: return "Veto file operations before they start (allow or deny)."
        }
    }
}

public struct NetEndpoint: Codable, Equatable, Sendable {
    public var scheme: NetScheme
    public var host: String
    public var port: Int?
    public var methods: [HTTPMethod]

    public init(scheme: NetScheme, host: String, port: Int? = nil, methods: [HTTPMethod]) {
        self.scheme = scheme; self.host = host; self.port = port; self.methods = methods
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case scheme, host, port, methods }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        scheme = try r.req(.scheme)
        host = try r.string(.host, pattern: ModPatterns.host, what: "host")
        port = try r.opt(.port)
        if let p = port, !(1...65535).contains(p) { throw r.fail(.port, .invalidValue, "port out of range") }
        methods = try r.req(.methods)
    }
}

public struct ModPermission: Codable, Equatable, Sendable {
    public var kind: ModPermissionKind
    public var reason: String?
    public var scope: FSScope?
    public var recursive: Bool?
    public var rootId: String?
    public var surfaces: [ModSurface]?
    public var endpoints: [NetEndpoint]?
    public var allowPrivate: Bool?
    public var maxBytes: Int?
    public var mode: ProcessMode?
    public var operations: [String]?
    public var destinations: [String]?
    public var quotaBytes: Int?
    public var level: SelectionLevel?

    public init(
        kind: ModPermissionKind, reason: String? = nil, scope: FSScope? = nil, recursive: Bool? = nil,
        rootId: String? = nil, surfaces: [ModSurface]? = nil, endpoints: [NetEndpoint]? = nil,
        allowPrivate: Bool? = nil, maxBytes: Int? = nil, mode: ProcessMode? = nil, operations: [String]? = nil,
        destinations: [String]? = nil, quotaBytes: Int? = nil, level: SelectionLevel? = nil
    ) {
        self.kind = kind; self.reason = reason; self.scope = scope; self.recursive = recursive
        self.rootId = rootId; self.surfaces = surfaces; self.endpoints = endpoints
        self.allowPrivate = allowPrivate; self.maxBytes = maxBytes; self.mode = mode
        self.operations = operations; self.destinations = destinations; self.quotaBytes = quotaBytes
        self.level = level
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, reason, scope, recursive, rootId, surfaces, endpoints, allowPrivate, maxBytes, mode
        case operations, destinations, quotaBytes, level
    }

    public init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        let path = decoder.codingPath
        guard any.contains(AnyKey("kind")) else {
            throw DecodingError.keyNotFound(AnyKey("kind"), .init(codingPath: path, debugDescription: "missing kind"))
        }
        let kind = try any.decode(ModPermissionKind.self, forKey: AnyKey("kind"))
        let spec = kind.fieldSpec
        let allowed = Set(spec.required + spec.optional + ["kind"])
        for key in any.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) where !allowed.contains(key.stringValue) {
            throw ModDecodeFailure.corrupted(path + [key], .unknownKey, "unknown key '\(key.stringValue)' for permission '\(kind.rawValue)'")
        }
        for key in spec.required where !any.contains(AnyKey(key)) {
            throw DecodingError.keyNotFound(AnyKey(key), .init(codingPath: path, debugDescription: "missing \(key)"))
        }
        let r = try StrictReader(decoder, CodingKeys.self)
        self.init(kind: kind)
        reason = try r.opt(.reason)
        scope = try r.opt(.scope)
        recursive = try r.opt(.recursive)
        rootId = try r.optString(.rootId, pattern: ModPatterns.rootID, what: "rootId")
        surfaces = try r.opt(.surfaces)
        endpoints = try r.opt(.endpoints)
        allowPrivate = try r.opt(.allowPrivate)
        maxBytes = try r.opt(.maxBytes)
        mode = try r.opt(.mode)
        operations = try r.opt(.operations)
        destinations = try r.opt(.destinations)
        quotaBytes = try r.opt(.quotaBytes)
        level = try r.opt(.level)
        switch kind {
        case .fsRead, .fsWrite:
            let allowedScopes: [FSScope] = kind == .fsRead ? [.selection, .root] : [.selection, .root, .destination]
            guard let s = scope, allowedScopes.contains(s) else {
                throw r.fail(.scope, .invalidValue, "scope must be one of \(allowedScopes.map(\.rawValue).joined(separator: ", ")) for \(kind.rawValue)")
            }
            if s == .root, rootId == nil { throw r.fail(.rootId, .missingKey, "scope 'root' requires rootId") }
            if s != .root, rootId != nil { throw r.fail(.rootId, .invalidValue, "rootId is only valid with scope 'root'") }
        case .processExec:
            if mode == .broker, operations == nil { throw r.fail(.operations, .missingKey, "mode 'broker' requires operations") }
            if mode == .unrestricted, operations != nil { throw r.fail(.operations, .invalidValue, "operations is only valid with mode 'broker'") }
        default: break
        }
    }
}

public struct ModSidebarItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var knownFolder: KnownFolder?
    public var location: String?
    public var icon: String?

    public init(id: String, title: String, knownFolder: KnownFolder? = nil, location: String? = nil, icon: String? = nil) {
        self.id = id; self.title = title; self.knownFolder = knownFolder; self.location = location; self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, knownFolder, location, icon }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        knownFolder = try r.opt(.knownFolder)
        location = try r.optString(.location, pattern: ModPatterns.localID, what: "location id")
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
        if (knownFolder == nil) == (location == nil) {
            throw r.fail(nil, .invalidValue, "exactly one of knownFolder or location is required")
        }
    }
}

public struct ModToolbarItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    public var icon: String?
    public var replaces: String?

    public init(id: String, title: String, command: String, icon: String? = nil, replaces: String? = nil) {
        self.id = id; self.title = title; self.command = command; self.icon = icon; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, command, icon, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        command = try r.string(.command, pattern: ModPatterns.commandRef, what: "command reference")
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModSidebarSection: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var items: [ModSidebarItem]
    public var icon: String?
    public var replaces: String?

    public init(id: String, title: String, items: [ModSidebarItem], icon: String? = nil, replaces: String? = nil) {
        self.id = id; self.title = title; self.items = items; self.icon = icon; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, items, icon, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        items = try r.req(.items)
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModContextMenuItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    public var target: MenuTarget
    public var replaces: String?

    public init(id: String, title: String, command: String, target: MenuTarget, replaces: String? = nil) {
        self.id = id; self.title = title; self.command = command; self.target = target; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, command, target, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        command = try r.string(.command, pattern: ModPatterns.commandRef, what: "command reference")
        target = try r.req(.target)
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModColumn: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var valueType: ColumnValueType
    public var handler: String
    public var width: Int?
    public var sortable: Bool?
    public var replaces: String?

    public init(id: String, title: String, valueType: ColumnValueType, handler: String, width: Int? = nil, sortable: Bool? = nil, replaces: String? = nil) {
        self.id = id; self.title = title; self.valueType = valueType; self.handler = handler
        self.width = width; self.sortable = sortable; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, valueType, handler, width, sortable, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        valueType = try r.req(.valueType)
        handler = try r.string(.handler, pattern: ModPatterns.handler, what: "handler")
        width = try r.opt(.width)
        if let w = width, !(40...1000).contains(w) { throw r.fail(.width, .invalidValue, "width must be 40...1000") }
        sortable = try r.opt(.sortable)
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModStatusBarItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var alignment: StatusAlignment?
    public var command: String?
    public var replaces: String?

    public init(id: String, title: String, alignment: StatusAlignment? = nil, command: String? = nil, replaces: String? = nil) {
        self.id = id; self.title = title; self.alignment = alignment; self.command = command; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, alignment, command, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        alignment = try r.opt(.alignment)
        command = try r.optString(.command, pattern: ModPatterns.commandRef, what: "command reference")
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModPanel: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var edge: PanelEdge
    public var presentation: PanelPresentation
    public var icon: String?

    public init(id: String, title: String, edge: PanelEdge, presentation: PanelPresentation, icon: String? = nil) {
        self.id = id; self.title = title; self.edge = edge; self.presentation = presentation; self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, edge, presentation, icon }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        edge = try r.req(.edge)
        presentation = try r.req(.presentation)
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
    }
}

public struct ModPreview: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var extensions: [String]
    public var handler: String
    public var replaces: String?

    public init(id: String, title: String, extensions: [String], handler: String, replaces: String? = nil) {
        self.id = id; self.title = title; self.extensions = extensions; self.handler = handler; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, extensions, handler, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        extensions = try r.stringArray(.extensions, pattern: ModPatterns.extensionName, what: "extension")
        handler = try r.string(.handler, pattern: ModPatterns.handler, what: "handler")
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModView: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var layout: ViewLayout
    public var columns: [String]?
    public var icon: String?
    public var replaces: String?

    public init(id: String, title: String, layout: ViewLayout, columns: [String]? = nil, icon: String? = nil, replaces: String? = nil) {
        self.id = id; self.title = title; self.layout = layout; self.columns = columns; self.icon = icon; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, layout, columns, icon, replaces }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        layout = try r.req(.layout)
        columns = try r.opt(.columns)
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
        replaces = try r.optString(.replaces, pattern: ModPatterns.builtinCommand, what: "built-in id")
    }
}

public struct ModLocation: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var scheme: String
    public var handler: String
    public var readOnly: Bool
    public var icon: String?

    public init(id: String, title: String, scheme: String, handler: String, readOnly: Bool, icon: String? = nil) {
        self.id = id; self.title = title; self.scheme = scheme; self.handler = handler; self.readOnly = readOnly; self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, scheme, handler, readOnly, icon }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        scheme = try r.string(.scheme, pattern: ModPatterns.scheme, what: "scheme")
        handler = try r.string(.handler, pattern: ModPatterns.handler, what: "handler")
        readOnly = try r.req(.readOnly)
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
    }
}

public struct ModCommand: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var handler: String
    public var category: String?
    public var icon: String?

    public init(id: String, title: String, handler: String, category: String? = nil, icon: String? = nil) {
        self.id = id; self.title = title; self.handler = handler; self.category = category; self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, handler, category, icon }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        handler = try r.string(.handler, pattern: ModPatterns.handler, what: "handler")
        category = try r.opt(.category)
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
    }
}

public struct ModKeybinding: Codable, Equatable, Sendable {
    public var id: String
    public var key: String
    public var command: String

    public init(id: String, key: String, command: String) { self.id = id; self.key = key; self.command = command }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, key, command }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        key = try r.string(.key, pattern: ModPatterns.keyChord, what: "key chord")
        command = try r.string(.command, pattern: ModPatterns.commandRef, what: "command reference")
    }
}

public struct ModSettingsPane: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var settings: [String]
    public var icon: String?

    public init(id: String, title: String, settings: [String], icon: String? = nil) {
        self.id = id; self.title = title; self.settings = settings; self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, settings, icon }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        settings = try r.stringArray(.settings, pattern: ModPatterns.settingKey, what: "setting key")
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
    }
}

public struct ModTheme: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var appearance: ThemeAppearance

    public init(id: String, title: String, path: String, appearance: ThemeAppearance) {
        self.id = id; self.title = title; self.path = path; self.appearance = appearance
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, path, appearance }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        path = try r.string(.path, pattern: ModPatterns.relativePath, code: .pathNotContained, what: "package path")
        appearance = try r.req(.appearance)
    }
}

public struct ModAssetSet: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var path: String

    public init(id: String, title: String, path: String) { self.id = id; self.title = title; self.path = path }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, path }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        path = try r.string(.path, pattern: ModPatterns.relativePath, code: .pathNotContained, what: "package path")
    }
}

public struct ModSearchProvider: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var handler: String
    public var icon: String?

    public init(id: String, title: String, handler: String, icon: String? = nil) {
        self.id = id; self.title = title; self.handler = handler; self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, handler, icon }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.localID, what: "id")
        title = try r.req(.title)
        handler = try r.string(.handler, pattern: ModPatterns.handler, what: "handler")
        icon = try r.optString(.icon, pattern: ModPatterns.icon, what: "icon")
    }
}

public enum ModContributionKind: String, CaseIterable, Sendable {
    case toolbar, sidebarSections, contextMenu, columns, statusBar, panels, previews, views, locations
    case commands, keybindings, settingsPanes, themes, iconSets, sounds, searchProviders

    public var surface: ModSurface? {
        switch self {
        case .toolbar: return .toolbar
        case .sidebarSections: return .sidebar
        case .contextMenu: return .contextMenu
        case .columns: return .column
        case .statusBar: return .statusBar
        case .panels: return .panel
        case .previews: return .preview
        case .views: return .view
        case .locations: return .location
        case .searchProviders: return .search
        case .commands, .keybindings, .settingsPanes, .themes, .iconSets, .sounds: return nil
        }
    }

    public var hookName: String? {
        switch self {
        case .columns: return "column.values"
        case .previews: return "preview.render"
        case .locations: return "location.list"
        case .searchProviders: return "search.query"
        case .commands: return "command.run"
        default: return nil
        }
    }
}

public struct ModContributions: Codable, Equatable, Sendable {
    public var toolbar: [ModToolbarItem]
    public var sidebarSections: [ModSidebarSection]
    public var contextMenu: [ModContextMenuItem]
    public var columns: [ModColumn]
    public var statusBar: [ModStatusBarItem]
    public var panels: [ModPanel]
    public var previews: [ModPreview]
    public var views: [ModView]
    public var locations: [ModLocation]
    public var commands: [ModCommand]
    public var keybindings: [ModKeybinding]
    public var settingsPanes: [ModSettingsPane]
    public var themes: [ModTheme]
    public var iconSets: [ModAssetSet]
    public var sounds: [ModAssetSet]
    public var searchProviders: [ModSearchProvider]

    public init(
        toolbar: [ModToolbarItem] = [], sidebarSections: [ModSidebarSection] = [], contextMenu: [ModContextMenuItem] = [],
        columns: [ModColumn] = [], statusBar: [ModStatusBarItem] = [], panels: [ModPanel] = [], previews: [ModPreview] = [],
        views: [ModView] = [], locations: [ModLocation] = [], commands: [ModCommand] = [], keybindings: [ModKeybinding] = [],
        settingsPanes: [ModSettingsPane] = [], themes: [ModTheme] = [], iconSets: [ModAssetSet] = [],
        sounds: [ModAssetSet] = [], searchProviders: [ModSearchProvider] = []
    ) {
        self.toolbar = toolbar; self.sidebarSections = sidebarSections; self.contextMenu = contextMenu
        self.columns = columns; self.statusBar = statusBar; self.panels = panels; self.previews = previews
        self.views = views; self.locations = locations; self.commands = commands; self.keybindings = keybindings
        self.settingsPanes = settingsPanes; self.themes = themes; self.iconSets = iconSets
        self.sounds = sounds; self.searchProviders = searchProviders
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case toolbar, sidebarSections, contextMenu, columns, statusBar, panels, previews, views, locations
        case commands, keybindings, settingsPanes, themes, iconSets, sounds, searchProviders
    }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        toolbar = try r.opt(.toolbar) ?? []
        sidebarSections = try r.opt(.sidebarSections) ?? []
        contextMenu = try r.opt(.contextMenu) ?? []
        columns = try r.opt(.columns) ?? []
        statusBar = try r.opt(.statusBar) ?? []
        panels = try r.opt(.panels) ?? []
        previews = try r.opt(.previews) ?? []
        views = try r.opt(.views) ?? []
        locations = try r.opt(.locations) ?? []
        commands = try r.opt(.commands) ?? []
        keybindings = try r.opt(.keybindings) ?? []
        settingsPanes = try r.opt(.settingsPanes) ?? []
        themes = try r.opt(.themes) ?? []
        iconSets = try r.opt(.iconSets) ?? []
        sounds = try r.opt(.sounds) ?? []
        searchProviders = try r.opt(.searchProviders) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !toolbar.isEmpty { try c.encode(toolbar, forKey: .toolbar) }
        if !sidebarSections.isEmpty { try c.encode(sidebarSections, forKey: .sidebarSections) }
        if !contextMenu.isEmpty { try c.encode(contextMenu, forKey: .contextMenu) }
        if !columns.isEmpty { try c.encode(columns, forKey: .columns) }
        if !statusBar.isEmpty { try c.encode(statusBar, forKey: .statusBar) }
        if !panels.isEmpty { try c.encode(panels, forKey: .panels) }
        if !previews.isEmpty { try c.encode(previews, forKey: .previews) }
        if !views.isEmpty { try c.encode(views, forKey: .views) }
        if !locations.isEmpty { try c.encode(locations, forKey: .locations) }
        if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
        if !keybindings.isEmpty { try c.encode(keybindings, forKey: .keybindings) }
        if !settingsPanes.isEmpty { try c.encode(settingsPanes, forKey: .settingsPanes) }
        if !themes.isEmpty { try c.encode(themes, forKey: .themes) }
        if !iconSets.isEmpty { try c.encode(iconSets, forKey: .iconSets) }
        if !sounds.isEmpty { try c.encode(sounds, forKey: .sounds) }
        if !searchProviders.isEmpty { try c.encode(searchProviders, forKey: .searchProviders) }
    }

    public func ids(of kind: ModContributionKind) -> [String] {
        switch kind {
        case .toolbar: return toolbar.map(\.id)
        case .sidebarSections: return sidebarSections.map(\.id)
        case .contextMenu: return contextMenu.map(\.id)
        case .columns: return columns.map(\.id)
        case .statusBar: return statusBar.map(\.id)
        case .panels: return panels.map(\.id)
        case .previews: return previews.map(\.id)
        case .views: return views.map(\.id)
        case .locations: return locations.map(\.id)
        case .commands: return commands.map(\.id)
        case .keybindings: return keybindings.map(\.id)
        case .settingsPanes: return settingsPanes.map(\.id)
        case .themes: return themes.map(\.id)
        case .iconSets: return iconSets.map(\.id)
        case .sounds: return sounds.map(\.id)
        case .searchProviders: return searchProviders.map(\.id)
        }
    }

    public var isEmpty: Bool { ModContributionKind.allCases.allSatisfy { ids(of: $0).isEmpty } }
}

public struct ModHookDecl: Codable, Equatable, Sendable {
    public var name: String
    public var handler: String
    public var version: Int

    public init(name: String, handler: String, version: Int = 1) { self.name = name; self.handler = handler; self.version = version }

    enum CodingKeys: String, CodingKey, CaseIterable { case name, handler, version }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        name = try r.req(.name)
        handler = try r.string(.handler, pattern: ModPatterns.handler, what: "handler")
        version = try r.req(.version)
    }
}

public struct ModSettingOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) { self.value = value; self.label = label }

    enum CodingKeys: String, CodingKey, CaseIterable { case value, label }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        value = try r.req(.value)
        label = try r.req(.label)
    }
}

public struct ModSetting: Codable, Equatable, Sendable {
    public var key: String
    public var type: SettingType
    public var label: String
    public var description: String?
    public var `default`: JSONValue
    public var minimum: Double?
    public var maximum: Double?
    public var maxLength: Int?
    public var options: [ModSettingOption]?

    public init(
        key: String, type: SettingType, label: String, description: String? = nil, default: JSONValue,
        minimum: Double? = nil, maximum: Double? = nil, maxLength: Int? = nil, options: [ModSettingOption]? = nil
    ) {
        self.key = key; self.type = type; self.label = label; self.description = description; self.default = `default`
        self.minimum = minimum; self.maximum = maximum; self.maxLength = maxLength; self.options = options
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case key, type, label, description, `default`, minimum, maximum, maxLength, options
    }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        key = try r.string(.key, pattern: ModPatterns.settingKey, what: "setting key")
        type = try r.req(.type)
        label = try r.req(.label)
        description = try r.opt(.description)
        `default` = try r.req(.default)
        minimum = try r.opt(.minimum)
        maximum = try r.opt(.maximum)
        maxLength = try r.opt(.maxLength)
        options = try r.opt(.options)
        try validateShape(r)
    }

    private func validateShape(_ r: StrictReader<CodingKeys>) throws {
        switch type {
        case .boolean:
            guard case .bool = `default` else { throw r.fail(.default, .wrongType, "default must be a boolean") }
        case .integer:
            guard case .int = `default` else { throw r.fail(.default, .wrongType, "default must be an integer") }
        case .number:
            guard `default`.numberValue != nil else { throw r.fail(.default, .wrongType, "default must be a number") }
        case .string:
            guard case .string = `default` else { throw r.fail(.default, .wrongType, "default must be a string") }
        case .enum:
            guard case .string(let s) = `default` else { throw r.fail(.default, .wrongType, "default must be a string") }
            guard let opts = options, !opts.isEmpty else { throw r.fail(.options, .missingKey, "enum settings require options") }
            guard opts.contains(where: { $0.value == s }) else { throw r.fail(.default, .invalidValue, "default is not one of the options") }
        }
        if type != .enum, r.has(.options) { throw r.fail(.options, .invalidValue, "options is only valid for enum settings") }
        if type != .integer, type != .number {
            if r.has(.minimum) { throw r.fail(.minimum, .invalidValue, "minimum is only valid for integer/number settings") }
            if r.has(.maximum) { throw r.fail(.maximum, .invalidValue, "maximum is only valid for integer/number settings") }
        }
        if type != .string, r.has(.maxLength) { throw r.fail(.maxLength, .invalidValue, "maxLength is only valid for string settings") }
        if let lo = minimum, let hi = maximum, lo > hi { throw r.fail(.minimum, .invalidValue, "minimum exceeds maximum") }
        if let d = `default`.numberValue, type == .integer || type == .number {
            if let lo = minimum, d < lo { throw r.fail(.default, .invalidValue, "default below minimum") }
            if let hi = maximum, d > hi { throw r.fail(.default, .invalidValue, "default above maximum") }
        }
        if case .string(let s) = `default`, type == .string, let m = maxLength, s.count > m {
            throw r.fail(.default, .invalidValue, "default longer than maxLength")
        }
    }
}

public struct ModDependency: Codable, Equatable, Sendable {
    public var id: String
    public var version: SemVer
    public var sha256: String

    public init(id: String, version: SemVer, sha256: String) { self.id = id; self.version = version; self.sha256 = sha256 }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, version, sha256 }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        id = try r.string(.id, pattern: ModPatterns.modID, code: .invalidModID, what: "mod id")
        version = try r.req(.version)
        sha256 = try r.string(.sha256, pattern: ModPatterns.sha256, what: "sha256")
    }
}

public struct ModManifest: Codable, Equatable, Sendable {
    public var manifestVersion: Int
    public var id: String
    public var name: String
    public var author: String
    public var version: SemVer
    public var api: SemVerRange
    public var app: SemVerRange
    public var runtime: ModRuntime
    public var entry: String?
    public var license: String
    public var permissions: [ModPermission]
    public var contributes: ModContributions
    public var hooks: [ModHookDecl]
    public var settings: [ModSetting]
    public var dependencies: [ModDependency]
    public var conflicts: [String]

    public init(
        manifestVersion: Int = 1, id: String, name: String, author: String, version: SemVer,
        api: SemVerRange, app: SemVerRange, runtime: ModRuntime, entry: String? = nil, license: String,
        permissions: [ModPermission] = [], contributes: ModContributions = ModContributions(),
        hooks: [ModHookDecl] = [], settings: [ModSetting] = [], dependencies: [ModDependency] = [],
        conflicts: [String] = []
    ) {
        self.manifestVersion = manifestVersion; self.id = id; self.name = name; self.author = author
        self.version = version; self.api = api; self.app = app; self.runtime = runtime; self.entry = entry
        self.license = license; self.permissions = permissions; self.contributes = contributes
        self.hooks = hooks; self.settings = settings; self.dependencies = dependencies; self.conflicts = conflicts
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case manifestVersion, id, name, author, version, api, app, runtime, entry, license
        case permissions, contributes, hooks, settings, dependencies, conflicts
    }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        manifestVersion = try r.req(.manifestVersion)
        guard manifestVersion == ModKitVersion.manifestVersion else {
            throw r.fail(.manifestVersion, .unsupportedManifestVersion, "manifestVersion \(manifestVersion) is not supported (expected \(ModKitVersion.manifestVersion))")
        }
        id = try r.string(.id, pattern: ModPatterns.modID, code: .invalidModID, what: "mod id")
        name = try r.req(.name)
        author = try r.string(.author, pattern: ModPatterns.author, what: "author")
        version = try r.req(.version)
        api = try r.req(.api)
        app = try r.req(.app)
        runtime = try r.req(.runtime)
        entry = try r.opt(.entry)
        license = try r.req(.license)
        permissions = try r.req(.permissions)
        contributes = try r.req(.contributes)
        hooks = try r.req(.hooks)
        settings = try r.req(.settings)
        dependencies = try r.req(.dependencies)
        conflicts = try r.stringArray(.conflicts, pattern: ModPatterns.modID, what: "mod id")
    }

    public func qualifiedID(_ localID: String) -> String { "\(id)/\(localID)" }
}

public extension ModManifest {
    static let maxBytes = 256 * 1024

    static func decode(_ data: Data, file: String = "manifest.json") -> Result<ModManifest, ModDiagnostic> {
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch let e as JSONParseError {
            return .failure(ModDiagnostic(.invalidJSON, file: file, pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message))
        } catch {
            return .failure(ModDiagnostic(.invalidJSON, file: file, message: "\(error)"))
        }
        guard case .object = value else {
            return .failure(ModDiagnostic(.wrongType, file: file, pointer: "", message: "manifest must be a JSON object"))
        }
        return ModDecoding.decode(ModManifest.self, from: value, file: file)
    }
}
