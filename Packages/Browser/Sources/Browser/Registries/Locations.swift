import AppKit
import FSCore
import Foundation
import Theming

public struct ProvidedLocation: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case container, search }

    public var providerID: String
    public var id: String
    public var title: String
    public var symbolName: String?
    public var kind: Kind

    public init(providerID: String, id: String, title: String, symbolName: String? = nil, kind: Kind = .container) {
        self.providerID = providerID
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.kind = kind
    }

    public static func search(providerID: String, query: String) -> ProvidedLocation {
        ProvidedLocation(providerID: providerID, id: query, title: "Searching “\(query)”", symbolName: "magnifyingglass", kind: .search)
    }

    public static func == (a: ProvidedLocation, b: ProvidedLocation) -> Bool {
        a.providerID == b.providerID && a.id == b.id && a.kind == b.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(providerID)
        hasher.combine(id)
        hasher.combine(kind)
    }
}

public enum BrowserDestination: Hashable, Sendable {
    case local(BrowserLocation)
    case provided(ProvidedLocation)

    public var displayName: String {
        switch self {
        case .local(let l): return l.displayName
        case .provided(let p): return p.title
        }
    }

    public var url: URL? {
        if case .local(let l) = self { return l.url }
        return nil
    }

    public var isVirtual: Bool {
        switch self {
        case .local(let l): return l.isVirtual
        case .provided: return true
        }
    }

    public var providedLocation: ProvidedLocation? {
        if case .provided(let p) = self { return p }
        return nil
    }
}

public struct LocationCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let list = LocationCapabilities(rawValue: 1)
    public static let read = LocationCapabilities(rawValue: 2)
    public static let write = LocationCapabilities(rawValue: 4)
    public static let trash = LocationCapabilities(rawValue: 8)
    public static let undo = LocationCapabilities(rawValue: 16)
    public static let watch = LocationCapabilities(rawValue: 32)
}

public struct ProvidedItem: Hashable, Sendable {
    public var id: String
    public var name: String
    public var isContainer: Bool
    public var symbolName: String?
    public var detail: String?
    public var size: Int64?
    public var modified: Date?
    public var child: ProvidedLocation?

    public init(id: String, name: String, isContainer: Bool = false, symbolName: String? = nil, detail: String? = nil, size: Int64? = nil, modified: Date? = nil, child: ProvidedLocation? = nil) {
        self.id = id
        self.name = name
        self.isContainer = isContainer
        self.symbolName = symbolName
        self.detail = detail
        self.size = size
        self.modified = modified
        self.child = child
    }
}

public struct LocationContext: Sendable {
    public var generation: Int
}

public protocol LocationProvider: Sendable {
    var providerID: String { get }
    var capabilities: LocationCapabilities { get }
    func list(_ location: ProvidedLocation, context: LocationContext) async throws -> [ProvidedItem]
    func parent(of location: ProvidedLocation) -> ProvidedLocation?
}

public extension LocationProvider {
    var capabilities: LocationCapabilities { [.list] }
}

public struct LocationProviderSpec: BrowserContribution {
    public var id: String
    public var title: String
    public var symbolName: String?
    public var provider: LocationProvider
    public var root: ProvidedLocation

    public init(id: String, title: String, symbolName: String? = nil, provider: LocationProvider, root: ProvidedLocation) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.provider = provider
        self.root = root
    }
}

@MainActor
public final class LocationRegistry: BrowserRegistry<LocationProviderSpec> {
    public static let shared = LocationRegistry()

    public init() { super.init(kind: .location) }

    override public func validate(_ item: LocationProviderSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.provider.providerID != item.id { return "The provider id must match the contribution id." }
        if item.root.providerID != item.id { return "The root location must belong to this provider." }
        if let existing = entries.first(where: { $0.item.id == item.id && $0.owner != owner }) { return "Location provider “\(item.id)” is already registered by \(existing.owner)." }
        return nil
    }

    public func provider(for providerID: String) -> LocationProvider? {
        entries.first { $0.item.id == providerID }?.item.provider
    }

    public func spec(for providerID: String) -> LocationProviderSpec? {
        entries.first { $0.item.id == providerID }?.item
    }
}

public struct SearchContext: Sendable {
    public var location: BrowserLocation
    public var providedLocation: ProvidedLocation?
}

public struct SearchResult: Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var symbolName: String?
    public var fileURL: URL?
    public var location: ProvidedLocation?

    public init(id: String, title: String, subtitle: String? = nil, symbolName: String? = nil, fileURL: URL? = nil, location: ProvidedLocation? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.fileURL = fileURL
        self.location = location
    }
}

public struct SearchBatch: Sendable {
    public var results: [SearchResult]
    public init(results: [SearchResult]) { self.results = results }
}

public protocol SearchProvider: Sendable {
    func search(_ query: String, context: SearchContext) -> AsyncThrowingStream<SearchBatch, Error>
}

