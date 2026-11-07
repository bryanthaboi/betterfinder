import Darwin
import Foundation
import ModHostProtocol
import ModKit

final class ModProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func attach(_ p: Process) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            process = p
            return true
        }
    }

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !cancelled, !finished else { lock.unlock(); return false }
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
        return true
    }

    func finish(_ commit: () -> Bool) -> Bool? {
        lock.withLock {
            guard !cancelled else { return nil }
            finished = true
            return commit()
        }
    }
}

final class ModOperationLedger: @unchecked Sendable {
    struct Entry {
        var owner: String
        var external: Bool
        var progress: ModOperationProgress
        var handle: ModProcessHandle?
        var seq: UInt64
        var finished: Bool
    }

    enum Lookup: Equatable {
        case progress(ModOperationProgress)
        case expired
        case unknown
    }

    let terminalLimit: Int
    let totalLimit: Int
    let expiredLimit: Int
    let activeLimit: Int
    let ownerActiveLimit: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var expired: [String: String] = [:]
    private var expiredOrder: [String] = []
    private var reserved: [String: Int] = [:]
    private var seq: UInt64 = 0

    init(terminalLimit: Int = 256, totalLimit: Int = 1024, expiredLimit: Int = 2048, activeLimit: Int = 512, ownerActiveLimit: Int = 128) {
        self.terminalLimit = max(1, terminalLimit)
        self.totalLimit = max(self.terminalLimit, totalLimit)
        self.expiredLimit = max(1, expiredLimit)
        self.activeLimit = max(1, activeLimit)
        self.ownerActiveLimit = max(1, min(ownerActiveLimit, self.activeLimit))
    }

    static func isTerminal(_ state: ModOperationState) -> Bool {
        state == .done || state == .failed || state == .cancelled
    }

    static func capacityError() -> ModCallError {
        ModCallError.limit("too many active operations; wait for one to finish or cancel it")
    }

    var count: Int { lock.withLock { entries.count } }

    var activeCount: Int { lock.withLock { entries.values.filter { !$0.finished }.count } }

    func register(_ id: String, owner: String, external: Bool, progress: ModOperationProgress = ModOperationProgress(state: .queued, completed: 0, total: 1), handle: ModProcessHandle? = nil) {
        lock.withLock { insertLocked(id, owner: owner, external: external, progress: progress, handle: handle) }
    }

    func registerActive(_ id: String, owner: String, external: Bool, progress: ModOperationProgress, handle: ModProcessHandle? = nil) throws {
        try lock.withLock {
            guard Self.isTerminal(progress.state) || reserveLocked(owner) else { throw Self.capacityError() }
            insertLocked(id, owner: owner, external: external, progress: progress, handle: handle)
        }
    }

    func reserve(owner: String, refreshing external: ModFileOperationsPerforming?) async throws {
        if lock.withLock({ reserveLocked(owner) }) { return }
        if let external { await refresh(external) }
        guard lock.withLock({ reserveLocked(owner) }) else { throw Self.capacityError() }
    }

    func release(owner: String) {
        lock.withLock { releaseLocked(owner) }
    }

    func refresh(_ external: ModFileOperationsPerforming) async {
        let ids: [String] = lock.withLock {
            entries.filter { $0.value.external && !$0.value.finished }.sorted { $0.value.seq < $1.value.seq }.prefix(activeLimit).map(\.key)
        }
        for id in ids {
            if let live = await external.status(id) { update(id, live) }
        }
    }

    func update(_ id: String, _ progress: ModOperationProgress) {
        lock.withLock {
            guard var e = entries[id] else { return }
            if e.finished && !Self.isTerminal(progress.state) { return }
            if e.finished && e.progress.state == .cancelled { return }
            e.progress = progress
            e.finished = Self.isTerminal(progress.state)
            entries[id] = e
            trimLocked()
        }
    }

