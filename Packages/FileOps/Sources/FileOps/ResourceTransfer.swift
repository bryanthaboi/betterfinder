import Foundation
import FSCore

public struct ResourceTransferRequest: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case copy, move }

    public let mode: Mode
    public let items: [OperationItem]
    public let origin: OperationOrigin
    public let destinationDirectory: ResourceID?

    public init(mode: Mode, items: [OperationItem], origin: OperationOrigin = .user) {
        self.mode = mode
        self.items = items
        self.origin = origin
        self.destinationDirectory = items.first?.destinationResource?.lexicalParent
    }

    public init(mode: Mode, sources: [ResourceID], into destination: ResourceID, origin: OperationOrigin = .user) {
        self.mode = mode
        self.items = sources.map { OperationItem(sourceResource: $0, destinationResource: destination.appending($0.name)) }
        self.origin = origin
        self.destinationDirectory = destination
    }

    public var involvesRemote: Bool { items.contains(where: \.isRemote) }
}

public protocol ResourceTransferProvider: Sendable {
    var id: String { get }
    func canTransfer(_ request: ResourceTransferRequest) -> Bool
    func transfer(_ request: ResourceTransferRequest, progress: @escaping @Sendable (FileOperationProgress) -> Void) async throws -> [URL?]
}

public final class ResourceTransferProviderRegistry: @unchecked Sendable {
    public static let shared = ResourceTransferProviderRegistry()

    public typealias RegistrationToken = FileOpsRegistrationToken

    private struct Entry {
        let seq: UInt64
        let provider: ResourceTransferProvider
        let owner: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextSeq: UInt64 = 0

    public init() {}

    @discardableResult
    public func register(_ provider: ResourceTransferProvider, owner: String) -> RegistrationToken {
        lock.lock()
        nextSeq += 1
        let seq = nextSeq
        entries.append(Entry(seq: seq, provider: provider, owner: owner))
        lock.unlock()
        return FileOpsRegistrationToken { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.entries.removeAll { $0.seq == seq }
            self.lock.unlock()
        }
    }

    public var providerIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.provider.id)
    }

    public func provider(for request: ResourceTransferRequest) -> ResourceTransferProvider? {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.first { $0.provider.canTransfer(request) }?.provider
    }

    public func contains(id: String) -> Bool { providerIDs.contains(id) }
}

public struct ResourceTransferReport: Sendable {
    public enum ItemResult: Sendable, Hashable {
        case committed(ResourceID)
        case skipped
        case failed(FileOperationItemError)
    }

    public var results: [ItemResult]
    public var errors: [FileOperationItemError]
    public var aborted: String?
    public var verifiedFiles = 0
    public var deletedSources: [ResourceID] = []
    var commits: [ResourceID: TransferCommit] = [:]
    var partialTargets: [Int: ResourceID] = [:]

    public var committed: [ResourceID] {
        results.compactMap { if case .committed(let id) = $0 { return id } else { return nil } }
    }
}

public struct ResourceTransferControl: Sendable {
    public var isCancelled: @Sendable () -> Bool
    public var isPaused: @Sendable () -> Bool

    public init(isCancelled: @escaping @Sendable () -> Bool = { false }, isPaused: @escaping @Sendable () -> Bool = { false }) {
        self.isCancelled = isCancelled
        self.isPaused = isPaused
    }

    func checkpoint() async throws {
        while isPaused() && !isCancelled() && !Task.isCancelled { try await Task.sleep(nanoseconds: 100_000_000) }
        if isCancelled() || Task.isCancelled { throw CancellationError() }
    }
}

public enum StagingArea {
    public static var root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("betterfinder-staging", isDirectory: true)

    public static func makeDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static func availableCapacity() -> Int64? {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VolumeInfo.availableCapacity(for: root)
    }
}

public final class CrossProviderTransfer: ResourceTransferProvider, @unchecked Sendable {
    public static let defaultID = "betterfinder.cross-provider"

    public let id: String
    public let registry: ResourceProviderRegistry
    public var resolver: ConflictResolver?
    public var defaultChoice: ConflictChoice
    public var stagingReserve: Int64 = 256 << 20
    public var readBackVerificationLimit: Int64 = 64 << 20

    public init(id: String = CrossProviderTransfer.defaultID, registry: ResourceProviderRegistry = .shared, resolver: ConflictResolver? = nil, defaultChoice: ConflictChoice = .keepBoth) {
        self.id = id
        self.registry = registry
        self.resolver = resolver
        self.defaultChoice = defaultChoice
    }

    public func canTransfer(_ request: ResourceTransferRequest) -> Bool {
        guard !request.items.isEmpty, request.involvesRemote else { return false }
        return request.items.allSatisfy { item in
            guard let s = item.sourceResource, let d = item.destinationResource else { return false }
            return registry.provider(for: s) != nil && registry.provider(for: d) != nil
        }
    }

