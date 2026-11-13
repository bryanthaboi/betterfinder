import AppBridge
import AppKit
import Browser
import Combine
import FileOps
import Settings
import Integration
import Theming
import Updates

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var openedViaURLs = false
    private lazy var workGate = ActiveWorkGate(
        activeCount: {
            FileOperationQueue.shared.activeOperationCount
                + FileOperationQueue.shared.backgroundMutationCount
                + RemoteMutationTracker.shared.activeCount
        },
        cancelAll: {
            FileOperationQueue.shared.cancelAll()
            RemoteMutationTracker.shared.cancelAll()
        },
        counts: FileOperationQueue.shared.$activeOperationCount
            .combineLatest(FileOperationQueue.shared.$backgroundMutationCount, RemoteMutationTracker.shared.$activeCount)
            .map { $0 + $1 + $2 }
            .eraseToAnyPublisher()
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        SettingsDefaults.register()
        FileOperationQueue.shared.conflictResolver = AlertConflictResolver()
        FileOperationHookRegistry.shared.decisionPresenter = AlertHookDecisionPresenter()
        FileOperationQueue.shared.onOperationFinished = { op in OperationFailureNotifier.shared.operationFinished(op) }
        GlobalHotKey.shared.onTrigger = {
            BrowserWindowManager.shared.openWindow(at: .folder(NewWindowLocation.resolve()))
            NSApp.activate(ignoringOtherApps: true)
        }
        GlobalHotKey.shared.restoreFromDefaults()
        VisorController.shared.initialLocation = { .folder(NewWindowLocation.resolve()) }
        VisorController.shared.install()
        NSApp.mainMenu = MainMenu.build()
        _ = ThemeManager.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SizeIndexController.shared.start()
        UserDefaults.standard.register(defaults: UpdatesDefaults.registered)
        UpdateController.shared.configure(tokenProvider: { GitHubTokenKeychain.read() })
        UpdateController.shared.installGate = { [workGate] in
            let ok = await workGate.confirm(.update)
            if !ok, FileOperationQueue.shared.activeOperationCount > 0 { OperationsWindowController.shared.show() }
            return ok
        }
        UpdateController.shared.startAutomaticChecks()
        CrashReporter.shared.checkOnLaunch()
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--bf-selftest-mods"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            let out = args.firstIndex(of: "--bf-selftest-out").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            ModSelfTest.runAndExit(examples: URL(fileURLWithPath: args[i + 1], isDirectory: true), output: out, keepInstalled: args.contains("--bf-selftest-keep"))
            return
        }
        #endif
        DispatchQueue.main.async { [self] in
            let openFirst = { [self] in
                if !openedViaURLs && BrowserWindowManager.shared.isEmpty && !VisorController.shared.opensNewWindows {
                    BrowserWindowManager.shared.openWindow(at: .folder(NewWindowLocation.resolve()))
                }
            }
            if !OnboardingWindowController.showIfNeeded(onFinish: openFirst) { openFirst() }
            DispatchQueue.main.async { ModsController.shared.start() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch workGate.terminationDecision() {
        case .proceed:
            break
        case .cancel:
            return .terminateCancel
        case .quitWhenIdle:
            workGate.quitWhenIdle { NSApp.terminate(nil) }
            OperationsWindowController.shared.show()
            return .terminateCancel
        case .cancelWorkThenProceed:
            OperationsWindowController.shared.show()
            Task { @MainActor [workGate] in
                _ = await workGate.waitForCancellation()
                self.shutdownMods { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        ModsMCP.shared.stop()
        guard ModsController.shared.runtime != nil else { return .terminateNow }
        shutdownMods { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func shutdownMods(then reply: @escaping @MainActor () -> Void) {
        ModsMCP.shared.stop()
        guard ModsController.shared.runtime != nil else { reply(); return }
        var replied = false
        let once = {
            guard !replied else { return }
            replied = true
            reply()
        }
        Task { @MainActor in
            await ModsController.shared.shutdown()
            once()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { once() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedViaURLs = true
        BrowserWindowManager.shared.handle(urls: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { BrowserWindowManager.shared.openWindow(at: .folder(NewWindowLocation.resolve())) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        BrowserWindowManager.shared.openWindow(at: .folder(NewWindowLocation.resolve()))
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateController.shared.checkForUpdates(userInitiated: true)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.sizeIndexController = SizeIndexController.shared
        ModsController.shared.attachSettings()
        SettingsWindowController.shared.show()
    }

    @objc func manageMods(_ sender: Any?) {
        SettingsWindowController.shared.sizeIndexController = SizeIndexController.shared
        ModsController.shared.manage()
    }

    @objc func installModFromFile(_ sender: Any?) { ModsController.shared.installFromFile() }
    @objc func loadUnpackedMod(_ sender: Any?) { ModsController.shared.loadUnpacked() }
    @objc func reloadMods(_ sender: Any?) { ModsController.shared.reload() }
    @objc func toggleModSafeMode(_ sender: Any?) { ModsController.shared.toggleSafeMode() }
    @objc func showModLogs(_ sender: Any?) { ModsController.shared.showLogs() }
    @objc func toggleMCPServer(_ sender: Any?) { ModsMCP.shared.toggle() }
    @objc func copyMCPConfig(_ sender: Any?) { ModsMCP.shared.copyConfig() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleModSafeMode(_:)) {
            menuItem.state = ModsController.shared.isSafeMode ? .on : .off
        }
        if menuItem.action == #selector(toggleMCPServer(_:)) {
            menuItem.title = ModsMCP.shared.isRunning ? "Stop MCP Server" : "Start MCP Server"
        }
        if menuItem.action == #selector(toggleVisor(_:)) {
            menuItem.title = VisorController.shared.isShown ? "Hide Visor" : "Show Visor"
        }
        if menuItem.action == #selector(toggleVisorPin(_:)) {
            menuItem.state = VisorController.shared.isPinned ? .on : .off
        }
        return true
    }

    @objc func toggleVisor(_ sender: Any?) {
        if VisorController.shared.isShown { VisorController.shared.hide(returnFocus: true) } else { VisorController.shared.show() }
    }

    @objc func toggleVisorPin(_ sender: Any?) {
        VisorController.shared.togglePinned()
    }

    @objc func showOnboarding(_ sender: Any?) {
        OnboardingWindowController.shared.show()
    }

    @objc func showOperations(_ sender: Any?) {
        OperationsWindowController.shared.showWindow(sender)
    }

    @objc func showRecentlyTrashed(_ sender: Any?) {
        RecentlyTrashedWindowController.shared.show()
    }

    @objc func showSpaceHog(_ sender: Any?) {
        SpaceHogWindowController.shared.showForActiveWindow()
    }

    @objc func showJunkCleanup(_ sender: Any?) {
        JunkCleanupWindowController.shared.show()
    }

    @objc func emptyTrash(_ sender: Any?) {
        Task { _ = await TrashUI.confirmAndEmptyTrash() }
    }
}
