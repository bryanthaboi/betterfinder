import AppKit
import Foundation
import ModHost
import ModKit
import Settings

@MainActor
public enum ModToast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    public static var isEnabled = true
    public private(set) static var history: [(title: String, message: String, level: String)] = []

    public static func show(title: String, message: String, level: String = "info") {
        history.append((title, message, level))
        if history.count > 50 { history.removeFirst(history.count - 50) }
        guard isEnabled, NSApp != nil else { return }
        let p = panel ?? make()
        panel = p
        guard let stack = p.contentView?.subviews.first as? NSStackView,
              let icon = stack.arrangedSubviews.first as? NSImageView,
              let label = stack.arrangedSubviews.last as? NSTextField else { return }
        let symbol = level == "error" ? "exclamationmark.triangle.fill" : level == "warning" ? "exclamationmark.circle" : "puzzlepiece.extension"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: level)
        icon.contentTintColor = level == "error" ? .systemRed : level == "warning" ? .systemOrange : .secondaryLabelColor
        label.stringValue = "\(title): \(message)"
        p.setContentSize(NSSize(width: min(520, max(220, label.intrinsicContentSize.width + 56)), height: 40))
        let anchor = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: anchor.midX - p.frame.width / 2, y: anchor.minY + 48))
        p.alphaValue = 1
        p.orderFrontRegardless()
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [.announcement: label.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { dismiss(p, reduceMotion: reduceMotion()) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (level == "error" ? 5 : 2.5), execute: work)
    }

    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func dismiss(_ p: NSWindow, reduceMotion: Bool) {
        guard !reduceMotion else {
            p.orderOut(nil)
            p.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private static func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        return p
    }
}

@MainActor
enum ModPermissionSheet {
    static func isHighRisk(_ p: ModPermission) -> Bool { ModHostManagementController.summary(p).risk == .high }

    static func approve(name: String, version: String, permissions: [ModPermission], receipt: PreflightReceipt) async -> Set<String>? {
        let alert = NSAlert()
        alert.messageText = "Enable “\(name)” \(version)?"
        let warnings = receipt.diagnostics.filter { $0.severity == .warning }.count
        var info = warnings == 0 ? "It passed preflight." : "It passed preflight with \(warnings) warning\(warnings == 1 ? "" : "s")."
        info += permissions.isEmpty ? " It doesn't ask for any permissions." : " Choose what it may do. High-risk permissions are off unless you turn them on."
        alert.informativeText = info
        var boxes: [(NSButton, String)] = []
        if !permissions.isEmpty {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            for p in permissions {
                let s = ModHostManagementController.summary(p)
                let box = NSButton(checkboxWithTitle: s.title, target: nil, action: nil)
                box.state = s.risk == .high ? .off : .on
                box.toolTip = s.reason
                box.setAccessibilityLabel("\(s.title), \(s.risk.label) risk")
                let reason = NSTextField(wrappingLabelWithString: "\(s.risk.label) risk · \(s.reason)")
                reason.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                reason.textColor = s.risk == .high ? .systemRed : .secondaryLabelColor
                reason.preferredMaxLayoutWidth = 320
                let row = NSStackView(views: [box, reason])
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = 1
                stack.addArrangedSubview(row)
                boxes.append((box, s.id))
            }
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            alert.accessoryView = stack
        }
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        guard await AppModServices.present(alert) == .alertFirstButtonReturn else { return nil }
        return Set(boxes.filter { $0.0.state == .on }.map(\.1))
    }

    static func showFailure(title: String, receipt: PreflightReceipt?, error: Error?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        var lines = [String]()
        if let error { lines.append(error.localizedDescription) }
        for d in (receipt?.diagnostics ?? []).filter({ $0.severity == .error }).prefix(8) {
            lines.append("\(d.code.rawValue)\(d.file.map { " \($0)" } ?? ""): \(d.message)")
        }
        alert.informativeText = lines.isEmpty ? "Preflight didn't complete." : lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        _ = await AppModServices.present(alert)
    }
}

@MainActor
public final class ModLogsWindowController: NSWindowController {
    public static let shared = ModLogsWindowController()

    public var source: (() -> [(id: String, name: String)])?
    public var logs: ((String) -> String)?
    public var events: (() -> String)?
    private let popup = NSPopUpButton()
    private let text = NSTextView()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        w.title = "Mod Logs"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("BetterFinderModLogs")
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        popup.target = self
        popup.action = #selector(changed(_:))
        popup.setAccessibilityLabel("Mod")
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(changed(_:)))
        let bar = NSStackView(views: [popup, refresh])
        bar.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.setAccessibilityLabel("Log")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    public func present() {
        let selected = popup.selectedItem?.representedObject as? String
        popup.removeAllItems()
        popup.addItem(withTitle: "Host events")
        popup.lastItem?.representedObject = ""
        for m in source?() ?? [] {
            popup.addItem(withTitle: m.name)
            popup.lastItem?.representedObject = m.id
        }
        if let selected, let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) { popup.selectItem(at: i) }
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ sender: Any?) { reload() }

    private func reload() {
        let id = popup.selectedItem?.representedObject as? String ?? ""
        let body = id.isEmpty ? (events?() ?? "") : (logs?(id) ?? "")
        text.string = body.isEmpty ? "No log entries." : body
        text.scrollToEndOfDocument(nil)
    }
}
