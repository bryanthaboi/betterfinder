import AppKit
import FileOps
import FSCore
import Foundation
import Remote

public final class AlertHostKeyApprover: HostKeyApproving, @unchecked Sendable {
    public init() {}

    public func approve(_ request: HostKeyApprovalRequest) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Do you trust “\(request.displayHost)”?"
            let prints = request.keys.map { "\($0.displayType)  \($0.fingerprint)" }.joined(separator: "\n")
            alert.informativeText = "betterfinder hasn’t connected to this server before, so it can’t confirm the server is who it claims to be. Compare these fingerprints with the ones your server administrator gave you before continuing.\n\n\(prints)"
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

@MainActor
public final class RemoteIntegration {
    public static let owner = "betterfinder.remote"
    public static var shared: RemoteIntegration = RemoteIntegration(manager: RemoteConnectionManager(hostKeyApprover: AlertHostKeyApprover()))

    public let manager: RemoteConnectionManager
    public let transfer: CrossProviderTransfer
    private var transferToken: FileOpsRegistrationToken?
    private var locationTokens: [UUID: BrowserRegistrationToken] = [:]
    private var installedRegistries: [ObjectIdentifier: BrowserRegistries] = [:]
    private var observer: NSObjectProtocol?

    public init(manager: RemoteConnectionManager, transferRegistry: ResourceTransferProviderRegistry = .shared) {
        self.manager = manager
        self.transfer = CrossProviderTransfer(registry: manager.registry)
        if !transferRegistry.contains(id: transfer.id) {
            transferToken = transferRegistry.register(transfer, owner: Self.owner)
        }
        observer = NotificationCenter.default.addObserver(forName: .remoteServersDidChange, object: manager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private static var didAutoInstall = false

    public static func installIfNeeded(into registries: BrowserRegistries) {
        guard !didAutoInstall else { return }
        didAutoInstall = true
        RemoteStaging.purge()
        shared.install(into: registries)
    }

    public func install(into registries: BrowserRegistries) {
        guard installedRegistries[ObjectIdentifier(registries)] == nil else { RemoteMenu.install(); return }
        installedRegistries[ObjectIdentifier(registries)] = registries
        manager.installAll()
        sync()
        RemoteMenu.install()
    }

    public var servers: [RemoteServer] { manager.servers }

    public func isInstalled(in registries: BrowserRegistries) -> Bool {
        installedRegistries[ObjectIdentifier(registries)] != nil
    }

    public func locationProvider(for server: RemoteServer) -> ResourceLocationProvider? {
        guard let p = try? manager.provider(for: server) else { return nil }
        return ResourceLocationProvider(p, rootTitle: server.name, symbolName: server.symbolName)
    }

    public func rootLocation(for server: RemoteServer) -> ProvidedLocation? {
        locationProvider(for: server)?.rootLocation
    }

    public func server(for location: ProvidedLocation) -> RemoteServer? {
        manager.server(providerID: location.providerID)
    }

    private func sync() {
        for t in locationTokens.values { t.cancel() }
        locationTokens = [:]
        for registries in installedRegistries.values {
            for server in manager.servers {
                guard let lp = locationProvider(for: server) else { continue }
                let spec = LocationProviderSpec(id: server.providerID, title: server.name, symbolName: server.symbolName, provider: lp, root: lp.rootLocation)
                let token = registries.locations.register(spec, owner: Self.owner)
                let previous = locationTokens[server.id]
                locationTokens[server.id] = previous.map { BrowserRegistrationToken.combined([$0, token]) } ?? token
            }
        }
        NotificationCenter.default.post(name: .remoteLocationsDidChange, object: self)
    }

    public func add(_ server: RemoteServer, secret: Data?) async throws -> ProvidedLocation {
        let saved = try await manager.add(server, secret: secret)
        sync()
        guard let loc = rootLocation(for: saved) else { throw ResourceError.providerUnavailable(saved.name) }
        return loc
    }

    public func remove(_ server: RemoteServer) {
        locationTokens.removeValue(forKey: server.id)?.cancel()
        try? manager.remove(server)
        sync()
    }

    public func disconnect(_ server: RemoteServer) {
        manager.disconnect(server)
        sync()
    }

    public func isDisconnected(providerID: String) -> Bool {
        manager.server(providerID: providerID).map(manager.isDisconnected) ?? false
    }

    public func reconnect(providerID: String) {
        guard let server = manager.server(providerID: providerID) else { return }
        manager.clearDisconnected(server)
    }
}

public extension Notification.Name {
    static let remoteLocationsDidChange = Notification.Name("RemoteLocationsDidChange")
    static let remoteResourcesDidChange = Notification.Name("RemoteResourcesDidChange")
}

@MainActor
enum RemoteMenu {
    static let title = "Connect to Server…"

    static func install() {
        guard let main = NSApp?.mainMenu else { return }
        if main.items.contains(where: { $0.submenu?.items.contains { $0.action == #selector(BrowserWindowController.connectToServer(_:)) } ?? false }) { return }
        let go = main.items.first { $0.submenu?.title == "Go" }?.submenu
        let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.connectToServer(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.command]
        if let go {
            go.addItem(.separator())
            go.addItem(item)
        }
    }
}
