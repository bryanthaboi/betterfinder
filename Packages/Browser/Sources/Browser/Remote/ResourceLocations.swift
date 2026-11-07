import AppKit
import FSCore
import Foundation

public extension ProvidedLocation {
    static func resource(_ id: ResourceID, title: String? = nil, symbolName: String? = nil) -> ProvidedLocation {
        ProvidedLocation(providerID: id.providerID, id: id.path, title: title ?? (id.isRoot ? "/" : id.name), symbolName: symbolName)
    }

    var resourceID: ResourceID? {
        guard kind == .container, id.hasPrefix("/") else { return nil }
        return ResourceID(providerID: providerID, path: id)
    }
}

public final class ResourceLocationProvider: LocationProvider, @unchecked Sendable {
    public let resourceProvider: ResourceProvider
    public let symbolName: String?
    public let rootTitle: String

    public init(_ provider: ResourceProvider, rootTitle: String? = nil, symbolName: String? = nil) {
        self.resourceProvider = provider
        self.rootTitle = rootTitle ?? provider.displayName
        self.symbolName = symbolName
    }

    public var providerID: String { resourceProvider.providerID }

    public var capabilities: LocationCapabilities {
        let c = resourceProvider.capabilities
        var out: LocationCapabilities = [.list]
        if c.contains(.read) { out.insert(.read) }
        if c.canWrite { out.insert(.write) }
        if c.canTrash { out.insert(.trash) }
        if c.canUndo { out.insert(.undo) }
        if c.canWatch { out.insert(.watch) }
        return out
    }

    public func title(for id: ResourceID) -> String {
        id == resourceProvider.root ? rootTitle : (id.isRoot ? "/" : id.name)
    }

    public func location(for id: ResourceID) -> ProvidedLocation {
        .resource(id, title: title(for: id), symbolName: id == resourceProvider.root ? symbolName : "folder")
    }

    public var rootLocation: ProvidedLocation { location(for: resourceProvider.root) }

    public func list(_ location: ProvidedLocation, context: LocationContext) async throws -> [ProvidedItem] {
        guard let id = location.resourceID else { return [] }
        return try await resourceProvider.listAll(id, options: ResourceListOptions(showHidden: BrowserDefaults.showHidden)).map { item in
            ProvidedItem(id: item.id.path, name: item.name, isContainer: item.isDirectory, symbolName: item.isDirectory ? "folder" : nil,
                         detail: item.kindDescription, size: item.size, modified: item.modified,
                         child: item.isDirectory ? self.location(for: item.id) : nil)
        }
    }

    public func parent(of location: ProvidedLocation) -> ProvidedLocation? {
        guard let id = location.resourceID, let parent = resourceProvider.parent(of: id) else { return nil }
        return self.location(for: parent)
    }
}
