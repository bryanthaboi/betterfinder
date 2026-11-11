import Foundation
import Darwin

public struct IndexSearchSummary: Sendable, Equatable {
    public var hitLimit = false
    public var indexed = true
    public init(hitLimit: Bool = false, indexed: Bool = true) {
        self.hitLimit = hitLimit
        self.indexed = indexed
    }
}

public enum IndexSearchEvent: Sendable, Equatable {
    case paths([String])
    case finished(IndexSearchSummary)
}

struct NameMatcher: Sendable {
    private let ascii: [UInt8]?
    private let folded: String

    init(_ query: String) {
        folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let bytes = Array(folded.utf8)
        ascii = bytes.allSatisfy { $0 < 0x80 } ? bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 } : nil
    }

    var isEmpty: Bool { folded.isEmpty }

    func matches(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let ascii else { return slow(name) }
        let count = name.count
        let length = ascii.count
        var plain = true
        if count >= length {
            let first = ascii[0]
            let last = count - length
            var i = 0
            while i < count {
                var byte = name[i]
                if byte >= 0x80 { plain = false } else if byte >= 65 && byte <= 90 { byte += 32 }
                if i <= last && byte == first {
                    var j = 1
                    while j < length {
                        var other = name[i + j]
                        if other >= 65 && other <= 90 { other += 32 }
                        if other != ascii[j] { break }
                        j += 1
                    }
                    if j == length { return true }
                }
                i += 1
            }
        } else {
            for byte in name where byte >= 0x80 { plain = false; break }
        }
        return plain ? false : slow(name)
    }

    private func slow(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        String(decoding: name, as: UTF8.self).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded)
    }
}

