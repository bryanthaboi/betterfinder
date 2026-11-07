import Foundation

public enum TagOps {
    public static func tags(for url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    public static func setTags(_ tags: [String], for url: URL) throws {
        try setTags(tags, for: [url])
    }

    public static func setTags(_ tags: [String], for urls: [URL]) throws {
        if !urls.isEmpty { try FileOperationHookRegistry.shared.throwIfAsyncRequired() }
        let previous = try applyTags(tags, to: urls)
        registerUndo(tags: tags, previous: previous, registry: .shared)
    }

    public static func setTagsAsync(_ tags: [String], for url: URL, registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        try await setTagsAsync(tags, for: [url], registry: registry, origin: origin)
    }

    public static func setTagsAsync(_ tags: [String], for urls: [URL], registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        guard !urls.isEmpty else { return }
        try await FileOperationQueue.trackingShared {
            let previous: [(URL, [String])] = try await registry.guarded(kind: .tag, items: urls.map { OperationItem(source: $0, destination: nil) }, origin: origin, tags: tags) {
                GuardedResult(value: try applyTags(tags, to: urls), urls: urls.map { Optional($0) })
            }
            await MainActor.run { registerUndo(tags: tags, previous: previous, registry: registry) }
        }
    }

    public static func addTags(_ names: [String], to url: URL) throws {
        var current = tags(for: url)
        for n in names where !current.contains(n) { current.append(n) }
        try setTags(current, for: url)
    }

    public static func removeTags(_ names: [String], from url: URL) throws {
        try setTags(tags(for: url).filter { !names.contains($0) }, for: url)
    }

    public static func addTagsAsync(_ names: [String], to url: URL, registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        var current = tags(for: url)
        for n in names where !current.contains(n) { current.append(n) }
        try await setTagsAsync(current, for: url, registry: registry, origin: origin)
    }

    public static func removeTagsAsync(_ names: [String], from url: URL, registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        try await setTagsAsync(tags(for: url).filter { !names.contains($0) }, for: url, registry: registry, origin: origin)
    }

    private static func applyTags(_ tags: [String], to urls: [URL]) throws -> [(URL, [String])] {
        var previous: [(URL, [String])] = []
        for url in urls {
            let old = Self.tags(for: url)
            do {
                try write(tags, to: url)
            } catch {
                for (u, t) in previous.reversed() { try? write(t, to: u) }
                throw error
            }
            previous.append((url, old))
        }
        return previous
    }

    private static func registerUndo(tags: [String], previous: [(URL, [String])], registry: FileOperationHookRegistry) {
        guard !previous.isEmpty, previous.contains(where: { $0.1 != tags }) else { return }
        guard Thread.isMainThread else { return }
        let urls = previous.map(\.0)
        MainActor.assumeIsolated {
            let queue = FileOperationQueue.shared
            queue.registerUndoPair(name: "Change Tags", undo: {
                queue.runStep(registry: registry, kind: .tag, items: urls.map { OperationItem(source: $0, destination: nil) }) {
                    for (u, t) in previous { try? write(t, to: u) }
                    return urls.map { Optional($0) }
                }
            }, redo: {
                queue.runStep(registry: registry, kind: .tag, items: urls.map { OperationItem(source: $0, destination: nil) }) {
                    for u in urls { try? write(tags, to: u) }
                    return urls.map { Optional($0) }
                }
            })
        }
    }

    private static func write(_ tags: [String], to url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
