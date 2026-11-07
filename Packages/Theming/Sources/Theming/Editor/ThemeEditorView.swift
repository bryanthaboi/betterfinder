import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct ThemeEditorView: View {
    @ObservedObject private var manager: ThemeManager
    @StateObject private var model: ThemeEditorModel
    @State private var tab: Tab = .colors
    @State private var previewActive = true
    @State private var confirmDelete = false
    @State private var confirmReset = false

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", colors = "Colors", fonts = "Fonts", window = "Window", controls = "Controls", list = "List", sounds = "Sounds"
        var id: String { rawValue }
    }

    public init(manager: ThemeManager? = nil) {
        self.init(manager: manager, initialTab: .colors)
    }

    init(manager: ThemeManager?, initialTab: Tab) {
        let manager = manager ?? .shared
        _manager = ObservedObject(wrappedValue: manager)
        _model = StateObject(wrappedValue: ThemeEditorModel(manager: manager))
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        HSplitView {
            themeList
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
            VStack(spacing: 0) {
                previewPane
                Divider()
                editorPane
            }
            .frame(minWidth: 520)
        }
        .frame(minWidth: 760, minHeight: 620)
        .onReceive(manager.$current) { _ in model.syncFromManager() }
        .onDisappear { model.flush() }
        .alert("Theme Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Delete \"\(model.draft.name)\"?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteCurrent() }
        } message: {
            Text("This removes the theme and its assets. This can't be undone.")
        }
        .confirmationDialog("Reset \"\(model.draft.name)\" to the original?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetToOriginal() }
        } message: {
            Text("Your changes to this built-in theme will be discarded.")
        }
    }

    private var builtIns: [Theme] { manager.available.filter { manager.isBuiltIn($0.id) } }
    private var userThemes: [Theme] { manager.available.filter { !manager.isBuiltIn($0.id) && !manager.isContributed($0.id) } }
    private var modThemes: [Theme] { manager.available.filter { manager.isContributed($0.id) } }

    private var themeList: some View {
        VStack(spacing: 0) {
            List(selection: Binding<String?>(get: { model.draft.id }, set: { if let id = $0 { model.select(id) } })) {
                Section("Built-in") {
                    ForEach(builtIns) { t in row(t) }
                }
                if !modThemes.isEmpty {
                    Section("From Mods") {
                        ForEach(modThemes) { t in row(t) }
                    }
                }
                if !userThemes.isEmpty {
                    Section("My Themes") {
                        ForEach(userThemes) { t in row(t) }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button { model.duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                    .accessibilityLabel("Duplicate \(model.draft.name)")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete")
                    .accessibilityLabel("Delete \(model.draft.name)")
                    .disabled(model.isBuiltIn || model.isContributed)
                Button { confirmReset = true } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Reset to Original")
                    .accessibilityLabel("Reset \(model.draft.name) to Original")
                    .disabled(!(model.isBuiltIn && model.hasOverride))
                Spacer()
                Menu {
                    Button("Import Theme…") { model.importTheme() }
                    Button("Export \"\(model.draft.name)\"…") { model.exportCurrent() }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Import or export .\(ThemeManager.packageExtension)")
                .accessibilityLabel("Import or export theme")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func row(_ t: Theme) -> some View {
        HStack(spacing: 8) {
            ThemeSwatch(theme: t)
            Text(t.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let owner = manager.contributionOwner(of: t.id) {
                Text(owner)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .foregroundStyle(.secondary)
                    .help("Provided by mod \(owner)")
                    .accessibilityLabel("Provided by mod \(owner)")
            }
            if manager.isModified(t.id) {
                Text("Modified")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .tag(t.id)
    }

    private var previewPane: some View {
        ThemePreview(theme: model.draft, isActive: previewActive, density: manager.density)
            .frame(minHeight: 300, idealHeight: 330, maxHeight: 360)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Editor section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Active", isOn: $previewActive)
                    .toggleStyle(.checkbox)
                    .help("Preview the active or inactive window state")
            }
            .padding(8)
            Form {
                switch tab {
                case .general: generalTab
                case .colors: colorsTab
                case .fonts: fontsTab
                case .window: windowTab
                case .controls: controlsTab
                case .list: listTab
                case .sounds: soundsTab
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private var generalTab: some View {
        Section {
            TextField("Name", text: model.binding(\.name))
            TextField("Author", text: Binding(get: { model.draft.author ?? "" }, set: { model.draft.author = $0.isEmpty ? nil : $0 }))
            EnumPicker(label: "Appearance", selection: model.binding(\.base))
            TextField("Icon set", text: model.binding(\.icons.set))
        } footer: {
            if let owner = model.contributionOwner {
                Text("Provided by mod \(owner). Editing makes your own copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isBuiltIn {
                Text("Built-in theme. Edits are saved as your own copy; Reset to Original restores it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section("Shortcuts") {
            Toggle("Use native window chrome", isOn: Binding(
                get: { model.draft.window.isNative },
                set: { native in
                    if native {
                        model.draft.window.titlebar = .native
                        model.draft.window.buttons = .native
                        model.draft.window.brushedMetal = false
                        model.draft.window.backgroundPattern = nil
                    } else if model.draft.window.titlebar == .native {
                        model.draft.window.titlebar = .solid
                    }
                }
            ))
        }
    }

    @ViewBuilder private var colorsTab: some View {
        Section("Window") {
            ColorRow(label: "Window background", value: model.binding(\.colors.windowBg))
            ColorRow(label: "Accent", value: model.binding(\.colors.accent))
            ColorRow(label: "Border", value: model.binding(\.colors.border))
        }
        Section("List") {
            ColorRow(label: "Background", value: model.binding(\.colors.listBg), accessibilityName: "List background")
            ColorRow(label: "Alternate row", value: model.binding(\.colors.rowAlt), allowsNone: true, noneDefault: "#F4F4F4")
            ColorRow(label: "Text", value: model.binding(\.colors.text), accessibilityName: "List text")
            ColorRow(label: "Secondary text", value: model.binding(\.colors.secondaryText))
            ColorRow(label: "Selection", value: model.binding(\.colors.selection), accessibilityName: "List selection")
            ColorRow(label: "Selection text", value: model.binding(\.colors.selectionText), accessibilityName: "List selection text")
            ColorRow(label: "Inactive selection", value: model.binding(\.colors.inactiveSelection))
            ColorRow(label: "Inactive selection text", value: model.binding(\.colors.inactiveSelectionText))
        }
        Section("Sidebar") {
            ColorRow(label: "Background", value: model.binding(\.colors.sidebarBg), accessibilityName: "Sidebar background")
            ColorRow(label: "Text", value: model.binding(\.colors.sidebarText), accessibilityName: "Sidebar text")
            ColorRow(label: "Icons", value: model.binding(\.colors.sidebarIcon), accessibilityName: "Sidebar icons")
            ColorRow(label: "Selection", value: model.binding(\.colors.sidebarSelection), accessibilityName: "Sidebar selection")
            ColorRow(label: "Selection text", value: model.binding(\.colors.sidebarSelectionText), accessibilityName: "Sidebar selection text")
        }
        Section("Toolbar & status bar") {
            ColorRow(label: "Toolbar background", value: model.binding(\.colors.toolbarBg))
            ColorRow(label: "Toolbar text", value: model.binding(\.colors.toolbarText))
            ColorRow(label: "Status bar", value: model.binding(\.colors.statusBarBg))
            ColorRow(label: "Status bar text", value: model.binding(\.colors.statusBarText))
        }
        Section("3D bevels") {
            ColorRow(label: "Face", value: model.binding(\.bevelColors.face), accessibilityName: "Bevel face")
            ColorRow(label: "Highlight", value: model.binding(\.bevelColors.highlight), accessibilityName: "Bevel highlight")
            ColorRow(label: "Light", value: model.binding(\.bevelColors.light), accessibilityName: "Bevel light")
            ColorRow(label: "Shadow", value: model.binding(\.bevelColors.shadow), accessibilityName: "Bevel shadow")
            ColorRow(label: "Dark shadow", value: model.binding(\.bevelColors.darkShadow), accessibilityName: "Bevel dark shadow")
            ColorRow(label: "Frame", value: model.binding(\.bevelColors.frame), accessibilityName: "Bevel frame")
        }
    }

    @ViewBuilder private var fontsTab: some View {
        Section("Text") {
            FontRow(label: "List", spec: model.binding(\.fonts.list))
            FontRow(label: "Interface", spec: model.binding(\.fonts.ui))
            OptionalFontRow(label: "Custom sidebar font", spec: model.binding(\.fonts.sidebar), fallback: model.draft.fonts.list)
            OptionalFontRow(label: "Custom status bar font", spec: model.binding(\.fonts.statusBar), fallback: model.draft.fonts.ui)
        }
        Section("Chrome") {
            FontRow(label: "Window title", spec: model.binding(\.window.titleFont))
            OptionalFontRow(label: "Custom header font", spec: model.binding(\.header.font), fallback: model.draft.fonts.ui)
            OptionalFontRow(label: "Custom path bar font", spec: model.binding(\.pathBar.font), fallback: model.draft.fonts.ui)
            OptionalFontRow(label: "Custom icon label font", spec: model.binding(\.iconLabels.font), fallback: model.draft.fonts.list)
        }
        Section {
            Text("Family accepts a comma-separated fallback list, e.g. \"Charcoal, Geneva, system\". Only fonts installed on this Mac are used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var windowTab: some View {
        Section("Title bar") {
            EnumPicker(label: "Fill", selection: model.binding(\.window.titlebar))
            ColorListEditor(label: "Active colors", colors: model.binding(\.window.colors))
            Toggle("Horizontal gradient", isOn: model.binding(\.window.horizontalGradient))
            ColorListEditor(label: "Inactive colors", colors: model.binding(\.window.inactiveColors), minimum: 0)
            Toggle("Brushed metal", isOn: model.binding(\.window.brushedMetal))
            SliderRow(label: "Caption inset", value: model.binding(\.window.captionInset), range: 0...6)
            Toggle("Separator line", isOn: model.binding(\.window.separator))
            ColorRow(label: "Frame / separator", value: model.binding(\.window.frameColor))
        }
        Section("Title") {
            EnumPicker(label: "Alignment", selection: model.binding(\.window.titleAlignment))
            ColorRow(label: "Title", value: model.binding(\.window.titleColor))
            ColorRow(label: "Inactive title", value: model.binding(\.window.inactiveTitleColor))
            OptionalColorRow(label: "Title shadow", value: model.binding(\.window.titleShadow))
        }
        Section("Window buttons") {
            EnumPicker(label: "Style", selection: model.binding(\.window.buttons), accessibilityName: "Window button style")
            ColorRow(label: "Face", value: model.binding(\.window.buttonFace), accessibilityName: "Window button face")
            ColorRow(label: "Glyph", value: model.binding(\.window.buttonGlyph), accessibilityName: "Window button glyph")
            ColorRow(label: "Close face", value: model.binding(\.window.closeButtonFace), allowsNone: true, noneDefault: "#D9502E", accessibilityName: "Close button face")
            Toggle("3D bevel", isOn: model.binding(\.window.buttonBevel))
            Toggle("Show minimize", isOn: model.binding(\.window.showsMinimize))
            SliderRow(label: "Size", value: model.binding(\.window.buttonSize), range: 0...24, zeroLabel: "Auto", accessibilityName: "Window button size")
            SliderRow(label: "Corner radius", value: model.binding(\.window.buttonCornerRadius), range: 0...8, accessibilityName: "Window button corner radius")
        }
        Section("Window background") {
            PatternEditor(label: "Patterned background", pattern: model.binding(\.window.backgroundPattern),
                          defaultPattern: .init(kind: .pinstripe, foreground: "#E9E9E9", background: "#F3F3F3", scale: 1),
                          chooseImage: chooseImage)
        }
    }

    @ViewBuilder private var controlsTab: some View {
        Section("Toolbar buttons") {
            EnumPicker(label: "Style", selection: model.binding(\.toolbar.style), accessibilityName: "Toolbar button style")
            EnumPicker(label: "Toolbar surface", selection: model.binding(\.toolbar.surface))
            ColorRow(label: "Background", value: model.binding(\.toolbar.background), accessibilityName: "Toolbar button background")
            ColorRow(label: "Glyphs", value: model.binding(\.toolbar.text), accessibilityName: "Toolbar glyphs")
            ColorRow(label: "Button face", value: model.binding(\.toolbar.buttonFace), accessibilityName: "Toolbar button face")
            ColorRow(label: "Button border", value: model.binding(\.toolbar.buttonBorder), accessibilityName: "Toolbar button border")
            ColorRow(label: "Hover", value: model.binding(\.toolbar.hover), accessibilityName: "Toolbar button hover")
            ColorRow(label: "Pressed", value: model.binding(\.toolbar.pressed), accessibilityName: "Toolbar button pressed")
            SliderRow(label: "Corner radius", value: model.binding(\.toolbar.cornerRadius), range: 0...14, accessibilityName: "Toolbar button corner radius")
        }
        Section("Scroll bars") {
            EnumPicker(label: "Style", selection: model.binding(\.scrollbar.style), accessibilityName: "Scroll bar style")
            ColorRow(label: "Track", value: model.binding(\.scrollbar.track), accessibilityName: "Scroll bar track")
            ColorRow(label: "Thumb", value: model.binding(\.scrollbar.thumb), accessibilityName: "Scroll bar thumb")
            ColorRow(label: "Thumb border", value: model.binding(\.scrollbar.thumbBorder), accessibilityName: "Scroll bar thumb border")
            Toggle("Arrow buttons", isOn: model.binding(\.scrollbar.arrows))
            SliderRow(label: "Width", value: model.binding(\.scrollbar.width), range: 10...24, accessibilityName: "Scroll bar width")
            SliderRow(label: "Minimum thumb", value: model.binding(\.scrollbar.minimumThumb), range: 8...48, accessibilityName: "Scroll bar minimum thumb")
        }
        Section("Path bar") {
            EnumPicker(label: "Style", selection: model.binding(\.pathBar.style), accessibilityName: "Path bar style")
            ColorRow(label: "Background", value: model.binding(\.pathBar.background), accessibilityName: "Path bar background")
            ColorRow(label: "Text", value: model.binding(\.pathBar.text), accessibilityName: "Path bar text")
            ColorRow(label: "Separator", value: model.binding(\.pathBar.separator), accessibilityName: "Path bar separator")
            ColorRow(label: "Current item", value: model.binding(\.pathBar.highlight), accessibilityName: "Path bar current item")
        }
        Section("Panels") {
            EnumPicker(label: "Status bar", selection: model.binding(\.surfaces.statusBar), accessibilityName: "Status bar surface")
            EnumPicker(label: "Sidebar", selection: model.binding(\.surfaces.sidebar), accessibilityName: "Sidebar surface")
            EnumPicker(label: "List frame", selection: model.binding(\.surfaces.list), accessibilityName: "List frame surface")
            SliderRow(label: "Status bar height", value: model.binding(\.metrics.statusBarHeight), range: 16...40)
        }
    }

    @ViewBuilder private var listTab: some View {
        Section("Rows") {
            SliderRow(label: "Row height", value: model.binding(\.metrics.rowHeight), range: 14...44)
            SliderRow(label: "Icon size", value: model.binding(\.metrics.listIconSize), range: 12...32)
            SliderRow(label: "Selection radius", value: model.binding(\.metrics.cornerRadius), range: 0...12)
            SliderRow(label: "Selection inset", value: model.binding(\.metrics.selectionInset), range: 0...12)
            SliderRow(label: "Selection border", value: model.binding(\.metrics.borderWidth), range: 0...4)
            SliderRow(label: "Sidebar row height", value: model.binding(\.metrics.sidebarRowHeight), range: 0...44, zeroLabel: "Auto")
            SliderRow(label: "Selection vertical inset", value: model.binding(\.metrics.selectionVerticalInset), range: 0...6)
            EnumPicker(label: "Bevel", selection: model.binding(\.metrics.bevel))
        }
        Section("Spacing") {
            Picker("Default density", selection: model.binding(\.metrics.defaultDensity)) {
                Text("Automatic").tag(Density?.none)
                ForEach(Density.allCases, id: \.self) { d in Text(d.displayName).tag(Density?.some(d)) }
            }
            SliderRow(label: "Cell padding", value: model.binding(\.metrics.cellHorizontalInset), range: 0...16)
            SliderRow(label: "Icon–text gap", value: model.binding(\.metrics.iconTextGap), range: 0...16)
            SliderRow(label: "Path bar height", value: model.binding(\.metrics.pathBarHeight), range: 18...40)
            SliderRow(label: "Icon grid gap (H)", value: model.binding(\.metrics.iconGridGapH), range: 0...32)
            SliderRow(label: "Icon grid gap (V)", value: model.binding(\.metrics.iconGridGapV), range: 0...32)
            SliderRow(label: "Icon grid inset", value: model.binding(\.metrics.iconGridInset), range: 0...32)
        }
        Section("Column header") {
            EnumPicker(label: "Style", selection: model.binding(\.header.style), accessibilityName: "Column header style")
            ColorRow(label: "Background", value: model.binding(\.header.background), accessibilityName: "Column header background")
            ColorRow(label: "Text", value: model.binding(\.header.text), accessibilityName: "Column header text")
            ColorRow(label: "Separator", value: model.binding(\.header.separator), accessibilityName: "Column header separator")
            ColorRow(label: "Sort indicator", value: model.binding(\.header.sortIndicator), accessibilityName: "Column header sort indicator")
            SliderRow(label: "Height", value: model.binding(\.header.height), range: 0...32, zeroLabel: "Auto", accessibilityName: "Column header height")
        }
        Section("Grid") {
            Toggle("Horizontal lines", isOn: model.binding(\.grid.horizontal))
            Toggle("Vertical lines", isOn: model.binding(\.grid.vertical))
            EnumPicker(label: "Line style", selection: model.binding(\.grid.style), accessibilityName: "Grid line style")
            ColorRow(label: "Color", value: model.binding(\.grid.color), accessibilityName: "Grid color")
            SliderRow(label: "Width", value: model.binding(\.grid.width), range: 1...3, accessibilityName: "Grid line width")
        }
        Section("Icon view labels") {
            EnumPicker(label: "Shape", selection: model.binding(\.iconLabels.shape), accessibilityName: "Icon label shape")
            ColorRow(label: "Text", value: model.binding(\.iconLabels.text), accessibilityName: "Icon label text")
            ColorRow(label: "Background", value: model.binding(\.iconLabels.background), accessibilityName: "Icon label background")
            ColorRow(label: "Selection", value: model.binding(\.iconLabels.selectionBackground), accessibilityName: "Icon label selection")
            ColorRow(label: "Selection text", value: model.binding(\.iconLabels.selectionText), accessibilityName: "Icon label selection text")
            Stepper("Max lines: \(model.draft.iconLabels.maxLines)", value: model.binding(\.iconLabels.maxLines), in: 1...5)
        }
        Section("Empty area") {
            PatternEditor(label: "Desktop pattern below rows", pattern: model.binding(\.desktopPattern),
                          defaultPattern: .init(kind: .dither50, foreground: "#000000", background: "#FFFFFF", scale: 1),
                          chooseImage: chooseImage)
        }
    }

    @ViewBuilder private var soundsTab: some View {
        Section {
            Toggle("Play theme sounds", isOn: Binding(get: { ThemeSounds.isEnabled }, set: { ThemeSounds.isEnabled = $0 }))
        }
        Section("Events") {
            ForEach(ThemeSoundEvent.allCases, id: \.self) { event in
                soundRow(event)
            }
        }
        Section {
            Text("Use a file copied into the theme, or a sound already on this Mac (system:Name). Built-in themes ship without sounds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func soundBinding(_ event: ThemeSoundEvent) -> Binding<String> {
        Binding(
            get: { model.draft.sounds[event.rawValue] ?? "" },
            set: { v in
                if v.isEmpty { model.draft.sounds.removeValue(forKey: event.rawValue) } else { model.draft.sounds[event.rawValue] = v }
                ThemeSounds.clearCache()
            }
        )
    }

    private func soundRow(_ event: ThemeSoundEvent) -> some View {
        let binding = soundBinding(event)
        return HStack {
            Text(event.displayName)
            Spacer()
            TextField("None", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("\(event.displayName) sound")
            Menu {
                Button("Choose File…") {
                    if let rel = model.chooseAsset(subdirectory: "sounds", types: [.audio]) { binding.wrappedValue = rel }
                }
                Divider()
                ForEach(Self.systemSoundNames, id: \.self) { name in
                    Button(name) { binding.wrappedValue = "system:\(name)" }
                }
                Divider()
                Button("None") { binding.wrappedValue = "" }
            } label: {
                Image(systemName: "music.note")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose \(event.displayName) sound")
            .accessibilityLabel("Choose \(event.displayName) sound")
            Button {
                model.flush()
                ThemeSounds.play(event, theme: model.draft, manager: manager)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play \(event.displayName) sound")
            .accessibilityLabel("Play \(event.displayName) sound")
            .disabled(binding.wrappedValue.isEmpty)
        }
    }

    private func chooseImage() -> String? {
        model.chooseAsset(subdirectory: "patterns", types: [.image])
    }

    static let systemSoundNames: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()
}
