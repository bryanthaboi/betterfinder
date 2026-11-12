import AppKit
import Combine
import FSCore
import FileOps

@MainActor
final class JunkCleanupModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case cleaning(String)
        case unavailable
    }

    struct Outcome: Equatable {
        var trashed = 0
        var removedFolders = 0
        var emptiedTrash = 0
        var failed = 0

        var summary: String {
            var parts: [String] = []
            if trashed > 0 { parts.append("Moved \(trashed.formatted()) item\(trashed == 1 ? "" : "s") to the Trash") }
            if removedFolders > 0 { parts.append("removed \(removedFolders.formatted()) empty folder\(removedFolders == 1 ? "" : "s")") }
            if emptiedTrash > 0 { parts.append("erased \(emptiedTrash.formatted()) item\(emptiedTrash == 1 ? "" : "s") from the Trash") }
            if failed > 0 { parts.append("\(failed.formatted()) couldn’t be cleaned") }
            guard let first = parts.first else { return "Nothing was cleaned up." }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ") + "."
        }
    }

    private(set) var groups: [JunkGroup] = []
    private(set) var checked = Set<String>()
    private(set) var phase: Phase = .idle
    var home: URL = DemoEnvironment.home
    var databaseURL: () -> URL = { SizeEngine.shared.indexLocation }
    var trashItems: @MainActor ([URL]) async -> (moved: Int, failed: Int) = JunkCleanupModel.trashThroughQueue
    var emptyTrash: @MainActor () async -> Int? = { await TrashUI.confirmAndEmptyTrash()?.removedCount }
    var onChange: (() -> Void)?
    private var tree: SizeIndexTree?
    private var cancelled = false

    var items: [JunkItem] { groups.flatMap(\.items) }
    var checkedItems: [JunkItem] { items.filter { checked.contains($0.id) } }
    var checkedBytes: Int64 { checkedItems.reduce(0) { $0 + $1.bytes } }
    var checkedEmptyFolders: Int { checkedItems.reduce(0) { $0 + $1.emptyFolderCount } }

    func isChecked(_ item: JunkItem) -> Bool { checked.contains(item.id) }

    func state(of group: JunkGroup) -> NSControl.StateValue {
        let count = group.items.filter { checked.contains($0.id) }.count
        return count == 0 ? .off : (count == group.items.count ? .on : .mixed)
    }

    func setChecked(_ value: Bool, item: JunkItem) {
        if value { checked.insert(item.id) } else { checked.remove(item.id) }
        onChange?()
    }

    func setChecked(_ value: Bool, group: JunkGroup) {
        for item in group.items { if value { checked.insert(item.id) } else { checked.remove(item.id) } }
        onChange?()
    }

    var selectionSummary: String {
        let picked = checkedItems
        guard !picked.isEmpty else {
            let total = groups.reduce(Int64(0)) { $0 + $1.bytes }
            return groups.isEmpty ? "" : "\(SizeFormatter.string(total)) found. Tick what you want gone."
        }
        var parts = ["\(picked.count.formatted()) selected"]
        if checkedBytes > 0 { parts.append(SizeFormatter.string(checkedBytes)) }
        if checkedEmptyFolders > 0 { parts.append("\(checkedEmptyFolders.formatted()) empty folders") }
        return parts.joined(separator: " · ")
    }

    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        onChange?()
        let database = databaseURL()
        let home = home
        let result = await Task.detached(priority: .userInitiated) { () -> (SizeIndexTree, [JunkGroup])? in
            guard let tree = try? SizeIndexTree(databaseURL: database), !tree.statistics().roots.isEmpty else { return nil }
            return (tree, JunkScanner(home: home).scan(tree))
        }.value
        guard let result else {
            tree = nil
            groups = []
            checked = []
            phase = .unavailable
            onChange?()
            return
        }
        tree = result.0
        groups = result.1
        checked = checked.intersection(Set(items.map(\.id)))
        phase = .ready
        onChange?()
    }

    func cancel() { cancelled = true }

    func clean() async -> Outcome {
        let picked = checkedItems
        guard !picked.isEmpty, phase == .ready else { return Outcome() }
        cancelled = false
        var outcome = Outcome()
        let toTrash = picked.filter { $0.action == .trash }.map(\.url)
        if !toTrash.isEmpty {
            phase = .cleaning("Moving \(toTrash.count.formatted()) item\(toTrash.count == 1 ? "" : "s") to the Trash…")
            onChange?()
            let result = await trashItems(toTrash)
            outcome.trashed += result.moved
            outcome.failed += result.failed
        }
        if let tree {
            for item in picked where item.emptyFolderCount > 0 && !cancelled {
                phase = .cleaning("Removing empty folders in \(item.title)…")
                onChange?()
                let url = item.url
                let flag = CancelFlag()
                let watcher = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        if self?.cancelled == true { flag.cancel() }
                    }
                }
                let removed = await Task.detached(priority: .userInitiated) {
                    JunkScanner.removeEmptyFolders(in: url, tree: tree, isCancelled: { flag.isCancelled })
                }.value
                watcher.cancel()
                outcome.removedFolders += removed
                SizeEngine.shared.refresh(paths: [url.path])
            }
        }
        if picked.contains(where: { $0.action == .emptyTrash }), !cancelled {
            phase = .cleaning("Emptying the Trash…")
            onChange?()
            outcome.emptiedTrash += await emptyTrash() ?? 0
        }
        checked.removeAll()
        phase = .ready
        onChange?()
        return outcome
    }

    static func trashThroughQueue(_ urls: [URL]) async -> (moved: Int, failed: Int) {
        let operation = FileOperationQueue.shared.enqueue(.trash(items: urls))
        var bag = Set<AnyCancellable>()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            operation.$state.sink { state in
                switch state {
                case .finished, .failed, .cancelled:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                default: break
                }
            }.store(in: &bag)
        }
        bag.removeAll()
        let failed = min(urls.count, operation.errors.count + operation.skippedCount)
        return (urls.count - failed, failed)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

