import AppBridge
import AppKit
import Foundation
import os
import Settings

@MainActor
final class ModsController {
    static let shared = ModsController()
    private let log = Logger(subsystem: "com.bryanthaboi.betterfinder", category: "mods")
    private(set) var runtime: AppModRuntime?
    private var starting: Task<Void, Never>?

    func start() {
        guard runtime == nil, starting == nil else { return }
        starting = Task { @MainActor in
            let t0 = Date()
            do {
                let r = try AppModRuntime()
                runtime = r
                r.onControllerChanged = { [weak self] _ in self?.attachSettingsIfLoaded() }
                await r.start()
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                log.info("mods started in \(ms, privacy: .public) ms (controller \(Int((r.startDuration ?? 0) * 1000), privacy: .public) ms)")
                attachSettingsIfLoaded()
                ExtraSettingsPanes.shared.install()
            } catch {
                log.error("mods unavailable: \(error.localizedDescription, privacy: .public)")
            }
            starting = nil
        }
    }

    func shutdown() async {
        await starting?.value
        await runtime?.shutdown()
    }

    private var settingsLoaded = false

    func attachSettings() {
        settingsLoaded = true
        attachSettingsIfLoaded()
    }

    private func attachSettingsIfLoaded() {
        guard settingsLoaded, let runtime else { return }
        let m = runtime.management
        if (SettingsWindowController.shared.modManagementController as AnyObject?) !== m {
            SettingsWindowController.shared.modManagementController = m
        }
    }

    private func withRuntime(_ body: @escaping @MainActor (AppModRuntime) async -> Void) {
        Task { @MainActor in
            await starting?.value
            guard let runtime else {
                let alert = NSAlert()
                alert.messageText = "Mods aren't available"
                alert.informativeText = "The mod runtime couldn't start. See Console for details."
                alert.runModal()
                return
            }
            await body(runtime)
        }
    }

    func manage() {
        withRuntime { [weak self] _ in
            self?.attachSettings()
            SettingsWindowController.shared.show(paneID: SettingsPaneID.mods)
        }
    }

    func installFromFile() { withRuntime { await $0.installFromFile() } }
    func loadUnpacked() { withRuntime { await $0.loadUnpackedMod() } }
    func reload() { withRuntime { await $0.reloadAll() } }
    func toggleSafeMode() { withRuntime { await $0.toggleSafeMode() } }
    func showLogs() { withRuntime { $0.showLogs() } }

    var isSafeMode: Bool { runtime?.isSafeMode ?? false }
}
