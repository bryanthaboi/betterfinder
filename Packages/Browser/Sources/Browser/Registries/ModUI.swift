import AppKit
import Foundation
import Theming

public struct ModUIListItem: Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var symbolName: String?

    public init(id: String, title: String, subtitle: String? = nil, symbolName: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
    }
}

public struct ModUITableColumn: Hashable, Sendable {
    public var id: String
    public var title: String
    public var width: Double?
    public var isRightAligned: Bool

    public init(id: String, title: String, width: Double? = nil, isRightAligned: Bool = false) {
        self.id = id
        self.title = title
        self.width = width
        self.isRightAligned = isRightAligned
    }
}

public struct ModUITableRow: Hashable, Sendable {
    public var id: String
    public var cells: [String: String]
    public var symbolName: String?

    public init(id: String, cells: [String: String], symbolName: String? = nil) {
        self.id = id
        self.cells = cells
        self.symbolName = symbolName
    }
}

public struct ModUIAppearance: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case primary, secondary, accent, success, warning, danger }
    public enum Weight: String, Hashable, Sendable { case regular, medium, semibold, bold }
    public enum Alignment: String, Hashable, Sendable { case leading, center, trailing }
    public enum Surface: String, Hashable, Sendable { case card, tinted }

    public var color: Role?
    public var size: Double?
    public var weight: Weight?
    public var alignment: Alignment?
    public var spacing: Double?
    public var padding: Double?
    public var surface: Surface?

    public init(color: Role? = nil, size: Double? = nil, weight: Weight? = nil, alignment: Alignment? = nil, spacing: Double? = nil, padding: Double? = nil, surface: Surface? = nil) {
        self.color = color
        self.size = size
        self.weight = weight
        self.alignment = alignment
        self.spacing = spacing
        self.padding = padding
        self.surface = surface
    }

    public var isEmpty: Bool { self == ModUIAppearance() }

    var fontWeight: NSFont.Weight? {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case nil: return nil
        }
    }

    @MainActor
    func resolvedColor(_ role: Role, theme: Theme) -> NSColor {
        switch role {
        case .primary: return theme.textColor
        case .secondary: return theme.secondaryTextColor
        case .accent: return theme.accentColor
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .danger: return .systemRed
        }
    }
}

final class ModUICardView: NSView {
    var surface: ModUIAppearance.Surface = .card
    var role: ModUIAppearance.Role?

    override var isFlipped: Bool { true }

    @MainActor
    func apply(theme: Theme, appearance: ModUIAppearance) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let tint = appearance.resolvedColor(role ?? .accent, theme: theme)
        switch surface {
        case .card:
            layer?.backgroundColor = theme.textColor.withAlphaComponent(0.06).cgColor
            layer?.borderColor = theme.textColor.withAlphaComponent(0.08).cgColor
        case .tinted:
            layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.28).cgColor
        }
        layer?.borderWidth = 1
    }
}

public struct ModUINode: Hashable, Sendable {
    public enum Axis: String, Hashable, Sendable { case horizontal, vertical }
    public enum LabelStyle: String, Hashable, Sendable { case body, title, secondary, monospaced }

    public indirect enum Kind: Hashable, Sendable {
        case stack(axis: Axis, spacing: Double?, children: [ModUINode])
        case label(text: String, style: LabelStyle)
        case button(title: String, symbolName: String?)
        case textField(value: String, placeholder: String?)
        case toggle(title: String, isOn: Bool)
        case popup(items: [ModUIListItem], selectedID: String?)
        case list(items: [ModUIListItem], selectedID: String?)
        case table(columns: [ModUITableColumn], rows: [ModUITableRow], selectedID: String?)
        case image(source: BrowserImageSource)
        case progress(value: Double?, caption: String?)
        case separator
        case symbol(name: String)
        case spacer
    }

    public var id: String
    public var kind: Kind
    public var accessibilityLabel: String?
    public var accessibilityHint: String?
    public var isEnabled: Bool
    public var appearance = ModUIAppearance()

    public init(id: String, kind: Kind, accessibilityLabel: String? = nil, accessibilityHint: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.isEnabled = isEnabled
    }

    public static func stack(id: String, axis: Axis = .vertical, spacing: Double? = nil, _ children: [ModUINode]) -> ModUINode {
        ModUINode(id: id, kind: .stack(axis: axis, spacing: spacing, children: children))
    }

