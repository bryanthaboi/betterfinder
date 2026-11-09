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
        var hitVisitLimit = false
        var skippedDirectories = 0

        var isComplete: Bool { !hitResultLimit && !hitVisitLimit && skippedDirectories == 0 }

        func notice(resultLimit: Int) -> String? {
            if hitResultLimit { return "Showing the first \(resultLimit.formatted()) matches — narrow your search" }
            if hitVisitLimit { return "Partial results — the search stopped after checking too many items" }
            if skippedDirectories == 1 { return "Partial results — 1 folder couldn’t be searched" }
            if skippedDirectories > 1 { return "Partial results — \(skippedDirectories.formatted()) folders couldn’t be searched" }
            return nil
        }
    }

    let kind: Kind
    var onPaths: (([String]) -> Void)?
    var onFinish: ((Completeness) -> Void)?
    var resultLimit = 5000
    var visitLimit = 2_000_000
    var forcesWalk = false
    private(set) var completeness = Completeness()

    private var query: NSMetadataQuery?
    private var consumed = 0
    private var delivered = 0
    private var walkToken: CancelToken?
    private var walking = false
    private var finished = false

    init(kind: Kind) {
        if DemoEnvironment.isEnabled, case .name(let text, let scope) = kind {
            self.kind = .name(text, scope: DemoEnvironment.searchURL(scope))
        } else {
            self.kind = kind
        }
    }

    func start() {
        if case .name(_, let scope) = kind, forcesWalk || Self.prefersWalk(scope) {
            startWalk()
            return
        }
        let q = NSMetadataQuery()
        q.notificationBatchingInterval = 0.25
        switch kind {
        case .name(let text, let scope):
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
            q.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(escaped)*")
            q.searchScopes = scope.path == "/" ? [NSMetadataQueryLocalComputerScope] : [scope]
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
        if !q.start() { startWalkIfPossible() }
    }

    func stop() {
        if let q = query {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: q)
        }
        query = nil
        walkToken?.cancel()
        walkToken = nil
        onPaths = nil
        onFinish = nil
    }

    static func prefersWalk(_ scope: URL) -> Bool {
        if scope.path == "/" { return false }
        if VolumeInfo.isNetworkVolume(scope) { return true }
        let v = try? scope.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        return v?.volumeIsInternal == false && v?.volumeIsLocal == true && !Self.volumeIsIndexed(scope)
    }

    static func volumeIsIndexed(_ url: URL) -> Bool {
        guard let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return true }
        let marker = vol.appendingPathComponent(".Spotlight-V100")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    @objc private func gathered(_ note: Notification) {
        drain()
    }

    @objc private func finishedGathering(_ note: Notification) {
        drain()
        query?.stop()
        if delivered == 0 { startWalkIfPossible() } else { finish() }
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

    private lazy var scopeRemap: (real: String, display: String)? = {
        guard case .name(_, let scope) = kind else { return nil }
        let display = scope.pathKey
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(display, &buf) != nil else { return nil }
        let real = String(cString: buf)
        return real == display ? nil : (real, display)
    }()

    private func deliver(_ raw: [String]) {
        guard !raw.isEmpty else { return }
        var paths = raw
        if let (real, display) = scopeRemap {
            paths = raw.map { $0.hasPrefix(real + "/") ? display + $0.dropFirst(real.count) : $0 }
        }
        if DemoEnvironment.isEnabled { paths = paths.filter { DemoEnvironment.contains(URL(fileURLWithPath: $0), in: DemoEnvironment.home) } }
        delivered += paths.count
        onPaths?(paths)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?(completeness)
    }

    private func startWalkIfPossible() {
        guard case .name(_, let scope) = kind, scope.path != "/" else { finish(); return }
        startWalk()
    }

    private func startWalk() {
        guard case .name(let text, let scope) = kind, !walking else { finish(); return }
        walking = true
        let token = CancelToken()
        walkToken = token
        let limit = resultLimit
        let maxVisits = visitLimit
        let showHidden = BrowserDefaults.showHidden
        DirectoryStream.queue.async { [weak self] in
            let needle = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            let skipped = WalkErrorCounter()
            let e = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: [.nameKey], options: options, errorHandler: { url, _ in
                skipped.record(url)
                return true
            })
            var batch: [String] = []
            var found = 0
            var visited = 0
            var last = Date()
            var hitResultLimit = false
            var hitVisitLimit = false
            while let url = e?.nextObject() as? URL {
                if token.isCancelled { return }
                visited += 1
                if visited > maxVisits { hitVisitLimit = true; break }
                let name = url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if name.contains(needle) {
                    batch.append(url.path)
                    found += 1
                    if found >= limit {
                        hitResultLimit = e?.nextObject() != nil
                        break
                    }
                }
                if !batch.isEmpty && Date().timeIntervalSince(last) > 0.25 {
                    let out = batch
                    batch.removeAll()
                    last = Date()
                    onMain { if !token.isCancelled { self?.deliver(out) } }
                }
            }
            let out = batch
            let skippedCount = skipped.count
            onMain {
                guard !token.isCancelled, let self else { return }
                self.completeness.hitResultLimit = self.completeness.hitResultLimit || hitResultLimit
                self.completeness.hitVisitLimit = hitVisitLimit
                self.completeness.skippedDirectories = skippedCount
                self.deliver(out)
                self.finish()
            }
        }
    }
}

final class WalkErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func record(_ url: URL) {
        lock.lock()
        paths.insert(url.path)
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return paths.count
    }
}
