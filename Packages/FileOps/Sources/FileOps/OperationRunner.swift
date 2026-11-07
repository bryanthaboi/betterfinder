import Foundation

struct ItemPlan: Sendable {
    enum Action: Sendable { case copy, move, trash }
    var action: Action
    var source: URL
    var destination: URL?
    var forcedChoice: ConflictChoice?
    var createsParents = false
    var resumeOwned: [String]? = nil
    var resumeLedger: CommitLedger? = nil
}

final class CommitLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var marks = Set<Int>()

    static func mark(_ st: stat) -> Int {
        var h = Hasher()
        h.combine(st.st_dev)
        h.combine(st.st_ino)
        h.combine(st.st_mode)
        h.combine(st.st_size)
        h.combine(st.st_mtimespec.tv_sec)
        h.combine(st.st_mtimespec.tv_nsec)
        h.combine(st.st_ctimespec.tv_sec)
        h.combine(st.st_ctimespec.tv_nsec)
        return h.finalize()
    }

    func record(path: String) {
        guard let st = FS.lstatInfo(path) else { return }
        let m = Self.mark(st)
        lock.lock(); marks.insert(m); lock.unlock()
    }

    func matches(_ url: URL) -> Bool {
        guard let st = FS.lstatInfo(url.path) else { return false }
        let m = Self.mark(st)
        lock.lock(); defer { lock.unlock() }
        return marks.contains(m)
    }

    func absorb(_ other: CommitLedger) {
        guard other !== self else { return }
        let theirs = other.snapshot()
        lock.lock(); marks.formUnion(theirs); lock.unlock()
    }

    private func snapshot() -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return marks
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return marks.isEmpty
    }
}

enum RemovalResult {
    case all
    case partial([(source: URL, copy: URL)])
}

enum UndoRecord: Sendable, Hashable {
    case created(URL)
    case moved(from: URL, to: URL)
    case replaced(destination: URL, backup: URL, from: URL?)

    var landedURL: URL {
        switch self {
        case .created(let u): return u
        case .moved(_, let t): return t
        case .replaced(let d, _, _): return d
        }
    }
}

struct RunOutcome: Sendable {
    var results: [URL?]
    var completed: Set<Int>
    var skipped: Set<Int>
    var errors: [FileOperationItemError]
    var abort: String?
    var journal: [UndoRecord] = []
    var undoBlocked: String? = nil
    var ledger: CommitLedger? = nil
}

struct InvalidDestination: Error, LocalizedError {
    let source: URL
    var errorDescription: String? { "“\(source.lastPathComponent)” can’t be placed inside itself." }
}

struct IncompleteReplacement: Error, LocalizedError {
    let name: String
    var errorDescription: String? { "“\(name)” wasn’t replaced because some items inside couldn’t be copied. The original was kept." }
}

struct ChangedDuringMove: Error, LocalizedError {
    let name: String
    var errorDescription: String? { "“\(name)” changed while it was being moved, so the original was kept." }
}

private final class DecisionBox: @unchecked Sendable {
    var value = ConflictDecision(.stop)
}

private enum RetainedOriginal {
    case trashed(URL)
    case temporary(URL)
}

final class OperationRunner: @unchecked Sendable {
    struct Placed {
        var url: URL?
        var complete: Bool
    }

    let plans: [ItemPlan]
    let control: OperationControl
    let resolver: ConflictResolver?
    let defaultChoice: ConflictChoice
    let trashService: TrashService
    let verify: Bool
    let sink: @Sendable (FileOperationProgress) -> Void
    let errors = ErrorCollector()
    private var memory: [Bool: ConflictChoice] = [:]
    private var tracker: ProgressTracker!
    private var context: CopyContext!
    private var itemSize: Int64 = 0
    private var journal: [UndoRecord] = []
    private var undoBlocked: String?
    private var createsParents = false
    private var resumeLedger: CommitLedger?
    private let keptLedger = CommitLedger()
    var forcesCopyMoves = false
    var afterCopy: (@Sendable (URL) -> Void)?

    init(plans: [ItemPlan], control: OperationControl, resolver: ConflictResolver?, defaultChoice: ConflictChoice, trashService: TrashService, verify: Bool, sink: @escaping @Sendable (FileOperationProgress) -> Void) {
        self.plans = plans
        self.control = control
        self.resolver = resolver
        self.defaultChoice = defaultChoice
        self.trashService = trashService
        self.verify = verify
        self.sink = sink
    }

    private func sameVolume(_ src: URL, _ dst: URL) -> Bool {
        if forcesCopyMoves { return false }
        guard let a = FS.lstatInfo(src.path)?.st_dev, let b = FS.device(of: dst.deletingLastPathComponent()) else { return false }
        return a == b
    }