    public func transfer(_ request: ResourceTransferRequest, progress: @escaping @Sendable (FileOperationProgress) -> Void) async throws -> [URL?] {
        let report = await run(request, progress: progress)
        if let abort = report.aborted, report.committed.isEmpty { throw ResourceError.remote(code: "Aborted", message: abort) }
        if report.committed.isEmpty, let first = report.errors.first { throw ResourceError.remote(code: "TransferFailed", message: first.message) }
        return report.results.map { if case .committed(let id) = $0 { return id.uri } else { return nil } }
    }

    public func run(_ request: ResourceTransferRequest, resolver override: ConflictResolver? = nil, control: ResourceTransferControl = .init(), progress: @escaping @Sendable (FileOperationProgress) -> Void) async -> ResourceTransferReport {
        await run(request, resolver: override, control: control, resume: [:], progress: progress)
    }

    func run(_ request: ResourceTransferRequest, resolver override: ConflictResolver?, control: ResourceTransferControl, resume: [ResourceID: TransferCommit], progress: @escaping @Sendable (FileOperationProgress) -> Void) async -> ResourceTransferReport {
        let job = TransferJob(engine: self, request: request, resolver: override ?? resolver, control: control, sink: progress)
        job.resume = resume
        return await job.run()
    }
}

struct TransferStop: Error {}

struct IncompleteResourceReplacement: Error, LocalizedError {
    let name: String
    var errorDescription: String? { "“\(name)” wasn’t replaced because some items couldn’t be transferred. The original was kept." }
}

struct ReplacementRecoveryFailed: Error, LocalizedError {
    let name: String
    let reason: String
    let backup: ResourceID?
    let staged: ResourceID?

    var errorDescription: String? {
        var parts = ["“\(name)” couldn’t be replaced: \(reason)"]
        if let backup { parts.append("The original couldn’t be put back and was kept as “\(backup.path)”.") }
        if let staged { parts.append("The incoming copy was kept as “\(staged.path)”.") }
        return parts.joined(separator: " ")
    }
}

struct TransferCommit: Sendable, Hashable {
    var source: ResourceItem
    var destination: ResourceItem
}

struct ManifestEntry: Sendable, Hashable {
    let isDirectory: Bool
    let size: Int64?
    let etag: String?
    let checksumSHA256: String?

    func matchesContent(_ other: ManifestEntry) -> Bool {
        guard !isDirectory, !other.isDirectory, size == other.size else { return false }
        if let a = etag, let b = other.etag, a != b { return false }
        if let a = checksumSHA256, let b = other.checksumSHA256, a.lowercased() != b.lowercased() { return false }
        return (etag?.isEmpty == false && etag == other.etag)
            || (checksumSHA256?.isEmpty == false && checksumSHA256?.lowercased() == other.checksumSHA256?.lowercased())
    }
}

final class TransferNode {
    enum State { case complete, partial, skipped }

    let item: ResourceItem
    var target: ResourceID?
    var state: State = .complete
    var hasFailure = false
    var firstError: FileOperationItemError?
    var sourceGone = false
    var children: [TransferNode] = []

    init(item: ResourceItem) { self.item = item }
}

final class TransferJob: @unchecked Sendable {
    let engine: CrossProviderTransfer
    let request: ResourceTransferRequest
    let resolver: ConflictResolver?
    let control: ResourceTransferControl
    let tracker: ProgressTracker
    var memory: [Bool: ConflictChoice] = [:]
    var errors: [FileOperationItemError] = []
    var verified = 0
    var deleted: [ResourceID] = []
    var stagingDir: URL?
    var resume: [ResourceID: TransferCommit] = [:]
    var commits: [ResourceID: TransferCommit] = [:]

    init(engine: CrossProviderTransfer, request: ResourceTransferRequest, resolver: ConflictResolver?, control: ResourceTransferControl, sink: @escaping @Sendable (FileOperationProgress) -> Void) {
        self.engine = engine
        self.request = request
        self.resolver = resolver
        self.control = control
        self.tracker = ProgressTracker(totalBytes: 0, totalItems: request.items.count, sink: sink)
    }

    var isMove: Bool { request.mode == .move }

    func provider(_ id: ResourceID) throws -> ResourceProvider {
        guard let p = engine.registry.provider(for: id) else { throw ResourceError.providerUnavailable(id.providerID) }
        return p
    }

    func staging() throws -> URL {
        if let stagingDir { return stagingDir }
        let d = try StagingArea.makeDirectory()
        stagingDir = d
        return d
    }