public struct SearchProviderSpec: BrowserContribution {
    public var id: String
    public var title: String
    public var symbolName: String?
    public var provider: SearchProvider

    public init(id: String, title: String, symbolName: String? = nil, provider: SearchProvider) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.provider = provider
    }
}

@MainActor
public final class SearchProviderRegistry: BrowserRegistry<SearchProviderSpec> {
    public static let shared = SearchProviderRegistry()

    public init() { super.init(kind: .search) }

    override public func validate(_ item: SearchProviderSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A search provider needs a title." }
        return nil
    }
}

public enum BrowserViewContent {
    case ui(ModUINode)
    case view(NSView)
}

@MainActor
public final class BrowserViewContext {
    public let destination: BrowserDestination
    public private(set) var content: BrowserViewContent?
    public private(set) var isDisposed = false
    public var onEvent: ((ModUIEvent) -> Void)?
    var onContent: ((BrowserViewContent) -> Void)?
    var navigator: ((BrowserDestination) -> Void)?
    private var disposers: [() -> Void] = []

    init(destination: BrowserDestination) {
        self.destination = destination
    }

    public func setContent(_ node: ModUINode) { push(.ui(node)) }
    public func setView(_ view: NSView) { push(.view(view)) }

    private func push(_ c: BrowserViewContent) {
        guard !isDisposed else { return }
        content = c
        onContent?(c)
    }

    public func navigate(to location: BrowserLocation) { navigator?(.local(location)) }
    public func navigate(to location: ProvidedLocation) { navigator?(.provided(location)) }
    public func onDispose(_ f: @escaping () -> Void) { disposers.append(f) }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        for d in disposers { d() }
        disposers.removeAll()
    }
}

public struct BrowserViewSpec: BrowserContribution {
    public var id: String
    public var title: String
    public var priority: Int
    public var matches: @MainActor (BrowserDestination) -> Bool
    public var build: @MainActor (BrowserViewContext) -> Void

    public init(id: String, title: String, priority: Int = 0, matches: @escaping @MainActor (BrowserDestination) -> Bool, build: @escaping @MainActor (BrowserViewContext) -> Void) {
        self.id = id
        self.title = title
        self.priority = priority
        self.matches = matches
        self.build = build
    }

    public init(id: String, title: String, providerID: String, priority: Int = 0, build: @escaping @MainActor (BrowserViewContext) -> Void) {
        self.init(id: id, title: title, priority: priority, matches: { dest in dest.providedLocation?.providerID == providerID }, build: build)
    }
}

@MainActor
public final class BrowserViewRegistry: BrowserRegistry<BrowserViewSpec> {
    public static let shared = BrowserViewRegistry()

    public init() { super.init(kind: .browserView) }

    override public func validate(_ item: BrowserViewSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.title.isEmpty { return "A browser view needs a title." }
        return nil
    }

    public func entry(matching destination: BrowserDestination) -> Entry? {
        visibleEntries.filter { $0.item.matches(destination) }.max { a, b in
            if a.item.priority != b.item.priority { return a.item.priority < b.item.priority }
            return a.sequence > b.sequence
        }
    }
}

@MainActor
final class PaneAuxViewController: NSViewController {
    let destination: BrowserDestination
    private let registries: BrowserRegistries
    private let renderer = ModUIRenderer()
    private let container = NSView()
    private var customView: NSView?
    private var context: BrowserViewContext?
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var itemCount = 0
    private(set) var isLoading = false
    private(set) var currentNode: ModUINode?
    private(set) var specID: String?
    var onNavigate: ((BrowserDestination) -> Void)?
    var onStateChange: (() -> Void)?
    var onOpenLocal: ((URL) -> Void)?
    private var items: [String: ProvidedItem] = [:]
    private var results: [String: SearchResult] = [:]

