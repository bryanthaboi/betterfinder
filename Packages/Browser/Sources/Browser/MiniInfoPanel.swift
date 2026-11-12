import AppKit
import FSCore
import Theming

enum MiniInfoText {
    static let placeholder = "—"

    static func file(logical: Int64?, allocated: Int64?) -> String {
        guard let logical else { return allocated.map { "\(SizeFormatter.string($0)) on disk" } ?? placeholder }
        guard let allocated, allocated != logical else { return SizeFormatter.string(logical) }
        return "\(SizeFormatter.string(logical)) (\(SizeFormatter.string(allocated)) on disk)"
    }

    static func folder(_ result: SizeResult?, allocated: Bool) -> String {
        guard let result else { return "Calculating…" }
        let size = SizeFormatter.string(allocated ? result.allocatedBytes : result.logicalBytes)
        let items = result.itemCount == 1 ? "1 item" : "\(result.itemCount.formatted()) items"
        guard result.isSettled else { return "Calculating… \(size)" }
        return result.isUnreadable ? "At least \(size) · \(items)" : "\(size) · \(items)"
    }

    static func volume(free: Int64?, total: Int64?) -> String {
        switch (free, total) {
        case (let free?, let total?): return "\(SizeFormatter.string(free)) free of \(SizeFormatter.string(total))"
        case (let free?, nil): return "\(SizeFormatter.string(free)) free"
        case (nil, let total?): return "\(SizeFormatter.string(total)) total"
        case (nil, nil): return placeholder
        }
    }
}

@MainActor
final class MiniInfoModel {
    enum Subject: Equatable { case file, folder, volume, missing }

    let url: URL
    private(set) var subject: Subject = .missing
    private(set) var name = ""
    private(set) var accessibilityName = ""
    private(set) var redactedName: String?
    private(set) var kind = ""
    private(set) var sizeText = MiniInfoText.placeholder
    private(set) var icon: NSImage?
    var onChange: (() -> Void)?

    static var volumeRefreshInterval: TimeInterval = 5
    static var rescanDelay: TimeInterval = 2
    var measure: @Sendable (URL) async -> AsyncStream<SizeResult> = { await SizeEngine.shared.size(of: $0) }
    var invalidate: @Sendable (String) async -> Void = { await SizeEngine.shared.invalidate(path: $0) }

    private var sizeTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var isMeasuring = false
    private var isDirty = false
    private var rescanScheduled = false
    private var changedPaths: Set<String> = []

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    func start() {
        stop()
        let home = HomeLabel.display
        guard let item = DirectoryLister.item(for: url) else {
            subject = .missing
            name = home.name(url.lastPathComponent, forPath: url.path)
            accessibilityName = home.accessibilityName(url.lastPathComponent, forPath: url.path)
            kind = "This item no longer exists."
            sizeText = MiniInfoText.placeholder
            onChange?()
            return
        }
        icon = IconRaster.fileIcon(url.path, points: 32, scale: IconRaster.scale)
        let isVolume = url.path == "/" || VolumeInfo.isVolumeRoot(url)
        let shown = isVolume || item.isPackage ? FileManager.default.displayName(atPath: url.path) : item.name
        name = home.name(shown, forPath: url.path)
        accessibilityName = home.accessibilityName(shown, forPath: url.path)
        redactedName = home.isRedacted && home.isHome(url.path) ? shown : nil
        if isVolume {
            subject = .volume
            kind = "Volume"
            refreshVolume()
            let t = Timer(timeInterval: Self.volumeRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolume() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if item.isDirectory {
            subject = .folder
            kind = item.kindDescription
            sizeText = MiniInfoText.folder(nil, allocated: BrowserDefaults.showAllocatedSize)
            measureFolder()
            let w = DirectoryWatcher(paths: [url], latency: 1.0) { [weak self] paths in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.contentsChanged(paths) } }
            }
            w.start()
            watcher = w
        } else {
            subject = .file
            kind = item.kindDescription
            sizeText = MiniInfoText.file(logical: item.logicalSize, allocated: item.allocatedSize)
        }
        onChange?()
    }

    func stop() {
        sizeTask?.cancel()
        sizeTask = nil
        watcher?.stop()
        watcher = nil
        timer?.invalidate()
        timer = nil
        isMeasuring = false
        isDirty = false
        rescanScheduled = false
        changedPaths.removeAll()
    }

    func refreshVolume() {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        let text = MiniInfoText.volume(free: VolumeInfo.availableCapacity(for: url), total: values?.volumeTotalCapacity.map(Int64.init))
        guard text != sizeText else { return }
        sizeText = text
        onChange?()
    }

    private func measureFolder() {
        sizeTask?.cancel()
        isMeasuring = true
        isDirty = false
        let url = url
        let measure = measure
        sizeTask = Task { [weak self] in
            var measured = false
            for await result in await measure(url) {
                guard let self, !Task.isCancelled else { return }
                measured = true
                self.apply(result)
            }
            guard let self, !Task.isCancelled else { return }
            if !measured, self.sizeText != MiniInfoText.placeholder {
                self.sizeText = MiniInfoText.placeholder
                self.onChange?()
            }
            self.isMeasuring = false
            if self.isDirty { self.scheduleRescan() }
        }
    }

