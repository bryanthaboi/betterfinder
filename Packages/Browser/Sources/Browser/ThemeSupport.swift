import AppKit
import FSCore
import Theming

@MainActor
public protocol ThemedSurface: AnyObject {
    func applyTheme(_ theme: Theme)
}

@MainActor
extension ThemedSurface {
    func observeThemeChanges() {
        ThemeObserver.bind(self) { owner, theme in owner.applyTheme(theme) }
    }
}

@MainActor
enum ThemeHooks {
    static func install(scroll: NSScrollView) {
        ThemedScroller.install(in: scroll)
    }

    static func apply(_ theme: Theme, table: NSTableView, headerHeight: CGFloat? = nil) {
        TableTheming.apply(theme, to: table, headerHeight: headerHeight)
    }
}

extension Theme {
    var usesSystemListColors: Bool { colors.listBg.lowercased().hasPrefix("system:") && colors.rowAlt.lowercased().hasPrefix("system:") }
    var usesSystemSelection: Bool { colors.selection.lowercased().hasPrefix("system:") }
    var listBackground: NSColor { Theme.color(colors.listBg) }
    var alternateRow: NSColor { colors.rowAlt.isEmpty ? Theme.color(colors.listBg) : Theme.color(colors.rowAlt) }
    var textColor: NSColor { Theme.color(colors.text) }
    var secondaryTextColor: NSColor { Theme.color(colors.secondaryText) }
    var selectionColor: NSColor { Theme.color(colors.selection) }
    var selectionTextColor: NSColor { Theme.color(colors.selectionText) }
    var accentColor: NSColor { Theme.color(colors.accent) }
    var borderColor: NSColor { Theme.color(colors.border) }
}

class FileCellView: NSTableCellView {
    private var iconRequestKey: String?
    private let fixedIconSide: CGFloat?
    var trailingInset: CGFloat? { didSet { needsLayout = true } }
    var leadingInset: CGFloat? { didSet { needsLayout = true } }

    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool, iconSize: CGFloat? = nil) {
        fixedIconSide = iconSize
        super.init(frame: .zero)
        self.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.cell?.truncatesLastVisibleLine = true
        tf.cell?.usesSingleLineMode = true
        addSubview(tf)
        textField = tf
        if showsIcon {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.setAccessibilityElement(false)
            addSubview(iv)
            imageView = iv
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lay = ThemeManager.shared.layout
        var x = leadingInset ?? lay.cellHorizontalInset
        if let iv = imageView {
            let side = min(fixedIconSide ?? lay.listIconSize, max(8, h - 2))
            iv.frame = NSRect(x: x, y: ((h - side) / 2).rounded(), width: side, height: side)
            x = iv.frame.maxX + lay.iconTextGap
        }
        if let tf = textField {
            let font = tf.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let th = (font.ascender - font.descender + font.leading).rounded(.up) + 2
            let trailing = trailingInset ?? lay.cellHorizontalInset
            tf.frame = NSRect(x: x, y: ((h - th) / 2).rounded(), width: max(0, bounds.width - x - trailing), height: th)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func setIcon(for item: FileItem, dimmed: CGFloat) {
        let key = item.url.pathKey
        iconRequestKey = key
        imageView?.alphaValue = dimmed
        imageView?.image = IconCache.shared.icon(for: item) { [weak self] img in
            guard let self, self.iconRequestKey == key else { return }
            self.imageView?.image = img
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateSelectedColors() }
    }

    var normalTextColor: NSColor = .labelColor { didSet { updateSelectedColors() } }
    var attributedText: ((NSColor) -> NSAttributedString)?

    var enclosingRowView: NSTableRowView? {
        var v = superview
        while let current = v {
            if let row = current as? NSTableRowView { return row }
            if current is NSTableView { return nil }
            v = current.superview
        }
        return nil
    }

    var selectionState: (selected: Bool, emphasized: Bool) {
        if let row = enclosingRowView { return (row.isSelected, row.isEmphasized) }
        return (backgroundStyle == .emphasized, true)
    }

    var resolvedTextColor: NSColor {
        let state = selectionState
        guard state.selected else { return normalTextColor }
        let theme = MainActor.assumeIsolated { ThemeManager.shared.current }
        return ListRenderer.selectionTextColor(theme, emphasized: state.emphasized)
    }

    func refreshTextColor() { updateSelectedColors() }

    func selectionColorsDidChange(selected: Bool, textColor: NSColor) {}

    private func updateSelectedColors() {
        guard let tf = textField, !tf.isEditable || tf.currentEditor() == nil else { return }
        let color = resolvedTextColor
        tf.textColor = color
        if let attributedText { tf.attributedStringValue = attributedText(color) }
        selectionColorsDidChange(selected: selectionState.selected, textColor: color)
    }
}

final class ThemedRowView: ThemedTableRowView {
    var rowIndex = 0

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { refreshCellColors() } }
    }

    override var isEmphasized: Bool {
        didSet { if oldValue != isEmphasized { refreshCellColors() } }
    }

    func refreshCellColors() {
        for case let cell as FileCellView in subviews { cell.refreshTextColor() }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let theme = MainActor.assumeIsolated { ThemeManager.shared.current }
        guard !theme.usesSystemListColors else { super.drawBackground(in: dirtyRect); return }
        let row = (superview as? NSTableView).map { $0.row(for: self) }.flatMap { $0 >= 0 ? $0 : nil } ?? rowIndex
        (row % 2 == 1 ? theme.alternateRow : theme.listBackground).setFill()
        bounds.fill()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin.y != frame.origin.y
        super.setFrameOrigin(newOrigin)
        if moved { needsDisplay = true }
    }
}

final class InlineWarning {
    @MainActor static var current: NSPopover?
    @MainActor static private(set) var lastMessage: String?

    @MainActor static func show(_ message: String, relativeTo view: NSView) {
        current?.close()
        lastMessage = message
        let vc = NSViewController()
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .systemRed
        label.preferredMaxLayoutWidth = 260
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        vc.view = container
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .semitransient
        p.animates = false
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        current = p
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @MainActor static func dismiss() {
        current?.close()
        current = nil
    }

    @MainActor static func resetLastMessage() { lastMessage = nil }
}
