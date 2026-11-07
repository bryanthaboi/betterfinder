import AppKit
import Combine

@MainActor
final class OperationRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()
    private let retryButton = NSButton()
    private let overrideButton = NSButton()
    private let errorsButton = NSButton()
    private var bag = Set<AnyCancellable>()
    private weak var operation: FileOperation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func configure(button: NSButton, symbol: String, tip: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        configure(button: pauseButton, symbol: "pause.fill", tip: "Pause", action: #selector(togglePause))
        configure(button: cancelButton, symbol: "xmark.circle.fill", tip: "Cancel", action: #selector(cancelTapped))
        configure(button: retryButton, symbol: "arrow.clockwise", tip: "Retry", action: #selector(retryOperation))
        configure(button: overrideButton, symbol: "exclamationmark.shield", tip: "Run Anyway", action: #selector(overrideHooks))
        configure(button: errorsButton, symbol: "exclamationmark.triangle.fill", tip: "Show Errors", action: #selector(showErrors))
        errorsButton.contentTintColor = .systemOrange

        let buttons = NSStackView(views: [overrideButton, errorsButton, pauseButton, retryButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let texts = NSStackView(views: [titleLabel, bar, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8
        let row = NSStackView(views: [texts, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalTo: texts.widthAnchor),
        ])
    }

    func bind(_ op: FileOperation) {
        bag.removeAll()
        operation = op
        titleLabel.stringValue = op.title
        Publishers.CombineLatest3(op.$state, op.$progress, op.$errors)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, progress, errors in
                self?.refresh(op: op, state: state, progress: progress, errors: errors)
            }
            .store(in: &bag)
    }

    private var controls: [NSButton] { [overrideButton, errorsButton, pauseButton, retryButton, cancelButton] }

    func refresh(op: FileOperation, state: FileOperationState, progress: FileOperationProgress, errors: [FileOperationItemError]) {
        let focused = controls.first { window?.firstResponder === $0 }
        let title = op.title
        let fraction = state == .finished ? 1 : progress.fractionCompleted
        bar.doubleValue = fraction
        bar.setAccessibilityLabel("Progress for \(title)")
        bar.setAccessibilityValueDescription("\(Int((fraction * 100).rounded())) percent")
        let paused = state == .paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
        pauseButton.toolTip = paused ? "Resume" : "Pause"
        pauseButton.setAccessibilityLabel(paused ? "Resume \(title)" : "Pause \(title)")
        cancelButton.setAccessibilityLabel("Cancel \(title)")
        overrideButton.setAccessibilityLabel("Run \(title) Anyway")
        errorsButton.setAccessibilityLabel("Show \(errors.count) error\(errors.count == 1 ? "" : "s") for \(title)")
        var awaiting = false
        if case .awaitingDecision = state { awaiting = true }
        pauseButton.isHidden = !op.isActive || awaiting
        overrideButton.isHidden = !awaiting
        cancelButton.isHidden = !op.isActive
        retryButton.isHidden = !op.canRetry
        errorsButton.isHidden = errors.isEmpty || op.isActive
        retryButton.toolTip = errors.isEmpty ? "Retry" : "Retry Failed"
        retryButton.setAccessibilityLabel(errors.isEmpty ? "Retry \(title)" : "Retry Failed Items in \(title)")
        bar.isHidden = !op.isActive || awaiting
        var detail = op.summary
        if state == .running {
            var parts: [String] = []
            if progress.totalUnits > 0 {
                parts.append("\(ByteCountFormatter.string(fromByteCount: progress.completedUnits, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalUnits, countStyle: .file))")
            }
            if progress.bytesPerSecond > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file) + "/s") }
            if let eta = progress.estimatedSecondsRemaining { parts.append(Self.format(eta) + " left") }
            if let current = progress.currentItem { parts.append(current) }
            detail = parts.joined(separator: " · ")
        }
        if !op.isActive, let first = errors.first, case .finished = state {
            detail += " · \(first.url.lastPathComponent): \(first.message)"
        }
        if !op.isActive, op.undoUnavailableReason != nil, state == .finished {
            detail += " · can’t be undone"
        }
        detailLabel.stringValue = detail
        if awaiting {
            toolTip = detail
        } else if !errors.isEmpty {
            toolTip = errors.prefix(20).map { "\($0.url.lastPathComponent): \($0.message)" }.joined(separator: "\n")
        } else {
            toolTip = op.undoUnavailableReason
        }
        if let focused, focused.isHidden { repairFocus() }
    }

    private func repairFocus() {
        guard let window else { return }
        if let next = controls.first(where: { !$0.isHidden && $0.acceptsFirstResponder }) {
            window.makeFirstResponder(next)
            return
        }
        var v: NSView? = superview
        while let current = v, !(current is NSTableView) { v = current.superview }
        window.makeFirstResponder(v)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1))s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    @objc private func togglePause() {
        guard let op = operation else { return }
        op.isPaused ? op.resume() : op.pause()
    }

    @objc private func overrideHooks() { operation?.overrideHooks() }
    @objc private func cancelTapped() { operation?.cancel() }
    @objc private func retryOperation() { operation?.retryFailed() }

    @objc private func showErrors() {
        guard let op = operation, !op.errors.isEmpty else { return }
        OperationErrorsPresenter.present(op, from: window)
    }
}

@MainActor
enum OperationErrorsPresenter {
    static func text(for op: FileOperation) -> String {
        op.errors.map { "\($0.url.path): \($0.message)" }.joined(separator: "\n")
    }

    static func present(_ op: FileOperation, from window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let n = op.errors.count
        alert.messageText = "\(n) item\(n == 1 ? "" : "s") in “\(op.title)” couldn’t be completed"
        alert.informativeText = op.canRetry ? "You can retry the failed items from the operations list." : "The rest of the operation finished."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = .systemFont(ofSize: 11)
            tv.string = text(for: op)
            tv.setAccessibilityLabel("Errors")
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Errors")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text(for: op), forType: .string)
            }
        }
        if let window, window.isVisible, !(window is NSPanel) {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

@MainActor
public final class OperationsListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let queue: FileOperationQueue
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No file operations")
    private var operations: [FileOperation] = []
    private var bag = Set<AnyCancellable>()

    public init(queue: FileOperationQueue? = nil) {
        self.queue = queue ?? .shared
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("operation"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 80
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear Finished", target: self, action: #selector(clearFinished))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        let cancelAll = NSButton(title: "Cancel All", target: self, action: #selector(cancelAll))
        cancelAll.bezelStyle = .rounded
        cancelAll.controlSize = .small
        let footer = NSStackView(views: [cancelAll, clear])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(footer)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root

        table.setAccessibilityLabel("File operations")
        clear.setAccessibilityLabel("Clear Finished Operations")
        cancelAll.setAccessibilityLabel("Cancel All Operations")

        queue.$operations
            .receive(on: RunLoop.main)
            .sink { [weak self] ops in
                guard let self else { return }
                let changed = ops.count != self.operations.count || zip(ops, self.operations).contains { $0 !== $1 }
                self.operations = ops
                self.emptyLabel.isHidden = !ops.isEmpty
                if changed { self.table.reloadData() }
            }
            .store(in: &bag)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        queue.acknowledgeFinished()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { operations.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("OperationRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? OperationRowView) ?? {
            let v = OperationRowView(frame: .zero)
            v.identifier = id
            return v
        }()
        cell.bind(operations[row])
        return cell
    }

    @objc private func clearFinished() { queue.clearFinished() }
    @objc private func cancelAll() { queue.cancelAll() }
}

@MainActor
public final class OperationsWindowController: NSWindowController {
    public static let shared = OperationsWindowController()

    public convenience init(queue: FileOperationQueue? = nil) {
        let vc = OperationsListViewController(queue: queue)
        let window = NSWindow(contentViewController: vc)
        window.title = "File Operations"
        window.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        window.setContentSize(NSSize(width: 420, height: 300))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FileOperationsWindow")
        self.init(window: window)
    }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class PassthroughProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
public final class OperationsIndicatorView: NSView, NSPopoverDelegate {
    private let button = NSButton()
    private let spinner = PassthroughProgressIndicator()
    private var bag = Set<AnyCancellable>()
    private var popover: NSPopover?
    private let queue: FileOperationQueue
    public var onClick: (() -> Void)?

    public init(queue: FileOperationQueue? = nil) {
        self.queue = queue ?? .shared
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(press)
        button.focusRingType = .default
        button.setAccessibilityLabel("File operations")
        button.setAccessibilityRole(.button)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        spinner.style = .spinning
        spinner.isIndeterminate = false
        spinner.minValue = 0
        spinner.maxValue = 1
        spinner.controlSize = .small
        spinner.setAccessibilityElement(false)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        isHidden = true
        Publishers.CombineLatest3(self.queue.$overallProgress, self.queue.$attention, self.queue.$activeOperationCount)
            .receive(on: RunLoop.main)
            .sink { [weak self] progress, attention, active in
                self?.update(progress: progress, attention: attention, active: active)
            }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var accessibleButton: NSButton { button }

    private func update(progress: Double?, attention: OperationsAttention, active: Int) {
        let showingPopover = popover?.isShown == true
        isHidden = progress == nil && attention == .none && !showingPopover
        spinner.isHidden = progress == nil
        spinner.doubleValue = progress ?? 0
        let value: String
        if let progress {
            button.image = nil
            value = "\(active) in progress, \(Int((progress * 100).rounded())) percent"
        } else {
            switch attention {
            case .failed(let n):
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                button.contentTintColor = .systemOrange
                value = "\(n) operation\(n == 1 ? "" : "s") had errors"
            case .completed(let n):
                button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                button.contentTintColor = .systemGreen
                value = "\(n) operation\(n == 1 ? "" : "s") finished"
            case .none:
                button.image = nil
                value = "No operations"
            }
        }
        button.setAccessibilityValue(value)
        button.toolTip = "File operations: \(value)"
    }

    @objc private func press() {
        if let onClick {
            onClick()
            queue.acknowledgeFinished()
            return
        }
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = OperationsListViewController(queue: queue)
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = p
    }

    public override func mouseDown(with event: NSEvent) {
        press()
    }

    public override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    public func popoverDidClose(_ notification: Notification) {
        popover = nil
        update(progress: queue.overallProgress, attention: queue.attention, active: queue.activeOperationCount)
        guard let window, !isHidden else { return }
        if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(button) }
    }
}