final class JunkRowView: NSTableCellView {
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let amount = NSTextField(labelWithString: "")
    var onToggle: ((Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.target = self
        check.action = #selector(toggled)
        check.allowsMixedState = true
        title.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        amount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        amount.alignment = .right
        for view in [check, title, detail, amount] as [NSView] { addSubview(view) }
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() {
        if check.state == .mixed { check.state = .on }
        onToggle?(check.state == .on)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        check.frame = NSRect(x: 2, y: ((h - 18) / 2).rounded(), width: 20, height: 18)
        let amountWidth: CGFloat = 150
        amount.frame = NSRect(x: bounds.width - amountWidth - 8, y: ((h - 16) / 2).rounded(), width: amountWidth, height: 16)
        let width = max(0, amount.frame.minX - 34)
        title.frame = NSRect(x: 26, y: h / 2 - 1, width: width, height: 16)
        detail.frame = NSRect(x: 26, y: h / 2 - 15, width: width, height: 14)
    }
}

@MainActor
final class JunkCleanupViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: JunkCleanupModel
    let outline = NSOutlineView()
    let statusLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let rescanButton = NSButton(title: "Scan Again", target: nil, action: nil)
    let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    let cleanButton = NSButton(title: "Clean Up…", target: nil, action: nil)
    private var lastOutcome: String?

    private final class GroupRef: NSObject {
        let id: String
        init(_ id: String) { self.id = id }
    }

    private final class ItemRef: NSObject {
        let id: String
        init(_ id: String) { self.id = id }
    }

    private var groupRefs: [GroupRef] = []
    private var itemRefs: [String: [ItemRef]] = [:]

    init(model: JunkCleanupModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("junk"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .fullWidth
        outline.rowHeight = 38
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Junk found")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [(rescanButton, #selector(rescan)), (revealButton, #selector(reveal)), (cleanButton, #selector(clean))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        cleanButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spinner, statusLabel, rescanButton, revealButton, cleanButton])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [scroll, footer, emptyLabel] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = container
        model.onChange = { [weak self] in self?.render(structureChanged: false) }
        render(structureChanged: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        rescan()
    }

    private func rebuildRefs() {
        groupRefs = model.groups.map { GroupRef($0.id) }
        itemRefs = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.id, $0.items.map { ItemRef($0.id) }) })
    }

    private var shownStructure: [String] = []

