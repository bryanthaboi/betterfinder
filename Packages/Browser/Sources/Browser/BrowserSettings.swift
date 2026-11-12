import AppKit
import Foundation

public enum BrowserViewMode: Int, Sendable, CaseIterable {
    case list = 0, column = 1, icon = 2

    var title: String {
        switch self {
        case .list: return "as List"
        case .column: return "as Columns"
        case .icon: return "as Icons"
        }
    }
}

enum SortKey: String, Sendable, CaseIterable {
    case name, modified, size, kind, added, created, tags, dimensions, location, custom

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        case .added: return "Date Added"
        case .created: return "Date Created"
        case .tags: return "Tags"
        case .dimensions: return "Dimensions"
        case .location: return "Location"
        case .custom: return "Custom"
        }
    }

    static var menuKeys: [SortKey] { allCases.filter { $0 != .custom } }
}

struct SortSpec: Sendable, Hashable {
    var key: SortKey
    var ascending: Bool
    var foldersFirst: Bool
    var customColumn: String? = nil
}

enum SearchScopeKind: Int, Sendable {
    case folder = 0, home = 1, computer = 2
}

extension Notification.Name {
    static let browserSortDidChange = Notification.Name("BrowserSortDidChange")
    static let browserViewOptionsDidChange = Notification.Name("BrowserViewOptionsDidChange")
    static let browserFavoritesDidChange = Notification.Name("BrowserFavoritesDidChange")
    static let browserVolumeWillEject = Notification.Name("BrowserVolumeWillEject")
    static let browserRenameDidEnd = Notification.Name("BrowserRenameDidEnd")
    static let browserIconsDidInvalidate = Notification.Name("BrowserIconsDidInvalidate")
}

enum BrowserDefaults {
    static var store: UserDefaults = .standard

    enum Key {
        static let viewMode = "browserViewMode"
        static let sortKey = "browserSortKey"
        static let sortAscending = "browserSortAscending"
        static let sortCustomColumn = "browserSortCustomColumn"
        static let foldersFirst = "foldersFirst"
        static let showHidden = "showHiddenFiles"
        static let returnOpens = "returnOpens"
        static let calculateFolderSizes = "calculateFolderSizes"
        static let networkFolderSizes = "calculateFolderSizesOnNetwork"
        static let networkThumbnails = "networkThumbnails"
        static let visibleColumns = "listVisibleColumns"
        static let heatColumnPlaced = "listHeatColumnPlaced"
        static let iconSize = "iconViewSize"
        static let showAllocatedSize = "showAllocatedSize"
        static let searchScope = "searchScope"
        static let favorites = "sidebarFavorites"
        static let knownTags = "knownTags"
        static let expanded = "expandedFolders"
        static let expandedOrder = "expandedFoldersOrder"
        static let openFoldersInTabs = "openFoldersInTabs"
        static let terminalAppPath = "terminalAppPath"
        static let terminalBundleID = "terminalBundleID"
    }

    static var openFoldersInTabs: Bool { store.bool(forKey: Key.openFoldersInTabs) }
    static var terminalAppPath: String? { store.string(forKey: Key.terminalAppPath) }
    static var terminalBundleID: String? { store.string(forKey: Key.terminalBundleID) }

    static var viewMode: BrowserViewMode {
        get { BrowserViewMode(rawValue: store.integer(forKey: Key.viewMode)) ?? .list }
        set { store.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    static var sort: SortSpec {
        get {
            SortSpec(
                key: store.string(forKey: Key.sortKey).flatMap(SortKey.init) ?? .name,
                ascending: store.object(forKey: Key.sortAscending) as? Bool ?? true,
                foldersFirst: store.bool(forKey: Key.foldersFirst),
                customColumn: store.string(forKey: Key.sortCustomColumn)
            )
        }
        set {
            store.set(newValue.key.rawValue, forKey: Key.sortKey)
            store.set(newValue.ascending, forKey: Key.sortAscending)
            store.set(newValue.foldersFirst, forKey: Key.foldersFirst)
            store.set(newValue.customColumn, forKey: Key.sortCustomColumn)
        }
    }

    static var showHidden: Bool {
        get { store.bool(forKey: Key.showHidden) }
        set { store.set(newValue, forKey: Key.showHidden) }
    }

    static var returnOpens: Bool { store.bool(forKey: Key.returnOpens) }

    static var calculateFolderSizes: Bool { store.object(forKey: Key.calculateFolderSizes) as? Bool ?? true }
    static var networkFolderSizes: Bool { store.bool(forKey: Key.networkFolderSizes) }
    static var networkThumbnails: Bool { store.bool(forKey: Key.networkThumbnails) }

    static let defaultColumns: [String] = ["modified", "size", "heat", "kind"]

    static var visibleColumns: Set<String> {
        get { Set(store.stringArray(forKey: Key.visibleColumns) ?? defaultColumns) }
        set { store.set(Array(newValue).sorted(), forKey: Key.visibleColumns) }
    }

    static var iconSize: Double {
        get { let v = store.double(forKey: Key.iconSize); return v > 0 ? min(max(v, 32), 256) : 64 }
        set { store.set(min(max(newValue, 32), 256), forKey: Key.iconSize) }
    }

    static var showAllocatedSize: Bool {
        get { store.object(forKey: Key.showAllocatedSize) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.showAllocatedSize) }
    }

    static var statusAlternateSize: Bool {
        get { !showAllocatedSize }
        set { showAllocatedSize = !newValue }
    }

    static var searchScope: SearchScopeKind {
        get { SearchScopeKind(rawValue: store.integer(forKey: Key.searchScope)) ?? .folder }
        set { store.set(newValue.rawValue, forKey: Key.searchScope) }
    }

    static var favorites: [String]? {
        get { store.stringArray(forKey: Key.favorites) }
        set { store.set(newValue, forKey: Key.favorites) }
    }

    static var knownTags: [String] {
        get { store.stringArray(forKey: Key.knownTags) ?? [] }
        set { store.set(Array(newValue.prefix(200)), forKey: Key.knownTags) }
    }

    static func noteTags(_ tags: [String]) {
        guard !tags.isEmpty else { return }
        var known = knownTags
        var changed = false
        for t in tags where !known.contains(t) { known.append(t); changed = true }
        if changed { knownTags = known }
    }
}

enum ExpansionMemory {
    static var maxRoots = 200
    static var maxPerRoot = 500

    static func expanded(in root: String) -> Set<String> {
        let dict = BrowserDefaults.store.dictionary(forKey: BrowserDefaults.Key.expanded) as? [String: [String]] ?? [:]
        return Set(dict[root] ?? [])
    }

    static func set(_ paths: Set<String>, in root: String) {
        let store = BrowserDefaults.store
        var dict = store.dictionary(forKey: BrowserDefaults.Key.expanded) as? [String: [String]] ?? [:]
        var order = store.stringArray(forKey: BrowserDefaults.Key.expandedOrder) ?? []
        order.removeAll { $0 == root }
        if paths.isEmpty {
            dict[root] = nil
        } else {
            dict[root] = Array(paths.sorted().prefix(maxPerRoot))
            order.append(root)
        }
        while order.count > maxRoots {
            let evicted = order.removeFirst()
            dict[evicted] = nil
        }
        for k in dict.keys where !order.contains(k) { dict[k] = nil }
        store.set(dict, forKey: BrowserDefaults.Key.expanded)
        store.set(order, forKey: BrowserDefaults.Key.expandedOrder)
    }
}
