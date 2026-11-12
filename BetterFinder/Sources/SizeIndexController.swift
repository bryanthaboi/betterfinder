import FSCore
import Foundation
import Settings

@MainActor
final class SizeIndexController: SizeIndexControlling {
    static let shared = SizeIndexController()
    private var control: any SizeIndexControl = SizeIndexClient()
    private var embedded: SizeIndexDaemon?
    private(set) var isIndexingPaused = UserDefaults.standard.bool(forKey: "sizeIndexPaused")
    private(set) var availability: SizeIndexAvailability = .available
    private(set) var indexStatus: SizeIndexStatus?
    private var registrationError: String?

    static var usesAgent: Bool {
        !DemoEnvironment.isEnabled && (Bundle.main.bundlePath.hasPrefix("/Applications/") || ProcessInfo.processInfo.environment["BF_REGISTER_INDEXER"] == "1")
    }

    func start() {
        let paused = isIndexingPaused
        guard Self.usesAgent else {
            do {
                let database = SizeIndexLocation.embeddedDatabase
                let daemon = try SizeIndexDaemon(databaseURL: database)
                embedded = daemon
                control = daemon
                SizeEngine.shared.attach(databaseURL: database, control: daemon)
                daemon.start(roots: [DemoEnvironment.home])
                if paused { Task { _ = await daemon.pause() } }
            } catch {
                availability = .unreachable("The file index couldn’t be opened: \(error.localizedDescription)")
            }
            return
        }
        do {
            try SizeIndexService.register()
        } catch {
            registrationError = error.localizedDescription
        }
        let client = SizeIndexClient()
        control = client
        let expected = SizeIndexService.buildIdentity(
            ofExecutable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BetterFinderIndexer"),
            bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
        Task.detached {
            _ = await client.ensureCurrent(expected: expected)
            if paused { _ = await client.pause() }
        }
    }

    func refreshAvailability() async -> SizeIndexAvailability {
        if Self.usesAgent {
            switch SizeIndexService.status {
            case .enabled:
                break
            case .requiresApproval:
                indexStatus = nil
                availability = .requiresApproval
                return availability
            default:
                indexStatus = nil
                availability = .unreachable(registrationError.map { "The file indexer couldn’t be registered: \($0)" } ?? "The file indexer isn’t registered, so folder sizes and search results aren’t updating.")
                return availability
            }
        } else if embedded == nil {
            return availability
        }
        indexStatus = SizeIndexStatus(await control.status())
        availability = indexStatus == nil
            ? .unreachable("The file indexer isn’t responding, so folder sizes and search results aren’t updating.")
            : .available
        return availability
    }

    func requestPause(_ paused: Bool) async -> Bool {
        let ok = paused ? await control.pause() : await control.resume()
        if ok {
            isIndexingPaused = paused
            UserDefaults.standard.set(paused, forKey: "sizeIndexPaused")
        }
        return ok
    }

    func requestRebuild() async -> Bool {
        await control.rebuild()
    }

    func setIndexingPaused(_ paused: Bool) {
        Task { _ = await requestPause(paused) }
    }

    func rebuildIndex() {
        Task { _ = await requestRebuild() }
    }
}
