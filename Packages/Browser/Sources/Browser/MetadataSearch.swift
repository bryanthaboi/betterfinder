import Foundation
import FSCore

@MainActor
final class MetadataSearch: NSObject {
    enum Kind {
        case name(String, scope: URL)
        case recents
        case tag(String)
    }

    struct Completeness: Equatable, Sendable {
        var hitResultLimit = false
        var unindexed = false

        var isComplete: Bool { !hitResultLimit && !unindexed }

        func notice(resultLimit: Int) -> String? {
            if hitResultLimit { return "Showing the first \(resultLimit.formatted()) matches — narrow your search" }
            if unindexed { return "This location isn’t in the file index yet" }
            return nil
        }
    }

    let kind: Kind
    var onPaths: (([String]) -> Void)?
    var onFinish: ((Completeness) -> Void)?
    var resultLimit = 5000
    var engine: SizeEngine = .shared
    private(set) var completeness = Completeness()

    private var query: NSMetadataQuery?
    private var consumed = 0
    private var delivered = 0
    private var indexTask: Task<Void, Never>?
    private var finished = false

    init(kind: Kind) {
        if DemoEnvironment.isEnabled, case .name(let text, let scope) = kind {
            self.kind = .name(text, scope: DemoEnvironment.searchURL(scope))
        } else {
            self.kind = kind
        }
    }

    func start() {
        let q = NSMetadataQuery()
        q.notificationBatchingInterval = 0.25
        switch kind {
        case .name(let text, let scope):
            searchIndex(text, under: scope)
            return
        case .recents:
            let since = Date().addingTimeInterval(-30 * 86400)
            q.predicate = NSPredicate(format: "%K >= %@ AND %K != 'public.folder'", NSMetadataItemLastUsedDateKey as NSString, since as NSDate, NSMetadataItemContentTypeKey as NSString)
            q.searchScopes = [NSMetadataQueryUserHomeScope]
            q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        case .tag(let tag):
            q.predicate = NSPredicate(format: "kMDItemUserTags == %@", tag)
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        }
        if DemoEnvironment.isEnabled { q.searchScopes = [DemoEnvironment.home] }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryGatheringProgress, object: q)
        nc.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidUpdate, object: q)
        nc.addObserver(self, selector: #selector(finishedGathering(_:)), name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        if !q.start() { finish() }
    }

    func stop() {
        if let q = query {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: q)
        }
        query = nil
        indexTask?.cancel()
        indexTask = nil
        onPaths = nil
        onFinish = nil
    }

    private func searchIndex(_ text: String, under scope: URL) {
        let stream = engine.search(text, under: scope, includeHidden: BrowserDefaults.showHidden, limit: resultLimit)
        indexTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .paths(let paths):
                    self.deliver(paths)
                case .finished(let summary):
                    self.completeness.hitResultLimit = summary.hitLimit
                    self.completeness.unindexed = !summary.indexed
                    self.finish()
                }
            }
        }
    }

    @objc private func gathered(_ note: Notification) {
        drain()
    }

    @objc private func finishedGathering(_ note: Notification) {
        drain()
        query?.stop()
        finish()
    }

    private func drain() {
        guard let q = query else { return }
        q.disableUpdates()
        let count = q.resultCount
        var paths: [String] = []
        while consumed < count && delivered + paths.count < resultLimit {
            if let item = q.result(at: consumed) as? NSMetadataItem, let p = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(p)
            }
            consumed += 1
        }
        if consumed < count && delivered + paths.count >= resultLimit { completeness.hitResultLimit = true }
        q.enableUpdates()
        deliver(paths)
    }

    private func deliver(_ raw: [String]) {
        guard !raw.isEmpty else { return }
        var paths = raw
        if DemoEnvironment.isEnabled { paths = paths.filter { DemoEnvironment.contains(URL(fileURLWithPath: $0), in: DemoEnvironment.home) } }
        delivered += paths.count
        onPaths?(paths)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?(completeness)
    }
}
