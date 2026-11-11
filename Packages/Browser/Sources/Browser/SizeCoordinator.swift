import Foundation
import FSCore

@MainActor
final class SizeCoordinator {
    static let backgroundLimit = 4000
    static let watchWindow: TimeInterval = 8
    static let missLimit = 30

    private struct Target {
        let url: URL
        let key: String
    }

    private(set) var results: [String: SizeResult] = [:]
    var enabled = true
    var engine: SizeEngine = .shared
    var onUpdate: ((String) -> Void)?

    private var wanted: [Target] = []
    private var background: [Target] = []
    private var tracked = Set<String>()
    private var container: URL?
    private var watching: [String: Date] = [:]
    private var misses: [String: Int] = [:]
    private var poll: Task<Void, Never>?
    private var sweep: Task<Void, Never>?
    private var lastFocus: [String] = []

    func result(for url: URL) -> SizeResult? { results[url.pathKey] }

    var settledAllocated: [String: Int64] {
        results.compactMapValues { $0.isSettled ? $0.allocatedBytes : nil }
    }

    func request(visible urls: [URL], pinned pinnedURLs: [URL] = [], everything: [URL] = [], container: URL? = nil) {
        guard enabled else { return }
        self.container = container?.path == "/" ? nil : container
        var seen = Set<String>()
        func targets(_ list: [URL]) -> [Target] {
            list.compactMap { url in
                let key = url.pathKey
                return seen.insert(key).inserted ? Target(url: url, key: key) : nil
            }
        }
        wanted = targets(pinnedURLs + urls)
        background = Array(targets(everything).prefix(Self.backgroundLimit))
        tracked = Set(wanted.map(\.key)).union(background.map(\.key))
        for target in wanted { misses[target.key] = nil }
        apply(engine.snapshot(of: wanted.map(\.url)), for: wanted)
        sendFocus()
        if !background.isEmpty { loadBackground() }
        startPolling()
    }

    func touch(path: String, under root: String) {
        let base = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(base) else { return }
        let rest = path.dropFirst(base.count)
        guard !rest.isEmpty else { return }
        let key = base + rest.prefix { $0 != "/" }
        guard tracked.contains(key) || results[key] != nil else { return }
        watching[key] = Date().addingTimeInterval(Self.watchWindow)
        misses[key] = nil
        startPolling()
    }

    func reset() {
        poll?.cancel()
        poll = nil
        sweep?.cancel()
        sweep = nil
        wanted.removeAll()
        background.removeAll()
        tracked.removeAll()
        container = nil
        watching.removeAll()
        misses.removeAll()
        results.removeAll()
        lastFocus.removeAll()
    }

    private func isLive(_ key: String, now: Date) -> Bool {
        if let until = watching[key] {
            if until > now { return true }
            watching[key] = nil
        }
        guard let known = results[key] else { return (misses[key] ?? 0) < Self.missLimit }
        return known.isCounting || known.isStale
    }

    private func apply(_ snapshot: [SizeResult?], for targets: [Target]) {
        var changed: [String] = []
        for (target, fresh) in zip(targets, snapshot) {
            guard let fresh else {
                if results[target.key] == nil { misses[target.key, default: 0] += 1 }
                continue
            }
            misses[target.key] = nil
            if results[target.key] != fresh {
                results[target.key] = fresh
                changed.append(target.key)
            }
        }
        for key in changed { onUpdate?(key) }
    }

    private func sendFocus() {
        let now = Date()
        var needy = wanted.filter { isLive($0.key, now: now) }.map(\.url)
        var keys = needy.map(\.path)
        if let container, wanted.contains(where: { results[$0.key] == nil }) || background.contains(where: { results[$0.key] == nil }) {
            needy.append(container)
            keys.append(container.path)
        }
        guard !keys.isEmpty, keys != lastFocus else { return }
        lastFocus = keys
        engine.focus(on: needy)
    }

    private func loadBackground() {
        sweep?.cancel()
        let targets = background
        let engine = engine
        sweep = Task { [weak self] in
            let urls = targets.map(\.url)
            let snapshot = await Task.detached(priority: .utility) { engine.snapshot(of: urls) }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(snapshot, for: targets)
            self.sendFocus()
            self.startPolling()
        }
    }

    private func nextRound() -> (targets: [Target], urgent: Bool, engine: SizeEngine)? {
        let now = Date()
        let live = (wanted + background).filter { isLive($0.key, now: now) }
        guard !live.isEmpty, enabled else {
            poll = nil
            return nil
        }
        return (live, live.contains { results[$0.key]?.isCounting ?? true }, engine)
    }

    private func startPolling() {
        guard poll == nil, enabled else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let round = self?.nextRound() else { return }
                try? await Task.sleep(for: .milliseconds(round.urgent ? 350 : 1200))
                if Task.isCancelled { return }
                let urls = round.targets.map(\.url)
                let snapshot = await Task.detached(priority: .utility) { round.engine.snapshot(of: urls) }.value
                guard let self, !Task.isCancelled else { return }
                self.apply(snapshot, for: round.targets)
            }
        }
    }
}
