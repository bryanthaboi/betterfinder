import Foundation

public enum BatchRename {
    public enum CaseStyle: Sendable, Hashable {
        case lowercase, uppercase, capitalizedWords, sentence
    }

    public enum SequencePlacement: Sendable, Hashable {
        case prefix, suffix, replaceName
    }

    public enum Rule: Sendable, Hashable {
        case replaceText(find: String, with: String, caseSensitive: Bool)
        case regex(pattern: String, template: String, caseSensitive: Bool)
        case addPrefix(String)
        case addSuffix(String)
        case sequence(start: Int, step: Int, padding: Int, placement: SequencePlacement, separator: String)
        case changeCase(CaseStyle)
    }

    public struct Options: Sendable, Hashable {
        public var applyToExtension: Bool
        public init(applyToExtension: Bool = false) { self.applyToExtension = applyToExtension }
    }

    public enum Conflict: Sendable, Hashable {
        case emptyName
        case invalidName
        case tooLong
        case duplicateTarget
        case existsOnDisk
        case invalidPattern
    }

    public struct PreviewItem: Sendable, Hashable, Identifiable {
        public var id: URL { url }
        public let url: URL
        public let oldName: String
        public let newName: String
        public let conflict: Conflict?

        public var isChanged: Bool { oldName != newName }
        public var newURL: URL { url.deletingLastPathComponent().appendingPathComponent(newName) }
    }

