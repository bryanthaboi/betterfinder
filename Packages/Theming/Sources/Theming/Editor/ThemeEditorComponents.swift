import AppKit
import SwiftUI

public struct ThemePreview: NSViewRepresentable {
    public var theme: Theme
    public var isActive: Bool
    public var density: Density?
    private let followsManagerDensity: Bool

    public init(theme: Theme, isActive: Bool = true) {
        self.theme = theme
        self.isActive = isActive
        self.density = nil
        self.followsManagerDensity = true
    }

    public init(theme: Theme, isActive: Bool = true, density: Density?) {
        self.theme = theme
        self.isActive = isActive
        self.density = density
        self.followsManagerDensity = false
    }

    @MainActor
    var resolvedDensity: Density? {
        followsManagerDensity ? ThemeManager.shared.density : density
    }

    public func makeNSView(context: Context) -> ThemePreviewView {
        let v = ThemePreviewView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        v.theme = theme
        v.isActive = isActive
        v.density = resolvedDensity
        return v
    }

    public func updateNSView(_ view: ThemePreviewView, context: Context) {
        view.theme = theme
        view.isActive = isActive
        view.density = resolvedDensity
    }
}

struct ColorRow: View {
    let label: String
    @Binding var value: String
    var allowsNone = false
    var noneDefault = "#EEEEEE"
    var accessibilityName: String?

    private var name: String { accessibilityName ?? label.trimmingCharacters(in: .whitespaces) }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: Theme.color(value)) },
            set: { value = NSColor($0).hexString }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            if Theme.isSystemToken(value) {
                Text(String(value.dropFirst(7)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(Theme.systemColorTokens, id: \.self) { token in
                    Button(token) { value = "system:\(token)" }
                }
                if allowsNone {
                    Divider()
                    Button("None") { value = "" }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityHidden(true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Use a system color")
            .accessibilityLabel("System color for \(name)")
            if allowsNone && value.isEmpty {
                Button("Add") { value = noneDefault }
                    .controlSize(.small)
                    .accessibilityLabel("Add \(name) color")
            } else {
                ColorPicker(name, selection: colorBinding)
                    .labelsHidden()
            }
        }
    }
}

struct OptionalColorRow: View {
    let label: String
    @Binding var value: String?
    var defaultValue = "#000000"

    var body: some View {
        ColorRow(
            label: label,
            value: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 }),
            allowsNone: true,
            noneDefault: defaultValue
        )
    }
}

struct ColorListEditor: View {
    let label: String
    @Binding var colors: [String]
    var minimum = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Button {
                    colors.append(colors.last ?? "#FFFFFF")
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add \(label) color stop")
                    .accessibilityLabel("Add \(label) color stop")
                Button {
                    if colors.count > minimum { colors.removeLast() }
                } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(colors.count <= minimum)
                    .help("Remove last \(label) color stop")
                    .accessibilityLabel("Remove last \(label) color stop")
            }
            ForEach(0..<colors.count, id: \.self) { i in
                ColorRow(
                    label: "  Stop \(i + 1)",
                    value: Binding(
                        get: { i < colors.count ? colors[i] : "#000000" },
                        set: { if i < colors.count { colors[i] = $0 } }
                    ),
                    accessibilityName: "\(label) stop \(i + 1)"
                )
            }
        }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var zeroLabel: String?
    var unit: String? = "points"
    var accessibilityName: String?

    private var valueText: String { String(format: step < 1 ? "%.1f" : "%.0f", value) }

    var accessibilityValueText: String {
        if let zeroLabel, value == 0 { return zeroLabel }
        guard let unit else { return valueText }
        return "\(valueText) \(value == 1 && unit.hasSuffix("s") ? String(unit.dropLast()) : unit)"
    }

    var body: some View {
        HStack {
            Text(label)
                .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(accessibilityName ?? label)
                .accessibilityValue(accessibilityValueText)
            Text(zeroLabel != nil && value == 0 ? zeroLabel! : valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

struct EnumPicker<E: ThemeEnum>: View {
    let label: String
    @Binding var selection: E
    var accessibilityName: String?

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(E.allCases), id: \.self) { value in
                Text(value.displayName).tag(value)
            }
        }
        .accessibilityLabel(accessibilityName ?? label)
    }
}