    static func isStop(_ e: Error) -> Bool {
        e is TransferStop || e is CancellationError || (e as? ResourceError) == .cancelled
    }

    func run() async -> ResourceTransferReport {
        var results = [ResourceTransferReport.ItemResult](repeating: .skipped, count: request.items.count)
        var aborted: String?
        var kept: [ResourceID: TransferCommit] = [:]
        var partialTargets: [Int: ResourceID] = [:]
        func keep(_ i: Int, target: ResourceID?) {
            let roots = [target, request.items[i].destinationResource].compactMap { $0 }
            if let target { partialTargets[i] = target }
            for (k, v) in commits.merging(resume, uniquingKeysWith: { a, _ in a }) where roots.contains(where: { k == $0 || k.isDescendant(of: $0) }) {
                kept[k] = v
            }
        }
        defer { if let stagingDir { try? FileManager.default.removeItem(at: stagingDir) } }
        tracker.finish()
        var stats: [ResourceItem?] = []
        for item in request.items {
            guard let s = item.sourceResource else { stats.append(nil); continue }
            let st = try? await (try? provider(s))?.stat(s)
            stats.append(st)
            if let size = st?.size, st?.isDirectory == false { tracker.addTotal(bytes: weighted(size, s, item.destinationResource)) }
        }
        for (i, item) in request.items.enumerated() {
            commits = [:]
            var placedTarget: ResourceID?
            do {
                try await control.checkpoint()
                guard let s = item.sourceResource, let d = item.destinationResource else {
                    throw ResourceError.unsupported("Transferring an item without a resource identity")
                }
                guard let info = stats[i] else { throw ResourceError.notFound(s.path) }
                if s.providerID == d.providerID && (d == s || d.isDescendant(of: s)) {
                    throw ResourceError.unsupported("Placing “\(s.name)” inside itself")
                }
                tracker.beginItem(name: s.name, size: 0)
                let node = try await transferItem(info, to: d)
                placedTarget = node.target
                switch node.state {
                case .skipped:
                    results[i] = .skipped
                case .complete:
                    results[i] = node.target.map { .committed($0) } ?? .skipped
                case .partial:
                    if node.hasFailure {
                        results[i] = .failed(node.firstError ?? FileOperationItemError(url: item.source ?? s.uri, message: "Some items in “\(s.name)” couldn’t be transferred."))
                    } else {
                        results[i] = node.target.map { .committed($0) } ?? .skipped
                    }
                }
                if isMove {
                    let srcP = try provider(s)
                    let before = errors.count
                    let clean = try await removePass(node, provider: srcP)
                    if !clean {
                        switch results[i] {
                        case .failed: break
                        default:
                            let first = errors.count > before ? errors[before] : FileOperationItemError(url: item.source ?? s.uri, message: "Some originals in “\(s.name)” couldn’t be removed after the move.")
                            results[i] = .failed(first)
                        }
                    }
                }
                if case .failed = results[i] { keep(i, target: placedTarget) }
                tracker.completeItemKeepingBytes()
            } catch is TransferStop {
                keep(i, target: placedTarget)
                aborted = "Stopped"
                break
            } catch is CancellationError {
                keep(i, target: placedTarget)
                aborted = "Cancelled"
                break
            } catch ResourceError.cancelled {
                keep(i, target: placedTarget)
                aborted = "Cancelled"
                break
            } catch {
                let e = FileOperationItemError.from(error, url: item.source ?? item.sourceResource?.uri ?? URL(fileURLWithPath: "/"))
                errors.append(e)
                results[i] = .failed(e)
                keep(i, target: placedTarget)
                tracker.completeItemKeepingBytes()
            }
        }
        tracker.finish()
        var report = ResourceTransferReport(results: results, errors: errors, aborted: aborted)
        report.verifiedFiles = verified
        report.deletedSources = deleted
        report.commits = kept
        report.partialTargets = partialTargets
        return report
    }

    func weighted(_ size: Int64, _ s: ResourceID, _ d: ResourceID?) -> Int64 {
        s.isLocal ? size : size * 2
    }

    func decide(_ source: ResourceItem, existing: ResourceItem) async throws -> ConflictChoice {
        let dirKey = source.isDirectory && existing.isDirectory
        if let remembered = memory[dirKey] { return remembered }
        let conflict = FileConflict(
            source: ConflictItemInfo(url: source.id.uri, isDirectory: source.isDirectory, size: source.size, modificationDate: source.modified),
            destination: ConflictItemInfo(url: existing.id.uri, isDirectory: existing.isDirectory, size: existing.size, modificationDate: existing.modified),
            isMove: isMove)
        var choice: ConflictChoice
        if let resolver {
            let decision = await resolver.resolve(conflict)
            choice = decision.choice
            if decision.applyToAll { memory[dirKey] = choice }
        } else {
            choice = engine.defaultChoice
        }
        if choice == .merge && !conflict.allowsMerge { choice = .keepBoth }
        return choice
    }

