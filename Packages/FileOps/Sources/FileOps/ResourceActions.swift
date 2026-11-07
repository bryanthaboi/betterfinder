import Foundation
import FSCore

public enum ResourceActions {
    public static func provider(for id: ResourceID, in registry: ResourceProviderRegistry) throws -> ResourceProvider {
        guard let p = registry.provider(for: id) else { throw ResourceError.providerUnavailable(id.providerID) }
        return p
    }

    public static func undoUnavailableReason(for id: ResourceID, registry: ResourceProviderRegistry = .shared) -> String? {
        guard let p = registry.provider(for: id), !p.capabilities.canUndo else { return nil }
        return "Undo isn’t available on \(p.displayName)."
    }

    public static func trashUnavailableReason(for id: ResourceID, registry: ResourceProviderRegistry = .shared) -> String? {
        guard let p = registry.provider(for: id) else { return "This location isn’t connected." }
        return trashUnavailableReason(provider: p)
    }

    public static func trashUnavailableReason(provider p: ResourceProvider) -> String? {
        p.capabilities.canTrash ? nil : "\(p.displayName) doesn’t have a Trash. Items you delete there are removed immediately."
    }

    static func validName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ResourceError.invalidName(name)
        }
    }

    @discardableResult
    public static func rename(_ id: ResourceID, to newName: String, registry: ResourceProviderRegistry = .shared, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> ResourceID {
        try await rename(id, to: newName, provider: try provider(for: id, in: registry), hooks: hooks, origin: origin)
    }

    @discardableResult
    public static func rename(_ id: ResourceID, to newName: String, provider p: ResourceProvider, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> ResourceID {
        try validName(newName)
        guard let parent = id.lexicalParent else { throw ResourceError.invalidName(newName) }
        let target = parent.appending(newName)
        if target == id { return id }
        guard p.capabilities.canRename else { throw ResourceError.unsupported("Renaming on \(p.displayName)") }
        return try await hooks.guardedAsync(kind: .rename, items: [OperationItem(sourceResource: id, destinationResource: target)], origin: origin) {
            _ = try await p.move(id, to: target)
            return GuardedResult(value: target, urls: [target.uri])
        }
    }

    public static func delete(_ ids: [ResourceID], registry: ResourceProviderRegistry = .shared, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        try await delete(ids, providers: try ids.map { try provider(for: $0, in: registry) }, hooks: hooks, origin: origin)
    }

    public static func delete(_ ids: [ResourceID], provider: ResourceProvider, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        try await delete(ids, providers: ids.map { _ in provider }, hooks: hooks, origin: origin)
    }

    static func delete(_ ids: [ResourceID], providers: [ResourceProvider], hooks: FileOperationHookRegistry, origin: OperationOrigin) async throws {
        guard !ids.isEmpty else { return }
        for p in providers where !p.capabilities.canDelete { throw ResourceError.unsupported("Deleting on \(p.displayName)") }
        try await hooks.guardedAsync(kind: .delete, items: ids.map { OperationItem(sourceResource: $0, destinationResource: nil) }, origin: origin) {
            for (id, p) in zip(ids, providers) {
                try Task.checkCancellation()
                try await p.delete(id, recursive: true)
            }
            return GuardedResult(value: (), urls: ids.map { _ in nil })
        }
    }

    public static func trash(_ ids: [ResourceID], registry: ResourceProviderRegistry = .shared, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        try await trash(ids, providers: try ids.map { try provider(for: $0, in: registry) }, hooks: hooks, origin: origin)
    }

    public static func trash(_ ids: [ResourceID], provider: ResourceProvider, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws {
        try await trash(ids, providers: ids.map { _ in provider }, hooks: hooks, origin: origin)
    }

    static func trash(_ ids: [ResourceID], providers: [ResourceProvider], hooks: FileOperationHookRegistry, origin: OperationOrigin) async throws {
        guard !ids.isEmpty else { return }
        for p in providers where !p.capabilities.canTrash {
            throw ResourceError.unsupported(trashUnavailableReason(provider: p) ?? "Moving to the Trash")
        }
        try await hooks.guardedAsync(kind: .trash, items: ids.map { OperationItem(sourceResource: $0, destinationResource: nil) }, origin: origin) {
            for (id, p) in zip(ids, providers) { try await p.trash(id) }
            return GuardedResult(value: (), urls: ids.map { _ in nil })
        }
    }

    @discardableResult
    public static func makeDirectory(in dir: ResourceID, name: String = "untitled folder", registry: ResourceProviderRegistry = .shared, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> ResourceID {
        try await makeDirectory(in: dir, name: name, provider: try provider(for: dir, in: registry), hooks: hooks, origin: origin)
    }

    @discardableResult
    public static func makeDirectory(in dir: ResourceID, name: String = "untitled folder", provider p: ResourceProvider, hooks: FileOperationHookRegistry = .shared, origin: OperationOrigin = .user) async throws -> ResourceID {
        try validName(name)
        guard p.capabilities.contains(.makeDirectory) else { throw ResourceError.unsupported("Creating folders on \(p.displayName)") }
        let names = Set(try await p.listAll(dir).map(\.name))
        var candidate = name
        var n = 2
        while names.contains(candidate) { candidate = "\(name) \(n)"; n += 1 }
        let target = dir.appending(candidate)
        return try await hooks.guardedAsync(kind: .newFolder, items: [OperationItem(sourceResource: nil, destinationResource: target)], origin: origin) {
            _ = try await p.makeDirectory(target)
            return GuardedResult(value: target, urls: [target.uri])
        }
    }
}
