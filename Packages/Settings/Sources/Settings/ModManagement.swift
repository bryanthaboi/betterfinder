import Foundation

public struct PermissionSummary: Identifiable, Hashable, Sendable {
    public enum Risk: Int, Comparable, Sendable {
        case low, medium, high

        public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }

    public var id: String
    public var title: String
    public var reason: String
    public var risk: Risk

    public init(id: String, title: String, reason: String, risk: Risk = .low) {
        self.id = id
        self.title = title
        self.reason = reason
        self.risk = risk
    }
}

public struct ModVersionInfo: Identifiable, Hashable, Sendable {
    public var version: String
    public var date: Date?
    public var notes: String?
    public var isCompatible: Bool
    public var id: String { version }

    public init(version: String, date: Date? = nil, notes: String? = nil, isCompatible: Bool = true) {
        self.version = version
        self.date = date
        self.notes = notes
        self.isCompatible = isCompatible
    }
}

public struct ModListing: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var version: String
    public var summary: String
    public var categories: [String]
    public var tags: [String]
    public var readme: String
    public var permissions: [PermissionSummary]
    public var versions: [ModVersionInfo]
    public var repoURL: URL?
    public var isCompatible: Bool
    public var compatibilityNote: String?
    public var updatedAt: Date?

    public init(
        id: String,
        title: String,
        author: String,
        version: String,
        summary: String = "",
        categories: [String] = [],
        tags: [String] = [],
        readme: String = "",
        permissions: [PermissionSummary] = [],
        versions: [ModVersionInfo] = [],
        repoURL: URL? = nil,
        isCompatible: Bool = true,
        compatibilityNote: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.version = version
        self.summary = summary
        self.categories = categories
        self.tags = tags
        self.readme = readme
        self.permissions = permissions
        self.versions = versions
        self.repoURL = repoURL
        self.isCompatible = isCompatible
        self.compatibilityNote = compatibilityNote
        self.updatedAt = updatedAt
    }

    public var highestRisk: PermissionSummary.Risk {
        permissions.map(\.risk).max() ?? .low
    }
}

public struct ModIndexSnapshot: Sendable {
    public var listings: [ModListing]
    public var fetchedAt: Date?
    public var isExpired: Bool
    public var isOffline: Bool

    public init(listings: [ModListing], fetchedAt: Date? = nil, isExpired: Bool = false, isOffline: Bool = false) {
        self.listings = listings
        self.fetchedAt = fetchedAt
        self.isExpired = isExpired
        self.isOffline = isOffline
    }

    public var canInstall: Bool { !isExpired }
}

public struct PreflightDiagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Comparable, Sendable {
        case info, warning, error

        public static func < (a: Severity, b: Severity) -> Bool {
            let order: [Severity] = [.info, .warning, .error]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    public var severity: Severity
    public var code: String
    public var message: String
    public var file: String?
    public var pointer: String?
    public var fix: String?
    public var id: String { "\(code)|\(file ?? "")|\(pointer ?? "")|\(message)" }

    public init(severity: Severity, code: String, message: String, file: String? = nil, pointer: String? = nil, fix: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.file = file
        self.pointer = pointer
        self.fix = fix
    }
}

public struct PreflightCheck: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable {
        case pass, fail, skipped, notRun
    }

    public var name: String
    public var state: State
    public var id: String { name }

    public init(name: String, state: State) {
        self.name = name
        self.state = state
    }
}

public struct PreflightResultSummary: Hashable, Sendable {
    public var modID: String
    public var version: String
    public var ranAt: Date?
    public var ok: Bool
    public var checks: [PreflightCheck]
    public var diagnostics: [PreflightDiagnostic]

    public init(modID: String, version: String, ranAt: Date? = nil, ok: Bool, checks: [PreflightCheck] = [], diagnostics: [PreflightDiagnostic] = []) {
        self.modID = modID
        self.version = version
        self.ranAt = ranAt
        self.ok = ok
        self.checks = checks
        self.diagnostics = diagnostics
    }

    public var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    public var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    public var incompleteChecks: [PreflightCheck] { checks.filter { $0.state != .pass } }

    public var allowsEnable: Bool {
        ok && errorCount == 0 && incompleteChecks.isEmpty
    }

