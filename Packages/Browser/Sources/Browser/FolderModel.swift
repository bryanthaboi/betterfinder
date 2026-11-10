import Foundation
import FSCore

@MainActor
final class FolderModel {
    enum Change {
        case reset
        case diff(ListDiff)
    }

    struct FSEventBatch {
        var rootChanged: Bool
        var directories: Set<String>
        var paths: [String]
    }

    let location: BrowserLocation
    private(set) var items: [FileItem] = []
    private var unfiltered: [FileItem] = []
    private(set) var filter: ItemFilter?
    var filteredOutCount: Int { filter == nil ? 0 : unfiltered.count - items.count }
    private(set) var hiddenCount = 0
    private(set) var isLoading = false
    private(set) var error: Error?
    private(set) var sorter: ItemSorter

    private var observers: [ObjectIdentifier: (Change) -> Void] = [:]
    var onFSEvents: ((FSEventBatch) -> Void)?
    var onRootGone: (() -> Void)?
    var onLoadingChange: (() -> Void)?

    private var token: CancelToken?
    private var generation = 0
    private var watcher: DirectoryWatcher?
    var searchNotice: String?
    static var makeSearch: (MetadataSearch.Kind) -> MetadataSearch = { MetadataSearch(kind: $0) }
    private var search: MetadataSearch?
    private var searchPaths: Set<String> = []
    private var searchAccumulated: [FileItem] = []
    private var searchSortInFlight = false
    private var searchSortDirty = false
    private var sortGeneration = 0
    private var pendingEventPaths: [String] = []
    private var eventFlushScheduled = false
    private var resolvedRoot: String?
    private var started = false

    init(location: BrowserLocation, sort: SortSpec = BrowserDefaults.sort) {
        self.location = location
        self.sorter = ItemSorter(spec: sort)
    }