    func uniqueName(for target: ResourceID, provider: ResourceProvider) async throws -> ResourceID {
        guard let parent = target.lexicalParent else { return target }
        let names = Set(try await provider.listAll(parent).map(\.name))
        let base = (target.name as NSString).deletingPathExtension
        let ext = (target.name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !names.contains(candidate) { return parent.appending(candidate) }
            n += 1
        }
    }

    func transferItem(_ source: ResourceItem, to requested: ResourceID) async throws -> TransferNode {
        try await control.checkpoint()
        let node = TransferNode(item: source)
        let srcP = try provider(source.id)
        let dstP = try provider(requested)
        guard dstP.capabilities.canWrite else { throw ResourceError.permissionDenied("\(dstP.displayName) is read-only") }
        if isMove && !srcP.capabilities.canDelete && !srcP.capabilities.canTrash {
            throw ResourceError.unsupported("Moving items out of \(srcP.displayName)")
        }
        var target = requested
        var overwrite = false
        var merge = false
        if let existing = try await dstP.exists(requested) {
            var resumed = false
            if let prior = resume[requested], Self.sameRevision(existing, prior.destination) {
                if source.isDirectory && existing.isDirectory {
                    merge = true
                    resumed = true
                } else if !source.isDirectory && !existing.isDirectory {
                    if Self.sameRevision(source, prior.source) {
                        node.target = requested
                        commits[requested] = TransferCommit(source: source, destination: existing)
                        return node
                    }
                    overwrite = true
                    resumed = true
                }
            }
            if !resumed {
                switch try await decide(source, existing: existing) {
                case .skip:
                    node.state = .skipped
                    return node
                case .stop: throw TransferStop()
                case .keepBoth: target = try await uniqueName(for: requested, provider: dstP)
                case .replace:
                    let sameServer = source.id.providerID == requested.providerID && !source.id.isLocal
                    if existing.isDirectory || source.isDirectory || sameServer {
                        try await replaceStaged(node, existing: existing, srcP: srcP, dstP: dstP)
                        return node
                    }
                    overwrite = true
                case .merge: merge = true
                }
            }
        }
        node.target = target
        if source.id.providerID == target.providerID && !source.id.isLocal && !merge && !overwrite {
            if isMove && srcP.capabilities.canRename {
                let moved = try await srcP.move(source.id, to: target)
                tracker.settleFile(2 * (moved.size ?? source.size ?? 0))
                deleted.append(source.id)
                node.sourceGone = true
                return node
            }
            if !isMove && srcP.capabilities.contains(.serverSideCopy) {
                do {
                    let copied = try await srcP.copy(source.id, to: target)
                    tracker.settleFile(2 * (copied.size ?? source.size ?? 0))
                    commits[target] = TransferCommit(source: source, destination: copied)
                    return node
                } catch ResourceError.unsupported {}
            }
        }
        if source.isDirectory {
            try await transferDirectory(node, to: target, merge: merge, srcP: srcP, dstP: dstP)
        } else {
            try await transferFile(source, to: target, overwrite: overwrite, srcP: srcP, dstP: dstP)
        }
        return node
    }

    func backupName(for target: ResourceID, local: Bool) -> String {
        let tag = UUID().uuidString.prefix(8)
        if local {
            let base = (target.name as NSString).deletingPathExtension
            let ext = (target.name as NSString).pathExtension
            return ext.isEmpty ? "\(base) (replaced \(tag))" : "\(base) (replaced \(tag)).\(ext)"
        }
        return ".\(target.name).bfbak-\(tag)"
    }

