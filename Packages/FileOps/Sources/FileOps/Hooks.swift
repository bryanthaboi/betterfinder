import Foundation
import FSCore

public enum OperationOrigin: Sendable, Hashable {
    case user
    case undo
    case redo
    case retry
    case mod(String)

    public var isMod: Bool {
        if case .mod = self { return true }
        return false
    }
}

public enum OperationKind: String, Sendable, Hashable, CaseIterable {
    case copy, move, trash, rename, duplicate, batchRename, newFolder, newFile, tag, delete
}

public struct OperationItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let source: URL?
    public let destination: URL?
    public let sourceResource: ResourceID?
    public let destinationResource: ResourceID?

    public init(id: UUID = UUID(), source: URL?, destination: URL?) {
        self.init(id: id, source: source, destination: destination, sourceResource: nil, destinationResource: nil)
    }

    public init(id: UUID = UUID(), source: URL?, destination: URL?, sourceResource: ResourceID?, destinationResource: ResourceID?) {
        self.id = id
        self.source = source
        self.destination = destination
        self.sourceResource = sourceResource ?? source.flatMap { $0.isFileURL ? ResourceID.local($0) : ResourceID(uri: $0) }
        self.destinationResource = destinationResource ?? destination.flatMap { $0.isFileURL ? ResourceID.local($0) : ResourceID(uri: $0) }
    }

    public init(id: UUID = UUID(), sourceResource: ResourceID?, destinationResource: ResourceID?) {
        self.init(id: id, source: sourceResource?.uri, destination: destinationResource?.uri, sourceResource: sourceResource, destinationResource: destinationResource)
    }

    public var isRemote: Bool {
        (sourceResource.map { !$0.isLocal } ?? false) || (destinationResource.map { !$0.isLocal } ?? false)
    }

    var primaryURL: URL { source ?? destination ?? URL(fileURLWithPath: "/") }
}

public struct OperationSnapshot: Sendable, Hashable {
    public let operationID: UUID
    public let attemptID: UUID
    public let kind: OperationKind
    public let items: [OperationItem]
    public let origin: OperationOrigin
    public let recursionDepth: Int
    public let tags: [String]?

    public init(operationID: UUID = UUID(), attemptID: UUID = UUID(), kind: OperationKind, items: [OperationItem], origin: OperationOrigin = .user, recursionDepth: Int = 0, tags: [String]? = nil) {
        self.operationID = operationID
        self.attemptID = attemptID
        self.kind = kind
        self.items = items
        self.origin = origin
        self.recursionDepth = recursionDepth
        self.tags = tags
    }
}

public struct OperationItemOutcome: Sendable, Hashable, Identifiable {
    public enum Result: Sendable, Hashable {
        case committed(URL?)
        case skipped
        case failed(FileOperationItemError)
    }

    public var id: UUID { item.id }
    public let index: Int
    public let item: OperationItem
    public let result: Result

    public init(index: Int, item: OperationItem, result: Result) {
        self.index = index
        self.item = item
        self.result = result
    }
}

public struct OperationOutcome: Sendable, Hashable {
    public let operationID: UUID
    public let attemptID: UUID
    public let items: [OperationItemOutcome]
    public let errors: [FileOperationItemError]
    public let aborted: String?

    public init(operationID: UUID, attemptID: UUID, items: [OperationItemOutcome], errors: [FileOperationItemError] = [], aborted: String? = nil) {
        self.operationID = operationID
        self.attemptID = attemptID
        self.items = items
        self.errors = errors
        self.aborted = aborted
    }

    public var committed: [OperationItemOutcome] {
        items.filter { if case .committed = $0.result { return true } else { return false } }
    }

    public var skipped: [OperationItemOutcome] {
        items.filter { if case .skipped = $0.result { return true } else { return false } }
    }

    public var failed: [OperationItemOutcome] {
        items.filter { if case .failed = $0.result { return true } else { return false } }
    }

    public var isPartialFailure: Bool {
        (!failed.isEmpty || !errors.isEmpty) && !committed.isEmpty
    }
}

public enum HookDecision: Sendable, Hashable {
    case allow
    case deny(String)
}

public protocol FileOperationHook: AnyObject, Sendable {
    var id: String { get }
    var priority: Int { get }
    var timeout: TimeInterval? { get }
    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision
    func after(_ snapshot: OperationSnapshot, _ outcome: OperationOutcome) async throws
}

public extension FileOperationHook {
    var timeout: TimeInterval? { nil }
    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision { .allow }
    func after(_ snapshot: OperationSnapshot, _ outcome: OperationOutcome) async throws {}
}

public protocol OperationAuthorizer: Sendable {
    func authorize(_ snapshot: OperationSnapshot) async -> HookDecision
}

public struct AllowAllAuthorizer: OperationAuthorizer {
    public init() {}
    public func authorize(_ snapshot: OperationSnapshot) async -> HookDecision { .allow }
}

public struct HookDenial: Sendable, Hashable {
    public let hookID: String
    public let owner: String
    public let reason: String

    public init(hookID: String, owner: String, reason: String) {
        self.hookID = hookID
        self.owner = owner
        self.reason = reason
    }

    public var message: String { "\(owner) blocked this operation: \(reason)" }
}

public struct PausedOperationInfo: Sendable, Hashable {
    public let snapshot: OperationSnapshot
    public let hookID: String
    public let owner: String
    public let reason: String

    public init(snapshot: OperationSnapshot, hookID: String, owner: String, reason: String) {
        self.snapshot = snapshot
        self.hookID = hookID
        self.owner = owner
        self.reason = reason
    }

    public var message: String { "\(owner) blocked this operation: \(reason)" }
}

public enum HookUserDecision: Sendable, Hashable {
    case runAnyway
    case cancel
}

public protocol HookDecisionPresenting: AnyObject, Sendable {
    func decide(_ info: PausedOperationInfo) async -> HookUserDecision
}

public struct HookDeniedError: Error, LocalizedError, Sendable {
    public let denial: HookDenial
    public var errorDescription: String? { denial.message }
}

public struct HookDecisionRequired: Error, LocalizedError, Sendable {
    public let info: PausedOperationInfo
    public var errorDescription: String? { info.message }
}

public struct HooksRequireAsync: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "File operation hooks are active; use the async API so they can run." }
}

public struct OperationRecursionLimitExceeded: Error, LocalizedError, Sendable {
    public let depth: Int
    public let limit: Int
    public var errorDescription: String? { "Operation nesting depth \(depth) exceeds the limit of \(limit)." }
}

public final class FileOpsRegistrationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return onCancel != nil
    }

    public func cancel() {
        lock.lock()
        let handler = onCancel
        onCancel = nil
        lock.unlock()
        handler?()
    }
}

enum HookContext {
    struct Info: Sendable {
        let owner: String
        let depth: Int
    }

    @TaskLocal static var current: Info?
}

final class DecisionLatch: @unchecked Sendable {
    enum Value: Sendable { case runAnyway, cancel }

    private let lock = NSLock()
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func reset() {
        lock.lock()
        if continuation == nil { value = nil }
        lock.unlock()
    }

    func resolve(_ v: Value) {
        lock.lock()
        if value == nil { value = v }
        let result = value!
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: result)
    }

    func wait() async -> Value {
        await withCheckedContinuation { (c: CheckedContinuation<Value, Never>) in
            lock.lock()
            if let value {
                lock.unlock()
                c.resume(returning: value)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}