enum FontCatalog {
    @MainActor static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    static let generic = ["system", "monospace", "rounded", "serif"]
    static let weights = ["regular", "light", "medium", "semibold", "bold", "heavy"]
}

struct FontRow: View {
    let label: String
    @Binding var spec: Theme.FontSpec
    var accessibilityName: String?

    private var name: String {
        let n = accessibilityName ?? label
        return n.isEmpty ? "Font" : n
    }

    private var weightBinding: Binding<String> {
        Binding(get: { spec.weight ?? "regular" }, set: { spec.weight = $0 == "regular" ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                TextField("Family or fallback list", text: $spec.family)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: 240)
                    .accessibilityLabel("\(name) font family")
                Menu {
                    ForEach(FontCatalog.generic, id: \.self) { f in
                        Button(f) { spec.family = f }
                    }
                    Divider()
                    ForEach(FontCatalog.families, id: \.self) { f in
                        Button(f) { spec.family = f }
                    }
                } label: {
                    Image(systemName: "textformat")
                        .accessibilityHidden(true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Font family for \(name)")
                .accessibilityLabel("Font family for \(name)")
            }
            HStack {
                Stepper("Size \(Int(spec.size))", value: $spec.size, in: 6...36, step: 1)
                    .accessibilityLabel("\(name) font size")
                    .accessibilityValue("\(Int(spec.size)) points")
                Spacer()
                Picker("Weight", selection: weightBinding) {
                    ForEach(FontCatalog.weights, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .frame(maxWidth: 180)
                .accessibilityLabel("\(name) font weight")
            }
            Text("The quick brown fox — \(Theme.resolveFont(spec).displayName ?? spec.family)")
                .font(Font(Theme.resolveFont(spec)))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}

struct OptionalFontRow: View {
    let label: String
    @Binding var spec: Theme.FontSpec?
    let fallback: Theme.FontSpec

    var roleName: String {
        var n = label
        if n.hasPrefix("Custom ") { n.removeFirst(7) }
        if n.hasSuffix(" font") { n.removeLast(5) }
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(label, isOn: Binding(get: { spec != nil }, set: { spec = $0 ? (spec ?? fallback) : nil }))
            if spec != nil {
                FontRow(label: "", spec: Binding(get: { spec ?? fallback }, set: { spec = $0 }), accessibilityName: roleName)
                    .padding(.leading, 16)
            }
        }
    }
}

struct PatternEditor: View {
    let label: String
    @Binding var pattern: Theme.Pattern?
    var defaultPattern = Theme.Pattern(kind: .checkerboard, foreground: "#000000", background: "#FFFFFF", scale: 1)
    var chooseImage: () -> String?

    private var value: Binding<Theme.Pattern> {
        Binding(get: { pattern ?? defaultPattern }, set: { pattern = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: Binding(get: { pattern != nil }, set: { pattern = $0 ? (pattern ?? defaultPattern) : nil }))
            if pattern != nil {
                Group {
                    EnumPicker(label: "Pattern", selection: value.kind)
                    ColorRow(label: "Foreground", value: value.foreground)
                    ColorRow(label: "Background", value: value.background)
                    SliderRow(label: "Scale", value: value.scale, range: 1...8, unit: nil)
                    if value.wrappedValue.kind == .image {
                        HStack {
                            TextField("Image (theme-relative)", text: Binding(get: { value.wrappedValue.image ?? "" }, set: { value.wrappedValue.image = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") {
                                if let rel = chooseImage() { value.wrappedValue.image = rel }
                            }
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: Theme.color(theme.window.colors.first ?? theme.colors.windowBg)))
            Rectangle().fill(Color(nsColor: Theme.color(theme.colors.listBg)))
            Rectangle().fill(Color(nsColor: Theme.color(theme.colors.selection)))
        }
        .frame(width: 30, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
        .environment(\.colorScheme, theme.base == .dark ? .dark : (theme.base == .light ? .light : .light))
    }
}
