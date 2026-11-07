import Combine
import SwiftUI

public struct SettingsPaneToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum SettingsPaneID {
    public static let general = "general"
    public static let defaultFileManager = "defaultFileManager"
    public static let appearance = "appearance"
    public static let permissions = "permissions"
    public static let advanced = "advanced"
    public static let mods = "mods"

    public static let reserved: Set<String> = [general, defaultFileManager, appearance, permissions, advanced, mods]
}

public enum SettingsPaneRegistryError: LocalizedError, Equatable {
    case emptyID
    case reservedID(String)
    case duplicateID(String)

    public var errorDescription: String? {
        switch self {
        case .emptyID: return "A settings pane needs an id."
        case .reservedID(let id): return "\"\(id)\" is a built-in settings pane."
        case .duplicateID(let id): return "A settings pane with id \"\(id)\" is already registered."
        }
    }
}

public struct SettingsPaneDescriptor: Identifiable {
    public let id: String
    public var title: String
    public var symbolName: String
    public var width: CGFloat
    public var minHeight: CGFloat
    public var makeView: @MainActor () -> AnyView

    public init<Content: View>(
        id: String,
        title: String,
        symbolName: String = "puzzlepiece.extension",
        width: CGFloat = 600,
        minHeight: CGFloat = 420,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.width = width
        self.minHeight = minHeight
        self.makeView = { AnyView(content()) }
    }

    @MainActor
    public static func modSettings(modID: String, title: String, store: ModSettingsStore, symbolName: String = "slider.horizontal.3") -> SettingsPaneDescriptor {
        SettingsPaneDescriptor(id: "mod.\(modID)", title: title, symbolName: symbolName) {
            ModSettingsFormView(model: ModSettingsFormModel(store: store))
        }
    }
}

public struct RegisteredSettingsPane: Identifiable {
    public let token: SettingsPaneToken
    public let owner: String
    public let descriptor: SettingsPaneDescriptor
    public var id: String { descriptor.id }
}

@MainActor
public final class SettingsPaneRegistry: ObservableObject {
    public static let shared = SettingsPaneRegistry()

    @Published public private(set) var panes: [RegisteredSettingsPane] = []

    public init() {}

    @discardableResult
    public func register(_ descriptor: SettingsPaneDescriptor, owner: String) throws -> SettingsPaneToken {
        guard !descriptor.id.isEmpty else { throw SettingsPaneRegistryError.emptyID }
        guard !SettingsPaneID.reserved.contains(descriptor.id) else { throw SettingsPaneRegistryError.reservedID(descriptor.id) }
        guard !panes.contains(where: { $0.id == descriptor.id }) else { throw SettingsPaneRegistryError.duplicateID(descriptor.id) }
        let token = SettingsPaneToken()
        panes.append(RegisteredSettingsPane(token: token, owner: owner, descriptor: descriptor))
        return token
    }

    @discardableResult
    public func remove(_ token: SettingsPaneToken) -> Bool {
        guard panes.contains(where: { $0.token == token }) else { return false }
        panes.removeAll { $0.token == token }
        return true
    }

    @discardableResult
    public func removeAll(owner: String) -> Int {
        let before = panes.count
        panes.removeAll { $0.owner == owner }
        return before - panes.count
    }

    public func pane(withID id: String) -> RegisteredSettingsPane? {
        panes.first { $0.id == id }
    }
}
