import Foundation
import ServiceManagement

public enum LoginItem {
    public enum State: Sendable {
        case enabled
        case requiresApproval
        case disabled
        case notFound
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .notFound
        @unknown default: return .disabled
        }
    }

    public static var isEnabled: Bool { state == .enabled }

    public static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw IntegrationError.loginItemFailed(error.localizedDescription)
        }
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
