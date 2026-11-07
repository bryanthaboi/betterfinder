import AppKit
import Foundation

@MainActor
public final class ModsPaneModel: ObservableObject {
    public enum Section: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case browse = "Browse"
        public var id: String { rawValue }
    }

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Name"
        case recentlyUpdated = "Recently Updated"
        case author = "Author"
        public var id: String { rawValue }
    }

    public struct Operation: Equatable {
        public enum Kind: Equatable {
            case install
            case update(modID: String)
        }

        public var kind: Kind
        public var listing: ModListing
        public var permissionsToReview: [PermissionSummary]
    }

    public enum Phase: Equatable {
        case idle
        case reviewingPermissions(Operation)
        case installing(Operation)
        case preflighting(modID: String)
        case finished(modID: String, result: PreflightResultSummary)
        case failed(message: String, modID: String?)
        case refused(Operation, result: PreflightResultSummary)

        public var isBusy: Bool {
            switch self {
            case .installing, .preflighting: return true
            default: return false
            }
        }

        public var isIdle: Bool { self == .idle }
    }

    public let controller: ModManagementControlling

    @Published public var section: Section = .installed
    @Published public private(set) var installed: [InstalledMod] = []
    @Published public private(set) var listings: [ModListing] = []
    @Published public private(set) var indexSnapshot: ModIndexSnapshot?
    @Published public private(set) var installedState: LoadState = .idle
    @Published public private(set) var indexState: LoadState = .idle
    @Published public var search = ""
    @Published public var categoryFilter: String?
    @Published public var sortOrder: SortOrder = .name
    @Published public var compatibleOnly = true
    @Published public var selectedListingID: String?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var busyModIDs: Set<String> = []
    @Published public var actionError: String?

    public var openFolder: (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public var announce: @MainActor (String) -> Void = { ModsAnnouncer.announce($0) }
    var headingFocusRequested: @MainActor (String) -> Void = { _ in }

    public init(controller: ModManagementControlling) {
        self.controller = controller
    }

    public var categories: [String] {
        Array(Set(listings.flatMap(\.categories))).sorted()
    }

    public var filteredListings: [ModListing] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = listings.filter { l in
            if compatibleOnly && !l.isCompatible { return false }
            if let c = categoryFilter, !l.categories.contains(c) { return false }
            guard !needle.isEmpty else { return true }
            let hay = ([l.title, l.author, l.summary, l.id] + l.tags + l.categories).joined(separator: " ").lowercased()
            return hay.contains(needle)
        }
        switch sortOrder {
        case .name: return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:
            return filtered.sorted {
                let byAuthor = $0.author.localizedCaseInsensitiveCompare($1.author)
                return byAuthor == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : byAuthor == .orderedAscending
            }
        case .recentlyUpdated: return filtered.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
    }

    public var selectedListing: ModListing? {
        listings.first { $0.id == selectedListingID }
    }

    public func installedMod(id: String) -> InstalledMod? {
        installed.first { $0.id == id }
    }

    public func isInstalled(_ listing: ModListing) -> Bool {
        installed.contains { $0.id == listing.id }
    }

    public func installBlockReason(for listing: ModListing) -> String? {
        if isInstalled(listing) { return "Already installed" }
        if !listing.isCompatible { return listing.compatibilityNote ?? "Not compatible with this version" }
        if let snapshot = indexSnapshot, !snapshot.canInstall { return "The index has expired; reconnect to install" }
        if !phase.isIdle { return "Another install is in progress" }
        return nil
    }

    public func updateBlockReason(for mod: InstalledMod) -> String? {
        guard mod.availableUpdate != nil else { return nil }
        if busyModIDs.contains(mod.id) { return "Working…" }
        if indexState == .loading { return "Refreshing the index…" }
        if let snapshot = indexSnapshot, !snapshot.canInstall { return "The index has expired; refresh it to update" }
        if !phase.isIdle { return "Another install is in progress" }
        return nil
    }

    public var isRefreshing: Bool { indexState == .loading || installedState == .loading }

    public var indexRefreshError: String? {
        if case .failed(let message) = indexState, !listings.isEmpty { return message }
        return nil
    }

    public func enableBlockReason(for mod: InstalledMod) -> String? {
        if busyModIDs.contains(mod.id) { return "Working…" }
        guard let result = mod.lastPreflight else { return "Run preflight first" }
        if result.errorCount > 0 { return "Fix \(result.errorCount) preflight error\(result.errorCount == 1 ? "" : "s")" }
        if !result.incompleteChecks.isEmpty { return "Preflight didn't complete" }
        if !result.ok { return "Preflight failed" }
        return nil
    }

    public func canEnable(_ mod: InstalledMod) -> Bool {
        enableBlockReason(for: mod) == nil
    }

    public func reloadInstalled() async {
        installedState = .loading
        do {
            installed = try await controller.listInstalled()
            installedState = .loaded
        } catch {
            installedState = .failed(error.localizedDescription)
        }
    }

    public func reloadIndex() async {
        indexState = .loading
        do {
            let snapshot = try await controller.fetchIndex()
            indexSnapshot = snapshot
            listings = snapshot.listings
            indexState = .loaded
            if let id = selectedListingID, !listings.contains(where: { $0.id == id }) { selectedListingID = nil }
        } catch {
            indexState = .failed(error.localizedDescription)
            return
        }
        if let fresh = try? await controller.listInstalled() {
            installed = fresh
            if installedState != .loaded { installedState = .loaded }
        }
    }

    public func reloadAll() async {
        await reloadInstalled()
        await reloadIndex()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async {
        guard let mod = installedMod(id: id), !busyModIDs.contains(id) else { return }
        if enabled, let reason = enableBlockReason(for: mod) {
            actionError = "\(mod.title) can't be enabled: \(reason)."
            return
        }
        busyModIDs.insert(id)
        defer { busyModIDs.remove(id) }
        do {
            let updated = enabled ? try await controller.enable(id: id) : try await controller.disable(id: id)
            replace(updated)
        } catch {
            actionError = error.localizedDescription
            await reloadInstalled()
        }
    }

    public func runPreflight(_ id: String) async {
        guard !busyModIDs.contains(id) else { return }
        busyModIDs.insert(id)
        defer { busyModIDs.remove(id) }
        do {
            let result = try await controller.preflight(id: id)
            if var mod = installedMod(id: id) {
                mod.lastPreflight = result
                if !result.allowsEnable { mod.isEnabled = false }
                replace(mod)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    public func uninstall(_ id: String, deleteData: Bool) async {
        guard !busyModIDs.contains(id) else { return }
        busyModIDs.insert(id)
        defer { busyModIDs.remove(id) }
        do {
            try await controller.uninstall(id: id, deleteData: deleteData)
            installed.removeAll { $0.id == id }
        } catch {
            actionError = error.localizedDescription
            await reloadInstalled()
        }
    }

    public func showFolder(for mod: InstalledMod) {
        guard let url = mod.folderURL else { return }
        openFolder(url)
    }

    @discardableResult
    public func beginInstall(_ listing: ModListing) -> Bool {
        guard installBlockReason(for: listing) == nil else { return false }
        phase = .reviewingPermissions(Operation(kind: .install, listing: listing, permissionsToReview: listing.permissions))
        return true
    }

    @discardableResult
    public func beginUpdate(_ id: String) -> Bool {
        guard let mod = installedMod(id: id), let listing = mod.availableUpdate else { return false }
        if let reason = updateBlockReason(for: mod) {
            actionError = "\(mod.title) can't be updated: \(reason)."
            return false
        }
        phase = .reviewingPermissions(Operation(kind: .update(modID: id), listing: listing, permissionsToReview: mod.expandedPermissionsInUpdate))
        return true
    }

    public func approveAndRun() async {
        guard case .reviewingPermissions(let op) = phase else { return }
        phase = .installing(op)
        let approved = Set(op.listing.permissions.map(\.id))
        let modID: String
        do {
            switch op.kind {
            case .install:
                let mod = try await controller.install(op.listing, approvedPermissionIDs: approved)
                modID = mod.id
                if installedMod(id: mod.id) == nil { installed.append(mod) } else { replace(mod) }
            case .update(let id):
                let mod = try await controller.update(id: id, approvedPermissionIDs: approved)
                modID = mod.id
                replace(mod)
            }
        } catch {
            if let report = controller.preflightRefusal(for: op.listing.id) {
                phase = .refused(op, result: report)
            } else {
                phase = .failed(message: error.localizedDescription, modID: nil)
            }
            return
        }
        phase = .preflighting(modID: modID)
        do {
            let result = try await controller.preflight(id: modID)
            if var mod = installedMod(id: modID) {
                mod.lastPreflight = result
                if !result.allowsEnable { mod.isEnabled = false }
                replace(mod)
            }
            phase = .finished(modID: modID, result: result)
        } catch {
            phase = .failed(message: error.localizedDescription, modID: modID)
        }
    }

    @discardableResult
    public func cancelFlow() -> Bool {
        switch phase {
        case .reviewingPermissions, .finished, .failed, .refused:
            phase = .idle
            return true
        case .idle:
            return true
        case .installing, .preflighting:
            return false
        }
    }

    public func enableFinishedMod() async {
        guard case .finished(let id, let result) = phase, result.allowsEnable else { return }
        busyModIDs.insert(id)
        defer { busyModIDs.remove(id) }
        do {
            let updated = try await controller.enable(id: id)
            replace(updated)
            phase = .idle
            announce("\(updated.title) enabled")
        } catch {
            phase = .failed(message: error.localizedDescription, modID: id)
        }
    }

    public var finishedModCanBeEnabled: Bool {
        if case .finished(_, let result) = phase { return result.allowsEnable }
        return false
    }

    private func replace(_ mod: InstalledMod) {
        if let i = installed.firstIndex(where: { $0.id == mod.id }) { installed[i] = mod } else { installed.append(mod) }
    }
}