    public enum RenameError: Error, LocalizedError {
        case conflicts([PreviewItem])
        case failed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .conflicts(let items): return "\(items.count) name\(items.count == 1 ? "" : "s") conflict, nothing was renamed."
            case .failed(let url, let m): return "Couldn’t rename “\(url.lastPathComponent)”: \(m)"
            }
        }
    }

    public static func newName(for name: String, index: Int, rules: [Rule], options: Options = Options()) -> (name: String, patternError: Bool) {
        var stem: String
        var ext: String
        if options.applyToExtension {
            stem = name
            ext = ""
        } else {
            let ns = name as NSString
            ext = ns.pathExtension
            stem = ext.isEmpty ? name : ns.deletingPathExtension
        }
        var patternError = false
        for rule in rules {
            switch rule {
            case .replaceText(let find, let with, let caseSensitive):
                guard !find.isEmpty else { continue }
                stem = stem.replacingOccurrences(of: find, with: with, options: caseSensitive ? [] : [.caseInsensitive])
            case .regex(let pattern, let template, let caseSensitive):
                guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
                    patternError = true
                    continue
                }
                let range = NSRange(stem.startIndex..., in: stem)
                stem = re.stringByReplacingMatches(in: stem, options: [], range: range, withTemplate: template)
            case .addPrefix(let text):
                stem = text + stem
            case .addSuffix(let text):
                stem += text
            case .sequence(let start, let step, let padding, let placement, let separator):
                let value = start + index * step
                var digits = String(abs(value))
                if digits.count < padding { digits = String(repeating: "0", count: padding - digits.count) + digits }
                if value < 0 { digits = "-" + digits }
                switch placement {
                case .prefix: stem = digits + separator + stem
                case .suffix: stem = stem + separator + digits
                case .replaceName: stem = digits
                }
            case .changeCase(let style):
                switch style {
                case .lowercase: stem = stem.lowercased()
                case .uppercase: stem = stem.uppercased()
                case .capitalizedWords: stem = stem.capitalized
                case .sentence:
                    let lower = stem.lowercased()
                    stem = lower.prefix(1).uppercased() + lower.dropFirst()
                }
            }
        }
        if ext.isEmpty { return (stem, patternError) }
        return (stem + "." + ext, patternError)
    }

    public static func preview(urls: [URL], rules: [Rule], options: Options = Options()) -> [PreviewItem] {
        var computed: [(url: URL, old: String, new: String, patternError: Bool)] = []
        for (i, url) in urls.enumerated() {
            let old = url.lastPathComponent
            let r = newName(for: old, index: i, rules: rules, options: options)
            computed.append((url, old, r.name, r.patternError))
        }

        func key(_ dir: URL, _ name: String) -> String {
            let caseInsensitive = !((try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false)
            let n = caseInsensitive ? name.lowercased() : name
            return dir.standardizedFileURL.path + "/" + n
        }

        var targetCounts: [String: Int] = [:]
        var oldKeys: [String: URL] = [:]
        for c in computed {
            let dir = c.url.deletingLastPathComponent()
            targetCounts[key(dir, c.new), default: 0] += 1
            oldKeys[key(dir, c.old)] = c.url
        }

        return computed.map { c in
            let dir = c.url.deletingLastPathComponent()
            var conflict: Conflict?
            if c.patternError {
                conflict = .invalidPattern
            } else if c.new.isEmpty {
                conflict = .emptyName
            } else if c.new.contains("/") || c.new.contains("\0") || c.new == "." || c.new == ".." {
                conflict = .invalidName
            } else if c.new.utf8.count > 255 {
                conflict = .tooLong
            } else if c.new != c.old {
                let k = key(dir, c.new)
                if (targetCounts[k] ?? 0) > 1 {
                    conflict = .duplicateTarget
                } else if FS.exists(dir.appendingPathComponent(c.new)), oldKeys[k] == nil, !FS.sameFile(c.url, dir.appendingPathComponent(c.new)) {
                    conflict = .existsOnDisk
                }
            }
            return PreviewItem(url: c.url, oldName: c.old, newName: c.new, conflict: conflict)
        }
    }

    @discardableResult
    public static func apply(_ items: [PreviewItem]) throws -> [URL] {
        let conflicts = items.filter { $0.isChanged && $0.conflict != nil }
        guard conflicts.isEmpty else { throw RenameError.conflicts(conflicts) }
        let changed = items.filter(\.isChanged)
        let pairs = changed.map { (from: $0.url, to: $0.newURL) }
        if !pairs.isEmpty { try FileOperationHookRegistry.shared.throwIfAsyncRequired() }
        try performRenames(pairs)
        if !pairs.isEmpty { registerUndo(pairs, registry: .shared) }
        return items.map { $0.isChanged ? $0.newURL : $0.url }
    }

    @discardableResult
    public static func applyAsync(_ items: [PreviewItem], registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> [URL] {
        let conflicts = items.filter { $0.isChanged && $0.conflict != nil }
        guard conflicts.isEmpty else { throw RenameError.conflicts(conflicts) }
        let pairs = items.filter(\.isChanged).map { (from: $0.url, to: $0.newURL) }
        if !pairs.isEmpty {
            try await FileOperationQueue.trackingShared {
                try await registry.guarded(kind: .batchRename, items: pairs.map { OperationItem(source: $0.from, destination: $0.to) }, origin: origin) {
                    try performRenames(pairs)
                    return GuardedResult(value: (), urls: pairs.map { Optional($0.to) })
                }
                await MainActor.run { registerUndo(pairs, registry: registry) }
            }
        }
        return items.map { $0.isChanged ? $0.newURL : $0.url }
    }

    @discardableResult
    public static func applyAsync(urls: [URL], rules: [Rule], options: Options = Options(), registry: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> [URL] {
        try await applyAsync(preview(urls: urls, rules: rules, options: options), registry: registry, origin: origin)
    }

    private static func registerUndo(_ pairs: [(from: URL, to: URL)], registry: FileOperationHookRegistry) {
        guard Thread.isMainThread else { return }
        let state = PairState(pairs: pairs)
        let name = "Rename \(pairs.count) Item\(pairs.count == 1 ? "" : "s")"
        MainActor.assumeIsolated {
            let queue = FileOperationQueue.shared
            queue.registerFallible(name: name, undo: { done in
                let reversed = state.pairs.map { (from: $0.to, to: $0.from) }
                queue.runStep(registry: registry, kind: .batchRename, items: reversed.map { OperationItem(source: $0.from, destination: $0.to) }, name: name, done: done) {
                    try performRenames(reversed)
                    return reversed.map { Optional($0.to) }
                }
            }, redo: { done in
                queue.runStep(registry: registry, kind: .batchRename, items: state.pairs.map { OperationItem(source: $0.from, destination: $0.to) }, name: name, done: done) {
                    try performRenames(state.pairs)
                    return state.pairs.map { Optional($0.to) }
                }
            })
        }
    }

    @discardableResult
    public static func apply(urls: [URL], rules: [Rule], options: Options = Options()) throws -> [URL] {
        try apply(preview(urls: urls, rules: rules, options: options))
    }

    private final class PairState {
        let pairs: [(from: URL, to: URL)]
        init(pairs: [(from: URL, to: URL)]) { self.pairs = pairs }
    }

    static func performRenames(_ pairs: [(from: URL, to: URL)]) throws {
        func k(_ u: URL) -> String { u.standardizedFileURL.path.lowercased() }
        let sources = Set(pairs.map { k($0.from) })
        let needsTemp = pairs.contains { sources.contains(k($0.to)) && k($0.to) != k($0.from) }
        if !needsTemp {
            var done: [(from: URL, to: URL)] = []
            do {
                for p in pairs {
                    try FileActions.renameExact(p.from, to: p.to)
                    done.append(p)
                }
            } catch {
                for p in done.reversed() { try? FileActions.renameExact(p.to, to: p.from) }
                throw RenameError.failed(done.count < pairs.count ? pairs[done.count].from : pairs[0].from, error.localizedDescription)
            }
            return
        }
        var staged: [(temp: URL, pair: (from: URL, to: URL))] = []
        var finished: [(from: URL, to: URL)] = []
        do {
            for p in pairs {
                let temp = FS.tempSibling(of: p.from)
                try FileActions.renameExact(p.from, to: temp)
                staged.append((temp, p))
            }
            for s in staged {
                try FileActions.renameExact(s.temp, to: s.pair.to)
                finished.append(s.pair)
            }
        } catch {
            var tempOf: [URL: URL] = [:]
            for s in staged { tempOf[s.pair.from] = s.temp }
            for p in finished.reversed() {
                let t = FS.tempSibling(of: p.from)
                if (try? FileActions.renameExact(p.to, to: t)) != nil { tempOf[p.from] = t }
            }
            for (from, temp) in tempOf { try? FileActions.renameExact(temp, to: from) }
            throw RenameError.failed(pairs[0].from, error.localizedDescription)
        }
    }
}
