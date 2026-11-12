import AppKit
import FSCore
import Integration
import SwiftUI
import Theming
import Updates

struct GeneralPane: View {
    @AppStorage(SettingsKey.newWindowLocation) private var location = NewWindowLocation.home.rawValue
    @AppStorage(SettingsKey.newWindowCustomPath) private var customPath = ""
    @AppStorage(SettingsKey.foldersFirst) private var foldersFirst = false
    @AppStorage(SettingsKey.showHiddenFiles) private var showHidden = false
    @AppStorage(SettingsKey.calculateFolderSizes) private var calcSizes = true
    @AppStorage(SettingsKey.calculateFolderSizesOnNetwork) private var calcSizesNetwork = false
    @AppStorage(SettingsKey.showAllocatedSize) private var allocated = true
    @AppStorage(SettingsKey.returnOpens) private var returnOpens = false
    @AppStorage(SettingsKey.openFoldersInTabs) private var openFoldersInTabs = false
    @AppStorage(SettingsKey.terminalAppPath) private var terminalPath = ""
    @AppStorage(SettingsKey.homeFolderNameStyle) private var homeNameStyle = HomeNameStyle.real.rawValue
    @AppStorage(SettingsKey.homeFolderNameCustom) private var homeNameCustom = ""
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.state == .requiresApproval
    @State private var loginError: String?
    @State private var hotKeyEnabled = GlobalHotKey.shared.isEnabled
    @State private var combo = GlobalHotKey.shared.combo
    @State private var hotKeyError: String?
    @AppStorage(SettingsKey.coloredLabels) private var coloredLabels = false
    @AppStorage(SettingsKey.columnAutoWidth) private var columnAutoWidth = true
    @AppStorage(SettingsKey.colorSidebarIcons) private var colorSidebarIcons = false
    @AppStorage(SettingsKey.dualPaneSidebars) private var dualPaneSidebars = false
    @AppStorage(SettingsKey.visorDoubleTapOption) private var visorDoubleTap = false
    @AppStorage(SettingsKey.visorAllSpaces) private var visorAllSpaces = true
    @AppStorage(SettingsKey.visorAboveDock) private var visorAboveDock = false
    @State private var visorEnabled = GlobalHotKey.visor.isEnabled
    @State private var visorCombo = GlobalHotKey.visor.combo
    @State private var visorError: String?
    @ObservedObject private var themes = ThemeManager.shared

