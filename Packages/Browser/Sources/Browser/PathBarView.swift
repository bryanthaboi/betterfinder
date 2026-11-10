import AppKit
import FSCore
import Theming

enum PathInput {
    static func normalize(_ raw: String, relativeTo base: URL?) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("file://") {
            guard let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s), u.isFileURL else { return nil }
            s = u.path
        }
        s = s.replacingOccurrences(of: "\\ ", with: " ")
        s = (s as NSString).expandingTildeInPath
        if !s.hasPrefix("/") {
            guard let base else { return nil }
            s = base.appendingPathComponent(s).path
        }
        let std = (s as NSString).standardizingPath
        return std.isEmpty ? "/" : std
    }

    static func resolve(_ raw: String, relativeTo base: URL?) -> (location: BrowserLocation, select: [URL])? {
        guard let path = normalize(raw, relativeTo: base) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let url = URL(fileURLWithPath: path)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if isDir.boolValue && !isPackage { return (.folder(url), []) }
        return (.folder(url.deletingLastPathComponent()), [url])
    }

    static func completions(for raw: String, relativeTo base: URL?, showHidden: Bool) -> (directory: String, prefix: String, matches: [String]) {
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (base?.appendingPathComponent(expanded).path ?? expanded)
        let dir: String
        let prefix: String
        if absolute.hasSuffix("/") {
            dir = absolute
            prefix = ""
        } else {
            dir = (absolute as NSString).deletingLastPathComponent
            prefix = (absolute as NSString).lastPathComponent
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.isEmpty ? "/" : dir)) ?? []
        let wantHidden = showHidden || prefix.hasPrefix(".")
        let matches = names.filter { n in
            (wantHidden || !n.hasPrefix(".")) && (prefix.isEmpty || n.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (dir, prefix, matches)
    }

    static func commonPrefix(_ names: [String]) -> String {
        guard var p = names.first else { return "" }
        for n in names.dropFirst() {
            while !p.isEmpty && n.range(of: p, options: [.caseInsensitive, .anchored]) == nil { p.removeLast() }
        }
        return p
    }

    static func complete(_ raw: String, relativeTo base: URL?, showHidden: Bool) -> (text: String, matches: [String]) {
        let (dir, prefix, matches) = completions(for: raw, relativeTo: base, showHidden: showHidden)
        guard !matches.isEmpty else { return (raw, []) }
        let usesTilde = raw.hasPrefix("~")
        func render(_ path: String) -> String {
            usesTilde ? (path as NSString).abbreviatingWithTildeInPath : path
        }
        if matches.count == 1 {
            let full = (dir as NSString).appendingPathComponent(matches[0])
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            return (render(full) + (isDir.boolValue ? "/" : ""), matches)
        }
        let common = commonPrefix(matches)
        if (common as NSString).length > (prefix as NSString).length {
            return (render((dir as NSString).appendingPathComponent(common)), matches)
        }
        return (raw, matches)
    }
}

@MainActor
final class PathBarView: NSView, NSTextFieldDelegate, ThemedSurface {
    var onNavigate: ((BrowserLocation, [URL]) -> Void)?
    var onScopeChange: ((SearchScopeKind) -> Void)?
    var onEndEditing: (() -> Void)?

    var isActive = false { didSet { crumbStack.alphaValue = isActive ? 1 : 0.75 } }

