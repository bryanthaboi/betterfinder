import AppBridge
import AppKit
import Browser
import MCPServer
import Settings
import SwiftUI
import Theming

enum DeveloperDefaults {
    static let developerMode = AppModDefaults.developerMode
    static let mcpServer = "modMCPServerEnabled"

    static var isDeveloperMode: Bool { UserDefaults.standard.bool(forKey: developerMode) }
    static var wantsMCPServer: Bool { UserDefaults.standard.object(forKey: mcpServer) as? Bool ?? true }
}

@MainActor
final class ExtraSettingsPanes {
    static let shared = ExtraSettingsPanes()
    static let owner = "betterfinder.extra"

    private var developerToken: SettingsPaneToken?
    private var statusBarToken: SettingsPaneToken?
    private var observer: NSObjectProtocol?
    private var lastDeveloperMode: Bool?
    private var lastWantsServer: Bool?

    func install() {
        guard observer == nil else { return }
        if statusBarToken == nil {
            statusBarToken = try? SettingsPaneRegistry.shared.register(
                SettingsPaneDescriptor(id: "statusBar", title: "Status Bar", symbolName: "rectangle.bottomthird.inset.filled", width: 560, minHeight: 420) {
                    StatusBarSettingsView(model: StatusBarSettingsModel(registry: BrowserRegistries.shared.statusBar))
                },
                owner: Self.owner
            )
        }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    func sync() {
        let developer = DeveloperDefaults.isDeveloperMode
        let wantsServer = DeveloperDefaults.wantsMCPServer
        guard developer != lastDeveloperMode || wantsServer != lastWantsServer else { return }
        lastDeveloperMode = developer
        lastWantsServer = wantsServer
        if developer {
            if developerToken == nil {
                developerToken = try? SettingsPaneRegistry.shared.register(
                    SettingsPaneDescriptor(id: "developer", title: "Developer", symbolName: "hammer", width: 560, minHeight: 420) {
                        DeveloperSettingsView(model: DeveloperSettingsModel())
                    },
                    owner: Self.owner
                )
            }
            if wantsServer {
                if !ModsMCP.shared.isRunning { ModsMCP.shared.startQuietly() }
            } else if ModsMCP.shared.isRunning {
                ModsMCP.shared.stop()
            }
        } else {
            if let token = developerToken {
                SettingsPaneRegistry.shared.remove(token)
                developerToken = nil
            }
            if ModsMCP.shared.isRunning { ModsMCP.shared.stop() }
        }
    }
}

@MainActor
final class DeveloperSettingsModel: ObservableObject {
    @Published var serverRunning = false
    @Published var serverURL: String?
    @Published var safeMode = false

    func refresh() {
        serverRunning = ModsMCP.shared.isRunning
        serverURL = ModsMCP.shared.endpointURL
        safeMode = ModsController.shared.isSafeMode
    }

    var workspacesFolder: URL { ModWorkspaces.standardRoot }
}

struct DeveloperSettingsView: View {
    @ObservedObject var model: DeveloperSettingsModel
    @AppStorage(DeveloperDefaults.mcpServer) private var wantsServer = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("MCP server") {
                Toggle("Run the MCP server while developer mode is on", isOn: $wantsServer)
                LabeledContent("Status") {
                    Text(model.serverRunning ? (model.serverURL.map { "Running at \($0)" } ?? "Running") : "Stopped")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Copy MCP Config") { ModsMCP.shared.copyConfig() }
                    .help("Copies a client config for the stdio and HTTP servers. It contains the access token, so paste it into a config file, not a prompt.")
            }
            Section("Mods") {
                HStack(spacing: Spacing.control) {
                    Button("Load Unpacked Mod…") { ModsController.shared.loadUnpacked() }
                    Button("Reload Mods") { ModsController.shared.reload() }
                    Button("Mod Logs…") { ModsController.shared.showLogs() }
                }
                Toggle("Safe mode (pause every mod)", isOn: Binding(
                    get: { model.safeMode },
                    set: { wanted in
                        if wanted != model.safeMode { ModsController.shared.toggleSafeMode() }
                        model.safeMode = wanted
                    }
                ))
                Button("Show Mod Workspaces in betterfinder") {
                    try? FileManager.default.createDirectory(at: model.workspacesFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open([model.workspacesFolder], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Section {
                Text("Developer mode loads unsigned mods straight from a folder or the MCP server. They still go through preflight and ask for permissions. Turn it off in Settings → Mods.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .onReceive(tick) { _ in model.refresh() }
    }
}

@MainActor
final class StatusBarSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var source: String
        var visible: Bool
    }

    @Published private(set) var rows: [Row] = []
    private let registry: StatusBarRegistry

    init(registry: StatusBarRegistry) {
        self.registry = registry
        registry.addObserver(self) { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        let updated = registry.orderedEntries.map { entry in
            Row(
                id: entry.qualifiedID, title: entry.item.accessibilityLabel,
                source: entry.owner == BrowserOwner.builtIn ? "Built in" : (ModsController.shared.runtime?.controller.status(id: entry.owner)?.name ?? entry.owner),
                visible: !registry.isHidden(entry.qualifiedID)
            )
        }
        if updated != rows { rows = updated }
    }

    func setVisible(_ id: String, _ visible: Bool) {
        registry.setHidden(id, !visible)
        reload()
    }

    func move(from source: IndexSet, to destination: Int) {
        var ids = rows.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        registry.setOrder(ids)
        reload()
    }

    func move(_ id: String, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        registry.move(id, toIndex: target)
        reload()
    }

    func reset() {
        registry.resetPreferences()
        reload()
    }
}

struct StatusBarSettingsView: View {
    @ObservedObject var model: StatusBarSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose what the status bar shows and in what order. Items from mods appear here as soon as the mod is enabled, and are shown until you turn them off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(Spacing.containerPadding)
            Divider()
            List {
                ForEach(model.rows) { row in
                    HStack(spacing: Spacing.control) {
                        Toggle(isOn: Binding(get: { row.visible }, set: { model.setVisible(row.id, $0) })) {
                            VStack(alignment: .leading, spacing: Spacing.relatedText) {
                                Text(row.title)
                                Text(row.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Show \(row.title), from \(row.source)")
                        Spacer()
                        Button { model.move(row.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(row.id == model.rows.first?.id)
                            .accessibilityLabel("Move \(row.title) earlier")
                        Button { model.move(row.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(row.id == model.rows.last?.id)
                            .accessibilityLabel("Move \(row.title) later")
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Reset to Defaults") { model.reset() }
            }
            .padding(Spacing.containerPadding)
        }
    }
}
