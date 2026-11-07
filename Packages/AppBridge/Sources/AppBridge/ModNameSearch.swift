import Foundation
import ModHost

public final class ModNameSearch: ModFileSearching, @unchecked Sendable {
    public let maxVisited: Int

    public init(maxVisited: Int = 20_000) { self.maxVisited = maxVisited }

    public func search(_ query: String, under root: URL, limit: Int, cursor: String?) async throws -> (urls: [URL], cursor: String?) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ([], nil) }
        let skip = cursor.flatMap(Int.init) ?? 0
        let cap = max(1, min(limit, 128))
        let maxVisited = maxVisited
        return try await Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.nameKey, .isHiddenKey]
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], nil) }
            var matched = 0
            var out = [URL]()
            var visited = 0
            while let url = en.nextObject() as? URL {
                visited += 1
                if visited % 256 == 0 { try Task.checkCancellation() }
                if visited > maxVisited { break }
                guard url.lastPathComponent.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                matched += 1
                if matched <= skip { continue }
                out.append(url)
                if out.count == cap { return (out, String(skip + cap)) }
            }
            return (out, nil)
        }.value
    }
}
