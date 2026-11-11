import AppKit
import FSCore
import FileOps
import SwiftUI
import Theming
import UniformTypeIdentifiers

@MainActor
final class InfoModel: ObservableObject {
    let url: URL
    @Published var name: String = ""
    @Published var kind: String = ""
    @Published var sizeText: String = "—"
    @Published var sizeDetail: String = ""
    @Published var whereText: String = ""
    @Published var created: Date?
    @Published var modified: Date?
    @Published var added: Date?
    @Published var tags: [String] = []
    @Published var apps: [URL] = []
    @Published var defaultApp: URL?
    @Published var chosenApp: URL?
    @Published var isFolder = false
    @Published var contentType: UTType?
    @Published var message: String?
    @Published var dimensions: String?
    @Published var icon: NSImage?
    @Published var nameLocked = false
    @Published var redactedName: String?
    @Published var volume: VolumeDetails?
    private var volumeTimer: Timer?
    private var sizeTask: Task<Void, Never>?
    static var announce: (String) -> Void = { message in
        AccessibilityNotification.Announcement(message).post()
    }

    init(url: URL) {
        self.url = url
        reload()
    }

    deinit {
        sizeTask?.cancel()
        let timer = volumeTimer
        if let timer { onMain { timer.invalidate() } }
    }

    private func reloadVolume(_ details: VolumeDetails, item: FileItem) {
        volume = details
        name = details.name
        nameLocked = true
        redactedName = nil
        kind = details.kindText
        icon = IconRaster.fileIcon(url.path, points: 48, scale: IconRaster.scale)
        whereText = details.mountPoint
        created = item.dateCreated
        modified = item.dateModified
        added = nil
        tags = []
        isFolder = true
        sizeTask?.cancel()
        sizeText = details.usedBytes.map { "\(SizeFormatter.string($0)) used" } ?? "—"
        sizeDetail = details.spaceText
        guard volumeTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let fresh = VolumeInfo.details(for: self.url), fresh != self.volume else { return }
                self.volume = fresh
                self.sizeText = fresh.usedBytes.map { "\(SizeFormatter.string($0)) used" } ?? "—"
                self.sizeDetail = fresh.spaceText
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeTimer = timer
    }

    func reload() {
        guard let item = DirectoryLister.item(for: url) else { message = "This item no longer exists."; return }
        if url.path == "/" || VolumeInfo.isVolumeRoot(url), let details = VolumeInfo.details(for: url) {
            reloadVolume(details, item: item)
            return
        }
        let home = HomeLabel.display
        nameLocked = home.isActive && home.isHome(url.path)
        redactedName = HomeLabel.isRedacted(url) ? item.name : nil
        name = home.name(item.name, forPath: url.path)
        kind = item.kindDescription
        icon = IconRaster.fileIcon(url.path, points: 48, scale: IconRaster.scale)
        whereText = url.deletingLastPathComponent().abbreviatedPath
        created = item.dateCreated
        modified = item.dateModified
        added = item.dateAdded
        tags = item.tagNames
        isFolder = item.isBrowsableFolder
        contentType = item.contentType
        if let d = DimensionsCache.shared.dimensions(for: item) { dimensions = "\(Int(d.width)) × \(Int(d.height))" }
        if !isFolder {
            apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            chosenApp = defaultApp
        }
        if item.isBrowsableFolder || item.isPackage {
            sizeText = "calculating…"
            sizeTask?.cancel()
            let name = home.accessibilityName(item.name, forPath: url.path)
            sizeTask = Task { [weak self] in
                var sawProgress = false
                var announced = false
                for await r in await SizeEngine.shared.size(of: item.url) {
                    guard let self, !Task.isCancelled else { return }
                    self.applySize(r, name: name, sawProgress: &sawProgress, announced: &announced)
                }
            }
        } else {
            let l = item.logicalSize ?? 0
            sizeText = "\(SizeFormatter.string(l)) (\(SizeFormatter.exact(l)))"
            sizeDetail = item.allocatedSize.map { "\(SizeFormatter.string($0)) on disk" } ?? ""
        }
    }