    func render(structureChanged: Bool) {
        let structure = model.groups.flatMap { [$0.id] + $0.items.map(\.id) }
        if structureChanged || structure != shownStructure {
            shownStructure = structure
            rebuildRefs()
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
        } else {
            let rows = outline.numberOfRows
            if rows > 0 { outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows), columnIndexes: [0]) }
        }
        switch model.phase {
        case .scanning:
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Looking for junk…"
        case .cleaning(let text):
            spinner.startAnimation(nil)
            statusLabel.stringValue = text
        case .unavailable:
            spinner.stopAnimation(nil)
            statusLabel.stringValue = ""
        case .idle, .ready:
            spinner.stopAnimation(nil)
            statusLabel.stringValue = model.checkedItems.isEmpty ? (lastOutcome ?? model.selectionSummary) : model.selectionSummary
        }
        switch model.phase {
        case .unavailable: emptyLabel.stringValue = "The file index isn’t available yet, so there’s nothing to check."
        case .ready where model.groups.isEmpty: emptyLabel.stringValue = "No junk found."
        default: emptyLabel.stringValue = ""
        }
        emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
        let busy = model.phase == .scanning || { if case .cleaning = model.phase { return true }; return false }()
        rescanButton.isEnabled = !busy
        cleanButton.isEnabled = !busy && !model.checkedItems.isEmpty
        revealButton.isEnabled = selectedItem != nil
    }

    private var selectedItem: JunkItem? {
        guard let ref = outline.item(atRow: outline.selectedRow) as? ItemRef else { return nil }
        return model.items.first { $0.id == ref.id }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groupRefs.count }
        if let group = item as? GroupRef { return itemRefs[group.id]?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? GroupRef { return itemRefs[group.id]![index] }
        return groupRefs[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is GroupRef }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("junk-row")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? JunkRowView) ?? JunkRowView(identifier: id)
        if let ref = item as? GroupRef, let group = model.groups.first(where: { $0.id == ref.id }) {
            cell.title.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.title.stringValue = group.title
            cell.detail.stringValue = group.explanation
            cell.amount.stringValue = Self.amount(bytes: group.bytes, folders: group.items.reduce(0) { $0 + $1.emptyFolderCount })
            cell.amount.textColor = .labelColor
            cell.check.state = model.state(of: group)
            cell.onToggle = { [weak self] value in self?.model.setChecked(value, group: group) }
            cell.toolTip = group.explanation
        } else if let ref = item as? ItemRef, let entry = model.items.first(where: { $0.id == ref.id }) {
            cell.title.font = .systemFont(ofSize: 12)
            cell.title.stringValue = entry.title
            cell.detail.stringValue = entry.detail
            cell.amount.stringValue = Self.amount(bytes: entry.bytes, folders: entry.emptyFolderCount)
            cell.amount.textColor = HeatScale.level(entry.bytes) >= 6 ? HeatScale.color(level: HeatScale.level(entry.bytes)) : .secondaryLabelColor
            cell.check.state = model.isChecked(entry) ? .on : .off
            cell.onToggle = { [weak self] value in self?.model.setChecked(value, item: entry) }
            cell.toolTip = entry.url.path
        }
        return cell
    }

    static func amount(bytes: Int64, folders: Int) -> String {
        if bytes > 0 { return SizeFormatter.string(bytes) }
        if folders > 0 { return "\(folders.formatted()) folders" }
        return "--"
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        revealButton.isEnabled = selectedItem != nil
    }

    @objc func rescan() {
        lastOutcome = nil
        Task { await model.scan() }
    }

    @objc func reveal() {
        guard let item = selectedItem else { return }
        switch item.action {
        case .removeEmptyFolders, .emptyTrash: BrowserWindowManager.shared.open(at: .folder(item.url))
        case .trash: BrowserWindowManager.shared.open(at: .folder(item.url.deletingLastPathComponent()), select: [item.url])
        }
    }

    static func confirmation(for items: [JunkItem]) -> (message: String, detail: String) {
        let trashing = items.filter { $0.action == .trash }
        let folders = items.reduce(0) { $0 + $1.emptyFolderCount }
        let bytes = trashing.reduce(Int64(0)) { $0 + $1.bytes }
        var lines: [String] = []
        if !trashing.isEmpty { lines.append("\(trashing.count.formatted()) item\(trashing.count == 1 ? "" : "s") (\(SizeFormatter.string(bytes))) will move to the Trash. You can put them back until the Trash is emptied.") }
        if folders > 0 { lines.append("\(folders.formatted()) empty folders will be removed for good. Folders that aren’t empty anymore are left alone.") }
        if items.contains(where: { $0.action == .emptyTrash }) { lines.append("You’ll be asked again before the Trash is emptied.") }
        return ("Clean up the selected junk?", lines.joined(separator: "\n\n"))
    }

    @objc func clean() {
        let picked = model.checkedItems
        guard !picked.isEmpty else { return }
        let text = Self.confirmation(for: picked)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Clean Up")
        alert.addButton(withTitle: "Cancel")
        let run = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let outcome = await self.model.clean()
                self.lastOutcome = outcome.summary
                self.render(structureChanged: false)
                try? await Task.sleep(for: .seconds(2))
                await self.model.scan()
            }
        }
        if let window = view.window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }
}

@MainActor
public final class JunkCleanupWindowController: NSWindowController {
    public static let shared = JunkCleanupWindowController()
    let content: JunkCleanupViewController

    public init() {
        content = JunkCleanupViewController(model: JunkCleanupModel())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Clean Up Junk"
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setFrameAutosaveName("BetterFinderJunkCleanup")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show() {
        let wasVisible = window?.isVisible ?? false
        if !wasVisible, UserDefaults.standard.string(forKey: "NSWindow Frame BetterFinderJunkCleanup") == nil { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if wasVisible { content.rescan() }
    }
}