    public static func label(id: String, _ text: String, style: LabelStyle = .body) -> ModUINode {
        ModUINode(id: id, kind: .label(text: text, style: style))
    }

    public static func button(id: String, title: String, symbolName: String? = nil, accessibilityLabel: String? = nil, isEnabled: Bool = true) -> ModUINode {
        ModUINode(id: id, kind: .button(title: title, symbolName: symbolName), accessibilityLabel: accessibilityLabel, isEnabled: isEnabled)
    }

    public static func textField(id: String, value: String, placeholder: String? = nil, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .textField(value: value, placeholder: placeholder), accessibilityLabel: accessibilityLabel)
    }

    public static func toggle(id: String, title: String, isOn: Bool, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .toggle(title: title, isOn: isOn), accessibilityLabel: accessibilityLabel)
    }

    public static func popup(id: String, items: [ModUIListItem], selectedID: String? = nil, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .popup(items: items, selectedID: selectedID), accessibilityLabel: accessibilityLabel)
    }

    public static func list(id: String, items: [ModUIListItem], selectedID: String? = nil, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .list(items: items, selectedID: selectedID), accessibilityLabel: accessibilityLabel)
    }

    public static func table(id: String, columns: [ModUITableColumn], rows: [ModUITableRow], selectedID: String? = nil, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .table(columns: columns, rows: rows, selectedID: selectedID), accessibilityLabel: accessibilityLabel)
    }

    public static func image(id: String, source: BrowserImageSource, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .image(source: source), accessibilityLabel: accessibilityLabel)
    }

    public static func progress(id: String, value: Double?, caption: String? = nil, accessibilityLabel: String? = nil) -> ModUINode {
        ModUINode(id: id, kind: .progress(value: value, caption: caption), accessibilityLabel: accessibilityLabel)
    }

    public static func separator(id: String) -> ModUINode {
        ModUINode(id: id, kind: .separator)
    }

    public var children: [ModUINode] {
        if case .stack(_, _, let c) = kind { return c }
        return []
    }

    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

    public var allIDs: [String] { [id] + children.flatMap(\.allIDs) }

    public func accessibilityIssues() -> [String] {
        var issues: [String] = []
        let label = accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch kind {
        case .button(let title, _): if blank(title) && label.isEmpty { issues.append("\(id): button needs a title or accessibility label") }
        case .textField: if label.isEmpty { issues.append("\(id): text field needs an accessibility label") }
        case .toggle(let title, _): if blank(title) && label.isEmpty { issues.append("\(id): toggle needs a title or accessibility label") }
        case .popup: if label.isEmpty { issues.append("\(id): select needs an accessibility label") }
        case .list, .table: if label.isEmpty { issues.append("\(id): list needs an accessibility label") }
        case .image: if label.isEmpty { issues.append("\(id): image needs an accessibility label") }
        case .progress: if label.isEmpty { issues.append("\(id): progress needs an accessibility label") }
        case .stack(_, _, let c): for n in c { issues += n.accessibilityIssues() }
        case .label, .separator, .symbol, .spacer: break
        }
        return issues
    }
}

public struct ModUIEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case press
        case textChanged(String)
        case textCommitted(String)
        case toggled(Bool)
        case selected(String)
        case activated(String)
    }

    public var nodeID: String
    public var kind: Kind

    public init(nodeID: String, kind: Kind) {
        self.nodeID = nodeID
        self.kind = kind
    }
}

