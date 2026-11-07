import AppKit
import Integration
import SwiftUI
import Theming

struct CompatibilityMatrixView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(RevealCompatibility.matrix) { entry in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(entry.coverage.symbol)
                        .font(.system(.body, design: .rounded).bold())
                        .foregroundStyle(color(entry.coverage))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: Spacing.relatedText / 2) {
                        Text(entry.title)
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .help(entry.coverage.label)
            }
        }
    }

    private func color(_ c: RevealEntryPoint.Coverage) -> Color {
        switch c {
        case .redirected: return .green
        case .notRedirected: return .red
        case .unverified: return .orange
        }
    }
}

struct MakeDefaultControls: View {
    @ObservedObject var model: DefaultManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Toggle(isOn: Binding(get: { model.status.isFullyDefault }, set: { model.setDefault($0) })) {
                    Text("Make betterfinder my default").font(.title3.weight(.semibold))
                }
                .toggleStyle(.switch)
                .disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            statusLine
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.warnings, id: \.self) { w in
                Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: Spacing.relatedText) {
            statusRow("Show in Finder / Reveal", model.status.isFileViewer)
            statusRow("Opening folders", model.status.isFolderHandler)
        }
        .font(.callout)
    }

    private func statusRow(_ title: String, _ on: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
            Text(title)
            Text(on ? "betterfinder" : "not set").foregroundStyle(.secondary)
        }
    }
}

struct PermissionRow: View {
    let status: PermissionStatus
    var grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.relatedText) {
                Text(status.kind.title)
                Text(status.detail ?? status.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.xs)
            if status.state != .granted && status.state != .notApplicable {
                Button(buttonTitle, action: grant)
            }
        }
    }

    private var buttonTitle: String {
        switch status.kind {
        case .fullDiskAccess: return "Open Settings"
        default: return status.state == .denied ? "Open Settings" : "Grant"
        }
    }

    private var icon: String {
        switch status.state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .notApplicable: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch status.state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .notApplicable, .unknown: return .secondary
        }
    }
}

struct PermissionsList: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(PermissionKind.allCases) { kind in
                PermissionRow(status: model.status(for: kind)) { model.grant(kind) }
            }
            HStack {
                Button("Re-check") { model.refresh() }.disabled(model.isRefreshing)
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { model.refresh() }
    }
}

@MainActor
struct ThemePickerList: View {
    @ObservedObject var themes: ThemeManager = .shared

    var body: some View {
        List(themes.available, selection: Binding(get: { themes.current.id }, set: { themes.select($0) })) { theme in
            HStack {
                Text(theme.name)
                Spacer()
                if themes.current.id == theme.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .tag(theme.id)
        }
    }
}