    public func reportText(title: String) -> String {
        var lines = ["\(title) \(version) — \(headline)"]
        if !checks.isEmpty {
            lines.append("Checks: " + checks.map { "\($0.name) \($0.state.rawValue)" }.joined(separator: ", "))
        }
        for d in diagnostics.sorted(by: { $0.severity > $1.severity }) {
            var line = "[\(d.severity)] \(d.code) \(d.message)"
            let location = [d.file, d.pointer].compactMap { $0 }.joined(separator: " ")
            if !location.isEmpty { line += " (\(location))" }
            if let fix = d.fix { line += " Fix: \(fix)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public var headline: String {
        if allowsEnable { return warningCount == 0 ? "Passed preflight" : "Passed with \(warningCount) warning\(warningCount == 1 ? "" : "s")" }
        if errorCount > 0 { return "\(errorCount) error\(errorCount == 1 ? "" : "s") — can't be enabled" }
        return "Preflight incomplete — can't be enabled"
    }
}

public struct InstalledMod: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var version: String
    public var isEnabled: Bool
    public var permissions: [PermissionSummary]
    public var lastPreflight: PreflightResultSummary?
    public var folderURL: URL?
    public var availableUpdate: ModListing?
    public var isLocalDevelopment: Bool

    public init(
        id: String,
        title: String,
        author: String,
        version: String,
        isEnabled: Bool = false,
        permissions: [PermissionSummary] = [],
        lastPreflight: PreflightResultSummary? = nil,
        folderURL: URL? = nil,
        availableUpdate: ModListing? = nil,
        isLocalDevelopment: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.version = version
        self.isEnabled = isEnabled
        self.permissions = permissions
        self.lastPreflight = lastPreflight
        self.folderURL = folderURL
        self.availableUpdate = availableUpdate
        self.isLocalDevelopment = isLocalDevelopment
    }

    public var expandedPermissionsInUpdate: [PermissionSummary] {
        guard let update = availableUpdate else { return [] }
        let held = Set(permissions.map(\.id))
        return update.permissions.filter { !held.contains($0.id) }
    }
}

public enum ModManagementError: LocalizedError, Equatable {
    case notFound(String)
    case enableBlocked(String)
    case indexUnavailable(String)
    case installRefused(String)
    case alreadyInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "\"\(id)\" isn't installed."
        case .enableBlocked(let why): return why
        case .indexUnavailable(let why): return "The mod index couldn't be loaded: \(why)"
        case .installRefused(let why): return why
        case .alreadyInstalled(let id): return "\"\(id)\" is already installed."
        }
    }
}

public protocol ModManagementControlling: AnyObject, Sendable {
    func listInstalled() async throws -> [InstalledMod]
    func fetchIndex() async throws -> ModIndexSnapshot
    func preflight(id: String) async throws -> PreflightResultSummary
    func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> InstalledMod
    func enable(id: String) async throws -> InstalledMod
    func disable(id: String) async throws -> InstalledMod
    func uninstall(id: String, deleteData: Bool) async throws
    func update(id: String, approvedPermissionIDs: Set<String>) async throws -> InstalledMod
    func preflightRefusal(for listingID: String) -> PreflightResultSummary?
}

public extension ModManagementControlling {
    func preflightRefusal(for listingID: String) -> PreflightResultSummary? { nil }
}

