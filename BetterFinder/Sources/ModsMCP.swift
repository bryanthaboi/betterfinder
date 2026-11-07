import AppBridge
import AppKit
import Browser
import Foundation
import MCPServer
import ModHost
import ModKit
import ModValidation

@MainActor
final class ModsMCP {
    static let shared = ModsMCP()

    private struct Approval {
        var modID: String
        var digest: String
        var review: JSONValue
        var expires: Date
        var decision: Bool?
    }

    private var host: MCPServerHost?
    private var approvals: [String: Approval] = [:]
    private let approvalTTL: TimeInterval = 600

    var isRunning: Bool { host?.isRunning ?? false }

    static var cliURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/betterfinder-mod") }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    func toggle() {
        if isRunning { stop() } else { Task { await startReporting() } }
    }

    @discardableResult
    func start() async throws -> MCPEndpointInfo {
        if let host, let endpoint = host.endpoint { return endpoint }
        let h = host ?? MCPServerHost(MCPServerHostConfiguration(
            server: MCPServerConfiguration(dryRunner: dryRunner(), live: makeHosting(), serverVersion: Self.appVersion)
        ))
        host = h
        return try await h.start()
    }

    private func startReporting() async {
        do {
            let endpoint = try await start()
            ModToast.show(title: "MCP", message: "Server running at \(endpoint.url).")
        } catch {
            showError("The MCP server couldn't start", error)
        }
    }

    func stop() {
        host?.stop()
        approvals.removeAll()
    }

    func copyConfig() {
        Task {
            var servers: [String: Any] = [
                "betterfinder-mod": ["command": Self.cliURL.path, "args": ["mcp"]] as [String: Any],
            ]
            var endpoint: MCPEndpointInfo?
            do { endpoint = try await start() } catch { showError("The MCP server couldn't start", error) }
            if let endpoint {
                servers["betterfinder"] = ["type": "http", "url": endpoint.url, "headers": ["Authorization": "Bearer \(endpoint.token)"]] as [String: Any]
            }
            let object: [String: Any] = ["mcpServers": servers]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let cliNote = FileManager.default.isExecutableFile(atPath: Self.cliURL.path) ? "" : " The embedded CLI is missing from this build."
            if let endpoint {
                ModToast.show(title: "MCP", message: "Copied config for betterfinder-mod (stdio) and betterfinder (\(endpoint.url)).\(cliNote)")
            } else {
                ModToast.show(title: "MCP", message: "Copied config for betterfinder-mod (stdio) only; the HTTP server isn't running.\(cliNote)", level: "warning")
            }
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        Task { _ = await AppModServices.present(alert) }
    }

    private func dryRunner() -> DryRunning {
        guard let controller = ModsController.shared.runtime?.controller else { return NotRunDryRunner() }
        return ModHostDryRunner(controller: controller)
    }

    private func makeHosting() -> ClosureLiveModHosting {
        let me = self
        return ClosureLiveModHosting(
            status: { await me.liveStatus() },
            load: { try await me.liveLoad($0) },
            unload: { try await me.liveUnload($0) },
            uiState: { try await me.liveUIState($0) },
            screenshot: { try await me.liveScreenshot($0) },
            logs: { try await me.liveLogs($0) }
        )
    }

    private func runtime() throws -> AppModRuntime {
        guard let r = ModsController.shared.runtime else { throw LiveHostError.unavailable("the betterfinder mod runtime isn't running") }
        return r
    }

    private var windows: [NSWindow] {
        NSApp.orderedWindows.filter { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
    }

    private var liveWindows: [LiveWindow] { windows.map { LiveWindow(id: String($0.windowNumber), title: $0.title) } }

    private func window(_ id: String) -> NSWindow? {
        if id.isEmpty || id == "front" { return windows.first }
        guard let n = Int(id) else { return nil }
        return windows.first { $0.windowNumber == n }
    }

    func liveStatus() -> LiveHostStatus {
        guard let r = ModsController.shared.runtime else { return .unavailable("the betterfinder mod runtime isn't running") }
        if r.isSafeMode {
            return LiveHostStatus(available: false, developerMode: r.developerMode, appVersion: Self.appVersion, windows: liveWindows, reason: "mods are paused in safe mode")
        }
        return LiveHostStatus(available: true, developerMode: r.developerMode, appVersion: Self.appVersion, windows: liveWindows)
    }

    func liveLoad(_ request: LiveLoadRequest) async throws -> LiveLoadResult {
        let r = try runtime()
        guard r.developerMode else { throw LiveHostError.developerModeRequired }
        guard !r.isSafeMode else { throw LiveHostError.unavailable("mods are paused in safe mode") }
        let folder = URL(fileURLWithPath: request.workspacePath, isDirectory: true).standardizedFileURL
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else {
            throw LiveHostError.failed("the workspace has no readable manifest.json", [])
        }
        let manifest: ModManifest
        switch ModManifest.decode(data) {
        case .success(let m): manifest = m
        case .failure(let d): throw LiveHostError.failed("manifest.json is invalid", [d])
        }
        guard manifest.id == request.modID else {
            throw LiveHostError.rejected("the workspace manifest id '\(manifest.id)' does not match '\(request.modID)'")
        }
        let wanted = Self.permissionIDs(manifest)
        let current = r.controller.status(id: manifest.id)
        let covered = current.map { $0.developer && $0.enabled && $0.active && wanted.isSubset(of: $0.approvedPermissionIDs) } ?? false
        if !covered {
            try await requireNativeApproval(manifest: manifest, request: request, existing: current, folder: folder)
        }
        window(request.windowID)?.makeKeyAndOrderFront(nil)
        let outcome = await r.loadUnpacked(folder, approver: { m, _ in
            m.id == manifest.id ? wanted.intersection(Self.permissionIDs(m)) : nil
        })
        if outcome.cancelled { throw LiveHostError.rejected("the load was cancelled in betterfinder") }
        let diagnostics = outcome.receipt?.diagnostics ?? []
        guard outcome.installed else {
            throw LiveHostError.failed(outcome.error ?? "preflight failed", diagnostics)
        }
        guard outcome.enabled else {
            throw LiveHostError.failed(outcome.error ?? "the mod was installed but couldn't be enabled", diagnostics.filter { $0.severity != .error })
        }
        return LiveLoadResult(generation: r.controller.status(id: manifest.id)?.generation ?? 0, diagnostics: diagnostics.filter { $0.severity != .error })
    }

    func liveUnload(_ id: String) async throws -> Bool {
        let r = try runtime()
        guard let s = r.controller.status(id: id) else { return false }
        r.unloadDev(id: id)
        guard s.enabled || s.active else { return false }
        do { try await r.controller.disable(id: id) } catch { throw LiveHostError.failed(error.localizedDescription, []) }
        r.sink.flush()
        return true
    }

    func liveUIState(_ id: String) throws -> LiveUIState {
        let r = try runtime()
        guard let s = r.controller.status(id: id) else { throw LiveHostError.rejected("'\(id)' is not installed") }
        var status: [String: JSONValue] = [
            "kind": .string("status"), "id": .string(id), "name": .string(s.name), "version": .string(s.version),
            "enabled": .bool(s.enabled), "active": .bool(s.active), "developer": .bool(s.developer),
            "approvedPermissions": .int(s.approvedPermissionIDs.count), "permissions": .int(s.permissions.count),
        ]
        if let e = s.lastError { status["lastError"] = .string(e) }
        if let e = s.suspendedReason { status["suspendedReason"] = .string(e) }
        let reg = r.configuration.registries
        var surfaces: [JSONValue] = [.object(status)]
        surfaces += Self.entries(reg.toolbar, id) + Self.entries(reg.sidebar, id) + Self.entries(reg.contextMenu, id)
        surfaces += Self.entries(reg.columns, id) + Self.entries(reg.statusBar, id) + Self.entries(reg.panels, id)
        surfaces += Self.entries(reg.previews, id) + Self.entries(reg.browserViews, id) + Self.entries(reg.commands, id)
        surfaces += Self.entries(reg.keyBindings, id) + Self.entries(reg.locations, id) + Self.entries(reg.searchProviders, id)
        return LiveUIState(windows: liveWindows, surfaces: surfaces, generation: s.generation ?? 0)
    }

    private static func entries<Item: BrowserContribution>(_ registry: BrowserRegistry<Item>, _ owner: String) -> [JSONValue] {
        registry.entries(owner: owner).map {
            .object(["kind": .string(registry.kind.rawValue), "id": .string($0.qualifiedID), "hidden": .bool(registry.isHidden($0.qualifiedID))])
        }
    }

    func liveScreenshot(_ request: LiveScreenshotRequest) throws -> Data {
        guard let w = window(request.windowID) else { throw LiveHostError.rejected("no betterfinder window with id '\(request.windowID.prefix(64))'") }
        guard let view = w.contentView else { throw LiveHostError.failed("the window has no content", []) }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw LiveHostError.failed("the window couldn't be rendered", [])
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw LiveHostError.failed("PNG encoding failed", []) }
        return png
    }

    func liveLogs(_ id: String) throws -> [LiveLogEntry] {
        let r = try runtime()
        let f = ISO8601DateFormatter()
        let live = r.controller.logs(id: id)
        if !live.isEmpty { return live.map { LiveLogEntry(time: f.string(from: $0.time), level: $0.level, message: $0.message) } }
        return r.logText(id: id).split(separator: "\n").suffix(500).map { Self.parseLogLine(String($0)) }
    }

    private static func parseLogLine(_ line: String) -> LiveLogEntry {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count >= 2, parts[1].hasPrefix("["), parts[1].hasSuffix("]"), ISO8601DateFormatter().date(from: String(parts[0])) != nil {
            return LiveLogEntry(time: String(parts[0]), level: String(parts[1].dropFirst().dropLast()), message: parts.count > 2 ? String(parts[2]) : "")
        }
        return LiveLogEntry(time: "", level: "info", message: line)
    }

    private static func permissionIDs(_ m: ModManifest) -> Set<String> {
        Set(m.permissions.map { ModHostManagementController.summary($0).id })
    }

    private func digest(_ manifest: ModManifest, _ request: LiveLoadRequest) -> String {
        ([manifest.id, request.treeHash, request.workspacePath] + Self.permissionIDs(manifest).sorted()).joined(separator: "\n")
    }

    func requireNativeApproval(manifest: ModManifest, request: LiveLoadRequest, existing: ModStatus?, folder: URL) async throws {
        let now = Date()
        approvals = approvals.filter { $0.value.expires > now }
        let digest = self.digest(manifest, request)
        if let id = request.approval, !id.isEmpty {
            guard let a = approvals[id], a.modID == manifest.id else {
                throw LiveHostError.rejected("the approval id is unknown, expired or was already used; call mod_load again without approval")
            }
            guard a.digest == digest else {
                approvals.removeValue(forKey: id)
                throw LiveHostError.rejected("the workspace changed since it was approved; call mod_load again without approval for a new review")
            }
            switch a.decision {
            case .some(true):
                approvals.removeValue(forKey: id)
                return
            case .some(false):
                approvals.removeValue(forKey: id)
                throw LiveHostError.rejected("the user denied loading \(manifest.id) in betterfinder")
            case .none:
                throw LiveHostError.approvalRequired(id: id, review: a.review)
            }
        }
        if let pending = approvals.first(where: { $0.value.digest == digest && $0.value.decision == nil }) {
            throw LiveHostError.approvalRequired(id: pending.key, review: pending.value.review)
        }
        let id = "apv-" + UUID().uuidString.lowercased()
        let review = self.review(manifest, request: request, existing: existing)
        approvals[id] = Approval(modID: manifest.id, digest: digest, review: review, expires: now.addingTimeInterval(approvalTTL), decision: nil)
        let alert = approvalAlert(manifest, existing: existing, folder: folder)
        let target = window(request.windowID)
        Task { @MainActor in
            target?.makeKeyAndOrderFront(nil)
            let approved = await AppModServices.present(alert) == .alertFirstButtonReturn
            if approvals[id] != nil { approvals[id]?.decision = approved }
        }
        throw LiveHostError.approvalRequired(id: id, review: review)
    }

    private func review(_ m: ModManifest, request: LiveLoadRequest, existing: ModStatus?) -> JSONValue {
        var o: [String: JSONValue] = [
            "action": .string("hot-load unsigned developer mod"),
            "id": .string(m.id), "name": .string(m.name), "version": .string(m.version.description), "author": .string(m.author),
            "revision": .string(request.treeHash),
            "permissions": .array(m.permissions.map {
                let s = ModHostManagementController.summary($0)
                return .object(["id": .string(s.id), "title": .string(s.title), "reason": .string(s.reason), "risk": .string(s.risk.label)])
            }),
            "expiresInSeconds": .int(Int(approvalTTL)),
        ]
        if let existing, !existing.developer { o["replaces"] = .string("installed version \(existing.version)") }
        return .object(o)
    }

    private func approvalAlert(_ m: ModManifest, existing: ModStatus?, folder: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Load “\(m.name)” from an MCP client?"
        var lines = [
            "A client connected to betterfinder's MCP server wants to hot-load this unsigned developer mod.",
            "",
            "ID: \(m.id)",
            "Version: \(m.version.description)\(m.author.isEmpty ? "" : " by \(m.author)")",
            "Folder: \((folder.path as NSString).abbreviatingWithTildeInPath)",
        ]
        if let existing, !existing.developer { lines.append("Replaces the installed version \(existing.version).") }
        lines.append("")
        if m.permissions.isEmpty {
            lines.append("Permissions: none")
        } else {
            lines.append("Permissions:")
            for p in m.permissions {
                let s = ModHostManagementController.summary(p)
                lines.append("• \(s.title) (\(s.risk.label) risk)\(s.reason.isEmpty || s.reason == s.title ? "" : " — \(s.reason)")")
            }
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = m.permissions.contains { ModHostManagementController.summary($0).risk == .high } ? .critical : .warning
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        return alert
    }
}