    func replaceStaged(_ node: TransferNode, existing: ResourceItem, srcP: ResourceProvider, dstP: ResourceProvider) async throws {
        let source = node.item
        let target = existing.id
        guard let parent = target.lexicalParent else { throw ResourceError.unsupported("Replacing “\(target.name)”") }
        guard dstP.capabilities.canRename else {
            if !source.isDirectory && !existing.isDirectory && !(source.id.providerID == target.providerID && !source.id.isLocal) {
                node.target = target
                try await transferFile(source, to: target, overwrite: true, srcP: srcP, dstP: dstP)
                return
            }
            throw ResourceError.unsupported("Safely replacing “\(target.name)” on \(dstP.displayName)")
        }
        let backup = parent.appending(backupName(for: target, local: target.isLocal))
        let staged = parent.appending(".\(target.name).bftmp-\(UUID().uuidString.prefix(8))")
        let sameServer = source.id.providerID == target.providerID && !source.id.isLocal
        let serverSide = sameServer && (isMove ? srcP.capabilities.canRename : srcP.capabilities.contains(.serverSideCopy))
        var stagedByMove = false
        var leftover: Error?
        node.target = staged
        if serverSide {
            let before = try await manifest(of: source.id, provider: srcP)
            do {
                try await control.checkpoint()
                if isMove {
                    let moved = try await srcP.move(source.id, to: staged)
                    stagedByMove = true
                    tracker.settleFile(2 * (moved.size ?? source.size ?? 0))
                } else {
                    let copied = try await srcP.copy(source.id, to: staged)
                    tracker.settleFile(2 * (copied.size ?? source.size ?? 0))
                }
            } catch {
                let recovered = await Self.detached { await self.recoverStaging(staged, source: source.id, before: before, moved: self.isMove, provider: dstP) }
                switch recovered {
                case .discarded:
                    throw error
                case .complete:
                    stagedByMove = true
                    leftover = error
                case .stuck:
                    throw ReplacementRecoveryFailed(name: target.name, reason: error.localizedDescription, backup: nil, staged: staged)
                }
            }
            let movedIn = stagedByMove
            guard await covers(staged, provider: dstP, manifest: before) else {
                let kept = await Self.detached { await self.unstage(staged, source: source.id, moved: movedIn, provider: dstP) }
                throw ReplacementRecoveryFailed(name: target.name, reason: "the copy on the server didn’t match the original", backup: nil, staged: kept)
            }
        } else {
            do {
                if source.isDirectory {
                    try await transferDirectory(node, to: staged, merge: false, srcP: srcP, dstP: dstP)
                } else {
                    try await transferFile(source, to: staged, overwrite: false, srcP: srcP, dstP: dstP)
                }
            } catch {
                _ = await Self.detached { await self.unstage(staged, source: source.id, moved: false, provider: dstP) }
                throw error
            }
            guard node.state == .complete else {
                _ = await Self.detached { await self.unstage(staged, source: source.id, moved: false, provider: dstP) }
                throw IncompleteResourceReplacement(name: target.name)
            }
        }
        let expected: [String: ManifestEntry]
        let moved = stagedByMove
        do {
            expected = try await manifest(of: staged, provider: dstP)
            try await control.checkpoint()
        } catch {
            let kept = await Self.detached { await self.unstage(staged, source: source.id, moved: moved, provider: dstP) }
            if let kept { throw ReplacementRecoveryFailed(name: target.name, reason: error.localizedDescription, backup: nil, staged: kept) }
            throw error
        }
        try await Self.detachedThrowing {
            try await self.swap(staged: staged, into: target, backup: backup, expected: expected, source: source.id, moved: moved, provider: dstP)
        }
        node.target = target
        commits[target] = TransferCommit(source: source, destination: (try? await dstP.stat(target)) ?? existing)
        if stagedByMove {
            node.sourceGone = true
            if let leftover {
                let err = FileOperationItemError.from(leftover, url: source.id.uri)
                errors.append(err)
                node.state = .partial
                node.hasFailure = true
                if node.firstError == nil { node.firstError = err }
            } else {
                deleted.append(source.id)
            }
        }
    }

    enum StagingRecovery { case discarded, complete, stuck }

