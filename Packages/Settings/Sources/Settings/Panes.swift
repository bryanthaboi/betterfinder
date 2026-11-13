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
    @AppStorage(SettingsKey.visorTerminal) private var visorTerminal = false
    @AppStorage(SettingsKey.visorOpensWindows) private var visorOpensWindows = false
    @AppStorage(SettingsKey.visorTerminalShell) private var visorShell = ""
    @State private var detectedShells: [TerminalShellProfile] = []
    @State private var visorEnabled = GlobalHotKey.visor.isEnabled
    @State private var visorCombo = GlobalHotKey.visor.combo
    @State private var visorError: String?
    @ObservedObject private var themes = ThemeManager.shared

    var openPane: (String) -> Void = { _ in }
    var extraPanes: [(id: String, title: String)] = []
    @State private var selection: GeneralSection = .windows
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [SettingsSearchEntry] {
        SettingsSearchIndex.entries(extraPanes: extraPanes).filter { $0.matches(trimmedQuery) }
    }

    private func sectionVisible(_ section: GeneralSection) -> Bool {
        if trimmedQuery.isEmpty { return selection == section }
        return SettingsSearchIndex.general.contains { $0.generalSection == section && $0.matches(trimmedQuery) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            ScrollViewReader { proxy in
                detail
                    .environment(\.settingsSearchQuery, trimmedQuery)
                    .onChange(of: selection) { _, section in
                        guard !trimmedQuery.isEmpty else { return }
                        withAnimation { proxy.scrollTo(section, anchor: .top) }
                    }
            }
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onAppear { syncLogin() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search settings")
                    .onSubmit(openFirstResult)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xs)
            if trimmedQuery.isEmpty {
                List(selection: Binding(get: { selection }, set: { if let s = $0 { selection = s } })) {
                    ForEach(GeneralSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                .listStyle(.sidebar)
            } else {
                searchResults
            }
        }
    }

    private var searchResults: some View {
        let hits = results
        let general = GeneralSection.allCases.filter { s in hits.contains { $0.generalSection == s } }
        let others = hits.filter { $0.generalSection == nil }
        return List {
            if hits.isEmpty {
                Text("No settings match").foregroundStyle(.secondary)
            }
            if !general.isEmpty {
                Section("General") {
                    ForEach(general) { section in
                        Button { selection = section } label: {
                            HStack {
                                Label(section.title, systemImage: section.symbol)
                                Spacer()
                                Text("\(hits.filter { $0.generalSection == section }.count)")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !others.isEmpty {
                Section("Other tabs") {
                    ForEach(others) { entry in
                        Button { openPane(entry.paneID) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).lineLimit(2)
                                Text(entry.paneTitle == entry.section ? entry.paneTitle : "\(entry.paneTitle) › \(entry.section)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func openFirstResult() {
        guard let first = results.first else { return }
        if let section = first.generalSection { selection = section } else { openPane(first.paneID) }
    }

    @ViewBuilder
    private var detail: some View {
        if !trimmedQuery.isEmpty && !GeneralSection.allCases.contains(where: sectionVisible) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                Text(results.isEmpty ? "No settings match “\(trimmedQuery)”" : "Matches are in other tabs")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            if sectionVisible(.windows) { Section("Windows") {
                Picker("New window opens at", selection: $location) {
                    ForEach(NewWindowLocation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .settingsRow("newWindow")
                if location == NewWindowLocation.custom.rawValue {
                    HStack {
                        Text(customPath.isEmpty ? "No folder chosen" : (customPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                    .settingsRow("newWindow")
                }
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Open folders in tabs in the active window", isOn: $openFoldersInTabs)
                    Text("Folders opened from other apps, the Dock or Open in New Window join the last active window as a tab. File > New Window always opens a window.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("openInTabs")
                Toggle("Color sidebar icons", isOn: $colorSidebarIcons).settingsRow("sidebarIcons")
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("A sidebar for each pane in dual pane", isOn: $dualPaneSidebars)
                    Text("The right pane gets its own sidebar on the right edge.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("dualSidebars")
                Toggle("Open betterfinder at login", isOn: Binding(get: { loginEnabled }, set: setLogin)).settingsRow("login")
                if loginNeedsApproval {
                    HStack {
                        Text("Approve betterfinder in Login Items.").font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                    .settingsRow("login")
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red).settingsRow("login") }
            }.id(GeneralSection.windows) }
            if sectionVisible(.listing) { Section("Listing") {
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
                .settingsRow("density")
                Toggle("Folders first", isOn: $foldersFirst).settingsRow("foldersFirst")
                Toggle("Show hidden files", isOn: $showHidden).settingsRow("hiddenFiles")
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Colored labels", isOn: $coloredLabels)
                    Text("Tints each row and icon label with the color of its last colored tag.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("coloredLabels")
                Toggle("Fit column widths to names in column view", isOn: $columnAutoWidth).settingsRow("columnFit")
                Toggle("Calculate folder sizes", isOn: $calcSizes).settingsRow("folderSizes")
                Toggle("Also on network volumes", isOn: $calcSizesNetwork).disabled(!calcSizes).padding(.leading, Spacing.l).settingsRow("networkSizes")
                Picker("Size shown", selection: $allocated) {
                    Text("Size on disk (\(SizeFormatter.string(4096)) minimum per file)").tag(true)
                    Text("Logical size").tag(false)
                }
                .pickerStyle(.radioGroup)
                .settingsRow("sizeShown")
            }.id(GeneralSection.listing) }
            if sectionVisible(.terminal) { Section("Terminal") {
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
                .settingsRow("terminal")
            }.id(GeneralSection.terminal) }
            if sectionVisible(.privacy) { Section("Privacy") {
                Picker("Home folder name", selection: $homeNameStyle) {
                    ForEach(HomeNameStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .settingsRow("homeName")
                if homeNameStyle == HomeNameStyle.custom.rawValue {
                    TextField("Shown instead", text: $homeNameCustom, prompt: Text("me"))
                        .accessibilityLabel("Custom home folder name")
                        .settingsRow("homeName")
                }
                Text("Changes how your home folder is shown in the path bar, sidebar, titles and info windows. Files and paths you type are not affected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .settingsRow("homeName")
            }.id(GeneralSection.privacy) }
            if sectionVisible(.visor) { Section("Visor") {
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Global hotkey slides the visor in", isOn: Binding(get: { visorEnabled }, set: setVisor))
                    Text(SettingsCopy.visorHelp)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("visor")
                if visorEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        HotKeyRecorder(combo: $visorCombo, onChange: changeVisorCombo, onReject: { visorError = $0 }).frame(width: 160)
                            .accessibilityLabel("Visor shortcut")
                    }
                    .settingsRow("visorShortcut")
                    Button("Reset to \(HotKeyCombo.visorDefault.displayString)") { changeVisorCombo(.visorDefault) }
                        .buttonStyle(.link)
                        .settingsRow("visorShortcut")
                    Toggle("Double-tap ⌥ also toggles it", isOn: $visorDoubleTap).settingsRow("visorDoubleTap")
                }
                if let visorError { Text(visorError).font(.caption).foregroundStyle(.red) }
                Toggle("Show on all Spaces", isOn: $visorAllSpaces).settingsRow("visorSpaces")
                Toggle("Show above the Dock", isOn: $visorAboveDock).settingsRow("visorDock")
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Open in Terminal opens a terminal on the right half of the visor", isOn: Binding(get: { visorTerminal && visorEnabled }, set: { visorTerminal = $0 }))
                        .disabled(!visorEnabled)
                    Text(visorEnabled ? "Uses the visor's built-in terminal instead of \(TerminalChoice.displayName(path: terminalPath)). ⌃` or the terminal button splits the visor any time." : "Turn on the visor hotkey first.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("visorTerminal")
                Picker("Visor terminal shell", selection: $visorShell) {
                    Text("Login shell (\((TerminalShells.loginShellPath() as NSString).lastPathComponent))").tag("")
                    ForEach(detectedShells) { Text($0.name).tag($0.path) }
                    if !visorShell.isEmpty, !detectedShells.contains(where: { $0.path == visorShell }) {
                        Text(TerminalShells.displayName(path: visorShell)).tag(visorShell)
                    }
                    Divider()
                    Text("Other…").tag(Self.otherShellTag)
                }
                .onChange(of: visorShell) { old, new in
                    if new == Self.otherShellTag { visorShell = chooseShell() ?? old }
                }
                .onAppear { if detectedShells.isEmpty { detectedShells = TerminalShells.detect() } }
                .settingsRow("visorShell")
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Open all new windows in the visor", isOn: $visorOpensWindows)
                    Text("New windows, the Dock and folders opened from other apps become visor tabs instead of separate windows.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("visorWindows")
            }.id(GeneralSection.visor) }
            if sectionVisible(.keyboard) { Section("Keyboard") {
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    Toggle("Windows keys", isOn: $returnOpens)
                    Text(SettingsCopy.windowsKeysHelp)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow("windowsKeys")
                Toggle("Global hotkey opens a new window", isOn: Binding(get: { hotKeyEnabled }, set: setHotKey)).settingsRow("hotkey")
                if hotKeyEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        HotKeyRecorder(combo: $combo, onChange: changeCombo, onReject: { hotKeyError = $0 }).frame(width: 160)
                            .accessibilityLabel("Global hotkey shortcut")
                    }
                    .settingsRow("hotkey")
                    Button("Reset to \(HotKeyCombo.default.displayString)") { changeCombo(.default) }
                        .buttonStyle(.link)
                        .settingsRow("hotkey")
                }
                if let hotKeyError { Text(hotKeyError).font(.caption).foregroundStyle(.red) }
            }.id(GeneralSection.keyboard) }
            if sectionVisible(.updates) {
                Updates.SettingsSectionView().id(GeneralSection.updates)
            }
        }
        .formStyle(.grouped)
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

    private static let otherShellTag = "\u{0}other"

    private func chooseShell() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = "Use Shell"
        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
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