    init(destination: BrowserDestination, registries: BrowserRegistries) {
        self.destination = destination
        self.registries = registries
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(destination.displayName)
        let r = renderer.rootView
        r.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(r)
        NSLayoutConstraint.activate([
            r.topAnchor.constraint(equalTo: container.topAnchor),
            r.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            r.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            r.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        renderer.onEvent = { [weak self] e in self?.handle(e) }
        view = container
    }

    func start() {
        _ = view
        if let entry = registries.browserViews.entry(matching: destination) {
            specID = entry.qualifiedID
            let ctx = BrowserViewContext(destination: destination)
            ctx.onContent = { [weak self] c in self?.apply(c) }
            ctx.navigator = { [weak self] d in self?.onNavigate?(d) }
            context = ctx
            renderer.onEvent = { [weak ctx] e in ctx?.onEvent?(e) }
            entry.item.build(ctx)
            if let c = ctx.content { apply(c) }
            return
        }
        guard case .provided(let p) = destination else { return }
        switch p.kind {
        case .container: loadContainer(p)
        case .search: runSearch(p)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        context?.dispose()
        context = nil
        generation += 1
    }

    func reload() {
        stop()
        customView?.removeFromSuperview()
        customView = nil
        start()
    }

    private func apply(_ content: BrowserViewContent) {
        switch content {
        case .ui(let node):
            customView?.removeFromSuperview()
            customView = nil
            renderer.rootView.isHidden = false
            currentNode = node
            itemCount = node.nodeCount
            renderer.render(node)
        case .view(let v):
            renderer.rootView.isHidden = true
            customView?.removeFromSuperview()
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            customView = v
        }
        onStateChange?()
    }

    private static let columns = [
        ModUITableColumn(id: "name", title: "Name"),
        ModUITableColumn(id: "detail", title: "Kind", width: 140),
        ModUITableColumn(id: "size", title: "Size", width: 90, isRightAligned: true),
        ModUITableColumn(id: "modified", title: "Date Modified", width: 170),
    ]

    private func message(_ text: String, retry: Bool) -> ModUINode {
        var children = [ModUINode.label(id: "message", text, style: .secondary)]
        if retry { children.append(.button(id: "retry", title: "Try Again", symbolName: "arrow.clockwise")) }
        return .stack(id: "root", spacing: 12, children)
    }

    private func loadContainer(_ p: ProvidedLocation) {
        guard let provider = registries.locations.provider(for: p.providerID) else {
            apply(.ui(message("No provider is available for “\(p.title)”.", retry: false)))
            return
        }
        generation += 1
        let gen = generation
        isLoading = true
        itemCount = 0
        apply(.ui(.stack(id: "root", [.progress(id: "loading", value: nil, caption: "Loading…", accessibilityLabel: "Loading \(p.title)")])))
        task = Task { [weak self] in
            do {
                let listed = try await provider.list(p, context: LocationContext(generation: gen))
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.items = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.isLoading = false
                self.showRows(listed, location: p)
            } catch {
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.isLoading = false
                self.apply(.ui(self.message(error.localizedDescription, retry: true)))
                self.itemCount = 0
                self.onStateChange?()
            }
        }
    }

    private func showRows(_ listed: [ProvidedItem], location: ProvidedLocation) {
        let rows = listed.map { item in
            ModUITableRow(id: item.id, cells: [
                "name": item.name,
                "detail": item.detail ?? (item.isContainer ? "Folder" : ""),
                "size": item.size.map(SizeFormatter.string) ?? "--",
                "modified": item.modified.map { ColumnValue.date($0).displayText } ?? "--",
            ], symbolName: item.symbolName ?? (item.isContainer ? "folder" : "doc"))
        }
        let node = ModUINode.table(id: "items", columns: Self.columns, rows: rows, accessibilityLabel: "Items in \(location.title)")
        apply(.ui(node))
        itemCount = listed.count
        onStateChange?()
    }

    private func runSearch(_ p: ProvidedLocation) {
        guard let spec = registries.searchProviders.entries.first(where: { $0.qualifiedID == p.providerID })?.item ?? registries.searchProviders.entries.first(where: { $0.item.id == p.providerID })?.item else {
            apply(.ui(message("The search provider is no longer available.", retry: false)))
            return
        }
        generation += 1
        let gen = generation
        isLoading = true
        results = [:]
        var order: [String] = []
        let context = SearchContext(location: .computer, providedLocation: nil)
        showResults([], title: p.title)
        task = Task { [weak self] in
            do {
                for try await batch in spec.provider.search(p.id, context: context) {
                    guard !Task.isCancelled, let self, self.generation == gen else { return }
                    for r in batch.results where self.results[r.id] == nil { self.results[r.id] = r; order.append(r.id) }
                    self.showResults(order.compactMap { self.results[$0] }, title: p.title)
                }
                guard let self, self.generation == gen else { return }
                self.isLoading = false
                self.onStateChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.isLoading = false
                self.apply(.ui(self.message(error.localizedDescription, retry: true)))
            }
        }
    }

    private func showResults(_ list: [SearchResult], title: String) {
        let rows = list.map { r in
            ModUITableRow(id: r.id, cells: ["name": r.title, "detail": r.subtitle ?? "", "size": "", "modified": ""], symbolName: r.symbolName ?? (r.fileURL != nil ? "doc" : "magnifyingglass"))
        }
        apply(.ui(.table(id: "items", columns: Array(Self.columns.prefix(2)), rows: rows, accessibilityLabel: title)))
        itemCount = list.count
        onStateChange?()
    }

    private func handle(_ event: ModUIEvent) {
        switch event.kind {
        case .press where event.nodeID == "retry": reload()
        case .activated(let id):
            if case .provided(let p) = destination, p.kind == .search, let r = results[id] {
                if let loc = r.location { onNavigate?(.provided(loc)) } else if let url = r.fileURL { onOpenLocal?(url) }
            } else if let child = items[id]?.child {
                onNavigate?(.provided(child))
            }
        default: break
        }
    }
}