    func lookup(_ id: String, owner: String, external: ModFileOperationsPerforming?) async -> Lookup {
        let state: (Entry?, Bool) = lock.withLock { (entries[id], expired[id] == owner) }
        guard let e = state.0, e.owner == owner else { return state.1 ? .expired : .unknown }
        guard e.external, !e.finished else { return .progress(e.progress) }
        let live = await external?.status(id) ?? e.progress
        update(id, live)
        return .progress(live)
    }

    func status(_ id: String, owner: String, external: ModFileOperationsPerforming?) async -> ModOperationProgress? {
        if case .progress(let p) = await lookup(id, owner: owner, external: external) { return p }
        return nil
    }

    func cancel(_ id: String, owner: String, external: ModFileOperationsPerforming?) async -> Bool? {
        let state: (Entry?, Bool) = lock.withLock { (entries[id], expired[id] == owner) }
        guard let e = state.0, e.owner == owner else { return state.1 ? false : nil }
        if e.external {
            guard !e.finished, let external else { return false }
            let ok = await external.cancel(id)
            if ok, let live = await external.status(id) { update(id, live) }
            return ok
        }
        guard !e.finished, let handle = e.handle, handle.cancel() else { return false }
        update(id, ModOperationProgress(state: .cancelled, completed: 0, total: e.progress.total))
        return true
    }

    func cancelAll(owner: String) {
        let handles: [ModProcessHandle] = lock.withLock {
            let mine = entries.filter { $0.value.owner == owner }
            for (id, _) in mine.sorted(by: { $0.value.seq < $1.value.seq }) { expireLocked(id) }
            reserved.removeValue(forKey: owner)
            return mine.values.filter { !$0.external && !$0.finished }.compactMap(\.handle)
        }
        for h in handles { h.cancel() }
    }

    private func insertLocked(_ id: String, owner: String, external: Bool, progress: ModOperationProgress, handle: ModProcessHandle?) {
        seq += 1
        expired.removeValue(forKey: id)
        let finished = Self.isTerminal(progress.state)
        if !finished { releaseLocked(owner) }
        entries[id] = Entry(owner: owner, external: external, progress: progress, handle: handle, seq: seq, finished: finished)
        trimLocked()
    }

    private func reserveLocked(_ owner: String) -> Bool {
        var mine = reserved[owner, default: 0]
        var all = reserved.values.reduce(0, +)
        for e in entries.values where !e.finished {
            all += 1
            if e.owner == owner { mine += 1 }
        }
        guard mine < ownerActiveLimit, all < activeLimit else { return false }
        reserved[owner] = reserved[owner, default: 0] + 1
        return true
    }

    private func releaseLocked(_ owner: String) {
        guard let n = reserved[owner] else { return }
        if n <= 1 { reserved.removeValue(forKey: owner) } else { reserved[owner] = n - 1 }
    }

    private func expireLocked(_ id: String) {
        guard let e = entries.removeValue(forKey: id) else { return }
        if expired.updateValue(e.owner, forKey: id) == nil { expiredOrder.append(id) }
        while expiredOrder.count > expiredLimit {
            expired.removeValue(forKey: expiredOrder.removeFirst())
        }
    }

    private func trimLocked() {
        let finished = entries.values.reduce(0) { $0 + ($1.finished ? 1 : 0) }
        let excess = max(finished - terminalLimit, entries.count - totalLimit)
        guard excess > 0 else { return }
        let victims = entries.filter(\.value.finished).sorted { $0.value.seq < $1.value.seq }.prefix(excess)
        for (id, _) in victims { expireLocked(id) }
    }
}

struct ModProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var cancelled: Bool = false
}

final class ModOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var out = Data()
    private var err = Data()
    private var timedOut = false

    init(limit: Int) { self.limit = limit }

    func append(_ d: Data, error: Bool) {
        lock.withLock {
            if error {
                if err.count < limit { err.append(d.prefix(limit - err.count)) }
            } else if out.count < limit {
                out.append(d.prefix(limit - out.count))
            }
        }
    }

    func markTimedOut() { lock.withLock { timedOut = true } }

    func result(status: Int32) -> ModProcessResult {
        lock.withLock { ModProcessResult(status: status, stdout: out, stderr: err, timedOut: timedOut) }
    }
}