    var body: some View {
        Form {
            Section("Windows") {
                Picker("New window opens at", selection: $location) {
                    ForEach(NewWindowLocation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if location == NewWindowLocation.custom.rawValue {
                    HStack {
                        Text(customPath.isEmpty ? "No folder chosen" : (customPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Open folders in tabs in the active window", isOn: $openFoldersInTabs)
                    Text("Folders opened from other apps, the Dock or Open in New Window join the last active window as a tab. File > New Window always opens a window.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Color sidebar icons", isOn: $colorSidebarIcons)
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("A sidebar for each pane in dual pane", isOn: $dualPaneSidebars)
                    Text("The right pane gets its own sidebar on the right edge.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Open betterfinder at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                if loginNeedsApproval {
                    HStack {
                        Text("Approve betterfinder in Login Items.").font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Listing") {
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Picker("Density", selection: Binding(get: { themes.effectiveDensity }, set: { themes.density = $0 })) {
                        ForEach(Density.allCases, id: \.self) { d in
                            Text(d == .regular ? "\(d.displayName) (default)" : d.displayName).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: Spacing.xs) {
                        Text(themes.density == nil ? "Following the theme. Retro themes keep their compact sizes." : "Applies to the sidebar, lists, columns and icons.")
                            .font(.caption).foregroundStyle(.secondary)
                        if themes.density != nil {
                            Button("Use theme default") { themes.density = nil }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                Toggle("Folders first", isOn: $foldersFirst)
                Toggle("Show hidden files", isOn: $showHidden)
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Colored labels", isOn: $coloredLabels)
                    Text("Tints each row and icon label with the color of its last colored tag.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Fit column widths to names in column view", isOn: $columnAutoWidth)
                Toggle("Calculate folder sizes", isOn: $calcSizes)
                Toggle("Also on network volumes", isOn: $calcSizesNetwork).disabled(!calcSizes).padding(.leading, Spacing.l)
                Picker("Size shown", selection: $allocated) {
                    Text("Size on disk (\(SizeFormatter.string(4096)) minimum per file)").tag(true)
                    Text("Logical size").tag(false)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Terminal") {
                HStack {
                    Text("Open in Terminal uses")
                    Spacer()
                    Text(TerminalChoice.displayName(path: terminalPath)).foregroundStyle(.secondary)
                        .accessibilityLabel("Terminal app: \(TerminalChoice.displayName(path: terminalPath))")
                    Menu("Change") {
                        Button("Terminal") { TerminalChoice.store(path: "", bundleID: nil) }
                        ForEach(TerminalChoice.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) { choice in
                            Button(choice.name) { TerminalChoice.store(path: choice.path, bundleID: choice.bundleID) }
                        }
                        Divider()
                        Button("Choose App…", action: chooseTerminal)
                    }
                    .fixedSize()
                    .accessibilityLabel("Change terminal app")
                }
            }
            Section("Privacy") {
                Picker("Home folder name", selection: $homeNameStyle) {
                    ForEach(HomeNameStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if homeNameStyle == HomeNameStyle.custom.rawValue {
                    TextField("Shown instead", text: $homeNameCustom, prompt: Text("me"))
                        .accessibilityLabel("Custom home folder name")
                }
                Text("Changes how your home folder is shown in the path bar, sidebar, titles and info windows. Files and paths you type are not affected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Visor") {
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Global hotkey slides the visor in", isOn: Binding(get: { visorEnabled }, set: setVisor))
                    Text(SettingsCopy.visorHelp)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if visorEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        HotKeyRecorder(combo: $visorCombo, onChange: changeVisorCombo, onReject: { visorError = $0 }).frame(width: 160)
                            .accessibilityLabel("Visor shortcut")
                    }
                    Button("Reset to \(HotKeyCombo.visorDefault.displayString)") { changeVisorCombo(.visorDefault) }
                        .buttonStyle(.link)
                    Toggle("Double-tap ⌥ also toggles it", isOn: $visorDoubleTap)
                }
                if let visorError { Text(visorError).font(.caption).foregroundStyle(.red) }
                Toggle("Show on all Spaces", isOn: $visorAllSpaces)
                Toggle("Show above the Dock", isOn: $visorAboveDock)
            }
            Section("Keyboard") {
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Windows keys", isOn: $returnOpens)
                    Text(SettingsCopy.windowsKeysHelp)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Global hotkey opens a new window", isOn: Binding(get: { hotKeyEnabled }, set: setHotKey))
                if hotKeyEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        HotKeyRecorder(combo: $combo, onChange: changeCombo, onReject: { hotKeyError = $0 }).frame(width: 160)
                            .accessibilityLabel("Global hotkey shortcut")
                    }
                    Button("Reset to \(HotKeyCombo.default.displayString)") { changeCombo(.default) }
                        .buttonStyle(.link)
                }
                if let hotKeyError { Text(hotKeyError).font(.caption).foregroundStyle(.red) }
            }
            Updates.SettingsSectionView()
        }
        .formStyle(.grouped)
        .onAppear { syncLogin() }
    }

    private func syncLogin() {
        loginEnabled = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.state == .requiresApproval
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do { try LoginItem.setEnabled(on) } catch { loginError = error.localizedDescription }
        syncLogin()
    }

    private func setHotKey(_ on: Bool) {
        hotKeyError = nil
        do {
            try GlobalHotKey.shared.setEnabled(on)
            hotKeyEnabled = on
        } catch {
            hotKeyError = error.localizedDescription
            hotKeyEnabled = GlobalHotKey.shared.isEnabled
        }
    }

    private func setVisor(_ on: Bool) {
        visorError = nil
        do {
            try GlobalHotKey.visor.setEnabled(on)
            visorEnabled = on
        } catch {
            visorError = error.localizedDescription
            visorEnabled = GlobalHotKey.visor.isEnabled
        }
    }

    private func changeVisorCombo(_ new: HotKeyCombo) {
        visorError = nil
        do {
            try GlobalHotKey.visor.setCombo(new)
            visorCombo = new
        } catch {
            visorError = error.localizedDescription
            visorCombo = GlobalHotKey.visor.combo
        }
    }

    private func changeCombo(_ new: HotKeyCombo) {
        hotKeyError = nil
        do {
            try GlobalHotKey.shared.setCombo(new)
            combo = new
        } catch {
            hotKeyError = error.localizedDescription
            combo = GlobalHotKey.shared.combo
        }
    }

    private func chooseTerminal() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        TerminalChoice.store(path: url.path, bundleID: Bundle(url: url)?.bundleIdentifier)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
    }
}

struct DefaultFileManagerPane: View {
    @StateObject private var model = DefaultManagerModel()
    @State private var confirmTweak: FinderTweaks.Tweak?

    var body: some View {
        Form {
            Section { MakeDefaultControls(model: model) }
            Section("What this covers") { CompatibilityMatrixView() }
            Section {
                Button("Restore Finder as default") { model.restoreEverything() }
                    .disabled(model.isBusy || (!model.status.hasRestorePoint && !model.status.isFileViewer && !model.status.isFolderHandler && !anyTweak))
                Text("Puts back the previous Finder handlers and undoes the tweaks below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Finder tweaks (optional)") {
                ForEach(FinderTweaks.Tweak.allCases) { tweak in
                    VStack(alignment: .leading, spacing: Spacing.relatedText) {
                        Toggle(tweak.title, isOn: Binding(
                            get: { model.tweakStates[tweak] ?? false },
                            set: { newValue in
                                if newValue { confirmTweak = tweak } else { model.setTweak(tweak, enabled: false) }
                            }
                        ))
                        .disabled(model.isBusy)
                        Text(tweak.warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .confirmationDialog(
            confirmTweak?.title ?? "",
            isPresented: Binding(get: { confirmTweak != nil }, set: { if !$0 { confirmTweak = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apply and Restart Finder") {
                if let t = confirmTweak { model.setTweak(t, enabled: true) }
                confirmTweak = nil
            }
            Button("Cancel", role: .cancel) { confirmTweak = nil }
        } message: {
            Text(confirmTweak?.warning ?? "")
        }
    }

    private var anyTweak: Bool { model.tweakStates.values.contains(true) }
}

struct AppearancePane: View {
    var body: some View {
        ThemeEditorView()
            .frame(minWidth: 760, minHeight: 520)
    }
}

struct PermissionsPane: View {
    @StateObject private var model = PermissionsModel()

    var body: some View {
        Form {
            Section {
                PermissionsList(model: model)
            } footer: {
                Text("Folder access is requested by macOS the first time betterfinder reads each location. Full Disk Access can only be granted in System Settings.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedPane: View {
    @AppStorage(SettingsKey.verifyCopies) private var verifyCopies = false
    @AppStorage(SettingsKey.trashViaFinder) private var trashViaFinder = false
    @StateObject private var index: SizeIndexSettingsModel

    init(sizeIndex: SizeIndexControlling) {
        _index = StateObject(wrappedValue: SizeIndexSettingsModel(controller: sizeIndex))
    }

    var body: some View {
        Form {
            Section("File operations") {
                Toggle("Verify copies with a checksum", isOn: $verifyCopies)
                Text("Reads every copied file back and compares it with the source. Slower, safer.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Move to Trash through Finder", isOn: $trashViaFinder)
                Text("Gives real Put Back support. Needs the Automation permission for Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("File index") {
                if let explanation = index.availability.explanation {
                    VStack(alignment: .leading, spacing: Spacing.relatedText) {
                        Label("File indexer unavailable", systemImage: "exclamationmark.triangle")
                        Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if index.availability == .requiresApproval {
                            Button("Open Login Items") { LoginItem.openSystemSettings() }
                        }
                    }
                }
                if let summary = index.statusSummary {
                    LabeledContent("Status") { Text(summary).monospacedDigit() }
                }
                Toggle("Pause indexing", isOn: Binding(get: { index.paused }, set: { value in
                    Task { await index.setPaused(value) }
                }))
                .disabled(!index.controlsEnabled || index.isChangingPause)
                if let error = index.pauseError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.xs) {
                    Button(rebuildFailed ? "Try Again" : "Rebuild index") { Task { await index.requestRebuild() } }
                        .disabled(!index.controlsEnabled || index.rebuild == .requesting)
                    switch index.rebuild {
                    case .idle: EmptyView()
                    case .requesting: ProgressView().controlSize(.small).accessibilityLabel("Requesting index rebuild")
                    case .started: Text("Rebuild started").font(.caption).foregroundStyle(.secondary)
                    case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await index.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var rebuildFailed: Bool {
        if case .failed = index.rebuild { return true }
        return false
    }
}
