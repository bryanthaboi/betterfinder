import AppKit

@MainActor
final class RecentlyTrashedModel {
    let service: TrashService
    let activity: FileOperationQueue
    private(set) var entries: [TrashJournalEntry] = []

    init(service: TrashService, activity: FileOperationQueue? = nil) {
        self.service = service
        self.activity = activity ?? .shared
    }

    func reload() {
        entries = service.journal.entries()
    }

    func isAvailable(_ entry: TrashJournalEntry) -> Bool { FS.exists(entry.trashedURL) }

    func restorable(_ selection: [TrashJournalEntry]) -> [TrashJournalEntry] { selection.filter(isAvailable) }

    func conflicts(_ selection: [TrashJournalEntry]) -> [TrashJournalEntry] {
        restorable(selection).filter { FS.exists($0.originalURL) }
    }

    func putBack(_ selection: [TrashJournalEntry]) async -> PutBackReport {
        let urls = restorable(selection).map(\.trashedURL)
        let service = self.service
        let report = await activity.trackBackgroundMutation {
            await Task.detached { service.putBack(urls) }.value
        }
        reload()
        return report
    }

    static func summary(of report: PutBackReport) -> String {
        let restored = report.restored.count
        let failed = report.failures.count
        var parts: [String] = []
        if restored > 0 { parts.append("Put back \(restored) item\(restored == 1 ? "" : "s")") }
        if failed > 0 { parts.append("\(failed) couldn’t be put back") }
        return parts.isEmpty ? "Nothing was put back" : parts.joined(separator: ", ")
    }
}

@MainActor
final class RecentlyTrashedViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: RecentlyTrashedModel
    let table = NSTableView()
    let putBackButton = NSButton(title: "Put Back", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Nothing has been moved to the Trash with betterfinder yet.")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(model: RecentlyTrashedModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        for (id, title, width) in [("name", "Name", 180.0), ("location", "Original Location", 220.0), ("date", "Date Trashed", 140.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 80
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(putBack)
        table.setAccessibilityLabel("Recently trashed items")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        putBackButton.target = self
        putBackButton.action = #selector(putBack)
        putBackButton.bezelStyle = .rounded
        putBackButton.keyEquivalent = "\r"
        putBackButton.setAccessibilityLabel("Put Back Selected Items")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, refreshButton, putBackButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(footer)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
        ])
        view = root
        reload()
    }

    func reload() {
        model.reload()
        table.reloadData()
        emptyLabel.isHidden = !model.entries.isEmpty
        updateButtons()
    }

    var selectedEntries: [TrashJournalEntry] {
        table.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0] : nil }
    }

    private func updateButtons() {
        putBackButton.isEnabled = !model.restorable(selectedEntries).isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.entries.indices.contains(row), let column = tableColumn else { return nil }
        let entry = model.entries[row]
        let id = NSUserInterfaceItemIdentifier("cell-" + column.identifier.rawValue)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let available = model.isAvailable(entry)
        switch column.identifier.rawValue {
        case "name":
            cell.textField?.stringValue = available ? entry.originalURL.lastPathComponent : "\(entry.originalURL.lastPathComponent) (no longer in the Trash)"
        case "location":
            cell.textField?.stringValue = (entry.originalURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        default:
            cell.textField?.stringValue = dateFormatter.string(from: entry.date)
        }
        cell.textField?.textColor = available ? .labelColor : .secondaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc func refresh() {
        statusLabel.stringValue = ""
        reload()
    }

    @objc func putBack() {
        let selection = model.restorable(selectedEntries)
        guard !selection.isEmpty else { return }
        let conflicts = model.conflicts(selection)
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            let n = conflicts.count
            alert.messageText = n == 1
                ? "An item named “\(conflicts[0].originalURL.lastPathComponent)” already exists at its original location."
                : "\(n) items already exist at their original locations."
            alert.informativeText = "The items will be put back with new names so nothing is overwritten.\n\n" + conflicts.prefix(10).map { ($0.originalURL.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            alert.addButton(withTitle: "Put Back with New Names")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        putBackButton.isEnabled = false
        Task { @MainActor in
            let report = await model.putBack(selection)
            table.reloadData()
            emptyLabel.isHidden = !model.entries.isEmpty
            updateButtons()
            statusLabel.stringValue = RecentlyTrashedModel.summary(of: report)
            NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [
                .announcement: statusLabel.stringValue,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
            guard !report.failures.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(report.failures.count) item\(report.failures.count == 1 ? "" : "s") couldn’t be put back"
            alert.informativeText = report.failures.prefix(20).map { "\($0.trashed.lastPathComponent): \($0.error.localizedDescription)" }.joined(separator: "\n")
            alert.runModal()
        }
    }
}

@MainActor
public final class RecentlyTrashedWindowController: NSWindowController {
    public static let shared = RecentlyTrashedWindowController()

    private var content: RecentlyTrashedViewController?

    public convenience init() {
        self.init(service: .shared)
    }

    public convenience init(service: TrashService) {
        let vc = RecentlyTrashedViewController(model: RecentlyTrashedModel(service: service))
        let window = NSWindow(contentViewController: vc)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "Recently Trashed"
        window.setContentSize(NSSize(width: 560, height: 360))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RecentlyTrashedWindow")
        self.init(window: window)
        content = vc
    }

    public func show() {
        content?.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