    func apply(_ result: SizeResult) {
        let text = MiniInfoText.folder(result, allocated: BrowserDefaults.showAllocatedSize)
        guard text != sizeText else { return }
        sizeText = text
        onChange?()
    }

    func contentsChanged(_ paths: [String]) {
        guard subject == .folder else { return }
        for p in paths.prefix(16) where changedPaths.count < 16 { changedPaths.insert(p) }
        isDirty = true
        if !isMeasuring { scheduleRescan() }
    }

    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescanDelay) { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    private func rescan() {
        guard rescanScheduled else { return }
        rescanScheduled = false
        guard subject == .folder, watcher != nil else { return }
        let paths = changedPaths.isEmpty ? [url.path] : Array(changedPaths)
        changedPaths.removeAll()
        let invalidate = invalidate
        isMeasuring = true
        isDirty = false
        sizeTask?.cancel()
        sizeTask = Task { [weak self] in
            for p in paths { await invalidate(p) }
            guard let self, !Task.isCancelled else { return }
            self.measureFolder()
        }
    }
}

@MainActor
final class MiniInfoView: NSView, ThemedSurface {
    static let width: CGFloat = 260
    static let iconSide: CGFloat = 32

    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let kindLabel = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    private let model: MiniInfoModel

    init(model: MiniInfoModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 72))
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        for label in [nameLabel, kindLabel, sizeLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [nameLabel, kindLabel, sizeLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Spacing.relatedText / 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(text)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.s),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.xs),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.s),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.s),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.iconSide + Spacing.xs * 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        model.onChange = { [weak self] in self?.refresh() }
        observeThemeChanges()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: Theme) {
        layer?.backgroundColor = theme.listBackground.cgColor
        let base = theme.uiFont
        nameLabel.font = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let small = NSFont(descriptor: base.fontDescriptor, size: max(10, base.pointSize - 1)) ?? base
        kindLabel.font = small
        sizeLabel.font = small
        nameLabel.textColor = theme.textColor
        kindLabel.textColor = theme.secondaryTextColor
        sizeLabel.textColor = theme.textColor
        refresh()
    }

    func refresh() {
        iconView.image = model.icon
        if let hidden = model.redactedName, let font = nameLabel.font {
            nameLabel.attributedStringValue = RedactedText.attributed(hidden, font: font, color: nameLabel.textColor ?? .labelColor)
        } else {
            nameLabel.stringValue = model.name
        }
        kindLabel.stringValue = model.kind
        sizeLabel.stringValue = model.sizeText
        let sizeTitle = model.subject == .volume ? "Space" : "Size"
        nameLabel.setAccessibilityLabel("Name: \(model.accessibilityName)")
        kindLabel.setAccessibilityLabel("Kind: \(model.kind)")
        sizeLabel.setAccessibilityLabel("\(sizeTitle): \(model.sizeText)")
        setAccessibilityLabel("\(model.accessibilityName), \(model.kind), \(model.sizeText)")
        let tip = model.url.displayPath
        nameLabel.toolTip = model.redactedName == nil ? tip : nil
    }
}

final class MiniInfoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class MiniInfoPanelController: NSWindowController, NSWindowDelegate {
    private(set) static var open: [String: MiniInfoPanelController] = [:]
    static let limit = 10

    let model: MiniInfoModel
    let infoView: MiniInfoView

    init(url: URL) {
        model = MiniInfoModel(url: url)
        infoView = MiniInfoView(model: model)
        let panel = MiniInfoPanel(
            contentRect: NSRect(x: 0, y: 0, width: MiniInfoView.width, height: 72),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.title = "Mini Info"
        super.init(window: panel)
        panel.contentView = infoView
        panel.delegate = self
        model.start()
        panel.setContentSize(NSSize(width: MiniInfoView.width, height: max(72, infoView.fittingSize.height)))
        panel.setAccessibilityLabel("\(model.accessibilityName) Mini Info")
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    static func show(_ urls: [URL], near point: NSPoint? = nil) -> [MiniInfoPanelController] {
        var offset: CGFloat = 0
        var shown: [MiniInfoPanelController] = []
        let anchor = point ?? NSEvent.mouseLocation
        for u in urls.prefix(limit) {
            let key = u.standardizedFileURL.path
            if let existing = open[key] {
                existing.window?.makeKeyAndOrderFront(nil)
                shown.append(existing)
                continue
            }
            let c = MiniInfoPanelController(url: u)
            open[key] = c
            if let w = c.window {
                var origin = NSPoint(x: anchor.x + 12 + offset, y: anchor.y - w.frame.height - 12 - offset)
                if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
                    origin.x = min(max(visible.minX, origin.x), visible.maxX - w.frame.width)
                    origin.y = min(max(visible.minY, origin.y), visible.maxY - w.frame.height)
                }
                w.setFrameOrigin(origin)
                w.makeKeyAndOrderFront(nil)
            }
            offset += 22
            shown.append(c)
        }
        return shown
    }

    static func closeAll() {
        for c in Array(open.values) { c.window?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        model.onChange = nil
        Self.open[model.url.path] = nil
    }
}