    deinit {
        token?.cancel()
        watcher?.stop()
        let s = search
        if let s { onMain { s.stop() } }
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping (Change) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    private func emit(_ change: Change) {
        for h in observers.values { h(change) }
    }

    var directoryURL: URL? { location.url }

    func start() {
        guard !started else { return }
        started = true
        if let url = location.url { startWatching(url) }
        load()
    }

    func stop() {
        token?.cancel()
        watcher?.stop()
        watcher = nil
        search?.stop()
        search = nil
        observers.removeAll()
        onFSEvents = nil
        onRootGone = nil
    }

    func refresh() {
        switch location {
        case .folder, .computer: relist(isInitial: false)
        default: load()
        }
    }

    func load() {
        search?.stop()
        search = nil
        searchNotice = nil
        switch location {
        case .folder, .computer:
            relist(isInitial: true)
        case .search(let scope, let q):
            runSearch(.name(q, scope: scope))
        case .recents:
            runSearch(.recents)
        case .tag(let t):
            runSearch(.tag(t))
        }
    }

    func updateSort(_ spec: SortSpec) {
        sorter.spec = spec
        resort()
    }

    func updateSizes(_ sizes: [String: Int64]) {
        sorter.sizes = sizes
        if sorter.spec.key == .size { resort() }
    }

    func updateCustomValues(_ values: [String: ColumnValue]) {
        sorter.customValues = values
        if sorter.spec.key == .custom { resort() }
    }

    func updateDimensions(_ dims: [String: Int]) {
        sorter.dimensions = dims
        if sorter.spec.key == .dimensions { resort() }
    }

    func sortedItems(_ input: [FileItem]) -> [FileItem] { sorter.sorted(input) }

    func setFilter(_ newFilter: ItemFilter?) {
        guard newFilter != filter else { return }
        filter = newFilter
        items = newFilter?.apply(unfiltered) ?? unfiltered
        emit(.reset)
    }

    private func resort() {
        let snapshot = unfiltered
        let s = sorter
        sortGeneration += 1
        let sg = sortGeneration
        let gen = generation
        DirectoryStream.queue.async { [weak self] in
            let sorted = s.sorted(snapshot)
            onMain {
                guard let self, self.generation == gen, self.sortGeneration == sg, self.unfiltered.count == snapshot.count else { return }
                self.unfiltered = sorted
                self.items = self.filter?.apply(sorted) ?? sorted
                self.emit(.reset)
            }
        }
    }

    private func setLoading(_ v: Bool) {
        guard isLoading != v else { return }
        isLoading = v
        onLoadingChange?()
    }

    private func relist(isInitial: Bool) {
        token?.cancel()
        let token = CancelToken()
        self.token = token
        generation += 1
        let gen = generation
        let location = self.location
        let showHidden = BrowserDefaults.showHidden
        let sorter = self.sorter
        let activeFilter = filter
        if isInitial {
            items = []
            unfiltered = []
            hiddenCount = 0
            error = nil
            emit(.reset)
        }
        setLoading(true)
        let baseline = items
        Task.detached(priority: .userInitiated) { [weak self] in
            var result = ListingResult(visible: [], hiddenCount: 0)
            var listError: Error?
            switch location {
            case .computer:
                result.visible = DirectoryStream.listVolumes()
            case .folder(let url):
                do {
                    result = try await DirectoryStream.enumerate(url, showHidden: showHidden, token: token) { partial, hidden in
                        guard isInitial else { return }
                        let sorted = sorter.sorted(partial)
                        onMain {
                            guard let self, self.generation == gen, !token.isCancelled else { return }
                            self.apply(sorted, hidden: hidden)
                        }
                    }
                } catch {
                    listError = error
                }
            default:
                break
            }
            if token.isCancelled { return }
            let sorted = sorter.sorted(result.visible)
            let hidden = result.hiddenCount
            let shown = activeFilter?.apply(sorted) ?? sorted
            let diff = isInitial ? nil : ListDiff.compute(old: baseline, new: shown)
            let finalError = listError
            onMain {
                guard let self, self.generation == gen, !token.isCancelled else { return }
                self.error = finalError
                if let diff, self.items == baseline, self.filter == activeFilter {
                    self.unfiltered = sorted
                    self.items = shown
                    self.hiddenCount = hidden
                    if !diff.isEmpty { self.emit(diff.size > 2000 ? .reset : .diff(diff)) }
                } else {
                    self.apply(sorted, hidden: hidden)
                }
                self.setLoading(false)
                if sorted.count > 2000 { MemoryRelief.schedule() }
                if self.sorter.spec != sorter.spec || self.sorter.sizes != sorter.sizes { self.resort() }
            }
        }
    }

    private func apply(_ all: [FileItem], hidden: Int) {
        hiddenCount = hidden
        unfiltered = all
        let sorted = filter?.apply(all) ?? all
        let old = items
        items = sorted
        if old.isEmpty || sorted.isEmpty || abs(sorted.count - old.count) > 2000 {
            emit(.reset)
        } else if let d = ListDiff.compute(old: old, new: sorted), d.size <= 2000 {
            if !d.isEmpty { emit(.diff(d)) }
        } else {
            emit(.reset)
        }
    }

    private func runSearch(_ kind: MetadataSearch.Kind) {
        token?.cancel()
        let token = CancelToken()
        self.token = token
        generation += 1
        items = []
        unfiltered = []
        hiddenCount = 0
        searchPaths = []
        searchAccumulated = []
        searchSortDirty = false
        searchSortInFlight = false
        searchNotice = nil
        let gen0 = generation
        emit(.reset)
        setLoading(true)
        let s = Self.makeSearch(kind)
        let excludeFolders: Bool
        if case .recents = kind { excludeFolders = true } else { excludeFolders = false }
        let showHidden = BrowserDefaults.showHidden
        s.onPaths = { [weak self] paths in
            guard let self else { return }
            let fresh = paths.filter { self.searchPaths.insert($0).inserted }
            guard !fresh.isEmpty else { return }
            let gen = self.generation
            DirectoryStream.queue.async { [weak self] in
                var newItems: [FileItem] = []
                for p in fresh {
                    if token.isCancelled { return }
                    guard let item = DirectoryLister.item(for: URL(fileURLWithPath: p)) else { continue }
                    if excludeFolders && item.isBrowsableFolder { continue }
                    if !showHidden && item.isHidden { continue }
                    newItems.append(item)
                }
                onMain {
                    guard let self, self.generation == gen, !token.isCancelled else { return }
                    self.searchAccumulated.append(contentsOf: newItems)
                    self.scheduleSearchSort(gen: gen, token: token)
                }
            }
        }
        let limit = s.resultLimit
        s.onFinish = { [weak self] completeness in
            guard let self, self.generation == gen0, !token.isCancelled else { return }
            self.searchNotice = completeness.notice(resultLimit: limit)
            if self.isLoading { self.setLoading(false) } else { self.onLoadingChange?() }
        }
        search = s
        s.start()
    }

    private func scheduleSearchSort(gen: Int, token: CancelToken) {
        guard !searchSortInFlight else { searchSortDirty = true; return }
        searchSortInFlight = true
        searchSortDirty = false
        let snapshot = searchAccumulated
        let sorter = self.sorter
        DirectoryStream.queue.async { [weak self] in
            let sorted = sorter.sorted(snapshot)
            onMain {
                guard let self else { return }
                guard self.generation == gen, !token.isCancelled else { return }
                self.searchSortInFlight = false
                if sorted.count >= self.unfiltered.count { self.apply(sorted, hidden: 0) }
                if self.searchSortDirty { self.scheduleSearchSort(gen: gen, token: token) }
            }
        }
    }

    private func startWatching(_ url: URL) {
        resolvedRoot = url.resolvingSymlinksInPath().pathKey
        let w = DirectoryWatcher(paths: [url]) { [weak self] paths in
            onMain { self?.queueEvents(paths) }
        }
        w.start()
        watcher = w
    }

    private func queueEvents(_ paths: [String]) {
        pendingEventPaths.append(contentsOf: paths)
        guard !eventFlushScheduled else { return }
        eventFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { self?.flushEvents() }
        }
    }

    private func flushEvents() {
        eventFlushScheduled = false
        guard let root = location.url?.pathKey else { return }
        let resolved = resolvedRoot ?? root
        let raw = pendingEventPaths
        pendingEventPaths.removeAll()
        var rootChanged = false
        var dirs = Set<String>()
        var mapped: [String] = []
        for p0 in raw {
            var p = (p0 as NSString).standardizingPath
            if p.hasSuffix("/") && p.count > 1 { p.removeLast() }
            if resolved != root, p.hasPrefix(resolved) { p = root + p.dropFirst(resolved.count) }
            mapped.append(p)
            if p == root {
                rootChanged = true
                continue
            }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == root { rootChanged = true } else { dirs.insert(parent) }
        }
        if !FileManager.default.fileExists(atPath: root) {
            onRootGone?()
            return
        }
        if rootChanged { relist(isInitial: false) }
        onFSEvents?(FSEventBatch(rootChanged: rootChanged, directories: dirs, paths: mapped))
    }
}