public final class PreviewModManagementController: ModManagementControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var installedStore: [InstalledMod]
    private var index: ModIndexSnapshot
    private var preflightOutcomes: [String: PreflightResultSummary] = [:]
    private var failingInstalls: Set<String> = []
    private var failingIndex: String?
    private var callLog: [String] = []
    private var deletedDataFor: [String] = []

    public var latencyNanoseconds: UInt64

    public init(installed: [InstalledMod]? = nil, snapshot: ModIndexSnapshot? = nil, latencyNanoseconds: UInt64 = 0) {
        self.installedStore = installed ?? PreviewModManagementController.sampleInstalled
        self.index = snapshot ?? ModIndexSnapshot(listings: PreviewModManagementController.sampleListings, fetchedAt: Date())
        self.latencyNanoseconds = latencyNanoseconds
    }

    public var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callLog
    }

    public var installedSnapshot: [InstalledMod] {
        lock.lock()
        defer { lock.unlock() }
        return installedStore
    }

    public var dataDeletedFor: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deletedDataFor
    }

    public func setPreflightOutcome(_ result: PreflightResultSummary, forID id: String) {
        lock.lock()
        defer { lock.unlock() }
        preflightOutcomes[id] = result
    }

    public func setInstallFails(_ id: String, _ fails: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if fails { failingInstalls.insert(id) } else { failingInstalls.remove(id) }
    }

    public func setIndexFailure(_ message: String?) {
        lock.lock()
        defer { lock.unlock() }
        failingIndex = message
    }

    public func setIndex(_ snapshot: ModIndexSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        index = snapshot
    }

    private func log(_ entry: String) {
        lock.lock()
        callLog.append(entry)
        lock.unlock()
    }

    private func pause() async {
        if latencyNanoseconds > 0 { try? await Task.sleep(nanoseconds: latencyNanoseconds) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func listInstalled() async throws -> [InstalledMod] {
        log("listInstalled")
        await pause()
        return installedSnapshot
    }

    public func fetchIndex() async throws -> ModIndexSnapshot {
        log("fetchIndex")
        await pause()
        return try locked {
            if let failingIndex { throw ModManagementError.indexUnavailable(failingIndex) }
            return index
        }
    }

    public func preflight(id: String) async throws -> PreflightResultSummary {
        log("preflight:\(id)")
        await pause()
        return try locked {
            guard let i = installedStore.firstIndex(where: { $0.id == id }) else { throw ModManagementError.notFound(id) }
            let mod = installedStore[i]
            var result = preflightOutcomes[id] ?? Self.passingResult(id: id, version: mod.version)
            result.ranAt = Date()
            installedStore[i].lastPreflight = result
            if !result.allowsEnable { installedStore[i].isEnabled = false }
            return result
        }
    }

    public func install(_ listing: ModListing, approvedPermissionIDs: Set<String>) async throws -> InstalledMod {
        log("install:\(listing.id)")
        await pause()
        return try locked {
            if failingInstalls.contains(listing.id) { throw ModManagementError.installRefused("Download of \(listing.title) failed verification.") }
            guard !installedStore.contains(where: { $0.id == listing.id }) else { throw ModManagementError.alreadyInstalled(listing.id) }
            let granted = listing.permissions.filter { approvedPermissionIDs.contains($0.id) }
            guard granted.count == listing.permissions.count else { throw ModManagementError.installRefused("Every requested permission must be reviewed before installing.") }
            let mod = InstalledMod(id: listing.id, title: listing.title, author: listing.author, version: listing.version, isEnabled: false, permissions: granted, folderURL: nil)
            installedStore.append(mod)
            return mod
        }
    }

    public func enable(id: String) async throws -> InstalledMod {
        log("enable:\(id)")
        await pause()
        return try locked {
            guard let i = installedStore.firstIndex(where: { $0.id == id }) else { throw ModManagementError.notFound(id) }
            guard installedStore[i].lastPreflight?.allowsEnable == true else {
                throw ModManagementError.enableBlocked("\(installedStore[i].title) hasn't passed preflight.")
            }
            installedStore[i].isEnabled = true
            return installedStore[i]
        }
    }

    public func disable(id: String) async throws -> InstalledMod {
        log("disable:\(id)")
        await pause()
        return try locked {
            guard let i = installedStore.firstIndex(where: { $0.id == id }) else { throw ModManagementError.notFound(id) }
            installedStore[i].isEnabled = false
            return installedStore[i]
        }
    }

    public func uninstall(id: String, deleteData: Bool) async throws {
        log("uninstall:\(id):\(deleteData)")
        await pause()
        try locked {
            guard installedStore.contains(where: { $0.id == id }) else { throw ModManagementError.notFound(id) }
            installedStore.removeAll { $0.id == id }
            if deleteData { deletedDataFor.append(id) }
        }
    }

    public func update(id: String, approvedPermissionIDs: Set<String>) async throws -> InstalledMod {
        log("update:\(id)")
        await pause()
        return try locked {
            guard let i = installedStore.firstIndex(where: { $0.id == id }) else { throw ModManagementError.notFound(id) }
            guard let update = installedStore[i].availableUpdate else { throw ModManagementError.installRefused("No update is available.") }
            let needed = Set(installedStore[i].expandedPermissionsInUpdate.map(\.id))
            guard needed.isSubset(of: approvedPermissionIDs) else { throw ModManagementError.installRefused("New permissions must be reviewed before updating.") }
            installedStore[i].version = update.version
            installedStore[i].permissions = update.permissions
            installedStore[i].availableUpdate = nil
            installedStore[i].lastPreflight = nil
            installedStore[i].isEnabled = false
            return installedStore[i]
        }
    }

    public static func passingResult(id: String, version: String) -> PreflightResultSummary {
        PreflightResultSummary(
            modID: id,
            version: version,
            ok: true,
            checks: ["schema", "types", "dryRun"].map { PreflightCheck(name: $0, state: .pass) }
        )
    }

    public static func failingResult(id: String, version: String) -> PreflightResultSummary {
        PreflightResultSummary(
            modID: id,
            version: version,
            ok: false,
            checks: [PreflightCheck(name: "schema", state: .pass), PreflightCheck(name: "types", state: .fail), PreflightCheck(name: "dryRun", state: .notRun)],
            diagnostics: [
                PreflightDiagnostic(
                    severity: .error,
                    code: "BFM204",
                    message: "Expected ColumnValue[], received string",
                    file: "scripts/main.bfscript.json",
                    pointer: "/functions/dimensions/body/0",
                    fix: "Return one value per item"
                ),
                PreflightDiagnostic(severity: .warning, code: "BFM110", message: "Setting \"threshold\" has no description", file: "settings.json"),
            ]
        )
    }

    public static let sampleListings: [ModListing] = [
        ModListing(
            id: "ada@git-status",
            title: "Git Status Column",
            author: "Ada",
            version: "1.2.0",
            summary: "Adds a column showing each item's Git state.",
            categories: ["FILESYSTEM", "UI"],
            tags: ["git", "column"],
            readme: "# Git Status Column\n\nShows modified, staged and untracked state next to each file.\n\n- Uses the curated Git broker\n- Never runs shell strings",
            permissions: [
                PermissionSummary(id: "git.read", title: "Read Git status", reason: "Needed to compute the column values.", risk: .medium),
            ],
            versions: [ModVersionInfo(version: "1.2.0", notes: "Faster on large repos."), ModVersionInfo(version: "1.1.0")],
            repoURL: URL(string: "https://github.com/example/git-status"),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        ),
        ModListing(
            id: "ben@markdown-preview",
            title: "Markdown Preview",
            author: "Ben",
            version: "0.9.1",
            summary: "Renders Markdown files in the preview pane.",
            categories: ["PREVIEW"],
            tags: ["markdown", "preview"],
            readme: "# Markdown Preview\n\nRenders **Markdown** as native attributed text.",
            permissions: [PermissionSummary(id: "files.read.selection", title: "Read selected files", reason: "Reads the file being previewed.", risk: .low)],
            versions: [ModVersionInfo(version: "0.9.1")],
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        ),
        ModListing(
            id: "cleo@neon-pack",
            title: "Neon Pack",
            author: "Cleo",
            version: "2.0.0",
            summary: "Theme, icons and sounds.",
            categories: ["THEME"],
            tags: ["theme", "icons", "sounds"],
            readme: "# Neon Pack\n\nA theme with a matching icon set and sound set.",
            permissions: [],
            versions: [ModVersionInfo(version: "2.0.0")],
            updatedAt: Date(timeIntervalSince1970: 1_785_000_000)
        ),
        ModListing(
            id: "dan@trash-guard",
            title: "Protected Folder Trash Guard",
            author: "Dan",
            version: "1.0.0",
            summary: "Blocks moving chosen folders to the Trash.",
            categories: ["WORKFLOW", "FILESYSTEM"],
            tags: ["safety"],
            readme: "# Trash Guard\n\nDenies trash operations on folders you protect.",
            permissions: [
                PermissionSummary(id: "fileops.hook.before", title: "Intercept file operations", reason: "Denies trash operations on protected folders.", risk: .high),
                PermissionSummary(id: "files.read.root", title: "Read a chosen folder", reason: "Needed to know which folders are protected.", risk: .medium),
            ],
            versions: [ModVersionInfo(version: "1.0.0")],
            updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
        ),
        ModListing(
            id: "eve@future-only",
            title: "Future Only",
            author: "Eve",
            version: "3.0.0",
            summary: "Needs a newer betterfinder API.",
            categories: ["AUTOMATION"],
            permissions: [],
            isCompatible: false,
            compatibilityNote: "Requires mod API 2.0."
        ),
    ]

    public static let sampleInstalled: [InstalledMod] = [
        InstalledMod(
            id: "cleo@neon-pack",
            title: "Neon Pack",
            author: "Cleo",
            version: "1.5.0",
            isEnabled: true,
            permissions: [],
            lastPreflight: passingResult(id: "cleo@neon-pack", version: "1.5.0"),
            folderURL: URL(fileURLWithPath: "/tmp/betterfinder/Mods/cleo@neon-pack"),
            availableUpdate: sampleListings.first { $0.id == "cleo@neon-pack" }
        ),
        InstalledMod(
            id: "local@scratch",
            title: "Scratch Column",
            author: "You",
            version: "0.0.1",
            isEnabled: false,
            permissions: [PermissionSummary(id: "files.read.selection", title: "Read selected files", reason: "Computes dimensions.", risk: .low)],
            lastPreflight: failingResult(id: "local@scratch", version: "0.0.1"),
            folderURL: URL(fileURLWithPath: "/tmp/betterfinder/ModDev/scratch"),
            isLocalDevelopment: true
        ),
    ]
}