enum ModProcessRunner {
    static func run(_ executable: String, _ args: [String], cwd: String? = nil, environment: [String: String], timeout: TimeInterval, maxOutput: Int = 256 * 1024, handle: ModProcessHandle? = nil) async -> ModProcessResult? {
        if handle?.isCancelled == true { return ModProcessResult(status: -1, stdout: Data(), stderr: Data(), timedOut: false, cancelled: true) }
        return await withCheckedContinuation { (c: CheckedContinuation<ModProcessResult?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.environment = environment
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let box = ModOutputBox(limit: maxOutput)
            out.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData, error: false) }
            err.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData, error: true) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                box.append(out.fileHandleForReading.readDataToEndOfFile(), error: false)
                box.append(err.fileHandleForReading.readDataToEndOfFile(), error: true)
                var r = box.result(status: proc.terminationStatus)
                r.cancelled = handle?.isCancelled == true
                c.resume(returning: r)
            }
            do { try p.run() } catch { c.resume(returning: nil); return }
            if let handle, !handle.attach(p) { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    box.markTimedOut()
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
    }

    static var baseEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    }
}

extension ModBroker {
    func archive(_ mod: ActiveMod, _ a: [JSONValue]) throws -> JSONValue {
        let items = try list(a[0], max: deps.catalog.limits.batchItems).map { try resolve(mod, $0, need: .read) }
        guard !items.isEmpty else { throw ModCallError.invalid("nothing to archive") }
        for item in items where item.identity.isDirectory {
            if case .selection(_, let recursive, _) = item.entry.scope, !(recursive && mod.grants.fs(.fsRead, scope: .selection).contains { $0.recursive == true }) {
                throw ModCallError.notGranted("archiving a folder requires a recursive fs.read grant")
            }
        }
        let dest = try resolve(mod, a[1], need: .write)
        guard ModFileIdentity.lstat(dest.real)?.isDirectory == true else { throw ModCallError.invalid("destination is not a folder") }
        let name = a[2].stringValue ?? ""
        let format = a[3].stringValue ?? "zip"
        let ext = format == "tarGz" ? "tar.gz" : "zip"
        let finalName = "\(name).\(ext)"
        guard ModPathRules.validName(name), ModPathRules.validName(finalName) else { throw ModCallError("invalidName", "'\(name)' is not a valid archive name") }
        let finalPath = (dest.real as NSString).appendingPathComponent(finalName)
        guard ModFileIdentity.lstat(finalPath) == nil else { throw ModCallError("exists", "'\(finalName)' already exists") }
        let tmpPath = (dest.real as NSString).appendingPathComponent(".bf-archive-\(UUID().uuidString).tmp")
        var args = ["-c", "-f", tmpPath]
        args += format == "tarGz" ? ["-z"] : ["--format", "zip"]
        for item in items {
            args += ["-C", (item.real as NSString).deletingLastPathComponent, "./" + (item.real as NSString).lastPathComponent]
        }
        let id = "arc_" + UUID().uuidString
        let ledger = deps.ledger
        let handle = ModProcessHandle()
        try ledger.registerActive(id, owner: mod.id, external: false, progress: ModOperationProgress(state: .running, completed: 0, total: items.count), handle: handle)
        let logs = mod.logs
        let count = items.count
        let runner = archiveRunner
        Task.detached {
            let r = await runner(args, handle)
            if handle.isCancelled || r?.cancelled == true {
                unlink(tmpPath)
                ledger.update(id, ModOperationProgress(state: .cancelled, completed: 0, total: count))
                return
            }
            guard let r, r.status == 0, !r.timedOut else {
                unlink(tmpPath)
                if handle.finish({ false }) == nil {
                    ledger.update(id, ModOperationProgress(state: .cancelled, completed: 0, total: count))
                    return
                }
                ledger.update(id, ModOperationProgress(state: .failed, completed: 0, total: count))
                logs.append("error", "archive failed: \(String(decoding: r?.stderr ?? Data(), as: UTF8.self))", rateLimited: false)
                return
            }
            let committed = handle.finish { link(tmpPath, finalPath) == 0 }
            unlink(tmpPath)
            switch committed {
            case .some(true): ledger.update(id, ModOperationProgress(state: .done, completed: count, total: count))
            case .some(false): ledger.update(id, ModOperationProgress(state: .failed, completed: 0, total: count))
            case .none: ledger.update(id, ModOperationProgress(state: .cancelled, completed: 0, total: count))
            }
        }
        return .object(["operationId": .string(id)])
    }