    static func detached<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task.detached { await work() }.value
    }

    static func detachedThrowing(_ work: @escaping @Sendable () async throws -> Void) async throws {
        try await Task.detached { try await work() }.value
    }

    func recoverStaging(_ staged: ResourceID, source: ResourceID, before: [String: ManifestEntry], moved: Bool, provider: ResourceProvider) async -> StagingRecovery {
        var discard = !moved
        if moved { discard = await covers(source, provider: provider, manifest: before, requireEvidence: true) }
        if discard {
            let kept = await unstage(staged, source: source, moved: false, provider: provider)
            return kept == nil ? .discarded : .stuck
        }
        let stagedComplete = await covers(staged, provider: provider, manifest: before)
        return stagedComplete ? .complete : .stuck
    }

    func unstage(_ staged: ResourceID, source: ResourceID, moved: Bool, provider: ResourceProvider) async -> ResourceID? {
        guard (try? await provider.exists(staged)) != nil else { return nil }
        if moved {
            if (try? await provider.exists(source)) == nil {
                do { _ = try await provider.move(staged, to: source); return nil } catch { return staged }
            }
            return await mergeBack(staged, into: source, provider: provider) ? nil : staged
        }
        do {
            try await provider.delete(staged, recursive: true)
            return nil
        } catch {
            return staged
        }
    }

    func swap(staged: ResourceID, into target: ResourceID, backup: ResourceID, expected: [String: ManifestEntry], source: ResourceID, moved: Bool, provider p: ResourceProvider) async throws {
        do {
            _ = try await p.move(target, to: backup)
        } catch {
            let restored = await restoreOriginal(backup, to: target, provider: p)
            let kept = await unstage(staged, source: source, moved: moved, provider: p)
            if !restored || kept != nil {
                throw ReplacementRecoveryFailed(name: target.name, reason: error.localizedDescription, backup: restored ? nil : backup, staged: kept)
            }
            throw error
        }
        do {
            _ = try await p.move(staged, to: target)
        } catch {
            if await covers(target, provider: p, manifest: expected, requireEvidence: true) {
                if (try? await p.exists(staged)) != nil { try? await p.delete(staged, recursive: true) }
                await discardReplaced(backup, provider: p)
                return
            }
            if (try? await p.exists(target)) != nil {
                let ours = await isSubset(target, of: expected, provider: p)
                let stagedIntact = await covers(staged, provider: p, manifest: expected, requireEvidence: true)
                guard ours && stagedIntact, (try? await p.delete(target, recursive: true)) != nil else {
                    throw ReplacementRecoveryFailed(name: target.name, reason: error.localizedDescription, backup: backup, staged: staged)
                }
            }
            let restored = await restoreOriginal(backup, to: target, provider: p)
            let kept = await unstage(staged, source: source, moved: moved, provider: p)
            if !restored || kept != nil {
                throw ReplacementRecoveryFailed(name: target.name, reason: error.localizedDescription, backup: restored ? nil : backup, staged: kept)
            }
            throw error
        }
        await discardReplaced(backup, provider: p)
    }

    func restoreOriginal(_ backup: ResourceID, to target: ResourceID, provider p: ResourceProvider) async -> Bool {
        guard (try? await p.exists(backup)) != nil else { return (try? await p.exists(target)) != nil }
        if (try? await p.exists(target)) == nil {
            do { _ = try await p.move(backup, to: target); return true } catch { return false }
        }
        return await mergeBack(backup, into: target, provider: p)
    }

    func mergeBack(_ from: ResourceID, into to: ResourceID, provider p: ResourceProvider) async -> Bool {
        guard let a = try? await p.stat(from), let b = try? await p.stat(to) else { return false }
        if a.isDirectory && b.isDirectory {
            guard let children = try? await p.listAll(from) else { return false }
            var ok = true
            for c in children {
                let dest = to.appending(c.name)
                if (try? await p.exists(dest)) == nil {
                    do { _ = try await p.move(c.id, to: dest) } catch { ok = false }
                } else if !(await mergeBack(c.id, into: dest, provider: p)) {
                    ok = false
                }
            }
            guard ok, (try? await p.listAll(from))?.isEmpty == true else { return false }
            return (try? await p.delete(from, recursive: false)) != nil
        }
        let original = ManifestEntry(isDirectory: a.isDirectory, size: a.size, etag: a.etag, checksumSHA256: a.checksumSHA256)
        let restored = ManifestEntry(isDirectory: b.isDirectory, size: b.size, etag: b.etag, checksumSHA256: b.checksumSHA256)
        guard original.matchesContent(restored) else { return false }
        return (try? await p.delete(from, recursive: false)) != nil
    }

    func manifest(of id: ResourceID, provider p: ResourceProvider) async throws -> [String: ManifestEntry] {
        let item = try await p.stat(id)
        var out: [String: ManifestEntry] = ["": ManifestEntry(isDirectory: item.isDirectory, size: item.isDirectory ? nil : item.size, etag: item.etag, checksumSHA256: item.checksumSHA256)]
        guard item.isDirectory else { return out }
        var pending: [(ResourceID, String)] = [(id, "")]
        while let (dir, prefix) = pending.popLast() {
            for child in try await p.listAll(dir) {
                let rel = prefix.isEmpty ? child.name : prefix + "/" + child.name
                out[rel] = ManifestEntry(isDirectory: child.isDirectory, size: child.isDirectory ? nil : child.size, etag: child.etag, checksumSHA256: child.checksumSHA256)
                if child.isDirectory { pending.append((child.id, rel)) }
            }
        }
        return out
    }

    func covers(_ id: ResourceID, provider p: ResourceProvider, manifest expected: [String: ManifestEntry], requireEvidence: Bool = false) async -> Bool {
        guard let found = try? await manifest(of: id, provider: p) else { return false }
        if requireEvidence {
            guard found.keys.sorted() == expected.keys.sorted(), expected.values.contains(where: { !$0.isDirectory }) else { return false }
        }
        for (k, v) in expected {
            guard let f = found[k], f.isDirectory == v.isDirectory, v.isDirectory || f.size == v.size else { return false }
            if requireEvidence && !v.isDirectory && !v.matchesContent(f) { return false }
        }
        return true
    }

    func isSubset(_ id: ResourceID, of expected: [String: ManifestEntry], provider p: ResourceProvider) async -> Bool {
        guard let found = try? await manifest(of: id, provider: p) else { return false }
        guard found.values.contains(where: { !$0.isDirectory }) else { return false }
        for (k, v) in found {
            guard let e = expected[k], e.isDirectory == v.isDirectory, e.isDirectory || e.matchesContent(v) else { return false }
        }
        return true
    }

    func discardReplaced(_ backup: ResourceID, provider: ResourceProvider) async {
        do {
            if backup.isLocal && provider.capabilities.canTrash {
                try await provider.trash(backup)
            } else {
                try await provider.delete(backup, recursive: true)
            }
        } catch {
            errors.append(FileOperationItemError(url: backup.uri, message: "The replaced item couldn’t be removed and was kept as “\(backup.name)”."))
        }
    }

    func transferDirectory(_ node: TransferNode, to target: ResourceID, merge: Bool, srcP: ResourceProvider, dstP: ResourceProvider) async throws {
        if !merge {
            let made = try await dstP.makeDirectory(target)
            commits[target] = TransferCommit(source: node.item, destination: made)
        }
        let children = try await srcP.listAll(node.item.id)
        for c in children where !c.isDirectory { tracker.addTotal(bytes: weighted(c.size ?? 0, c.id, target)) }
        for child in children {
            try await control.checkpoint()
            do {
                tracker.setCurrent(child.name)
                let c = try await transferItem(child, to: target.appending(child.name))
                node.children.append(c)
                if c.state != .complete { node.state = .partial }
                if c.hasFailure {
                    node.hasFailure = true
                    if node.firstError == nil { node.firstError = c.firstError }
                }
            } catch let e where Self.isStop(e) {
                throw e
            } catch {
                let err = FileOperationItemError.from(error, url: child.id.uri)
                errors.append(err)
                node.state = .partial
                node.hasFailure = true
                if node.firstError == nil { node.firstError = err }
            }
        }
    }

    func transferFile(_ source: ResourceItem, to target: ResourceID, overwrite: Bool, srcP: ResourceProvider, dstP: ResourceProvider) async throws {
        let size = source.size ?? 0
        tracker.setCurrent(source.name)
        let staged: URL
        var ownsStaged = false
        if let local = source.id.fileURL {
            staged = local
        } else {
            if let free = StagingArea.availableCapacity(), free - engine.stagingReserve < size {
                throw ResourceError.insufficientSpace(needed: size, available: max(0, free - engine.stagingReserve))
            }
            staged = try staging().appendingPathComponent(UUID().uuidString)
            ownsStaged = true
            let tracker = self.tracker
            let downloaded = try await srcP.download(source.id, to: staged, progress: { tracker.setFileBytes($0) })
            tracker.settleFile(downloaded.size ?? size)
        }
        defer { if ownsStaged { try? FileManager.default.removeItem(at: staged) } }
        try await control.checkpoint()
        let digest = try await FileDigest.computeAsync(staged)
        if ownsStaged {
            if let expected = source.size, digest.size != expected {
                throw ResourceError.verificationFailed("“\(source.name)” arrived with \(digest.size) bytes instead of \(expected)")
            }
            if let sha = source.checksumSHA256, sha.lowercased() != digest.sha256 {
                throw ResourceError.verificationFailed("“\(source.name)” didn’t match its stored SHA-256")
            }
        }
        let tracker = self.tracker
        let options = ResourceUploadOptions(overwrite: overwrite, sha256: digest.sha256, contentType: source.contentType?.preferredMIMEType)
        let uploaded = try await dstP.upload(from: staged, to: target, options: options, progress: { tracker.setFileBytes($0) })
        tracker.settleFile(uploaded.size ?? digest.size)
        let landed = try await verify(uploaded, digest: digest, target: target, provider: dstP, readBack: isMove)
        commits[target] = TransferCommit(source: source, destination: landed)
        verified += 1
    }

    @discardableResult
    func verify(_ uploaded: ResourceItem, digest: FileDigest, target: ResourceID, provider: ResourceProvider, readBack: Bool) async throws -> ResourceItem {
        let check = try await provider.stat(target)
        guard check.size == digest.size else {
            throw ResourceError.verificationFailed("“\(target.name)” is \(check.size ?? -1) bytes at the destination, expected \(digest.size)")
        }
        if let sha = check.checksumSHA256 ?? uploaded.checksumSHA256, sha.lowercased() != digest.sha256 {
            throw ResourceError.verificationFailed("“\(target.name)” has a different SHA-256 at the destination")
        }
        if let etag = check.etag, etag.count == 32, etag.allSatisfy(\.isHexDigit), etag.lowercased() != digest.md5 {
            throw ResourceError.verificationFailed("“\(target.name)” has a different ETag at the destination")
        }
        if let local = target.fileURL {
            let written = try await FileDigest.computeAsync(local)
            guard written.sha256 == digest.sha256 else { throw ResourceError.verificationFailed("“\(target.name)” didn’t match after writing") }
            return check
        }
        let hasContentHash = (check.checksumSHA256 ?? uploaded.checksumSHA256) != nil || (check.etag.map { $0.count == 32 && $0.allSatisfy(\.isHexDigit) } ?? false)
        guard readBack && !hasContentHash else { return check }
        if let free = StagingArea.availableCapacity(), free - engine.stagingReserve < digest.size {
            throw ResourceError.verificationFailed("There isn’t enough free space to read “\(target.name)” back for verification, so the original was kept")
        }
        let copy = try staging().appendingPathComponent("verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try await provider.download(target, to: copy, progress: { _ in })
        let back = try await FileDigest.computeAsync(copy)
        guard back.sha256 == digest.sha256 else { throw ResourceError.verificationFailed("“\(target.name)” read back differently from what was sent") }
        return check
    }

    func removePass(_ node: TransferNode, provider: ResourceProvider) async throws -> Bool {
        switch node.state {
        case .skipped:
            return true
        case .complete:
            guard !node.sourceGone else { return true }
            return try await removeNode(node, provider: provider)
        case .partial:
            var clean = true
            for child in node.children where try await !removePass(child, provider: provider) { clean = false }
            return clean
        }
    }

    static func sameRevision(_ a: ResourceItem, _ b: ResourceItem) -> Bool {
        guard a.isDirectory == b.isDirectory else { return false }
        if a.isDirectory { return true }
        guard a.size == b.size else { return false }
        var strong = false
        if let x = a.modified, let y = b.modified { guard x == y else { return false }; strong = true }
        if let x = a.etag, let y = b.etag { guard x == y else { return false }; strong = true }
        if let x = a.checksumSHA256, let y = b.checksumSHA256 { guard x.lowercased() == y.lowercased() else { return false }; strong = true }
        return strong
    }

    static func unchanged(_ now: ResourceItem, _ before: ResourceItem) -> Bool {
        guard now.isDirectory == before.isDirectory else { return false }
        if now.isDirectory { return true }
        if now.size != before.size { return false }
        if let a = now.modified, let b = before.modified, a != b { return false }
        if let a = now.etag, let b = before.etag, a != b { return false }
        return true
    }

    func snapshotMatches(_ node: TransferNode, provider: ResourceProvider) async throws -> Bool {
        let current = try await provider.listAll(node.item.id)
        let expected = node.children.filter { !$0.sourceGone }
        guard current.count == expected.count else { return false }
        let byName = Dictionary(expected.map { ($0.item.name, $0) }, uniquingKeysWith: { a, _ in a })
        for item in current {
            guard let child = byName[item.name], Self.unchanged(item, child.item) else { return false }
            if item.isDirectory, try await !snapshotMatches(child, provider: provider) { return false }
        }
        return true
    }

    func removeNode(_ node: TransferNode, provider: ResourceProvider) async throws -> Bool {
        try await control.checkpoint()
        let id = node.item.id
        let useTrash = id.isLocal && provider.capabilities.canTrash
        let changed = FileOperationItemError(url: id.uri, message: "“\(id.name)” changed during the move, so the original was kept.")
        do {
            if node.item.isDirectory {
                if useTrash, try await snapshotMatches(node, provider: provider) {
                    try await provider.trash(id)
                    deleted.append(id)
                    return true
                }
                var clean = true
                for child in node.children where !child.sourceGone && child.state == .complete {
                    if try await !removeNode(child, provider: provider) { clean = false }
                }
                if try await provider.listAll(id).isEmpty {
                    try await provider.delete(id, recursive: false)
                    deleted.append(id)
                    return clean
                }
                if clean {
                    errors.append(FileOperationItemError(url: id.uri, message: "“\(id.name)” was kept because items were added to it during the move."))
                }
                return false
            }
            if useTrash {
                let now = try await provider.stat(id)
                guard Self.unchanged(now, node.item) else {
                    errors.append(changed)
                    return false
                }
                try await provider.trash(id)
            } else {
                guard try await provider.deleteIfUnchanged(id, from: node.item) else {
                    errors.append(changed)
                    return false
                }
            }
            deleted.append(id)
            return true
        } catch let e where Self.isStop(e) {
            throw e
        } catch {
            errors.append(FileOperationItemError.from(error, url: id.uri))
            return false
        }
    }
}
