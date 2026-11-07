import Foundation
import FSCore

@MainActor
final class SizeCoordinator {
    private(set) var results: [String: SizeResult] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var pending: [URL] = []
    private var pinned: Set<String> = []
    var maxConcurrent = 4
    var enabled = true
    var onUpdate: ((String) -> Void)?

    func result(for url: URL) -> SizeResult? { results[url.pathKey] }

    var completedAllocated: [String: Int64] {
        results.compactMapValues { $0.isComplete ? $0.allocatedBytes : nil }
    }

    func request(visible urls: [URL], pinned pinnedURLs: [URL] = []) {
        guard enabled else { return }
        pinned = Set(pinnedURLs.map(\.pathKey))
        let wanted = pinnedURLs + urls
        let wantedKeys = Set(wanted.map(\.pathKey))
        for (key, task) in running where !wantedKeys.contains(key) {
            task.cancel()
            running[key] = nil
        }
        var seen = Set<String>()
        pending = wanted.filter { u in
            let k = u.pathKey
            guard seen.insert(k).inserted else { return false }
            return running[k] == nil && results[k]?.isComplete != true
        }
        pump()
    }

    func invalidate(_ key: String) {
        if let t = running[key] { t.cancel(); running[key] = nil }
        results[key] = nil
    }

    func invalidateContaining(path: String, under root: String) {
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return }
        let rest = path.dropFirst(root == "/" ? 1 : root.count + 1)
        guard let first = rest.split(separator: "/").first else { return }
        let top = (root == "/" ? "/" : root + "/") + first
        if results[top] != nil || running[top] != nil {
            invalidate(top)
            pending.insert(URL(fileURLWithPath: top), at: 0)
            pump()
        }
    }

    func reset() {
        for t in running.values { t.cancel() }
        running.removeAll()
        pending.removeAll()
        results.removeAll()
    }

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let url = pending.removeFirst()
            let key = url.pathKey
            guard running[key] == nil else { continue }
            running[key] = Task { [weak self] in
                let stream = await SizeEngine.shared.size(of: url)
                var lastEmit = Date.distantPast
                for await r in stream {
                    if Task.isCancelled { break }
                    guard let self else { return }
                    self.results[key] = r
                    if r.isComplete || Date().timeIntervalSince(lastEmit) > 0.25 {
                        lastEmit = Date()
                        self.onUpdate?(key)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.running[key] = nil
                self.pump()
            }
        }
    }
}
