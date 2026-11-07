import AppKit
import Foundation

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(SemanticVersion)
    case noInfo
    case available(UpdateRelease)
    case downloading(UpdateRelease, Double)
    case verifying(UpdateRelease)
    case installing(UpdateRelease)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var skippedVersion: SemanticVersion?

    @Published public private(set) var isWaitingForInstallGate = false

    public let preferences: UpdatePreferences
    public var terminateHandler: @MainActor () -> Void = { NSApp.terminate(nil) }
    public var installGate: (@MainActor () async -> Bool)?
    var accessibilityEvents = UpdateAccessibilityEvents()
    var makeInstaller: (SemanticVersion?, (@Sendable () -> String?)?) -> UpdateInstalling = { current, token in
        UpdateInstaller(verifier: UpdateVerifier(currentVersion: current), tokenProvider: token)
    }

    private var feedURL: URL
    private var tokenProvider: (@Sendable () -> String?)?
    private var checker: UpdateChecker
    private var windowController: UpdateWindowController?
    private var workTask: Task<Void, Never>?
    private var timer: Timer?

    public init(
        preferences: UpdatePreferences = UpdatePreferences(),
        feedURL: URL = UpdateCheckerConfiguration.defaultFeedURL,
        tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.preferences = preferences
        self.feedURL = feedURL
        self.tokenProvider = tokenProvider
        self.checker = UpdateChecker(
            configuration: UpdateCheckerConfiguration(feedURL: feedURL, tokenProvider: tokenProvider),
            preferences: preferences
        )
        self.lastChecked = preferences.lastChecked
        self.skippedVersion = preferences.skippedVersion
    }

    public func configure(feedURL: URL = UpdateCheckerConfiguration.defaultFeedURL, tokenProvider: (@Sendable () -> String?)? = nil) {
        self.feedURL = feedURL
        self.tokenProvider = tokenProvider
        self.checker = UpdateChecker(
            configuration: UpdateCheckerConfiguration(feedURL: feedURL, tokenProvider: tokenProvider),
            preferences: preferences
        )
    }

    public var canCheckForUpdates: Bool { !state.isBusy }

    public var currentVersionString: String { checker.configuration.currentVersion }

    public var installBlockedReason: String? {
        do {
            try InstallLocation.validate(bundleURL: Bundle.main.bundleURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func startAutomaticChecks(initialDelay: TimeInterval = 5) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task { @MainActor in
            if initialDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000)) }
            self.checkIfDue()
        }
    }

    public func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    public func checkIfDue() {
        guard preferences.isDue(), canCheckForUpdates else { return }
        checkForUpdates(userInitiated: false)
    }

    public func checkForUpdates(userInitiated: Bool) {
        if case .available = state, userInitiated {
            showWindow()
            return
        }
        guard canCheckForUpdates else {
            if userInitiated { showWindow() }
            return
        }
        state = .checking
        if userInitiated { showWindow() }
        workTask = Task { @MainActor in
            do {
                let result = try await checker.check(userInitiated: userInitiated)
                lastChecked = preferences.lastChecked
                switch result {
                case .updateAvailable(let release):
                    state = .available(release)
                    showWindow()
                case .skipped:
                    state = .idle
                case .upToDate(let latest):
                    state = userInitiated ? .upToDate(latest) : .idle
                case .noInfo:
                    state = userInitiated ? .noInfo : .idle
                }
            } catch {
                lastChecked = preferences.lastChecked
                if Task.isCancelled { state = .idle }
                else { state = userInitiated ? .failed(error.localizedDescription) : .idle }
            }
        }
    }

    public func installAndRelaunch() {
        guard case .available(let release) = state else { return }
        state = .downloading(release, 0)
        let installer = makeInstaller(checker.currentVersion, tokenProvider)
        workTask = Task { @MainActor in
            do {
                let prepared = try await installer.prepare(release) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .downloading = self.state { self.state = fraction >= 1 ? .verifying(release) : .downloading(release, fraction) }
                    }
                }
                try Task.checkCancellation()
                if let installGate {
                    state = .verifying(release)
                    isWaitingForInstallGate = true
                    let proceed = await installGate()
                    isWaitingForInstallGate = false
                    guard proceed, !Task.isCancelled else {
                        state = .available(release)
                        return
                    }
                }
                state = .installing(release)
                try installer.install(prepared)
                terminateHandler()
            } catch is CancellationError {
                state = .available(release)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelWork() {
        workTask?.cancel()
    }

    func setStateForTesting(_ newState: UpdateState) {
        state = newState
    }

    var pendingWork: Task<Void, Never>? { workTask }

    public func skipThisVersion() {
        if case .available(let release) = state {
            preferences.skippedVersion = release.version
            skippedVersion = release.version
        }
        state = .idle
        windowController?.close()
    }

    public func clearSkippedVersion() {
        preferences.skippedVersion = nil
        skippedVersion = nil
    }

    public func remindMeLater() {
        if case .available = state { state = .idle }
        windowController?.close()
    }

    public func dismiss() {
        if !state.isBusy { state = .idle }
        windowController?.close()
    }

    public func showWindow() {
        if windowController == nil { windowController = UpdateWindowController(controller: self) }
        windowController?.show()
    }
}