    func run() -> RunOutcome {
        var results = [URL?](repeating: nil, count: plans.count)
        var completed = Set<Int>()
        var skipped = Set<Int>()
        var abort: String?

        var initial = FileOperationProgress(completedUnits: 0, totalUnits: 0, currentItem: "Preparing…")
        initial.itemsTotal = plans.count
        sink(initial)

        var weights = [Int64](repeating: 0, count: plans.count)
        var total: Int64 = 0
        do {
            for (i, plan) in plans.enumerated() {
                try control.checkpoint()
                let needsBytes: Bool
                switch plan.action {
                case .copy: needsBytes = true
                case .move: needsBytes = !sameVolume(plan.source, plan.destination ?? plan.source)
                case .trash: needsBytes = false
                }
                guard needsBytes else { continue }
                let size = try FS.size(of: plan.source, control: control).bytes
                weights[i] = verify ? size * 2 : size
                total += weights[i]
            }
        } catch {
            return RunOutcome(results: results, completed: completed, skipped: skipped, errors: [], abort: "cancelled")
        }

        tracker = ProgressTracker(totalBytes: total, totalItems: plans.count, sink: sink)
        context = CopyContext(control: control, tracker: tracker, errors: errors, topSource: plans.first?.source ?? URL(fileURLWithPath: "/"))

        loop: for (i, plan) in plans.enumerated() {
            if control.isCancelled { abort = "cancelled"; break }
            let itemLedger = CommitLedger()
            context.ledger = itemLedger
            resumeLedger = plan.resumeLedger
            defer {
                if !completed.contains(i) {
                    keptLedger.absorb(itemLedger)
                    if let carried = plan.resumeLedger { keptLedger.absorb(carried) }
                }
            }
            do {
                try control.checkpoint()
                tracker.beginItem(name: plan.source.lastPathComponent, size: weights[i])
                itemSize = weights[i] / (verify ? 2 : 1)
                context.topSource = plan.source
                createsParents = plan.createsParents
                switch plan.action {
                case .trash:
                    results[i] = try trashService.trash(plan.source)
                    completed.insert(i)
                case .copy, .move:
                    guard let dst = plan.destination else { throw POSIXError(.EINVAL) }
                    if FS.isDirectory(plan.source) && FS.isDescendant(dst, of: plan.source) {
                        throw InvalidDestination(source: plan.source)
                    }
                    let owned = plan.resumeOwned.map { Set($0) }
                    let placed = try transferNode(plan.source, dst, isMove: plan.action == .move, forced: plan.forcedChoice, top: true, owned: owned)
                    results[i] = placed.url
                    if placed.complete {
                        completed.insert(i)
                        if placed.url == nil { skipped.insert(i) }
                    }
                }
                tracker.completeItem(size: weights[i])
            } catch OperationAbort.cancelled {
                abort = "cancelled"
                break loop
            } catch OperationAbort.stopped {
                abort = "stopped"
                break loop
            } catch {
                errors.add(.from(error, url: plan.source))
                tracker.completeItem(size: weights[i])
            }
        }
        tracker.finish()
        context.ledger = nil
        return RunOutcome(results: results, completed: completed, skipped: skipped, errors: errors.all, abort: abort, journal: journal, undoBlocked: undoBlocked, ledger: keptLedger.isEmpty ? nil : keptLedger)
    }

