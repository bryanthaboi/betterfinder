import AppKit
import Foundation
import Integration

@MainActor
public final class DefaultManagerModel: ObservableObject {
    @Published public private(set) var status: DefaultFileManager.Status
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?
    @Published public var warnings: [String] = []
    @Published public private(set) var tweakStates: [FinderTweaks.Tweak: Bool] = [:]

    private let controller: DefaultFileManagerController
    private let tweaks: FinderTweaks

    public init(controller: DefaultFileManagerController = DefaultFileManager.controller, tweaks: FinderTweaks = FinderTweaks()) {
        self.controller = controller
        self.tweaks = tweaks
        self.status = controller.status()
        refreshTweaks()
    }

    public func refresh() {
        status = controller.status()
        refreshTweaks()
    }

    private func refreshTweaks() {
        var states: [FinderTweaks.Tweak: Bool] = [:]
        for t in FinderTweaks.Tweak.allCases { states[t] = tweaks.isEnabled(t) }
        tweakStates = states
    }

    public func setDefault(_ enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        warnings = []
        Task { [controller] in
            do {
                let report = enabled ? try await controller.makeDefault() : try await controller.restoreFinder()
                warnings = report.warnings
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            refresh()
        }
    }

    public func restoreEverything() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        warnings = []
        Task { [controller, tweaks] in
            do {
                let report = try await controller.restoreFinder()
                warnings = report.warnings
                let anyTweak = FinderTweaks.Tweak.allCases.contains { tweaks.isEnabled($0) || tweaks.hasRecordedPrevious($0) }
                if anyTweak { try await tweaks.revertAll(relaunchFinder: true) }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            refresh()
        }
    }

    public func setTweak(_ tweak: FinderTweaks.Tweak, enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task { [tweaks] in
            do {
                if enabled { try await tweaks.enable(tweak, relaunchFinder: true) } else { try await tweaks.revert(tweak, relaunchFinder: true) }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            refresh()
        }
    }
}

@MainActor
public final class PermissionsModel: ObservableObject {
    @Published public private(set) var statuses: [PermissionStatus] = []
    @Published public private(set) var isRefreshing = false

    private let center: PermissionsCenter

    public init(center: PermissionsCenter = .shared) {
        self.center = center
    }

    public var hasMissingAccess: Bool {
        statuses.contains { $0.state == .denied }
    }

    public func status(for kind: PermissionKind) -> PermissionStatus {
        statuses.first { $0.kind == kind } ?? PermissionStatus(kind: kind, state: .unknown)
    }

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let center = center
        Task {
            let result = await Task.detached { center.allStatuses() }.value
            statuses = result
            isRefreshing = false
        }
    }

    public func grant(_ kind: PermissionKind) {
        let center = center
        switch kind {
        case .automationFinder:
            Task {
                let result = await Task.detached { center.requestAutomation() }.value
                if result.state == .denied { center.openSettings(for: kind) }
                refresh()
            }
        case .fullDiskAccess:
            center.openSettings(for: kind)
        default:
            Task {
                let result = await Task.detached { center.status(for: kind) }.value
                if result.state == .denied { center.openSettings(for: kind) }
                refresh()
            }
        }
    }
}
