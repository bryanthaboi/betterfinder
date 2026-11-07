import Combine
import FileOps
import Foundation
import ModKit
import Settings

public struct ModHostEnvironment: Sendable, Equatable {
    public var locale: String
    public var dark: Bool
    public var currentLocation: (id: String, title: String, provider: String?)?
    public var currentFolder: URL?

    public init(locale: String = Locale.current.identifier, dark: Bool = false, currentLocation: (id: String, title: String, provider: String?)? = nil, currentFolder: URL? = nil) {
        self.locale = locale
        self.dark = dark
        self.currentLocation = currentLocation
        self.currentFolder = currentFolder
    }

    public static func == (a: ModHostEnvironment, b: ModHostEnvironment) -> Bool {
        a.locale == b.locale && a.dark == b.dark && a.currentLocation?.id == b.currentLocation?.id && a.currentFolder == b.currentFolder
    }
}

public protocol ModHostServices: AnyObject, Sendable {
    func pickDestination(modId: String, prompt: String) async -> URL?
    func confirmUnrestrictedExecution(modId: String, executable: String, arguments: [String]) async -> Bool
    func requestCredential(modId: String, name: String, destination: String) async -> String?
    func environment() async -> ModHostEnvironment
}

public final class DenyingModHostServices: ModHostServices, @unchecked Sendable {
    public init() {}
    public func pickDestination(modId: String, prompt: String) async -> URL? { nil }
    public func confirmUnrestrictedExecution(modId: String, executable: String, arguments: [String]) async -> Bool { false }
    public func requestCredential(modId: String, name: String, destination: String) async -> String? { nil }
    public func environment() async -> ModHostEnvironment { ModHostEnvironment() }
}

public enum ModConflictPolicy: String, Sendable { case fail, rename, skip }

public enum ModOperationState: String, Sendable { case queued, running, done, failed, cancelled }

public struct ModOperationProgress: Sendable, Equatable {
    public var state: ModOperationState
    public var completed: Int
    public var total: Int
    public init(state: ModOperationState, completed: Int, total: Int) { self.state = state; self.completed = completed; self.total = total }
}

public protocol ModFileOperationsPerforming: AnyObject, Sendable {
    func copy(_ items: [URL], to destination: URL, conflict: ModConflictPolicy, modId: String) async throws -> String
    func move(_ items: [URL], to destination: URL, conflict: ModConflictPolicy, modId: String) async throws -> String
    func trash(_ items: [URL], modId: String) async throws -> String
    func rename(_ item: URL, to newName: String, modId: String) async throws -> String
    func status(_ operationId: String) async -> ModOperationProgress?
    func cancel(_ operationId: String) async -> Bool
}

public protocol ModFileOperationsObserving: AnyObject, Sendable {
    func observeCompletion(_ operationId: String, _ handler: @escaping @Sendable (ModOperationProgress) -> Void) async
}

public protocol ModIndexProviding: AnyObject, Sendable {
    func fetch() async throws -> ModIndexSnapshot
}

public protocol ModPackageFetching: AnyObject, Sendable {
    func fetchPackage(for listing: ModListing) async throws -> URL
}

public struct ModReleaseArtifact: Sendable {
    public var archive: URL
    public var listing: ModIndexListing
    public var author: ModAuthorFile

    public init(archive: URL, listing: ModIndexListing, author: ModAuthorFile) {
        self.archive = archive; self.listing = listing; self.author = author
    }
}

public protocol ModVerifiedPackageFetching: ModPackageFetching {
    func fetchRelease(for listing: ModListing) async throws -> ModReleaseArtifact
}

public protocol ModFileSearching: AnyObject, Sendable {
    func search(_ query: String, under root: URL, limit: Int, cursor: String?) async throws -> (urls: [URL], cursor: String?)
}

public protocol ModCredentialStoring: AnyObject, Sendable {
    func names(modId: String) -> [(name: String, destination: String)]
    func secret(modId: String, name: String) -> (secret: String, destination: String)?
    func store(modId: String, name: String, destination: String, secret: String) throws
    func removeAll(modId: String)
}

public final class SecretStoreCredentials: ModCredentialStoring, @unchecked Sendable {
    private let secrets: SecretStore
    private let index: URL
    private let lock = NSLock()

    public init(secrets: SecretStore = KeychainSecretStore(servicePrefix: "betterfinder.mod.credential."), paths: ModHostPaths) {
        self.secrets = secrets
        self.index = paths.data.appendingPathComponent("credentials.json")
    }

    private func load() -> [String: [String: String]] {
        guard let d = try? Data(contentsOf: index), let v = try? JSONDecoder().decode([String: [String: String]].self, from: d) else { return [:] }
        return v
    }