    func gitStatus(_ mod: ActiveMod, _ a: [JSONValue]) async throws -> JSONValue {
        let root = try resolve(mod, a[0], need: .list)
        guard case .root = root.entry.scope else { throw ModCallError.notGranted("git status needs a granted root") }
        let args = [
            "-C", root.real, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null",
            "--no-optional-locks", "--attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            "status", "--porcelain=v1", "-b", "-z", "--untracked-files=normal", "--ignore-submodules=all",
        ]
        var env = ModProcessRunner.baseEnvironment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        guard let r = await ModProcessRunner.run("/usr/bin/git", args, environment: env, timeout: 5) else { throw ModCallError("notARepository", "git is unavailable") }
        if r.timedOut { throw ModCallError.timeout("git status timed out") }
        guard r.status == 0 else { throw ModCallError("notARepository", "not a git repository") }
        return Self.parsePorcelain(r.stdout)
    }

    static func parsePorcelain(_ data: Data) -> JSONValue {
        let parts = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var branch: String?
        var entries = [JSONValue]()
        var i = 0
        while i < parts.count {
            let p = parts[i]
            i += 1
            if p.hasPrefix("## ") {
                let b = p.dropFirst(3)
                branch = String(b.split(separator: ".", maxSplits: 1).first.map { $0.hasPrefix("No commits yet on ") ? $0.dropFirst(18) : $0 } ?? b)
                if let range = branch?.range(of: "...") { branch = String(branch![..<range.lowerBound]) }
                continue
            }
            guard p.count > 3 else { continue }
            let xy = String(p.prefix(2))
            let path = String(p.dropFirst(3))
            let state: String
            if xy == "??" { state = "untracked" }
            else if xy.contains("U") || xy == "AA" || xy == "DD" { state = "conflicted" }
            else if xy.contains("R") || xy.contains("C") { state = "renamed"; i += 1 }
            else if xy.contains("A") { state = "added" }
            else if xy.contains("D") { state = "deleted" }
            else { state = "modified" }
            entries.append(.object(["path": .string(path), "state": .string(state)]))
            if entries.count >= 4096 { break }
        }
        var o: [String: JSONValue] = ["entries": .array(entries)]
        if let branch, !branch.isEmpty { o["branch"] = .string(branch) }
        return .object(o)
    }

    func processRun(_ mod: ActiveMod, _ a: [JSONValue]) async throws -> JSONValue {
        let exe = a[0].stringValue ?? ""
        let args = (a[1].arrayValue ?? []).compactMap(\.stringValue)
        guard exe.hasPrefix("/"), args.count <= 256 else { throw ModCallError("spawnFailed", "executable must be an absolute path") }
        var cwd: String?
        if !a[2].isNull { cwd = try resolve(mod, a[2], need: .read).real }
        guard await deps.services.confirmUnrestrictedExecution(modId: mod.id, executable: exe, arguments: args) else {
            throw ModCallError.notGranted("the user did not approve running \(exe)")
        }
        mod.logs.append("warn", "process.run \(exe) \(args.joined(separator: " "))", rateLimited: false)
        guard let r = await ModProcessRunner.run(exe, args, cwd: cwd, environment: ModProcessRunner.baseEnvironment, timeout: 30) else {
            throw ModCallError("spawnFailed", "could not start \(exe)")
        }
        if r.timedOut { throw ModCallError.timeout("\(exe) timed out") }
        return .object([
            "exitCode": .int(Int(r.status)),
            "stdout": .string(String(decoding: r.stdout, as: UTF8.self)),
            "stderr": .string(String(decoding: r.stderr, as: UTF8.self)),
        ])
    }
}
