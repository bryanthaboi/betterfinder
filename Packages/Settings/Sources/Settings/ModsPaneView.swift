import AppKit
import SwiftUI
import Theming

public struct ModsPaneView: View {
    @ObservedObject var model: ModsPaneModel
    @State private var uninstallTarget: InstalledMod?
    @State private var deleteDataOnUninstall = false

    public init(model: ModsPaneModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.control) {
                Picker("Section", selection: $model.section) {
                    ForEach(ModsPaneModel.Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    Task { await model.reloadAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("Reload installed mods and the mod index")
                .accessibilityLabel("Refresh mods and index")
                if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing mods") }
            }
            .padding(Spacing.containerPadding)
            Divider()
            switch model.section {
            case .installed: InstalledModsView(model: model, uninstallTarget: $uninstallTarget)
            case .browse: IndexBrowserView(model: model)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await model.reloadAll()
        }
        .sheet(isPresented: Binding(get: { !model.phase.isIdle }, set: { if !$0 { model.cancelFlow() } })) {
            ModInstallFlowSheet(model: model)
        }
        .alert("Mods", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            "Uninstall \"\(uninstallTarget?.title ?? "")\"?",
            isPresented: Binding(get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let mod = uninstallTarget { Task { await model.uninstall(mod.id, deleteData: false) } }
                uninstallTarget = nil
            }
            Button("Uninstall and Delete Its Data", role: .destructive) {
                if let mod = uninstallTarget { Task { await model.uninstall(mod.id, deleteData: true) } }
                uninstallTarget = nil
            }
            Button("Cancel", role: .cancel) { uninstallTarget = nil }
        } message: {
            Text("Its settings and saved secrets are kept unless you delete them.")
        }
    }
}

struct InstalledModsView: View {
    @ObservedObject var model: ModsPaneModel
    @Binding var uninstallTarget: InstalledMod?

    var body: some View {
        Group {
            switch model.installedState {
            case .idle where model.installed.isEmpty, .loading where model.installed.isEmpty:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where model.installed.isEmpty:
                ErrorState(message: message) { Task { await model.reloadInstalled() } }
            default:
                if model.installed.isEmpty {
                    EmptyState(symbol: "puzzlepiece.extension", title: "No mods installed", detail: "Browse the index to find some. Nothing is enabled automatically.")
                } else {
                    List {
                        ForEach(model.installed) { mod in
                            InstalledModRow(model: model, mod: mod, uninstallTarget: $uninstallTarget)
                        }
                    }
                }
            }
        }
    }
}

struct InstalledModRow: View {
    @ObservedObject var model: ModsPaneModel
    let mod: InstalledMod
    @Binding var uninstallTarget: InstalledMod?
    @State private var showDiagnostics = false

    var body: some View {
        let busy = model.busyModIDs.contains(mod.id)
        let blockReason = model.enableBlockReason(for: mod)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    HStack(spacing: Spacing.xs) {
                        Text(mod.title).font(.headline)
                        Text("v\(mod.version)").font(.caption).foregroundStyle(.secondary)
                        if mod.isLocalDevelopment { Badge(text: "Local", color: .purple) }
                    }
                    Text(mod.author).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Toggle("Enabled", isOn: Binding(
                    get: { mod.isEnabled },
                    set: { value in Task { await model.setEnabled(mod.id, value) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(busy || (!mod.isEnabled && blockReason != nil))
                .help(mod.isEnabled ? "Disable" : (blockReason ?? "Enable"))
                .accessibilityLabel("Enable \(mod.title)")
            }

            PreflightBadgeRow(result: mod.lastPreflight, blockReason: mod.isEnabled ? nil : blockReason, showDiagnostics: $showDiagnostics)
            if showDiagnostics, let result = mod.lastPreflight {
                DiagnosticsList(result: result)
            }
            PermissionChips(permissions: mod.permissions)

            HStack(spacing: Spacing.s) {
                Button("Run Preflight") { Task { await model.runPreflight(mod.id) } }.disabled(busy)
                if let update = mod.availableUpdate {
                    let updateBlock = model.updateBlockReason(for: mod)
                    Button("Update to v\(update.version)") { model.beginUpdate(mod.id) }
                        .disabled(updateBlock != nil)
                        .help(updateBlock ?? "Update \(mod.title)")
                    if let updateBlock {
                        Text(updateBlock).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if mod.folderURL != nil {
                    Button("Show Folder") { model.showFolder(for: mod) }
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { uninstallTarget = mod }.disabled(busy)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.vertical, Spacing.xs)
    }
}

struct PreflightBadgeRow: View {
    let result: PreflightResultSummary?
    let blockReason: String?
    @Binding var showDiagnostics: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let result {
                Image(systemName: result.allowsEnable ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.allowsEnable ? .green : .red)
                Text(result.headline).font(.callout)
                if let ran = result.ranAt {
                    Text(ran, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                if !result.diagnostics.isEmpty {
                    Button(showDiagnostics ? "Hide Diagnostics" : "Diagnostics (\(result.diagnostics.count))") { showDiagnostics.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } else {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                Text("Not checked yet").font(.callout)
            }
            if let blockReason {
                Text("· \(blockReason)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DiagnosticsList: View {
    let result: PreflightResultSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            if !result.checks.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.control, alignment: .leading)], alignment: .leading, spacing: Spacing.relatedText) {
                    ForEach(result.checks) { check in
                        Badge(text: "\(check.name): \(check.state.rawValue)", color: color(check.state))
                    }
                }
            }
            ForEach(result.diagnostics.sorted { $0.severity > $1.severity }) { d in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(d.severity)).foregroundStyle(color(d.severity))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(d.code)  \(d.message)").font(.callout).fixedSize(horizontal: false, vertical: true)
                        if d.file != nil || d.pointer != nil {
                            Text([d.file, d.pointer].compactMap { $0 }.joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let fix = d.fix { Text("Fix: \(fix)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func icon(_ s: PreflightDiagnostic.Severity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(_ s: PreflightDiagnostic.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    private func color(_ s: PreflightCheck.State) -> Color {
        switch s {
        case .pass: return .green
        case .fail: return .red
        case .skipped, .notRun: return .orange
        }
    }
}

struct PermissionChips: View {
    let permissions: [PermissionSummary]

    var body: some View {
        if permissions.isEmpty {
            Text("No special permissions").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.relatedText) {
                Text("Permissions").font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                PermissionList(permissions: permissions)
            }
        }
    }
}

struct IndexBrowserView: View {
    @ObservedObject var model: ModsPaneModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                listPane
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            ModListingDetailView(model: model)
                .frame(minWidth: 380)
        }
    }

    private var filterBar: some View {
        VStack(spacing: Spacing.xs) {
            TextField("Search mods", text: $model.search)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Category", selection: $model.categoryFilter) {
                    Text("All Categories").tag(String?.none)
                    ForEach(model.categories, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
                .labelsHidden()
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(ModsPaneModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            HStack {
                Toggle("Compatible only", isOn: $model.compatibleOnly).toggleStyle(.checkbox).font(.caption)
                Spacer()
                if let snapshot = model.indexSnapshot, snapshot.isExpired || snapshot.isOffline {
                    Badge(text: snapshot.isExpired ? "Index expired" : "Offline", color: .orange)
                }
            }
            if let error = model.indexRefreshError {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Couldn’t refresh: \(error). Showing the last loaded index.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await model.reloadIndex() } }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(Spacing.containerPadding)
    }

    @ViewBuilder
    private var listPane: some View {
        switch model.indexState {
        case .idle where model.listings.isEmpty, .loading where model.listings.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.listings.isEmpty:
            ErrorState(message: message) { Task { await model.reloadIndex() } }
        default:
            let items = model.filteredListings
            if items.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Try a different search or category.")
            } else {
                List(items, selection: $model.selectedListingID) { listing in
                    ListingRow(listing: listing, installed: model.isInstalled(listing)).tag(listing.id)
                }
            }
        }
    }
}

struct ListingRow: View {
    let listing: ModListing
    let installed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.relatedText) {
            HStack {
                Text(listing.title).font(.headline).lineLimit(1)
                Spacer()
                if installed { Badge(text: "Installed", color: .green) }
                else if !listing.isCompatible { Badge(text: "Incompatible", color: .gray) }
            }
            Text("\(listing.author) · v\(listing.version)").font(.caption).foregroundStyle(.secondary)
            if !listing.summary.isEmpty { Text(listing.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.xxs)
    }
}

struct ModListingDetailView: View {
    @ObservedObject var model: ModsPaneModel

    var body: some View {
        if let listing = model.selectedListing {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Spacing.relatedText) {
                            Text(listing.title).font(.title2.bold())
                            Text("\(listing.author) · v\(listing.version)").foregroundStyle(.secondary)
                            if !listing.categories.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: Spacing.control, alignment: .leading)], alignment: .leading, spacing: Spacing.relatedText) {
                                    ForEach(listing.categories, id: \.self) { Badge(text: $0.capitalized, color: .blue) }
                                }
                            }
                        }
                        Spacer()
                        installControl(listing)
                    }
                    if let note = listing.compatibilityNote, !listing.isCompatible {
                        Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    GroupBox("Permissions") { PermissionList(permissions: listing.permissions).frame(maxWidth: .infinity, alignment: .leading) }
                    GroupBox("About") { MarkdownLiteView(text: listing.readme.isEmpty ? listing.summary : listing.readme).frame(maxWidth: .infinity, alignment: .leading) }
                    if !listing.versions.isEmpty {
                        GroupBox("Versions") {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                ForEach(listing.versions) { v in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("v\(v.version)").font(.callout.monospacedDigit())
                                        if !v.isCompatible { Badge(text: "Incompatible", color: .gray) }
                                        if let notes = v.notes { Text(notes).font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        if let date = v.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let repo = listing.repoURL {
                        Link("Source repository", destination: repo).font(.callout)
                    }
                }
                .padding(Spacing.dialogMargin)
            }
        } else {
            EmptyState(symbol: "square.stack.3d.up", title: "Select a mod", detail: "Details, permissions and versions appear here.")
        }
    }

    @ViewBuilder
    private func installControl(_ listing: ModListing) -> some View {
        let reason = model.installBlockReason(for: listing)
        VStack(alignment: .trailing, spacing: 3) {
            Button(model.isInstalled(listing) ? "Installed" : "Install…") { model.beginInstall(listing) }
                .buttonStyle(.borderedProminent)
                .disabled(reason != nil)
            if let reason, !model.isInstalled(listing) { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct PermissionList: View {
    let permissions: [PermissionSummary]

    var body: some View {
        if permissions.isEmpty {
            Text("This mod requests no permissions.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(permissions) { p in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(p.risk)).foregroundStyle(color(p.risk)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(p.title).font(.callout.weight(.semibold))
                                Badge(text: p.risk.label, color: color(p.risk))
                            }
                            Text(p.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func icon(_ r: PermissionSummary.Risk) -> String {
        switch r {
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ r: PermissionSummary.Risk) -> Color {
        switch r {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

struct ModInstallFlowSheet: View {
    @ObservedObject var model: ModsPaneModel
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionGap) {
            switch model.phase {
            case .idle:
                EmptyView()
            case .reviewingPermissions(let op):
                header(op)
                if op.permissionsToReview.isEmpty {
                    Text(op.listing.permissions.isEmpty ? "This mod requests no permissions." : "No new permissions beyond what's already granted.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(isUpdate(op) ? "This update asks for new permissions:" : "This mod is asking for:").font(.callout)
                    ScrollView { PermissionList(permissions: op.permissionsToReview).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 260)
                }
                Text("Nothing runs until the mod passes preflight and you enable it.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelFlow() }.keyboardShortcut(.cancelAction)
                    Button(isUpdate(op) ? "Allow and Update" : "Allow and Install") { Task { await model.approveAndRun() } }
                        .keyboardShortcut(.defaultAction)
                }
            case .installing(let op):
                header(op)
                ProgressRow(text: isUpdate(op) ? "Downloading and verifying update…" : "Downloading and verifying…",
                            label: "\(isUpdate(op) ? "Updating" : "Installing") \(op.listing.title)")
            case .preflighting(let id):
                heading(headingText ?? "")
                ProgressRow(text: "Checking the mod against the shared validator…", label: "Running preflight for \(model.installedMod(id: id)?.title ?? id)")
            case .refused(let op, let result):
                heading(headingText ?? "")
                Label(result.headline, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                ScrollView { DiagnosticsList(result: result) }.frame(maxHeight: 240)
                Text(isUpdate(op) ? "\(op.listing.title) failed preflight, so nothing changed. The installed version keeps working." : "\(op.listing.title) failed preflight, so nothing was installed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.reportText(title: op.listing.title), forType: .string)
                    }
                    Spacer()
                    Button("Close") { model.cancelFlow() }.keyboardShortcut(.defaultAction)
                }
            case .finished(let id, let result):
                heading(headingText ?? "")
                Label(result.headline, systemImage: result.allowsEnable ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.allowsEnable ? .green : .red)
                if !result.diagnostics.isEmpty || !result.checks.isEmpty {
                    ScrollView { DiagnosticsList(result: result) }.frame(maxHeight: 240)
                }
                if !result.allowsEnable {
                    Text("\(model.installedMod(id: id)?.title ?? id) stays installed but disabled until every error is fixed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(result.allowsEnable ? "Not Now" : "Close") { model.cancelFlow() }.keyboardShortcut(.cancelAction)
                    Button("Enable") { Task { await model.enableFinishedMod() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.finishedModCanBeEnabled)
                }
            case .failed(let message, _):
                heading(headingText ?? "")
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { model.cancelFlow() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(model.phase.isBusy)
        .onChange(of: ModFlowPhaseKey(model.phase)) { _, key in
            headingFocused = true
            if let headingText { model.headingFocusRequested(headingText) }
            if let text = key.announcement { model.announce(text) }
        }
    }

    private var headingText: String? {
        switch model.phase {
        case .idle: return nil
        case .reviewingPermissions(let op), .installing(let op): return "\(isUpdate(op) ? "Update" : "Install") \(op.listing.title)"
        case .preflighting: return "Running preflight"
        case .refused(let op, _): return isUpdate(op) ? "Update refused" : "Can't install \(op.listing.title)"
        case .finished(_, let result): return result.allowsEnable ? "Ready to enable" : "Can't be enabled"
        case .failed: return "Something went wrong"
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headingFocused)
    }

    private func isUpdate(_ op: ModsPaneModel.Operation) -> Bool {
        if case .update = op.kind { return true }
        return false
    }

    private func header(_ op: ModsPaneModel.Operation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(headingText ?? "")
            Text("\(op.listing.author) · v\(op.listing.version)").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ProgressRow: View {
    let text: String
    var label: String?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).accessibilityLabel(label ?? text)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct ModFlowPhaseKey: Equatable {
    var kind: String
    var announcement: String?

    init(_ phase: ModsPaneModel.Phase) {
        switch phase {
        case .idle: kind = "idle"; announcement = nil
        case .reviewingPermissions(let op): kind = "review:\(op.listing.id)"; announcement = nil
        case .installing(let op): kind = "installing:\(op.listing.id)"; announcement = nil
        case .preflighting(let id): kind = "preflight:\(id)"; announcement = nil
        case .finished(let id, let result): kind = "finished:\(id)"; announcement = result.allowsEnable ? "Preflight passed. Ready to enable." : "Preflight finished. \(result.headline)"
        case .failed(let message, let modID): kind = "failed"; announcement = modID == nil ? "Install failed. \(message)" : "Something went wrong. \(message)"
        case .refused(let op, let result): kind = "refused:\(op.listing.id)"; announcement = "\(op.listing.title) failed preflight. \(result.headline)"
        }
    }
}

@MainActor
enum ModsAnnouncer {
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 32)).foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Try Again", action: retry)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MarkdownLiteView: View {
    let text: String

    private struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
        enum Kind { case heading(Int), bullet, body, blank }
    }

    private var lines: [Line] {
        text.components(separatedBy: "\n").enumerated().map { i, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return Line(id: i, kind: .blank, text: "") }
            if let r = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                let level = trimmed[r].dropLast().count
                return Line(id: i, kind: .heading(level), text: String(trimmed[r.upperBound...]))
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return Line(id: i, kind: .bullet, text: String(trimmed.dropFirst(2))) }
            return Line(id: i, kind: .body, text: trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                switch line.kind {
                case .blank: Spacer().frame(height: 4)
                case .heading(let level): inline(line.text).font(level == 1 ? .title3.bold() : .headline)
                case .bullet: HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(line.text) }
                case .body: inline(line.text)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: s, options: options) { return Text(attributed) }
        return Text(s)
    }
}
