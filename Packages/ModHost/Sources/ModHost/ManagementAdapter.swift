import Foundation
import ModKit
import Settings

public final class ModHostManagementController: ModManagementControlling, @unchecked Sendable {
    public let runtime: ModHostController
    public let index: ModIndexProviding?
    public let fetcher: ModPackageFetching?
    private let lock = NSLock()
    private var snapshot: ModIndexSnapshot?
    private var refusals: [String: PreflightResultSummary] = [:]

    public init(runtime: ModHostController, index: ModIndexProviding? = nil, fetcher: ModPackageFetching? = nil) {
        self.runtime = runtime
        self.index = index
        self.fetcher = fetcher
    }

    public static func summary(_ p: ModPermission) -> PermissionSummary {
        let risk: PermissionSummary.Risk
        switch p.kind {
        case .processExec: risk = p.mode == .unrestricted ? .high : .medium
        case .operationsIntercept, .uiOverride: risk = .high
        case .fsWrite, .net, .credentials, .operationsObserve: risk = .medium
        case .fsRead: risk = p.scope == .root && p.recursive == true ? .medium : .low
        case .ui, .uiSelection, .storage: risk = .low
        }
        var title = p.kind.summary
        switch p.kind {
        case .fsRead, .fsWrite: title = "\(p.kind == .fsRead ? "Read" : "Write") files (\(p.scope?.rawValue ?? "")\(p.rootId.map { ": \($0)" } ?? "")\(p.recursive == true ? ", recursive" : ""))"
        case .net: title = "Network: " + (p.endpoints ?? []).map { "\($0.scheme.rawValue)://\($0.host)" }.joined(separator: ", ")
        case .ui: title = "UI: " + (p.surfaces ?? []).map(\.rawValue).joined(separator: ", ")
        case .processExec: title = p.mode == .unrestricted ? "Run any program with your account's full access" : "Run built-in tools: " + (p.operations ?? []).joined(separator: ", ")
        case .operationsIntercept: title = "Block file operations: " + (p.operations ?? []).joined(separator: ", ")
        case .operationsObserve: title = "Observe file operations: " + (p.operations ?? []).joined(separator: ", ")
        default: break
        }
        return PermissionSummary(id: ModPermissionID.make(p), title: title, reason: p.reason ?? p.kind.summary, risk: risk)
    }

    public static func summary(_ r: PreflightReceipt, modID: String, version: String, ranAt: Date?) -> PreflightResultSummary {
        let checks = ModKit.PreflightCheck.allCases.map { c -> Settings.PreflightCheck in
            let state: Settings.PreflightCheck.State
            switch r[c] {
            case .pass: state = .pass
            case .fail: state = .fail
            case .notRun: state = .notRun
            }
            return Settings.PreflightCheck(name: c.rawValue, state: state)
        }
        let diags = r.diagnostics.map { d -> PreflightDiagnostic in
            let sev: PreflightDiagnostic.Severity = d.severity == .error ? .error : d.severity == .warning ? .warning : .info
            return PreflightDiagnostic(severity: sev, code: d.code.rawValue, message: d.message, file: d.file, pointer: d.pointer, fix: d.fix)
        }
        return PreflightResultSummary(modID: modID, version: version, ranAt: ranAt, ok: r.ok, checks: checks, diagnostics: diags)
    }

    func installed(_ s: ModStatus) -> Settings.InstalledMod {
        lock.lock()
        let listing = snapshot?.listings.first { $0.id == s.id }
        lock.unlock()
        var update: ModListing?
        if let listing, let a = SemVer.parse(listing.version), let b = SemVer.parse(s.version), a > b { update = listing }
        let approved = s.permissions.filter { s.approvedPermissionIDs.contains(ModPermissionID.make($0)) }.map(Self.summary)
        return Settings.InstalledMod(
            id: s.id, title: s.name, author: s.author, version: s.version, isEnabled: s.enabled && s.active, permissions: approved,
            lastPreflight: Self.summary(s.receipt, modID: s.id, version: s.version, ranAt: nil), folderURL: s.snapshot,
            availableUpdate: update, isLocalDevelopment: s.developer
        )
    }

    public func listInstalled() async throws -> [Settings.InstalledMod] { runtime.status().map(installed) }