public final class SizeIndexSearcher: @unchecked Sendable {
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "xcodeproj", "xcworkspace", "playground", "xcarchive", "xcdatamodeld",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "rtfd", "scptd", "wdgt", "mpkg",
        "qlgenerator", "mdimporter", "prefpane", "saver", "component", "vst", "vst3", "dsym", "docset", "action", "workflow", "sparsebundle", "download",
    ]
    static let walkThreshold: Int64 = 150_000

    private let databaseURL: URL

    public init(databaseURL: URL = SizeIndexLocation.database) {
        self.databaseURL = databaseURL
    }

    private struct Location {
        var path: String
        var sealed: Bool
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String>
        private var remaining: Int
        private(set) var overflowed = false
        private let emit: ([String]) -> Void
        private let stop: () -> Bool

        init(seen: Set<String>, limit: Int, stop: @escaping () -> Bool, emit: @escaping ([String]) -> Void) {
            self.seen = seen
            remaining = limit
            self.stop = stop
            self.emit = emit
        }

        var delivered: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        var finished: Bool {
            lock.lock()
            let full = overflowed
            lock.unlock()
            return full || stop()
        }

        func offer(_ batch: [String]) {
            guard !batch.isEmpty else { return }
            lock.lock()
            var fresh: [String] = []
            for path in batch where !seen.contains(path) {
                guard remaining > 0 else { overflowed = true; break }
                seen.insert(path)
                remaining -= 1
                fresh.append(path)
            }
            lock.unlock()
            if !fresh.isEmpty { emit(fresh) }
        }
    }

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    private func open() -> IndexDatabase? {
        try? IndexDatabase(databaseURL, readOnly: true, cacheKiB: 8192, mmapBytes: 1 << 30)
    }

    func scope(_ url: URL, in db: IndexDatabase) -> (id: Int64, items: Int64, counting: Bool)? {
        if url.path == "/" {
            return (try? db.first("SELECT count(*),coalesce(sum(fresh),0) FROM dirs WHERE parent=0 AND flags&?=0", args: [.int(IndexFlag.detached)]) { s -> (id: Int64, items: Int64, counting: Bool)? in
                IndexDatabase.int(s, 0) > 0 ? (0, Int64.max, IndexDatabase.int(s, 1) > 0) : nil
            }) ?? nil
        }
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, let uuid = IndexVolume.identifier(forPath: url.path),
              let vol = (try? db.first("SELECT id FROM volumes WHERE uuid=?", args: [.text(uuid)]) { IndexDatabase.int($0, 0) }) ?? nil else { return nil }
        return (try? db.first("SELECT id,items,fresh FROM dirs WHERE vol=? AND inode=?", args: [.int(vol), .int(Int64(bitPattern: UInt64(st.st_ino)))]) {
            (IndexDatabase.int($0, 0), IndexDatabase.int($0, 1), IndexDatabase.int($0, 2) > 0)
        }) ?? nil
    }

    public struct Pass: Sendable {
        public var found: Bool
        public var counting: Bool
        public var hitLimit: Bool
        public var delivered: Set<String>
    }

    public func pass(query: String, under scope: URL, includeHidden: Bool, limit: Int, skipping delivered: Set<String> = [],
                     isCancelled: @escaping @Sendable () -> Bool, emit: @escaping @Sendable ([String]) -> Void) -> Pass {
        let matcher = NameMatcher(query)
        guard !matcher.isEmpty, let db = open(), let target = self.scope(scope, in: db) else {
            return Pass(found: false, counting: false, hitLimit: false, delivered: delivered)
        }
        let sink = Sink(seen: delivered, limit: max(0, limit - delivered.count), stop: isCancelled, emit: emit)
        let base = scope.path
        if target.items <= Self.walkThreshold {
            walk(db, from: target.id, base: base, matcher: matcher, includeHidden: includeHidden, sink: sink)
        } else {
            sweep(scope: target.id, base: base, matcher: matcher, includeHidden: includeHidden, sink: sink)
        }
        return Pass(found: true, counting: target.counting, hitLimit: sink.overflowed, delivered: sink.delivered)
    }

    private func walk(_ db: IndexDatabase, from root: Int64, base: String, matcher: NameMatcher, includeHidden: Bool, sink: Sink) {
        var stack: [(id: Int64, path: String)] = [(root, base)]
        var batch: [String] = []
        while let (id, path) = stack.popLast() {
            if sink.finished { return }
            let prefix = path == "/" ? "/" : path + "/"
            try? db.each("SELECT name FROM files WHERE dir=?", args: [.int(id)]) { s in
                let bytes = IndexDatabase.bytes(s, 0)
                if !includeHidden, bytes.first == 46 { return }
                if matcher.matches(bytes) { batch.append(prefix + String(decoding: bytes, as: UTF8.self)) }
            }
            try? db.each("SELECT id,name,flags FROM dirs WHERE parent=?", args: [.int(id)]) { s in
                if !includeHidden, IndexDatabase.int(s, 2) & IndexFlag.hidden != 0 { return }
                let bytes = IndexDatabase.bytes(s, 1)
                let name = String(decoding: bytes, as: UTF8.self)
                if matcher.matches(bytes) { batch.append(prefix + name) }
                if !Self.isPackage(name) { stack.append((IndexDatabase.int(s, 0), prefix + name)) }
            }
            if batch.count >= 128 {
                sink.offer(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        sink.offer(batch)
    }

    private func sweep(scope: Int64, base: String, matcher: NameMatcher, includeHidden: Bool, sink: Sink) {
        guard let probe = open(), let top = (try? probe.first("SELECT max(id) FROM dirs", args: []) { IndexDatabase.int($0, 0) }) ?? nil, top > 0 else { return }
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let slices = workers * 8
        let step = max(1, (top + Int64(slices)) / Int64(slices))
        let lock = NSLock()
        var next = 0
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            guard let db = self.open() else { return }
            let seed: [Int64: Location?] = scope == 0 ? [:] : [scope: Location(path: base, sealed: false)]
            var memo = seed
            func locate(_ id: Int64, depth: Int = 0) -> Location? {
                if let known = memo[id] { return known }
                var result: Location?
                if depth < 512, let (parent, name, flags) = (try? db.first("SELECT parent,name,flags FROM dirs WHERE id=?", args: [.int(id)]) {
                    (IndexDatabase.int($0, 0), IndexDatabase.text($0, 1) ?? "", IndexDatabase.int($0, 2))
                }) ?? nil {
                    if parent == 0 {
                        if scope == 0, flags & IndexFlag.detached == 0 { result = Location(path: name, sealed: false) }
                    } else if includeHidden || flags & IndexFlag.hidden == 0, let above = locate(parent, depth: depth + 1), !above.sealed {
                        result = Location(path: (above.path == "/" ? "/" : above.path + "/") + name, sealed: Self.isPackage(name))
                    }
                }
                if memo.count > 200_000 { memo = seed }
                memo[id] = .some(result)
                return result
            }
            var batch: [String] = []
            while !sink.finished {
                lock.lock()
                let slice = next
                next += 1
                lock.unlock()
                guard slice < slices else { break }
                let low = Int64(slice) * step
                let high = low + step
                try? db.each("SELECT dir,name FROM files WHERE dir>=? AND dir<?", args: [.int(low), .int(high)]) { s in
                    let bytes = IndexDatabase.bytes(s, 1)
                    if !includeHidden, bytes.first == 46 { return }
                    guard matcher.matches(bytes), let home = locate(IndexDatabase.int(s, 0)), !home.sealed else { return }
                    batch.append((home.path == "/" ? "/" : home.path + "/") + String(decoding: bytes, as: UTF8.self))
                }
                var hits: [Int64] = []
                try? db.each("SELECT id,name FROM dirs WHERE id>=? AND id<? AND parent!=0", args: [.int(low), .int(high)]) { s in
                    if matcher.matches(IndexDatabase.bytes(s, 1)) { hits.append(IndexDatabase.int(s, 0)) }
                }
                for id in hits where id != scope {
                    if let found = locate(id) { batch.append(found.path) }
                }
                if !batch.isEmpty {
                    sink.offer(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
    }
}