    private let crumbStack = NSStackView()
    private let field = NSTextField()
    private let scopeControl = NSSegmentedControl(labels: ["This Folder", "Home", "This Mac"], trackingMode: .selectOne, target: nil, action: nil)
    private let separator = NSBox()
    private let surface = ThemedSurfaceView(role: .pathBar)
    private var location: BrowserLocation = .computer
    private(set) var isEditing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        crumbStack.orientation = .horizontal
        crumbStack.spacing = Spacing.crumbSeparatorGap
        crumbStack.alignment = .centerY
        crumbStack.translatesAutoresizingMaskIntoConstraints = false
        crumbStack.setHuggingPriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isHidden = true
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.placeholderString = "Type a path, ~/folder, or paste a file:// URL"
        field.font = .systemFont(ofSize: 12)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Path")
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.controlSize = .small
        scopeControl.font = .systemFont(ofSize: 11)
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        scopeControl.isHidden = true
        scopeControl.setAccessibilityLabel("Search scope")
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(crumbStack)
        addSubview(field)
        addSubview(scopeControl)
        addSubview(separator)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            crumbLeading,
            crumbStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbToBar,
            fieldLeading,
            fieldToBar,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            scopeControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.s),
            scopeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path bar")
        setAccessibilityHelp("Click or press Command-L to type a path")
        updateCustomActions()
        observeThemeChanges()
    }

    required init?(coder: NSCoder) { fatalError() }

    private lazy var crumbLeading = crumbStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.s - Spacing.xs)
    private lazy var fieldLeading = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs)
    private lazy var crumbToBar = crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.s)
    private lazy var crumbToScope = crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: scopeControl.leadingAnchor, constant: -Spacing.xs)
    private lazy var fieldToBar = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.s)
    private lazy var fieldToScope = field.trailingAnchor.constraint(equalTo: scopeControl.leadingAnchor, constant: -Spacing.xs)
    private var outerPadding: CGFloat = Spacing.s

    static let ellipsisWidth: CGFloat = 24

    static func metrics(for theme: Theme) -> (outer: CGFloat, padH: CGFloat, height: CGFloat) {
        let lay = theme.layout
        let compact = lay.isAuthenticCompact
        let outer = compact ? Spacing.xs : Spacing.s
        let padH = compact ? Spacing.xxs : Spacing.xs
        let font = theme.pathBarFont
        let preferred = min(Spacing.crumbHeight, max(16, lay.pathBarHeight - Spacing.crumbPaddingV * 2))
        let height = min(max(lay.pathBarHeight, 16), max(preferred, ThemeLayout.lineHeight(font) + Spacing.xxs))
        return (outer, padH, height)
    }

    static func crumbColors(for theme: Theme) -> (text: NSColor, current: NSColor, separator: NSColor) {
        let text = Theme.color(theme.pathBar.text)
        var current = Theme.color(theme.pathBar.highlight)
        let background = Theme.color(theme.pathBar.background)
        if NSColor.contrastRatio(current, background) < 4.5 { current = theme.textColor }
        return (text, current, Theme.color(theme.pathBar.separator))
    }

    func applyTheme(_ theme: Theme) {
        let m = Self.metrics(for: theme)
        outerPadding = m.outer
        crumbLeading.constant = m.outer - m.padH
        fieldLeading.constant = m.outer - Spacing.xxs
        crumbToBar.constant = -m.outer
        fieldToBar.constant = -m.outer
        field.font = theme.pathBarFont
        separator.isHidden = theme.pathBar.style != .native
        rebuildCrumbs()
    }

    private var providedTitle: String?
    private var providedSymbol: String?
    private(set) var providedPath: String?

    var isShowingProvided: Bool { providedTitle != nil }

    func showProvided(title: String, symbolName: String?, path: String? = nil) {
        providedTitle = title
        providedSymbol = symbolName
        providedPath = path
        if isEditing { endEditing(restoreFocus: false) }
        setScopeVisible(false)
        rebuildCrumbs()
        setAccessibilityValue(path ?? title)
        updateCustomActions()
    }

    func update(location: BrowserLocation) {
        providedTitle = nil
        providedSymbol = nil
        providedPath = nil
        self.location = location
        if isEditing { endEditing(restoreFocus: false) }
        if case .search = location {
            scopeControl.selectedSegment = BrowserDefaults.searchScope.rawValue
            setScopeVisible(true)
        } else {
            setScopeVisible(false)
        }
        rebuildCrumbs()
        setAccessibilityValue(currentPathText().isEmpty ? location.displayName : currentPathText())
        updateCustomActions()
    }

    private func setScopeVisible(_ visible: Bool) {
        scopeControl.isHidden = !visible
        NSLayoutConstraint.deactivate(visible ? [crumbToBar, fieldToBar] : [crumbToScope, fieldToScope])
        NSLayoutConstraint.activate(visible ? [crumbToScope, fieldToScope] : [crumbToBar, fieldToBar])
    }

    private func updateCustomActions() {
        if isShowingProvided {
            guard let path = providedPath else { setAccessibilityCustomActions([]); return }
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Copy server path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                return true
            }])
            setAccessibilityHelp(nil)
            return
        }
        setAccessibilityHelp("Click or press Command-L to type a path")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Edit path") { [weak self] in
            self?.beginEditing()
            return true
        }])
    }

    private func chain(for url: URL) -> [URL] {
        var out: [URL] = []
        var cur = url.standardizedFileURL
        while true {
            out.insert(cur, at: 0)
            if cur.path == "/" || VolumeInfo.isVolumeRoot(cur) { break }
            let parent = cur.deletingLastPathComponent()
            if parent.pathKey == cur.pathKey { break }
            cur = parent
            if out.count > 64 { break }
        }
        return out
    }

    private struct CrumbEntry {
        let title: String
        let url: URL?
        let location: BrowserLocation?
        let image: NSImage?
        var redacted: String? = nil
    }

    private func folderCrumb(_ u: URL, isRoot: Bool, image: NSImage?) -> CrumbEntry {
        if HomeLabel.isRedacted(u) {
            return CrumbEntry(title: HomeNameDisplay.redactedAccessibilityName, url: u, location: .folder(u), image: image, redacted: FileManager.default.displayName(atPath: u.path))
        }
        return CrumbEntry(title: isRoot ? BrowserLocation.folder(u).displayName : u.displayTitle, url: u, location: .folder(u), image: image)
    }

    func refreshDisplay() {
        rebuildCrumbs()
    }

    private var crumbEntries: [CrumbEntry] = []
    private(set) var collapsedAncestors: [URL] = []
    private var visibleTailCount = 0
    private var crumbMinimumWidths: [CGFloat] = []

    private func rebuildCrumbs() {
        var entries: [CrumbEntry] = []
        if let providedTitle {
            entries = [CrumbEntry(title: providedTitle, url: nil, location: nil, image: providedSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) })]
        } else {
            switch location {
            case .folder(let url):
                let parts = chain(for: url)
                for (i, u) in parts.enumerated() {
                    entries.append(folderCrumb(u, isRoot: i == 0, image: i == 0 || i == parts.count - 1 ? IconCache.shared.fileIcon(u, size: 14) : nil))
                }
            case .search(let scope, let q):
                let parts = scope.path == "/" ? [] : chain(for: scope)
                if parts.isEmpty {
                    entries.append(CrumbEntry(title: BrowserLocation.computer.displayName, url: nil, location: .computer, image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)))
                }
                for (i, u) in parts.enumerated() {
                    entries.append(folderCrumb(u, isRoot: i == 0, image: nil))
                }
                entries.append(CrumbEntry(title: "“\(q)”", url: nil, location: nil, image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")))
            case .computer:
                entries = [CrumbEntry(title: BrowserLocation.computer.displayName, url: nil, location: .computer, image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil))]
            case .recents:
                entries = [CrumbEntry(title: "Recents", url: nil, location: .recents, image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil))]
            case .tag(let t):
                entries = [CrumbEntry(title: t, url: nil, location: .tag(t), image: TagColors.dot(TagColors.color(for: t), size: 12))]
            }
        }
        crumbEntries = entries
        visibleTailCount = 0
        layoutCrumbs()
    }

    private var availableCrumbWidth: CGFloat {
        let trailing = scopeControl.isHidden ? outerPadding : outerPadding + scopeControl.intrinsicContentSize.width + Spacing.xs
        return bounds.width - crumbLeading.constant - trailing
    }

    private func makeCrumb(_ e: CrumbEntry, isLast: Bool, theme: Theme, metrics m: (outer: CGFloat, padH: CGFloat, height: CGFloat)) -> CrumbButton {
        let colors = Self.crumbColors(for: theme)
        let b = CrumbButton(title: e.title, url: e.url, location: e.location)
        b.padding = m.padH
        b.crumbHeight = m.height
        let image = e.image
        if let image, image.size != NSSize(width: 14, height: 14) { image.size = NSSize(width: 14, height: 14) }
        b.image = image
        b.imagePosition = image == nil ? .noImage : .imageLeading
        b.font = theme.pathBarFont
        let color = isLast ? colors.current : colors.text
        b.contentTintColor = color
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.tighteningFactorForTruncation = 0
        if let hidden = e.redacted {
            b.attributedTitle = RedactedText.attributed(hidden, font: b.font!, color: color)
        } else {
            b.attributedTitle = NSAttributedString(string: e.title, attributes: [.foregroundColor: color, .font: b.font!, .paragraphStyle: para])
        }
        b.target = self
        b.action = #selector(crumbClicked(_:))
        b.bar = self
        b.setContentCompressionResistancePriority(isLast ? .defaultHigh : .defaultLow, for: .horizontal)
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        if isLast { b.setAccessibilityValue("Current location") }
        return b
    }

    private func minimumWidth(_ b: CrumbButton, isLast: Bool, padH: CGFloat) -> CGFloat {
        let w = b.intrinsicContentSize.width
        return isLast ? min(w, 120) : min(w, padH * 2 + 28)
    }

    static func visibleTail(minimumWidths: [CGFloat], available: CGFloat, separatorUnit: CGFloat, ellipsis: CGFloat) -> Int {
        let n = minimumWidths.count
        guard n > 1, available > 0 else { return n }
        let all = minimumWidths.reduce(0, +) + CGFloat(n - 1) * separatorUnit
        if all <= available { return n }
        var k = 1
        while k < n - 1 {
            let tail = minimumWidths.suffix(k + 1).reduce(0, +) + CGFloat(k + 1) * separatorUnit + ellipsis
            if tail > available { break }
            k += 1
        }
        return k
    }

    private func layoutCrumbs() {
        let theme = ThemeManager.shared.current
        let m = Self.metrics(for: theme)
        let entries = crumbEntries
        let buttons = entries.enumerated().map { makeCrumb($0.element, isLast: $0.offset == entries.count - 1, theme: theme, metrics: m) }
        let mins = buttons.enumerated().map { minimumWidth($0.element, isLast: $0.offset == buttons.count - 1, padH: m.padH) }
        let separatorUnit = Spacing.crumbSeparatorWidth + Spacing.crumbSeparatorGap * 2
        let tail = Self.visibleTail(minimumWidths: mins, available: availableCrumbWidth, separatorUnit: separatorUnit, ellipsis: Self.ellipsisWidth)
        visibleTailCount = tail
        crumbMinimumWidths = mins
        for v in crumbStack.arrangedSubviews { crumbStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let colors = Self.crumbColors(for: theme)
        func addSep() {
            let sep = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            sep.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            sep.contentTintColor = colors.separator
            sep.setAccessibilityElement(false)
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.widthAnchor.constraint(equalToConstant: Spacing.crumbSeparatorWidth).isActive = true
            crumbStack.addArrangedSubview(sep)
        }
        let hidden = buttons.count - tail
        collapsedAncestors = hidden > 0 ? entries.prefix(hidden).compactMap(\.url) : []
        if hidden > 0 {
            let more = CrumbButton(title: "…", url: nil, location: nil)
            more.padding = 0
            more.crumbHeight = m.height
            more.font = theme.pathBarFont
            more.attributedTitle = NSAttributedString(string: "…", attributes: [.foregroundColor: colors.text, .font: theme.pathBarFont])
            more.target = self
            more.action = #selector(showCollapsedAncestors(_:))
            more.bar = self
            more.isCollapsedAncestors = true
            more.setAccessibilityLabel("Enclosing folders")
            more.setAccessibilityHelp("Show \(hidden) hidden enclosing folder\(hidden == 1 ? "" : "s")")
            more.toolTip = entries.prefix(hidden).map(\.title).joined(separator: " › ")
            more.translatesAutoresizingMaskIntoConstraints = false
            more.widthAnchor.constraint(equalToConstant: Self.ellipsisWidth).isActive = true
            crumbStack.addArrangedSubview(more)
        }
        for (i, b) in buttons.enumerated() where i >= hidden {
            if i > 0 { addSep() }
            crumbStack.addArrangedSubview(b)
            if i < buttons.count - 1 { b.widthAnchor.constraint(greaterThanOrEqualToConstant: mins[i]).isActive = true }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard changed, !crumbMinimumWidths.isEmpty else { return }
        let tail = Self.visibleTail(minimumWidths: crumbMinimumWidths, available: availableCrumbWidth, separatorUnit: Spacing.crumbSeparatorWidth + Spacing.crumbSeparatorGap * 2, ellipsis: Self.ellipsisWidth)
        if tail != visibleTailCount { layoutCrumbs() }
    }

    func collapsedAncestorsMenu() -> NSMenu {
        let menu = NSMenu()
        for u in collapsedAncestors.reversed() {
            let item = NSMenuItem(title: u.path == "/" ? BrowserLocation.folder(u).displayName : u.displayTitle, action: #selector(collapsedAncestorChosen(_:)), keyEquivalent: "")
            item.image = IconCache.shared.fileIcon(u, size: 16)
            item.representedObject = u
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showCollapsedAncestors(_ sender: CrumbButton) {
        collapsedAncestorsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func collapsedAncestorChosen(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? URL else { return }
        var select: [URL] = []
        if let current = location.url, target.isAncestor(of: current) {
            let comps = current.pathComponents.dropFirst(target.pathComponents.count)
            if let first = comps.first { select = [target.appendingPathComponent(first)] }
        }
        onNavigate?(.folder(target), select)
    }

    @objc private func crumbClicked(_ sender: CrumbButton) {
        guard let loc = sender.location else { return }
        let current = location.url
        var select: [URL] = []
        if let current, let target = loc.url, target.isAncestor(of: current) {
            let comps = current.pathComponents.dropFirst(target.pathComponents.count)
            if let first = comps.first { select = [target.appendingPathComponent(first)] }
        }
        onNavigate?(loc, select)
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        if let s = SearchScopeKind(rawValue: sender.selectedSegment) { onScopeChange?(s) }
    }

    func ancestorsMenu(for crumb: CrumbButton) -> NSMenu {
        let menu = NSMenu()
        if crumb.isCollapsedAncestors { return collapsedAncestorsMenu() }
        if isShowingProvided, let path = providedPath {
            let copy = NSMenuItem(title: "Copy Server Path", action: #selector(copyServerPath(_:)), keyEquivalent: "")
            copy.representedObject = path
            copy.target = self
            menu.addItem(copy)
            return menu
        }
        guard let url = crumb.url else { return menu }
        var cur: URL? = url
        while let u = cur {
            let item = NSMenuItem(title: u.path == "/" ? BrowserLocation.folder(u).displayName : u.displayTitle, action: #selector(ancestorChosen(_:)), keyEquivalent: "")
            item.image = IconCache.shared.fileIcon(u, size: 16)
            item.representedObject = u
            item.target = self
            menu.addItem(item)
            if u.path == "/" { break }
            let p = u.deletingLastPathComponent()
            cur = p.pathKey == u.pathKey ? nil : p
        }
        menu.addItem(.separator())
        let comp = NSMenuItem(title: BrowserLocation.computer.displayName, action: #selector(computerChosen(_:)), keyEquivalent: "")
        comp.target = self
        menu.addItem(comp)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copyCrumbPath(_:)), keyEquivalent: "")
        copy.representedObject = url
        copy.target = self
        menu.addItem(copy)
        let tab = NSMenuItem(title: "Open in New Tab", action: #selector(openCrumbInTab(_:)), keyEquivalent: "")
        tab.representedObject = url
        tab.target = self
        menu.addItem(tab)
        return menu
    }

    @objc private func ancestorChosen(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { onNavigate?(.folder(u), []) }
    }

    @objc private func computerChosen(_ sender: NSMenuItem) { onNavigate?(.computer, []) }

    @objc private func copyServerPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func copyCrumbPath(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { FileCommands.copyPaths([u]) }
    }

    @objc private func openCrumbInTab(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let wc = window?.windowController as? BrowserWindowController else { return }
        wc.openInNewTab(.folder(u))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 1, !isShowingProvided { beginEditing() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    static let providedEditingMessage = "Typing a path isn’t available for this location. Right-click the path to copy it."

    func beginEditing(text: String? = nil) {
        if isShowingProvided {
            InlineWarning.show(Self.providedEditingMessage, relativeTo: self)
            return
        }
        isEditing = true
        crumbStack.isHidden = true
        field.isHidden = false
        NSAccessibility.post(element: field, notification: .focusedUIElementChanged)
        field.textColor = .labelColor
        field.stringValue = text ?? currentPathText()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func currentPathText() -> String {
        switch location {
        case .folder(let u): return u.abbreviatedPath
        case .search(let s, _): return s.abbreviatedPath
        default: return ""
        }
    }

    func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        crumbStack.isHidden = false
        if restoreFocus { onEndEditing?() }
    }

    private func commit() {
        guard let r = PathInput.resolve(field.stringValue, relativeTo: location.url ?? location.scopeURL) else {
            NSSound.beep()
            field.textColor = .systemRed
            InlineWarning.show("No folder or file exists at that path.", relativeTo: field)
            return
        }
        InlineWarning.dismiss()
        endEditing(restoreFocus: true)
        onNavigate?(r.location, r.select)
    }

    private func complete() {
        let (text, matches) = PathInput.complete(field.stringValue, relativeTo: location.url, showHidden: BrowserDefaults.showHidden)
        if text != field.stringValue {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            return
        }
        guard matches.count > 1 else {
            if matches.isEmpty {
                NSSound.beep()
                InlineWarning.show(Self.noCompletionMessage, relativeTo: field)
            }
            return
        }
        let menu = NSMenu()
        let (dir, _, _) = PathInput.completions(for: field.stringValue, relativeTo: location.url, showHidden: BrowserDefaults.showHidden)
        let usesTilde = field.stringValue.hasPrefix("~")
        for m in matches.prefix(60) {
            let full = (dir as NSString).appendingPathComponent(m)
            let item = NSMenuItem(title: m, action: #selector(completionChosen(_:)), keyEquivalent: "")
            item.image = IconRaster.fileIcon(full, points: 16, scale: IconRaster.scale)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            item.representedObject = (usesTilde ? (full as NSString).abbreviatingWithTildeInPath : full) + (isDir.boolValue ? "/" : "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: field.bounds.height + 4), in: field)
    }

    static let noCompletionMessage = "No files or folders match that path."

    @objc private func completionChosen(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        window?.makeFirstResponder(field)
        field.stringValue = s
        field.currentEditor()?.selectedRange = NSRange(location: (s as NSString).length, length: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            InlineWarning.dismiss()
            endEditing(restoreFocus: true); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.complete(_:)):
            complete(); return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        field.textColor = .labelColor
        InlineWarning.dismiss()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if isEditing { endEditing(restoreFocus: false) }
    }
}

@MainActor
final class CrumbButton: NSButton {
    let url: URL?
    let location: BrowserLocation?
    weak var bar: PathBarView?
    private var dropActive = false { didSet { layer?.backgroundColor = dropActive ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor : nil } }
    var padding: CGFloat = Spacing.xs { didSet { invalidateIntrinsicContentSize() } }
    var isCollapsedAncestors = false
    var crumbHeight: CGFloat = Spacing.crumbHeight { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        let text = ceil(attributedTitle.size().width)
        let icon = image.map { $0.size.width + (text > 0 ? Spacing.xxs : 0) } ?? 0
        return NSSize(width: text + icon + padding * 2, height: crumbHeight)
    }
    private let spring = SpringLoader()

    init(title: String, url: URL?, location: BrowserLocation?) {
        self.url = url
        self.location = location
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = 6
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        setButtonType(.momentaryChange)
        if url != nil { registerForDraggedTypes(DropSupport.types) }
        setAccessibilityLabel(title)
        setAccessibilityHelp(location == nil ? nil : "Go to \(title)")
        if location == nil { isEnabled = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.ancestorsMenu(for: self) }

    override func rightMouseDown(with event: NSEvent) {
        if let m = bar?.ancestorsMenu(for: self) { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url else { return [] }
        let op = DropSupport.operation(for: sender, destination: url)
        dropActive = !op.isEmpty
        if !op.isEmpty, let loc = location {
            spring.hover(url) { [weak self] in self?.bar?.onNavigate?(loc, []) }
        }
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropActive = false; spring.cancel() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropActive = false
        spring.cancel()
        guard let url else { return false }
        return DropSupport.perform(sender, destination: url)
    }
}
