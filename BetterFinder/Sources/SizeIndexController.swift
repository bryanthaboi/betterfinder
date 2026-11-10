import FSCore
import Foundation
import Settings

@MainActor
final class SizeIndexController: SizeIndexControlling {
    static let shared = SizeIndexController()
    private let client = SizeIndexClient()
    private(set) var isIndexingPaused = UserDefaults.standard.bool(forKey: "sizeIndexPaused")
    private(set) var availability: SizeIndexAvailability = .available
    private var registrationError: String?

    static var shouldRegister: Bool {
        !DemoEnvironment.isEnabled && (Bundle.main.bundlePath.hasPrefix("/Applications/") || ProcessInfo.processInfo.environment["BF_REGISTER_INDEXER"] == "1")
    }

    static let notInstalledReason = "This copy of betterfinder doesn’t run the background size indexer, so folder sizes are calculated inside the app. Pausing and rebuilding only apply to the indexer."

    func start() {
        guard Self.shouldRegister else {
            availability = .notInstalled(Self.notInstalledReason)
            return
        }
        do {
            try SizeIndexService.register()
        } catch {
            registrationError = error.localizedDescription
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paused = isIndexingPaused
        let client = client
        let expected = SizeIndexService.buildIdentity(
            ofExecutable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BetterFinderIndexer"),
            bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
        Task.detached {
            _ = await client.ensureCurrent(expected: expected)
            _ = await client.addRoot(path: home)
            if paused { _ = await client.pause() }
        }
    }

    func refreshAvailability() async -> SizeIndexAvailability {
        guard Self.shouldRegister else {
            availability = .notInstalled(Self.notInstalledReason)
            return availability
        }
        switch SizeIndexService.status {
        case .requiresApproval:
            availability = .requiresApproval
        case .enabled:
            let reply = await client.status()
            availability = reply == "unavailable"
                ? .unreachable("The size indexer isn’t responding, so folder sizes are calculated inside betterfinder for now.")
                : .available
        default:
            availability = .unreachable(registrationError.map { "The size indexer couldn’t be registered: \($0)" } ?? "The size indexer isn’t registered, so folder sizes are calculated inside betterfinder.")
        }
        return availability
    }

    func requestPause(_ paused: Bool) async -> Bool {
        let ok = paused ? await client.pause() : await client.resume()
        if ok {
            isIndexingPaused = paused
            UserDefaults.standard.set(paused, forKey: "sizeIndexPaused")
        }
        return ok
    }

    func requestRebuild() async -> Bool {
        await client.rebuild()
    }

    func setIndexingPaused(_ paused: Bool) {
        Task { _ = await requestPause(paused) }
    }

    func rebuildIndex() {
        Task { _ = await requestRebuild() }
    }
}