    func applySize(_ r: SizeResult, name: String, sawProgress: inout Bool, announced: inout Bool) {
        let finished = r.isSettled
        let size = "\(SizeFormatter.string(r.allocatedBytes)) on disk"
        sizeText = size + (finished ? (r.isUnreadable ? " (some items unreadable)" : "") : "…")
        sizeDetail = "\(SizeFormatter.exact(r.logicalBytes)) logical · \(r.itemCount.formatted()) items"
        guard finished else { sawProgress = true; return }
        guard sawProgress, !announced else { return }
        announced = true
        Self.announce("\(name), \(size), calculation complete\(r.isUnreadable ? ", some items unreadable" : "")")
    }

    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nameLocked, trimmed != url.lastPathComponent else { return }
        if let problem = RenameSession.validate(trimmed, renaming: url), !problem.hasPrefix("Names starting") {
            message = problem
            return
        }
        let url = url
        Task { [weak self] in
            do {
                let new = try await FileActions.renameAsync(url, to: trimmed)
                self?.message = nil
                InfoPanelController.replace(url, with: new)
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    func setTags(_ new: [String]) {
        let url = url
        Task { [weak self] in
            do {
                try await TagOps.setTagsAsync(new, for: url)
                self?.tags = new
                BrowserDefaults.noteTags(new)
                self?.message = nil
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    func openWithChanged(_ app: URL?) {
        guard let app, app != defaultApp else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: url) { [weak self] err in
            onMain {
                if let err { self?.message = err.localizedDescription } else { self?.defaultApp = app }
            }
        }
    }

    func changeAll() {
        guard let app = chosenApp, let type = contentType else { return }
        let alert = NSAlert()
        alert.messageText = "Open all “\(type.localizedDescription ?? type.identifier)” files with \(FileManager.default.displayName(atPath: app.path))?"
        alert.informativeText = "This applies to every document of this kind."
        alert.addButton(withTitle: "Change All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { [weak self] err in
            onMain {
                if let err { self?.message = err.localizedDescription } else { self?.defaultApp = app; self?.message = "Changed." }
            }
        }
    }
}

struct InfoView: View {
    @ObservedObject var model: InfoModel
    var scrolls = true
    @State private var editingName: String = ""
    @State private var newTag: String = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.vertical) { content }
            } else {
                content
            }
        }
        .frame(width: Spacing.infoPanelWidth)
        .onAppear { editingName = model.name }
        .onChange(of: model.name) { _, v in editingName = v }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionGap) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(nsImage: model.icon ?? NSImage())
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.relatedText) {
                    if let hidden = model.redactedName {
                        Text(hidden).font(.headline).lineLimit(1).blur(radius: 6)
                            .accessibilityLabel("Name: \(HomeNameDisplay.redactedAccessibilityName)")
                    } else if model.nameLocked {
                        Text(model.name).font(.headline).lineLimit(1)
                            .accessibilityLabel("Name: \(model.name)")
                    } else {
                        TextField("Name", text: $editingName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.rename(to: editingName) }
                            .accessibilityLabel("Name")
                    }
                    Text(model.kind).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Kind: \(model.kind)")
                }
            }
            if let m = model.message {
                Text(m).font(.caption).foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Divider()
            if let volume = model.volume, let fraction = volume.usedFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Space used")
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent, \(volume.spaceText)")
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.xs) {
                if let volume = model.volume {
                    if let total = volume.totalBytes { row("Capacity", SizeFormatter.string(total), detail: SizeFormatter.exact(total)) }
                    if let free = volume.availableBytes { row("Available", SizeFormatter.string(free), detail: SizeFormatter.exact(free)) }
                    if let used = volume.usedBytes { row("Used", SizeFormatter.string(used), detail: volume.usedFraction.map { "\(Int(($0 * 100).rounded()))% of capacity" } ?? "") }
                    if !volume.format.isEmpty { row("Format", volume.format) }
                    row("Mounted at", volume.mountPoint)
                    if !volume.device.isEmpty { row("Device", volume.device) }
                    row("Access", volume.isReadOnly ? "Read only" : "Read and write", detail: volume.isEjectable ? "Can be ejected" : "")
                } else {
                    row("Size", model.sizeText, detail: model.sizeDetail)
                    row("Where", model.whereText)
                }
                if let d = model.dimensions { row("Dimensions", d) }
                if let d = model.created { row("Created", Self.dateFormatter.string(from: d)) }
                if let d = model.modified { row("Modified", Self.dateFormatter.string(from: d)) }
                if let d = model.added { row("Added", Self.dateFormatter.string(from: d)) }
            }
            if model.volume == nil {
                Divider()
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Tags").font(.headline).accessibilityAddTraits(.isHeader)
                    FlowTags(tags: model.tags) { t in model.setTags(model.tags.filter { $0 != t }) }
                    HStack {
                        TextField("Add tag", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTag)
                            .accessibilityLabel("Add tag")
                        Menu("Choose") {
                            ForEach(MainActor.assumeIsolated { TagColors.systemTags } + BrowserDefaults.knownTags.filter { !TagColors.systemTags.contains($0) }, id: \.self) { t in
                                Button(t) { if !model.tags.contains(t) { model.setTags(model.tags + [t]) } }
                            }
                        }
                        .fixedSize()
                        .accessibilityLabel("Choose a tag")
                    }
                }
            }
            if !model.isFolder && !model.apps.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Open with").font(.headline).accessibilityAddTraits(.isHeader)
                    Picker("Open with", selection: Binding(get: { model.chosenApp }, set: { model.chosenApp = $0; model.openWithChanged($0) })) {
                        ForEach(model.apps, id: \.self) { app in
                            Text(FileManager.default.displayName(atPath: app.path) + (app == model.defaultApp ? " (default)" : "")).tag(Optional(app))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Open with")
                    HStack {
                        Text("Use this app to open all documents like this one.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Change All…") { model.changeAll() }
                            .disabled(model.contentType == nil)
                    }
                }
            }
        }
        .padding(Spacing.dialogMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !t.isEmpty, !model.tags.contains(t) else { return }
        model.setTags(model.tags + [t])
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, detail: String = "") -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: Spacing.relatedText) {
                Text(value).textSelection(.enabled)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(detail.isEmpty ? value : "\(value), \(detail)")
    }
}

struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("No tags").font(.caption).foregroundStyle(.secondary)
        } else {
            WrappingLayout(spacing: Spacing.xs) {
                ForEach(tags, id: \.self) { t in
                    HStack(spacing: Spacing.xxs) {
                        Circle().fill(Color(nsColor: MainActor.assumeIsolated { TagColors.color(for: t) } ?? .tertiaryLabelColor)).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(t).font(.caption).lineLimit(1).truncationMode(.middle).accessibilityLabel("Tag \(t)")
                        Button { onRemove(t) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(t)")
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs / 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        }
    }
}

struct WrappingLayout: Layout {
    var spacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var size = v.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !rows[rows.count - 1].isEmpty, x + spacing + size.width > width {
                rows.append([])
                x = 0
            }
            x += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((i, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for (n, row) in rows.enumerated() {
            let rowWidth = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            widest = max(widest, rowWidth)
            height += (row.map(\.size.height).max() ?? 0) + (n > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

@MainActor
final class InfoPanelController: NSWindowController, NSWindowDelegate {
    private static var open: [String: InfoPanelController] = [:]
    let model: InfoModel

    init(url: URL) {
        model = InfoModel(url: url)
        let host = NSHostingController(rootView: InfoView(model: model))
        host.sizingOptions = []
        let ideal = NSHostingView(rootView: InfoView(model: model, scrolls: false)).fittingSize
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        let size = NSSize(width: Spacing.infoPanelWidth, height: max(Self.minimumHeight, min(ideal.height, available)))
        host.view.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .utilityWindow, .resizable]
        panel.setContentSize(size)
        panel.contentMinSize = NSSize(width: Spacing.infoPanelWidth, height: Self.minimumHeight)
        panel.contentMaxSize = NSSize(width: Spacing.infoPanelWidth, height: .greatestFiniteMagnitude)
        panel.title = "\(HomeLabel.name(url.lastPathComponent, for: url)) Info"
        panel.setAccessibilityLabel("\(HomeLabel.accessibilityName(url.lastPathComponent, for: url)) Info")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    static let minimumHeight: CGFloat = 200

    static func show(_ urls: [URL]) {
        var offset: CGFloat = 0
        for u in urls.prefix(10) {
            let key = u.pathKey
            if let existing = open[key] {
                existing.model.reload()
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            let c = InfoPanelController(url: u)
            open[key] = c
            if let w = c.window {
                w.center()
                w.setFrameOrigin(NSPoint(x: w.frame.minX + offset, y: w.frame.minY - offset))
            }
            offset += 22
            c.showWindow(nil)
        }
    }

    static func replace(_ old: URL, with new: URL) {
        guard let c = open.removeValue(forKey: old.pathKey) else { return }
        c.window?.close()
        show([new])
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[model.url.pathKey] = nil
    }
}