    public func names(modId: String) -> [(name: String, destination: String)] {
        lock.lock(); defer { lock.unlock() }
        return (load()[modId] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public func secret(modId: String, name: String) -> (secret: String, destination: String)? {
        lock.lock()
        let dest = load()[modId]?[name]
        lock.unlock()
        guard let dest, let s = try? secrets.readSecret(modID: modId, key: name) else { return nil }
        return (s, dest)
    }

    public func store(modId: String, name: String, destination: String, secret: String) throws {
        try secrets.writeSecret(secret, modID: modId, key: name)
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[modId, default: [:]][name] = destination
        try ModFiles.writePrivate(try JSONEncoder().encode(all), to: index)
    }

    public func removeAll(modId: String) {
        try? secrets.deleteAllSecrets(modID: modId)
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all.removeValue(forKey: modId)
        if let d = try? JSONEncoder().encode(all) { try? ModFiles.writePrivate(d, to: index) }
    }
}

@MainActor
public final class FileOperationQueueAdapter: ModFileOperationsPerforming, ModFileOperationsObserving, @unchecked Sendable {
    public let queue: FileOperationQueue
    public let finishedLimit: Int
    private var operations: [String: FileOperation] = [:]
    private var renames: [String: ModOperationProgress] = [:]
    private var watches: [String: AnyCancellable] = [:]
    private var observers: [String: [@Sendable (ModOperationProgress) -> Void]] = [:]
    private var finished: [String: ModOperationProgress] = [:]
    private var finishedOrder: [String] = []

    public convenience init() { self.init(queue: .shared) }

    public init(queue: FileOperationQueue) {
        self.queue = queue
        self.finishedLimit = 1024
    }

    public init(queue: FileOperationQueue, finishedLimit: Int) {
        self.queue = queue
        self.finishedLimit = max(1, finishedLimit)
    }

    private func track(_ op: FileOperation) -> String {
        let id = op.operationID.uuidString
        operations[id] = op
        watches[id] = op.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.settle(id) }
        }
        return id
    }

    private static func progress(of op: FileOperation) -> ModOperationProgress {
        let state: ModOperationState
        switch op.state {
        case .queued: state = .queued
        case .running, .paused, .awaitingDecision: state = .running
        case .finished: state = .done
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        return ModOperationProgress(state: state, completed: op.progress.itemsCompleted, total: max(op.progress.itemsTotal, op.progress.itemsCompleted))
    }

    private func settle(_ id: String) {
        guard let op = operations[id], !op.isActive else { return }
        operations.removeValue(forKey: id)
        watches.removeValue(forKey: id)
        complete(id, Self.progress(of: op))
    }

    private func complete(_ id: String, _ progress: ModOperationProgress) {
        if finished.updateValue(progress, forKey: id) == nil { finishedOrder.append(id) }
        while finishedOrder.count > finishedLimit {
            finished.removeValue(forKey: finishedOrder.removeFirst())
        }
        for handler in observers.removeValue(forKey: id) ?? [] { handler(progress) }
    }

    nonisolated public func copy(_ items: [URL], to destination: URL, conflict: ModConflictPolicy, modId: String) async throws -> String {
        await MainActor.run { track(queue.enqueue(.copy(sources: items, destination: destination), origin: .mod(modId))) }
    }

    nonisolated public func move(_ items: [URL], to destination: URL, conflict: ModConflictPolicy, modId: String) async throws -> String {
        await MainActor.run { track(queue.enqueue(.move(sources: items, destination: destination), origin: .mod(modId))) }
    }

    nonisolated public func trash(_ items: [URL], modId: String) async throws -> String {
        await MainActor.run { track(queue.enqueue(.trash(items: items), origin: .mod(modId))) }
    }

    nonisolated public func rename(_ item: URL, to newName: String, modId: String) async throws -> String {
        let id = UUID().uuidString
        await MainActor.run { renames[id] = ModOperationProgress(state: .running, completed: 0, total: 1) }
        Task { @MainActor in
            let result: ModOperationProgress
            do {
                _ = try await FileActions.renameAsync(item, to: newName, origin: .mod(modId))
                result = ModOperationProgress(state: .done, completed: 1, total: 1)
            } catch {
                result = ModOperationProgress(state: .failed, completed: 0, total: 1)
            }
            renames.removeValue(forKey: id)
            complete(id, result)
        }
        return id
    }

    nonisolated public func status(_ operationId: String) async -> ModOperationProgress? {
        await MainActor.run {
            if let r = renames[operationId] { return r }
            if let done = finished[operationId] { return done }
            guard let op = operations[operationId] else { return nil }
            return Self.progress(of: op)
        }
    }

    nonisolated public func cancel(_ operationId: String) async -> Bool {
        await MainActor.run {
            guard let op = operations[operationId], op.isActive else { return false }
            op.cancel()
            return true
        }
    }

    nonisolated public func observeCompletion(_ operationId: String, _ handler: @escaping @Sendable (ModOperationProgress) -> Void) async {
        await MainActor.run {
            if let done = finished[operationId] {
                handler(done)
            } else if operations[operationId] != nil || renames[operationId] != nil {
                observers[operationId, default: []].append(handler)
            }
        }
    }
}