@MainActor
public final class ModUIRenderer: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) var node: ModUINode?
    public let rootView: NSView
    public var onEvent: ((ModUIEvent) -> Void)?

    private var controls: [String: NSView] = [:]
    private var tableData: [ObjectIdentifier: TableData] = [:]
    private var themeToken: AnyObject?
    private var suppressEvents = false

    private final class TableData {
        let nodeID: String
        var columns: [ModUITableColumn]
        var rows: [ModUITableRow]
        var isList: Bool
        var items: [ModUIListItem]
        init(nodeID: String, columns: [ModUITableColumn], rows: [ModUITableRow], isList: Bool, items: [ModUIListItem]) {
            self.nodeID = nodeID
            self.columns = columns
            self.rows = rows
            self.isList = isList
            self.items = items
        }
    }

    public init(onEvent: ((ModUIEvent) -> Void)? = nil) {
        self.onEvent = onEvent
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        self.rootView = root
        super.init()
        themeToken = ThemeObserver.bind(self) { owner, _ in owner.reapplyTheme() }
    }

    public func control(withID id: String) -> NSView? { controls[id] }

    public var allControls: [NSView] { Array(controls.values) }

    public func render(_ newNode: ModUINode) {
        let focused = focusedControlID()
        let range = (rootView.window?.firstResponder as? NSText)?.selectedRange
        let previousOrder = node.map { focusOrder($0) } ?? []
        controls.removeAll()
        tableData.removeAll()
        suppressEvents = true
        for v in rootView.subviews { v.removeFromSuperview() }
        suppressEvents = false
        let built = build(newNode)
        built.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: rootView.topAnchor),
            built.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            built.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor),
        ])
        node = newNode
        reapplyTheme()
        guard let focused, let window = rootView.window else { return }
        if let view = controls[focused] {
            window.makeFirstResponder(view)
            if let range, let editor = (view as? NSTextField)?.currentEditor() { editor.selectedRange = range }
            return
        }
        let replacement = Self.fallbackFocus(removed: focused, previousOrder: previousOrder, newOrder: focusOrder(newNode)).flatMap { controls[$0] }
        if let replacement {
            window.makeFirstResponder(replacement)
        } else {
            window.makeFirstResponder(nil)
            if let next = rootView.nextValidKeyView { window.makeFirstResponder(next) }
        }
        NSAccessibility.post(element: rootView, notification: .layoutChanged)
    }

    static func fallbackFocus(removed: String, previousOrder: [String], newOrder: [String]) -> String? {
        let surviving = Set(newOrder)
        if let index = previousOrder.firstIndex(of: removed) {
            if let next = previousOrder[(index + 1)...].first(where: surviving.contains) { return next }
            if let previous = previousOrder[..<index].last(where: surviving.contains) { return previous }
        }
        return newOrder.first
    }

    private func focusOrder(_ n: ModUINode) -> [String] {
        var out: [String] = []
        func walk(_ n: ModUINode) {
            switch n.kind {
            case .stack(_, _, let children): children.forEach(walk)
            case .button, .textField, .toggle, .popup, .list, .table: if n.isEnabled { out.append(n.id) }
            case .label, .image, .progress, .separator, .symbol, .spacer: break
            }
        }
        walk(n)
        return out
    }

    private func focusedControlID() -> String? {
        guard let responder = rootView.window?.firstResponder else { return nil }
        let view: NSView?
        if let text = responder as? NSTextView, text.isFieldEditor { view = text.delegate as? NSView } else { view = responder as? NSView }
        guard let view else { return nil }
        return controls.first { $0.value === view }?.key
    }

    private func emit(_ id: String, _ kind: ModUIEvent.Kind) {
        guard !suppressEvents else { return }
        onEvent?(ModUIEvent(nodeID: id, kind: kind))
    }

    private func build(_ n: ModUINode) -> NSView {
        let view: NSView
        switch n.kind {
        case .stack(let axis, let spacing, let children):
            let built = children.map(build)
            let stack = NSStackView(views: built)
            stack.orientation = axis == .horizontal ? .horizontal : .vertical
            if axis == .horizontal {
                stack.alignment = .centerY
            } else {
                switch n.appearance.alignment {
                case .center: stack.alignment = .centerX
                case .trailing: stack.alignment = .trailing
                case .leading, nil: stack.alignment = .leading
                }
            }
            stack.spacing = CGFloat(min(max(n.appearance.spacing ?? spacing ?? 8, 0), 64))
            stack.distribution = axis == .horizontal && children.count > 1 && children.allSatisfy({ $0.appearance.surface != nil }) ? .fillEqually : .fill
            stack.setAccessibilityRole(.group)
            if axis == .vertical {
                for (child, childView) in zip(children, built) where child.fillsWidth {
                    let fill = childView.widthAnchor.constraint(equalTo: stack.widthAnchor)
                    fill.priority = .defaultHigh
                    fill.isActive = true
                }
            }
            let inset = CGFloat(min(max(n.appearance.padding ?? (n.appearance.surface == nil ? 0 : 12), 0), 64))
            if let surface = n.appearance.surface {
                let card = ModUICardView()
                card.surface = surface
                card.role = n.appearance.color
                stack.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
                    stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
                    stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
                    stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
                ])
                view = card
            } else {
                stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
                view = stack
            }
        case .label(let text, let style):
            let label = NSTextField(wrappingLabelWithString: text)
            label.isSelectable = true
            label.lineBreakMode = .byWordWrapping
            label.identifier = NSUserInterfaceItemIdentifier("label:\(style.rawValue)")
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            switch n.appearance.alignment {
            case .center: label.alignment = .center
            case .trailing: label.alignment = .right
            case .leading, nil: break
            }
            view = label
        case .button(let title, let symbol):
            let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: n.accessibilityLabel ?? title) {
                button.image = img
                button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            }
            button.refusesFirstResponder = false
            view = button
        case .textField(let value, let placeholder):
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.delegate = self
            field.isEditable = n.isEnabled
            field.refusesFirstResponder = false
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view = field
        case .toggle(let title, let isOn):
            let check = NSButton(checkboxWithTitle: title, target: self, action: #selector(togglePressed(_:)))
            check.state = isOn ? .on : .off
            check.refusesFirstResponder = false
            view = check
        case .popup(let items, let selected):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for item in items {
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.representedObject = item.id
                popup.menu?.addItem(entry)
            }
            if let selected, let index = items.firstIndex(where: { $0.id == selected }) { popup.selectItem(at: index) }
            popup.target = self
            popup.action = #selector(popupChanged(_:))
            popup.refusesFirstResponder = false
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view = popup
        case .list(let items, let selected):
            return buildTable(n, columns: [ModUITableColumn(id: "title", title: "")], rows: [], isList: true, items: items, selectedID: selected)
        case .table(let columns, let rows, let selected):
            return buildTable(n, columns: columns, rows: rows, isList: false, items: [], selectedID: selected)
        case .image(let source):
            let iv = NSImageView()
            iv.image = source.image(accessibilityDescription: n.accessibilityLabel)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view = iv
        case .progress(let value, let caption):
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 2
            let bar = NSProgressIndicator()
            bar.style = .bar
            let fraction = value.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
            bar.isIndeterminate = fraction == nil
            bar.minValue = 0
            bar.maxValue = 1
            if let fraction { bar.doubleValue = fraction } else { bar.startAnimation(nil) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            box.addArrangedSubview(bar)
            if let caption {
                let c = NSTextField(labelWithString: caption)
                c.identifier = NSUserInterfaceItemIdentifier("label:secondary")
                box.addArrangedSubview(c)
            }
            let label = n.accessibilityLabel ?? caption ?? "Progress"
            bar.setAccessibilityLabel(label)
            bar.setAccessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
            controls[n.id] = bar
            box.setAccessibilityElement(false)
            return box
        case .separator:
            let sep = NSBox()
            sep.boxType = .separator
            view = sep
        case .symbol(let name):
            let iv = NSImageView()
            let size = CGFloat(min(max(n.appearance.size ?? 16, 8), 96))
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: n.appearance.fontWeight ?? .regular)
            iv.image = NSImage(systemSymbolName: name, accessibilityDescription: n.accessibilityLabel)?.withSymbolConfiguration(config)
            iv.imageScaling = .scaleNone
            iv.setContentHuggingPriority(.required, for: .horizontal)
            iv.setContentHuggingPriority(.required, for: .vertical)
            view = iv
        case .spacer:
            let gap = NSView()
            gap.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            gap.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
            gap.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            gap.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
            view = gap
        }
        applyAccessibility(view, n)
        if let control = view as? NSControl { control.isEnabled = n.isEnabled }
        controls[n.id] = view
        return view
    }

    private func buildTable(_ n: ModUINode, columns: [ModUITableColumn], rows: [ModUITableRow], isList: Bool, items: [ModUIListItem], selectedID: String?) -> NSView {
        let table = NSTableView()
        table.headerView = isList ? nil : NSTableHeaderView()
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = ThemeManager.shared.layout.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for col in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            c.title = col.title
            if let w = col.width { c.width = CGFloat(w) }
            c.minWidth = 40
            c.headerCell.alignment = col.isRightAligned ? .right : .natural
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableActivated(_:))
        let data = TableData(nodeID: n.id, columns: columns, rows: rows, isList: isList, items: items)
        tableData[ObjectIdentifier(table)] = data
        table.reloadData()
        suppressEvents = true
        if let selectedID {
            let index = isList ? items.firstIndex { $0.id == selectedID } : rows.firstIndex { $0.id == selectedID }
            if let index { table.selectRowIndexes([index], byExtendingSelection: false) }
        }
        suppressEvents = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        table.setAccessibilityLabel(n.accessibilityLabel ?? n.id)
        table.setAccessibilityHelp(n.accessibilityHint)
        controls[n.id] = table
        return scroll
    }

    private func applyAccessibility(_ view: NSView, _ n: ModUINode) {
        let label = n.accessibilityLabel
        switch n.kind {
        case .stack, .separator:
            view.setAccessibilityElement(false)
            if let label { view.setAccessibilityLabel(label); view.setAccessibilityElement(true) }
        case .label(let text, _):
            view.setAccessibilityLabel(label ?? text)
        case .button(let title, _):
            view.setAccessibilityLabel(label ?? (title.isEmpty ? n.id : title))
            view.setAccessibilityRole(.button)
        case .textField(_, let placeholder):
            view.setAccessibilityLabel(label ?? placeholder ?? n.id)
        case .toggle(let title, _):
            view.setAccessibilityLabel(label ?? (title.isEmpty ? n.id : title))
        case .popup:
            view.setAccessibilityLabel(label ?? n.id)
        case .image, .symbol:
            if let label { view.setAccessibilityLabel(label); view.setAccessibilityElement(true) } else { view.setAccessibilityElement(false) }
        case .spacer:
            view.setAccessibilityElement(false)
        case .list, .table, .progress:
            break
        }
        if let hint = n.accessibilityHint { view.setAccessibilityHelp(hint) }
    }

    func reapplyTheme() {
        let theme = ThemeManager.shared.current
        for (id, view) in controls {
            guard let n = node?.find(id) else { continue }
            switch n.kind {
            case .label(_, let style):
                guard let tf = view as? NSTextField else { continue }
                switch style {
                case .body: tf.font = theme.uiFont; tf.textColor = theme.textColor
                case .title: tf.font = NSFont.systemFont(ofSize: theme.uiFont.pointSize + 3, weight: .semibold); tf.textColor = theme.textColor
                case .secondary: tf.font = theme.uiFont; tf.textColor = theme.secondaryTextColor
                case .monospaced: tf.font = NSFont.monospacedSystemFont(ofSize: theme.uiFont.pointSize, weight: .regular); tf.textColor = theme.textColor
                }
                let look = n.appearance
                if look.size != nil || look.weight != nil, let base = tf.font {
                    let size = CGFloat(min(max(look.size ?? Double(base.pointSize), 8), 96))
                    let weight = look.fontWeight ?? (style == .title ? .semibold : .regular)
                    tf.font = style == .monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
                }
                if let role = look.color { tf.textColor = look.resolvedColor(role, theme: theme) }
            case .symbol:
                (view as? NSImageView)?.contentTintColor = n.appearance.resolvedColor(n.appearance.color ?? .primary, theme: theme)
            case .stack:
                (view as? ModUICardView)?.apply(theme: theme, appearance: n.appearance)
            case .button(_, let symbol):
                (view as? NSButton)?.font = theme.uiFont
                if symbol != nil { (view as? NSButton)?.contentTintColor = theme.accentColor }
            case .textField:
                guard let tf = view as? NSTextField else { continue }
                tf.font = theme.uiFont
                tf.textColor = theme.textColor
            case .toggle, .popup:
                (view as? NSButton)?.font = theme.uiFont
            case .list, .table:
                guard let table = view as? NSTableView else { continue }
                table.backgroundColor = theme.listBackground
                table.rowHeight = theme.layout.rowHeight
                let selection = table.selectedRowIndexes
                suppressEvents = true
                table.reloadData()
                table.selectRowIndexes(selection, byExtendingSelection: false)
                suppressEvents = false
            case .progress(_, _):
                break
            default:
                break
            }
        }
        for view in rootView.subviews { tintCaptions(view, theme) }
    }

    private func tintCaptions(_ view: NSView, _ theme: Theme) {
        if let tf = view as? NSTextField, tf.identifier?.rawValue == "label:secondary", controls.values.contains(where: { $0 === tf }) == false {
            tf.font = theme.uiFont
            tf.textColor = theme.secondaryTextColor
        }
        for s in view.subviews { tintCaptions(s, theme) }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = controls.first(where: { $0.value === sender })?.key else { return }
        emit(id, .press)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let id = controls.first(where: { $0.value === sender })?.key, let choice = sender.selectedItem?.representedObject as? String else { return }
        emit(id, .selected(choice))
    }

    @objc private func togglePressed(_ sender: NSButton) {
        guard let id = controls.first(where: { $0.value === sender })?.key else { return }
        emit(id, .toggled(sender.state == .on))
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = controls.first(where: { $0.value === field })?.key else { return }
        emit(id, .textChanged(field.stringValue))
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = controls.first(where: { $0.value === field })?.key else { return }
        emit(id, .textCommitted(field.stringValue))
    }

    @objc private func tableActivated(_ sender: NSTableView) {
        guard let data = tableData[ObjectIdentifier(sender)], sender.clickedRow >= 0 else { return }
        if let id = rowID(data, sender.clickedRow) { emit(data.nodeID, .activated(id)) }
    }

    private func rowID(_ data: TableData, _ row: Int) -> String? {
        if data.isList { return data.items.indices.contains(row) ? data.items[row].id : nil }
        return data.rows.indices.contains(row) ? data.rows[row].id : nil
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        guard let data = tableData[ObjectIdentifier(tableView)] else { return 0 }
        return data.isList ? data.items.count : data.rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let data = tableData[ObjectIdentifier(tableView)], let col = tableColumn else { return nil }
        let theme = ThemeManager.shared.current
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.font = theme.listFont
        tf.textColor = theme.textColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        var leading = cell.leadingAnchor
        var inset = theme.layout.cellHorizontalInset
        var symbol: String?
        var text = ""
        var accessible = ""
        if data.isList, data.items.indices.contains(row) {
            let item = data.items[row]
            text = item.title
            symbol = item.symbolName
            accessible = [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")
            if let sub = item.subtitle { tf.toolTip = sub }
        } else if !data.isList, data.rows.indices.contains(row) {
            let r = data.rows[row]
            text = r.cells[col.identifier.rawValue] ?? ""
            if col === tableView.tableColumns.first { symbol = r.symbolName }
            accessible = data.columns.compactMap { c in r.cells[c.id].map { "\(c.title) \($0)" } }.joined(separator: ", ")
        }
        tf.stringValue = text
        tf.alignment = data.columns.first { $0.id == col.identifier.rawValue }?.isRightAligned == true ? .right : .natural
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.contentTintColor = theme.accentColor
            iv.setAccessibilityElement(false)
            cell.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: theme.layout.cellHorizontalInset),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
            ])
            leading = iv.trailingAnchor
            inset = theme.layout.iconTextGap
        }
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leading, constant: inset),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -theme.layout.cellHorizontalInset),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(accessible.isEmpty ? text : accessible)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, let data = tableData[ObjectIdentifier(table)], table.selectedRow >= 0,
              let id = rowID(data, table.selectedRow) else { return }
        emit(data.nodeID, .selected(id))
    }
}

extension ModUINode {
    var fillsWidth: Bool {
        switch kind {
        case .stack(let axis, _, let children):
            if appearance.surface != nil || appearance.alignment != nil { return true }
            return axis == .horizontal && children.contains { if case .spacer = $0.kind { return true }; return $0.appearance.surface != nil }
        case .label: return appearance.alignment != nil
        case .separator, .progress, .list, .table, .textField, .popup: return true
        case .button, .toggle, .image, .symbol, .spacer: return false
        }
    }

    func find(_ id: String) -> ModUINode? {
        if self.id == id { return self }
        for c in children { if let f = c.find(id) { return f } }
        return nil
    }
}

@MainActor
final class ModUIViewController: NSViewController {
    let renderer = ModUIRenderer()

    override func loadView() {
        let container = NSView()
        container.addSubview(renderer.rootView)
        NSLayoutConstraint.activate([
            renderer.rootView.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.panelPadding),
            renderer.rootView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.panelPadding),
            renderer.rootView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Spacing.panelPadding),
            renderer.rootView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Spacing.panelPadding),
        ])
        view = container
    }

    func show(_ node: ModUINode) {
        _ = view
        renderer.render(node)
    }
}
