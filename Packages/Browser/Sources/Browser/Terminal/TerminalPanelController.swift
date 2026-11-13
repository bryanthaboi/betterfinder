import AppKit
import Integration

@MainActor
final class TerminalPanelController: NSViewController {
    private(set) var sessions: [TerminalSession] = []
    private(set) var active: TerminalSession?
    let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
    private let tabStack = NSStackView()
    private let profileButton = NSButton()
    var onEmpty: () -> Void = {}
    var defaultDirectory: () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    var shellPath: () -> String = { TerminalShells.configuredPath(in: BrowserDefaults.store) }
    var detectShells: () -> [TerminalShellProfile] = { TerminalShells.detect() }
    private var titleTimer: Timer?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        root.setAccessibilityLabel("Terminal panel")
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        tabStack.orientation = .horizontal
        tabStack.spacing = 2
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.setHuggingPriority(.defaultLow, for: .horizontal)
        tabStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let add = Self.barButton("plus", "New Terminal Tab", target: self, action: #selector(newTabClicked(_:)))
        profileButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Choose shell")
        profileButton.bezelStyle = .accessoryBarAction
        profileButton.isBordered = false
        profileButton.target = self
        profileButton.action = #selector(showProfiles(_:))
        profileButton.toolTip = "New tab with a different shell"
        profileButton.setAccessibilityLabel("Choose shell")
        let hide = Self.barButton("xmark", "Hide Terminal", target: self, action: #selector(hideClicked(_:)))
        let buttons = NSStackView(views: [add, profileButton, hide])
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(tabStack)
        bar.addSubview(buttons)
        bar.wantsLayer = true
        bar.layer?.masksToBounds = true
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        root.addSubview(line)
        root.addSubview(terminalView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            tabStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: bar.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -4),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            line.topAnchor.constraint(equalTo: bar.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: line.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private static func barButton(_ symbol: String, _ label: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        titleTimer?.invalidate()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildTabs() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        titleTimer?.invalidate()
        titleTimer = nil
    }

    @discardableResult
    func newSession(directory: URL? = nil, shell: String? = nil) -> TerminalSession {
        _ = view
        let grid = terminalView.gridSize(for: terminalView.bounds.size)
        let session = TerminalSession(shellPath: shell ?? shellPath(), directory: directory ?? currentDirectoryHint(), cols: grid.cols, rows: grid.rows)
        session.onChange = { [weak self, weak session] in
            guard let self, let session, session === self.active else { return }
            self.terminalView.contentChanged()
        }
        session.onTitleChange = { [weak self] in self?.rebuildTabs() }
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.close(session)
        }
        sessions.append(session)
        session.start()
        select(session)
        return session
    }

    private func currentDirectoryHint() -> URL {
        defaultDirectory()
    }

    func open(directory: URL) {
        if let active, !active.exited, !active.isBusy {
            active.changeDirectory(to: directory)
            focus()
        } else {
            newSession(directory: directory)
        }
    }

    func select(_ session: TerminalSession) {
        active = session
        terminalView.session = session
        rebuildTabs()
        focus()
    }

    func focus() {
        view.window?.makeFirstResponder(terminalView)
    }

    var isFocused: Bool { view.window?.firstResponder === terminalView }

    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        session.terminate()
        sessions.remove(at: index)
        if active === session {
            if sessions.isEmpty {
                active = nil
                terminalView.session = nil
            } else {
                select(sessions[min(index, sessions.count - 1)])
            }
        }
        rebuildTabs()
        if sessions.isEmpty { onEmpty() }
    }

    func terminateAll() {
        for s in sessions { s.terminate() }
        sessions.removeAll()
        active = nil
        terminalView.session = nil
        titleTimer?.invalidate()
    }

    func selectNext(_ delta: Int) {
        guard let active, let i = sessions.firstIndex(where: { $0 === active }), sessions.count > 1 else { return }
        select(sessions[(i + delta + sessions.count) % sessions.count])
    }

    private func rebuildTabs() {
        guard isViewLoaded else { return }
        let existing = tabStack.arrangedSubviews.compactMap { $0 as? TerminalTabButton }
        if existing.map(\.sessionID) == sessions.map(\.id) {
            for (button, session) in zip(existing, sessions) { button.update(title: session.title, selected: session === active) }
            return
        }
        for v in tabStack.arrangedSubviews { tabStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for session in sessions {
            let button = TerminalTabButton(sessionID: session.id)
            button.update(title: session.title, selected: session === active)
            button.onSelect = { [weak self, weak session] in if let session { self?.select(session) } }
            button.onClose = { [weak self, weak session] in if let session { self?.close(session) } }
            tabStack.addArrangedSubview(button)
        }
    }

    @objc private func newTabClicked(_ sender: Any?) {
        newSession(directory: active?.currentDirectory)
    }

    @objc private func hideClicked(_ sender: Any?) {
        (view.window?.windowController as? BrowserWindowController)?.hideTerminal()
    }

    @objc private func showProfiles(_ sender: NSButton) {
        let menu = NSMenu()
        let current = shellPath()
        for profile in detectShells() {
            let item = NSMenuItem(title: profile.name, action: #selector(newWithProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.path
            if profile.path == current { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Other Shell…", action: #selector(chooseShell(_:)), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func newWithProfile(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        newSession(directory: active?.currentDirectory, shell: path)
    }

    @objc private func chooseShell(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = "Use Shell"
        panel.message = "Choose a shell or command-line program to run in a new terminal tab."
        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        newSession(directory: active?.currentDirectory, shell: url.path)
    }
}

@MainActor
final class TerminalTabButton: NSView {
    let sessionID: UUID
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var selected = false

    init(sessionID: UUID) {
        self.sessionID = sessionID
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("Close terminal tab")
        addSubview(label)
        addSubview(closeButton)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 12),
        ])
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, selected: Bool) {
        if label.stringValue != title { label.stringValue = title }
        self.selected = selected
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel(title)
        setAccessibilityValue(selected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { onSelect() }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() }
    }

    @objc private func closeClicked() { onClose() }
}