    private func decide(_ conflict: FileConflict, forced: ConflictChoice?) -> ConflictChoice {
        var choice: ConflictChoice
        if let forced {
            choice = forced
        } else if let remembered = memory[conflict.allowsMerge] {
            choice = remembered
        } else if let resolver {
            let box = DecisionBox()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.value = await resolver.resolve(conflict)
                sem.signal()
            }
            sem.wait()
            if box.value.applyToAll { memory[conflict.allowsMerge] = box.value.choice }
            choice = box.value.choice
        } else {
            choice = defaultChoice
        }
        if choice == .merge && !conflict.allowsMerge { choice = .replace }
        return choice
    }

    static func isOwned(_ url: URL, by owned: Set<String>) -> Bool {
        var path = url.standardizedFileURL.path
        while true {
            if owned.contains(path) { return true }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return false }
            path = parent
        }
    }

    private func transferNode(_ src: URL, _ dst: URL, isMove: Bool, forced: ConflictChoice?, top: Bool, owned: Set<String>?) throws -> Placed {
        try control.checkpoint()
        if !FS.exists(dst) {
            if createsParents && top {
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            return try place(src, at: dst, isMove: isMove, top: top)
        }
        if FS.sameFile(src, dst) {
            if isMove { return Placed(url: dst, complete: true) }
            return try place(src, at: FS.uniqueSibling(of: dst), isMove: false, top: top)
        }
        if let owned {
            if FS.isDirectory(src) && FS.isDirectory(dst) {
                return try merge(src, dst, isMove: isMove, forced: forced, owned: owned)
            }
            if Self.isOwned(dst, by: owned), resumeLedger?.matches(dst) == true, try identical(src, dst, strict: isMove) {
                return try resume(src, dst, isMove: isMove)
            }
        }
        if let resumeLedger, resumeLedger.matches(dst), !FS.isDirectory(dst) {
            try FileManager.default.removeItem(at: dst)
            return try place(src, at: dst, isMove: isMove, top: top)
        }
        let conflict = FileConflict(source: .read(src), destination: .read(dst), isMove: isMove)
        switch decide(conflict, forced: forced) {
        case .stop:
            throw OperationAbort.stopped
        case .skip:
            return Placed(url: nil, complete: true)
        case .keepBoth:
            return try place(src, at: FS.uniqueSibling(of: dst), isMove: isMove, top: top)
        case .replace:
            return try replace(src, dst, isMove: isMove, top: top)
        case .merge:
            return try merge(src, dst, isMove: isMove, forced: forced, owned: owned)
        }
    }

    private func resume(_ src: URL, _ dst: URL, isMove: Bool) throws -> Placed {
        if isMove {
            try FileManager.default.removeItem(at: src)
            journal.append(.moved(from: src, to: dst))
        }
        return Placed(url: dst, complete: true)
    }

    private func identical(_ a: URL, _ b: URL, strict: Bool) throws -> Bool {
        guard let x = FS.lstatInfo(a.path), let y = FS.lstatInfo(b.path) else { return false }
        guard (x.st_mode & S_IFMT) == S_IFREG, (y.st_mode & S_IFMT) == S_IFREG, x.st_size == y.st_size else { return false }
        if !strict {
            return x.st_mtimespec.tv_sec == y.st_mtimespec.tv_sec
        }
        return try Verifier.digest(of: a, control: control, tracker: nil) == Verifier.digest(of: b, control: control, tracker: nil)
    }

    private func place(_ src: URL, at dst: URL, isMove: Bool, top: Bool) throws -> Placed {
        if isMove && sameVolume(src, dst) {
            if renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) == 0 {
                journal.append(.moved(from: src, to: dst))
                return Placed(url: dst, complete: true)
            }
            let code = errno
            if code != EXDEV { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        let started = timespec.now
        let clean = try copyAndVerify(src, dst, top: top)
        guard isMove && clean else {
            if FS.exists(dst) { journal.append(.created(dst)) }
            return Placed(url: dst, complete: clean)
        }
        afterCopy?(src)
        switch removeCopied(src, copy: dst, since: started) {
        case .all:
            journal.append(.moved(from: src, to: dst))
            return Placed(url: dst, complete: true)
        case .partial(let removed):
            journal.append(.created(dst))
            journal.append(contentsOf: removed.map { .moved(from: $0.source, to: $0.copy) })
            return Placed(url: dst, complete: false)
        }
    }

    private func retainOriginal(_ dst: URL) throws -> RetainedOriginal {
        if let trashed = try? trashService.trash(dst), trashed.standardizedFileURL.path != dst.standardizedFileURL.path, FS.exists(trashed), !FS.exists(dst) {
            return .trashed(trashed)
        }
        if !FS.exists(dst) {
            undoBlocked = "The replaced “\(dst.lastPathComponent)” was moved to the Trash, but its new location couldn’t be found, so this can’t be undone."
            return .temporary(dst)
        }
        let backup = FS.tempSibling(of: dst)
        if Darwin.rename(dst.path, backup.path) != 0 {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return .temporary(backup)
    }

    private func restoreOriginal(_ retained: RetainedOriginal, to dst: URL) {
        switch retained {
        case .trashed(let t):
            try? trashService.restore(t, to: dst)
        case .temporary(let t):
            if t.standardizedFileURL.path != dst.standardizedFileURL.path, !FS.exists(dst) { _ = Darwin.rename(t.path, dst.path) }
        }
    }

    private func commitReplacement(_ dst: URL, retained: RetainedOriginal, from: URL?) {
        switch retained {
        case .trashed(let t):
            journal.append(.replaced(destination: dst, backup: t, from: from))
        case .temporary(let t):
            if t.standardizedFileURL.path != dst.standardizedFileURL.path { FS.remove(t) }
            journal.append(from.map { .moved(from: $0, to: dst) } ?? .created(dst))
            if undoBlocked == nil {
                undoBlocked = "“\(dst.lastPathComponent)” couldn’t be moved to the Trash when it was replaced, so this can’t be undone."
            }
        }
    }

    private func replace(_ src: URL, _ dst: URL, isMove: Bool, top: Bool) throws -> Placed {
        if FS.isDescendant(src, of: dst) { throw InvalidDestination(source: src) }
        if isMove && sameVolume(src, dst) {
            let retained = try retainOriginal(dst)
            if renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                restoreOriginal(retained, to: dst)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            commitReplacement(dst, retained: retained, from: src)
            return Placed(url: dst, complete: true)
        }
        let tmp = FS.tempSibling(of: dst)
        let started = timespec.now
        let clean = try copyAndVerify(src, tmp, top: top)
        guard clean else {
            FS.remove(tmp)
            throw IncompleteReplacement(name: dst.lastPathComponent)
        }
        let retained: RetainedOriginal
        do {
            retained = try retainOriginal(dst)
        } catch {
            FS.remove(tmp)
            throw error
        }
        if renamex_np(tmp.path, dst.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            restoreOriginal(retained, to: dst)
            FS.remove(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        context.ledger?.record(path: dst.path)
        var movedFrom: URL?
        var removed: [(source: URL, copy: URL)] = []
        var complete = true
        if isMove {
            afterCopy?(src)
            switch removeCopied(src, copy: dst, since: started) {
            case .all: movedFrom = src
            case .partial(let r): removed = r; complete = false
            }
        }
        commitReplacement(dst, retained: retained, from: movedFrom)
        journal.append(contentsOf: removed.map { .moved(from: $0.source, to: $0.copy) })
        return Placed(url: dst, complete: complete)
    }

    private func merge(_ src: URL, _ dst: URL, isMove: Bool, forced: ConflictChoice?, owned: Set<String>?) throws -> Placed {
        let children = try FileManager.default.contentsOfDirectory(atPath: src.path)
        var complete = true
        for name in children {
            try control.checkpoint()
            let s = src.appendingPathComponent(name)
            let d = dst.appendingPathComponent(name)
            do {
                let placed = try transferNode(s, d, isMove: isMove, forced: forced, top: false, owned: owned)
                if !placed.complete { complete = false }
            } catch OperationAbort.cancelled {
                throw OperationAbort.cancelled
            } catch OperationAbort.stopped {
                throw OperationAbort.stopped
            } catch {
                complete = false
                errors.add(.from(error, url: s))
            }
        }
        if isMove { _ = rmdir(src.path) }
        return Placed(url: dst, complete: complete)
    }

    func removeCopied(_ src: URL, copy: URL, since: timespec) -> RemovalResult {
        guard let st = FS.lstatInfo(src.path) else { return .all }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: src.path)
            } catch {
                errors.add(.from(error, url: src))
                return .partial([])
            }
            var all = true
            var removed: [(source: URL, copy: URL)] = []
            for name in names {
                let s = src.appendingPathComponent(name)
                let c = copy.appendingPathComponent(name)
                switch removeCopied(s, copy: c, since: since) {
                case .all: removed.append((s, c))
                case .partial(let r): all = false; removed.append(contentsOf: r)
                }
            }
            guard all else { return .partial(removed) }
            if rmdir(src.path) != 0 {
                let code = errno
                if code == ENOTEMPTY || code == EEXIST {
                    errors.add(.from(ChangedDuringMove(name: src.lastPathComponent), url: src))
                } else {
                    errors.add(.posix(code, url: src))
                }
                return .partial(removed)
            }
            return .all
        }
        guard let c = FS.lstatInfo(copy.path), (c.st_mode & S_IFMT) == (st.st_mode & S_IFMT),
              (st.st_mode & S_IFMT) != S_IFREG || c.st_size == st.st_size,
              !st.st_ctimespec.isAfter(since) else {
            errors.add(.from(ChangedDuringMove(name: src.lastPathComponent), url: src))
            return .partial([])
        }
        if unlink(src.path) != 0 {
            errors.add(.posix(errno, url: src))
            return .partial([])
        }
        return .all
    }

    @discardableResult
    private func copyAndVerify(_ src: URL, _ dst: URL, top: Bool) throws -> Bool {
        do {
            let clean = try CopyEngine.copy(from: src, to: dst, context: context)
            if top { tracker.markCopied(itemSize) }
            if verify && clean {
                try Verifier.verify(source: src, destination: dst, control: control, tracker: tracker)
            }
            return clean
        } catch {
            FS.remove(dst)
            throw error
        }
    }
}

extension timespec {
    static var now: timespec {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return ts
    }

    func isAfter(_ other: timespec) -> Bool {
        tv_sec > other.tv_sec || (tv_sec == other.tv_sec && tv_nsec > other.tv_nsec)
    }
}