    public func fetchIndex() async throws -> ModIndexSnapshot {
        guard let index else { throw ModManagementError.indexUnavailable("no index is configured") }
        let s = try await index.fetch()
        lock.withLock { snapshot = s }
        return s
    }

    public func preflight(id: String) async throws -> PreflightResultSummary {
        guard let st = runtime.status(id: id) else { throw ModManagementError.notFound(id) }
        let r = try await runtime.preflight(id: id)
        return Self.summary(r, modID: id, version: st.version, ranAt: Date())
    }

    public func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> Settings.InstalledMod {
        if runtime.status(id: listing.id) != nil { throw ModManagementError.alreadyInstalled(listing.id) }
        return try await installListing(listing, approvedPermissionIDs: approvedPermissionIDs)
    }

    public func preflightRefusal(for listingID: String) -> PreflightResultSummary? {
        lock.withLock { refusals[listingID] }
    }

    private func installListing(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> Settings.InstalledMod {
        lock.withLock { refusals[listing.id] = nil }
        let canInstall = lock.withLock { snapshot?.canInstall ?? true }
        guard canInstall else { throw ModManagementError.installRefused("The mod index has expired; refresh it before installing.") }
        guard let fetcher else { throw ModManagementError.installRefused("Installing from the index is unavailable.") }
        guard let verified = fetcher as? ModVerifiedPackageFetching else {
            throw ModManagementError.installRefused("\(listing.title) can't be installed: the index source doesn't provide signed releases.")
        }
        let release = try await verified.fetchRelease(for: listing)
        let report: ModPreflightReport
        do { report = try await runtime.installRelease(release) } catch let e as ModRuntimeError {
            throw ModManagementError.installRefused(e.localizedDescription)
        }
        guard report.installed, let manifest = report.manifest else {
            let errors = report.receipt.diagnostics.filter { $0.severity == .error }
            let summary = Self.summary(report.receipt, modID: listing.id, version: listing.version, ranAt: Date())
            lock.withLock { refusals[listing.id] = summary }
            throw ModManagementError.installRefused("\(listing.title) failed preflight: " + (errors.first?.message ?? "incomplete checks"))
        }
        guard manifest.id == listing.id else {
            try? await runtime.uninstall(id: manifest.id, deleteData: false)
            throw ModManagementError.installRefused("The downloaded package is \(manifest.id), not \(listing.id).")
        }
        let declared = Set(manifest.permissions.map(ModPermissionID.make))
        try await runtime.approve(id: manifest.id, permissionIDs: approvedPermissionIDs.intersection(declared))
        guard let st = runtime.status(id: manifest.id) else { throw ModManagementError.notFound(manifest.id) }
        return installed(st)
    }

    public func enable(id: String) async throws -> Settings.InstalledMod {
        guard runtime.status(id: id) != nil else { throw ModManagementError.notFound(id) }
        do { try await runtime.enable(id: id) } catch { throw ModManagementError.enableBlocked(error.localizedDescription) }
        return installed(runtime.status(id: id)!)
    }

    public func disable(id: String) async throws -> Settings.InstalledMod {
        guard runtime.status(id: id) != nil else { throw ModManagementError.notFound(id) }
        try await runtime.disable(id: id)
        return installed(runtime.status(id: id)!)
    }

    public func uninstall(id: String, deleteData: Bool) async throws {
        guard runtime.status(id: id) != nil else { throw ModManagementError.notFound(id) }
        try await runtime.uninstall(id: id, deleteData: deleteData)
    }

    public func update(id: String, approvedPermissionIDs: Set<String>) async throws -> Settings.InstalledMod {
        guard let st = runtime.status(id: id) else { throw ModManagementError.notFound(id) }
        let listing = lock.withLock { snapshot?.listings.first { $0.id == id } }
        guard let listing, listing.version != st.version else { throw ModManagementError.installRefused("No update is available.") }
        let held = st.approvedPermissionIDs
        let needed = Set(listing.permissions.map(\.id)).subtracting(held)
        guard needed.isSubset(of: approvedPermissionIDs) else { throw ModManagementError.installRefused("New permissions must be reviewed before updating.") }
        return try await installListing(listing, approvedPermissionIDs: held.union(approvedPermissionIDs))
    }
}
