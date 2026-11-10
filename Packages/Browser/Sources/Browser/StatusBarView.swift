import AppKit
import FSCore
import Theming

struct ICloudStatus: Sendable {
    var text: String?
    var downloading: Bool

    static func read(_ url: URL) -> ICloudStatus {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingErrorKey, .totalFileAllocatedSizeKey, .fileSizeKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return ICloudStatus(text: nil, downloading: false) }
        if let e = v.ubiquitousItemDownloadingError { return ICloudStatus(text: "download failed: \(e.localizedDescription)", downloading: false) }
        if let e = v.ubiquitousItemUploadingError { return ICloudStatus(text: "upload failed: \(e.localizedDescription)", downloading: false) }
        if v.ubiquitousItemIsUploading == true { return ICloudStatus(text: "uploading", downloading: true) }
        if v.ubiquitousItemIsDownloading == true {
            let logical = Double(v.fileSize ?? 0)
            let alloc = Double(v.totalFileAllocatedSize ?? 0)
            let pct = logical > 0 ? Int(min(99, max(0, alloc / logical * 100))) : 0
            return ICloudStatus(text: "downloading \(pct)%", downloading: true)
        }
        if v.ubiquitousItemIsUploaded == false { return ICloudStatus(text: "waiting to upload", downloading: true) }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded { return ICloudStatus(text: "in iCloud", downloading: false) }
        return ICloudStatus(text: "downloaded", downloading: false)
    }
}


public struct StatusBarContext {
    public let location: BrowserLocation
    public let providedLocation: ProvidedLocation?
    public let selection: [FileItem]
    public let itemCount: Int
    public let isLoading: Bool
    public let hiddenCount: Int
    public let errorDescription: String?
    public let resourceSelection: [ResourceItem]
    let model: FolderModel?
    let sizes: SizeCoordinator?

    public init(location: BrowserLocation, providedLocation: ProvidedLocation? = nil, selection: [FileItem] = [], itemCount: Int = 0, isLoading: Bool = false, hiddenCount: Int = 0, errorDescription: String? = nil, resourceSelection: [ResourceItem] = []) {
        self.location = location
        self.providedLocation = providedLocation
        self.selection = selection
        self.itemCount = itemCount
        self.isLoading = isLoading
        self.hiddenCount = hiddenCount
        self.errorDescription = errorDescription
        self.resourceSelection = resourceSelection
        self.model = nil
        self.sizes = nil
    }

    @MainActor
    init(location: BrowserLocation, providedLocation: ProvidedLocation?, model: FolderModel, selection: [FileItem], sizes: SizeCoordinator) {
        self.location = location
        self.providedLocation = providedLocation
        self.selection = selection
        self.itemCount = model.items.count
        self.isLoading = model.isLoading
        self.hiddenCount = model.hiddenCount
        self.errorDescription = model.error?.localizedDescription
        self.resourceSelection = []
        self.model = model
        self.sizes = sizes
    }
}

@MainActor
public final class StatusBarSegmentOutput {
    public private(set) var text = ""
    public private(set) var toolTip: String?
    public private(set) var isBusy = false
    public private(set) var isHidden = false
    private(set) var announcement: String?
    var onChange: (() -> Void)?

    func announce(_ message: String) {
        announcement = message
        onChange?()
    }

    func takeAnnouncement() -> String? {
        defer { announcement = nil }
        return announcement
    }

    public func set(text: String, toolTip: String? = nil) {
        self.text = text
        self.toolTip = toolTip
        onChange?()
    }

    public func setBusy(_ busy: Bool) {
        guard isBusy != busy else { return }
        isBusy = busy
        onChange?()
    }

    public func setHidden(_ hidden: Bool) {
        guard isHidden != hidden else { return }
        isHidden = hidden
        onChange?()
    }
}

@MainActor
public protocol StatusBarSegmentDriver: AnyObject {
    func update(_ context: StatusBarContext, output: StatusBarSegmentOutput)
    func stop()
}

public struct StatusBarSegmentSpec: BrowserContribution {
    public enum Alignment: Sendable { case leading, center, trailing }

    public var id: String
    public var alignment: Alignment
    public var accessibilityLabel: String
    public var accessibilityHelp: String?
    public var text: (@MainActor (StatusBarContext) -> String?)?
    public var makeDriver: (@MainActor () -> StatusBarSegmentDriver)?
    public var action: (@MainActor (BrowserContext) -> Void)?
    public var defaultOrder: Int

    public init(id: String, alignment: Alignment = .trailing, accessibilityLabel: String, accessibilityHelp: String? = nil,
                text: (@MainActor (StatusBarContext) -> String?)? = nil, makeDriver: (@MainActor () -> StatusBarSegmentDriver)? = nil,
                action: (@MainActor (BrowserContext) -> Void)? = nil, defaultOrder: Int = 0) {
        self.id = id
        self.alignment = alignment
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
        self.text = text
        self.makeDriver = makeDriver
        self.action = action
        self.defaultOrder = defaultOrder
    }
}

@MainActor
public final class StatusBarRegistry: BrowserRegistry<StatusBarSegmentSpec> {
    public static let shared = StatusBarRegistry()

    public init() { super.init(kind: .statusBar) }

    override public func validate(_ item: StatusBarSegmentSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.text == nil && item.makeDriver == nil { return "A status bar segment needs text or a driver." }
        if item.accessibilityLabel.isEmpty { return "A status bar segment needs an accessibility label." }
        return nil
    }
}

@MainActor
private final class TextSegmentDriver: StatusBarSegmentDriver {
    let text: @MainActor (StatusBarContext) -> String?
    init(text: @escaping @MainActor (StatusBarContext) -> String?) { self.text = text }
    func update(_ context: StatusBarContext, output: StatusBarSegmentOutput) {
        if let t = text(context) {
            output.setHidden(false)
            output.set(text: t)
        } else {
            output.setHidden(true)
        }
    }
    func stop() {}
}

@MainActor
enum StatusAnnouncements {
    static var post: (String, NSView) -> Void = { message, view in
        guard view.window?.isKeyWindow ?? false else { return }
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
}

struct StatusSizeUnit: Equatable {
    let allocated: Bool

    @MainActor static var current: StatusSizeUnit { StatusSizeUnit(allocated: BrowserDefaults.showAllocatedSize) }
    var other: StatusSizeUnit { StatusSizeUnit(allocated: !allocated) }
    func detail(_ bytes: Int64) -> String { "\(describe(bytes)) (\(SizeFormatter.exact(bytes)))" }

    func bytes(_ r: SizeResult) -> Int64 { allocated ? r.allocatedBytes : r.logicalBytes }
    func bytes(_ item: FileItem) -> Int64 { allocated ? (item.allocatedSize ?? item.logicalSize ?? 0) : (item.logicalSize ?? 0) }
    var suffix: String { allocated ? " on disk" : " logical" }
    func describe(_ bytes: Int64) -> String { SizeFormatter.string(bytes) + suffix }
}

@MainActor
final class SelectionSizeTally {
    private var latest: [Int: SizeResult] = [:]
    private var finished: [Int: SizeResult?] = [:]
    let count: Int
    var onProgress: (() -> Void)?

    init(count: Int) { self.count = count }

    func update(_ index: Int, _ r: SizeResult) {
        latest[index] = r
        onProgress?()
    }

    func finish(_ index: Int, _ r: SizeResult?) {
        finished[index] = r
        if let r { latest[index] = r }
    }

    var pending: Int { count - finished.count }
    var unreadable: Bool { finished.values.contains { !($0?.isComplete ?? false) } }
    func bytes(_ unit: StatusSizeUnit) -> Int64 { latest.values.reduce(0) { $0 + unit.bytes($1) } }
}

@MainActor
final class SizeSummaryDriver: StatusBarSegmentDriver {
    typealias Measure = @Sendable (URL) async -> AsyncStream<SizeResult>

    static let maxConcurrentFolders = 4
    static var announcementDelay: TimeInterval = 0.75
    nonisolated static let engineMeasure: Measure = { url in await SizeEngine.shared.size(of: url) }

    var measure: Measure = SizeSummaryDriver.engineMeasure
    private var sizeTask: Task<Void, Never>?
    private var cloudTimer: Timer?
    private var availableCache: [String: (Int64, Date)] = [:]
    private var lastSignature = ""
    private var calculationStart: Date?

    static let spec = StatusBarSegmentSpec(
        id: "size", alignment: .center, accessibilityLabel: "Status", accessibilityHelp: "Click to switch between size on disk and logical size",
        makeDriver: { SizeSummaryDriver() },
        action: { context in
            BrowserDefaults.statusAlternateSize.toggle()
            context.controller?.activePane.updateStatus()
        },
        defaultOrder: -100
    )

    func stop() {
        sizeTask?.cancel()
        sizeTask = nil
        cloudTimer?.invalidate()
        cloudTimer = nil
        calculationStart = nil
    }

    private func available(for url: URL) -> Int64? {
        let key = url.pathKey
        if let (v, t) = availableCache[key], Date().timeIntervalSince(t) < 5 { return v }
        guard let v = VolumeInfo.availableCapacity(for: url) else { return nil }
        availableCache[key] = (v, Date())
        return v
    }

    static func providedSummary(_ context: StatusBarContext) -> String {
        let sel = context.resourceSelection
        if sel.isEmpty {
            if let e = context.errorDescription, context.itemCount == 0 { return "Can't read this folder: \(e)" }
            return context.isLoading ? "Loading… \(plural(context.itemCount, "item"))" : plural(context.itemCount, "item")
        }
        if sel.count == 1 {
            let i = sel[0]
            if i.isDirectory { return "\(i.name) — folder" }
            guard let size = i.size else { return "\(i.name) — size unknown" }
            return "\(i.name) — \(SizeFormatter.string(size)) (\(SizeFormatter.exact(size)))"
        }
        let files = sel.filter { !$0.isDirectory }
        let folders = sel.count - files.count
        let total = files.compactMap(\.size).reduce(0, +)
        var parts: [String] = []
        if !files.isEmpty { parts.append(plural(files.count, "file")) }
        if folders > 0 { parts.append(plural(folders, "folder")) }
        let sizeText = folders > 0 ? "\(SizeFormatter.string(total)) in files" : SizeFormatter.string(total)
        return "\(sel.count.formatted()) selected — \(sizeText) (\(parts.joined(separator: ", ")))"
    }

    static func plural(_ n: Int, _ word: String) -> String {
        "\(n.formatted()) \(word)\(n == 1 ? "" : "s")"
    }

    static func selectionSummary(count: Int, breakdown: String, bytes: Int64, unit: StatusSizeUnit, pendingFolders: Int, totalFolders: Int, unreadable: Bool) -> String {
        let size = unit.describe(bytes)
        if pendingFolders > 0 {
            let measured = totalFolders - pendingFolders
            return "\(count.formatted()) selected — calculating… \(size), \(measured.formatted()) of \(plural(totalFolders, "folder")) measured (\(breakdown))"
        }
        if unreadable { return "\(count.formatted()) selected — at least \(size) (\(breakdown), some items unreadable)" }
        return "\(count.formatted()) selected — \(size) (\(breakdown))"
    }

    private func announceCompletion(_ message: String, output: StatusBarSegmentOutput) {
        defer { calculationStart = nil }
        guard let start = calculationStart, Date().timeIntervalSince(start) >= Self.announcementDelay else { return }
        output.announce(message)
    }

    func update(_ context: StatusBarContext, output: StatusBarSegmentOutput) {
        if context.providedLocation != nil {
            stop()
            output.setBusy(context.isLoading)
            output.set(text: Self.providedSummary(context))
            return
        }
        guard let model = context.model, let sizes = context.sizes else { return }
        let location = context.location
        let selection = context.selection
        func setText(_ s: String, tooltip: String? = nil) { output.set(text: s, toolTip: tooltip) }
        let spinner = output
        let signature = "\(location)|\(selection.map(\.url.pathKey).joined(separator: ","))|\(BrowserDefaults.statusAlternateSize)"
        let selectionChanged = signature != lastSignature
        lastSignature = signature
        if selectionChanged {
            sizeTask?.cancel()
            sizeTask = nil
            cloudTimer?.invalidate()
            cloudTimer = nil
            calculationStart = nil
            spinner.setBusy(false)
        }
        let unit = StatusSizeUnit.current
        switch selection.count {
        case 0:
            spinner.setBusy(false)
            let n = model.items.count
            if let err = model.error, n == 0 {
                setText("Can't read this folder: \(err.localizedDescription)")
                return
            }
            var s: String
            if location.isVirtual {
                s = model.isLoading ? "Searching… \(Self.plural(n, "result"))" : Self.plural(n, "result")
            } else {
                s = model.isLoading ? "Loading… \(Self.plural(n, "item"))" : Self.plural(n, "item")
            }
            if model.isLoading { spinner.setBusy(true) }
            if model.hiddenCount > 0 {
                s += BrowserDefaults.showHidden ? " (incl. \(model.hiddenCount.formatted()) hidden)" : " (\(model.hiddenCount.formatted()) hidden)"
            }
            if let filter = model.filter {
                s += " · showing \(filter.title), \(model.filteredOutCount.formatted()) filtered out (esc to clear)"
            }
            if let notice = model.searchNotice, !notice.isEmpty {
                s += " · \(notice)"
            } else if let url = location.url, let free = available(for: url) {
                s += " · \(SizeFormatter.string(free)) available"
            }
            setText(s, tooltip: model.searchNotice)
        case 1 where selection[0].isBrowsableFolder:
            guard selectionChanged || sizeTask == nil else { return }
            let item = selection[0]
            let name = item.name
            func render(_ r: SizeResult) {
                let primary = unit.bytes(r)
                let tip = unit.other.detail(unit.other.bytes(r))
                if r.isComplete || (r.isPartial && !r.isStale) {
                    setText("\(name) — \(unit.describe(primary)) · \(Self.plural(r.itemCount, "item"))\(r.isComplete ? "" : " (some items unreadable)")", tooltip: tip)
                    spinner.setBusy(false)
                    announceCompletion("\(name), \(unit.describe(primary)), calculation complete\(r.isComplete ? "" : ", some items unreadable")", output: output)
                } else {
                    setText("\(name) — calculating… \(unit.describe(primary))", tooltip: tip)
                }
            }
            if selectionChanged, sizes.result(for: item.url)?.isComplete != true { calculationStart = Date() }
            if let r = sizes.result(for: item.url), r.isComplete || sizes.enabled {
                spinner.setBusy(true)
                render(r)
                return
            }
            setText("\(name) — calculating…")
            spinner.setBusy(true)
            guard !sizes.enabled else { return }
            let measure = self.measure
            sizeTask = Task { [weak self] in
                for await r in await measure(item.url) {
                    guard self != nil, !Task.isCancelled else { return }
                    render(r)
                }
            }
        case 1:
            let item = selection[0]
            let s = "\(item.name) — \(unit.detail(unit.bytes(item)))"
            let tip = unit.other.detail(unit.other.bytes(item))
            spinner.setBusy(false)
            setText(s, tooltip: tip)
            if item.isUbiquitous, selectionChanged {
                let url = item.url
                let base = s
                func poll() {
                    DirectoryStream.queue.async { [weak self] in
                        let st = ICloudStatus.read(url)
                        onMain {
                            guard let self, self.lastSignature == signature else { return }
                            if let t = st.text { setText(base + " · \(t)", tooltip: tip) }
                            if !st.downloading { self.cloudTimer?.invalidate(); self.cloudTimer = nil }
                        }
                    }
                }
                poll()
                cloudTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in MainActor.assumeIsolated { poll() } }
            }
        default:
            guard selectionChanged || sizeTask == nil else { return }
            let files = selection.filter { !$0.isBrowsableFolder }
            let folders = selection.filter(\.isBrowsableFolder)
            let fileBytes = files.reduce(Int64(0)) { $0 + unit.bytes($1) }
            var parts: [String] = []
            if !files.isEmpty { parts.append(Self.plural(files.count, "file")) }
            if !folders.isEmpty { parts.append(Self.plural(folders.count, "folder")) }
            let breakdown = parts.joined(separator: ", ")
            let count = selection.count
            let urls = folders.map(\.url)
            setText(Self.selectionSummary(count: count, breakdown: breakdown, bytes: fileBytes, unit: unit, pendingFolders: urls.count, totalFolders: urls.count, unreadable: false))
            guard !urls.isEmpty else { spinner.setBusy(false); return }
            spinner.setBusy(true)
            calculationStart = Date()
            let measure = self.measure
            let tally = SelectionSizeTally(count: urls.count)
            var lastEmit = Date.distantPast
            tally.onProgress = { [weak tally] in
                guard let tally, Date().timeIntervalSince(lastEmit) > 0.25 else { return }
                lastEmit = Date()
                setText(Self.selectionSummary(count: count, breakdown: breakdown, bytes: fileBytes + tally.bytes(unit), unit: unit, pendingFolders: tally.pending, totalFolders: urls.count, unreadable: false))
            }
            sizeTask = Task { [weak self] in
                await withTaskGroup(of: (Int, SizeResult?).self) { group in
                    var next = 0
                    while next < min(Self.maxConcurrentFolders, urls.count) {
                        let i = next, url = urls[i]
                        next += 1
                        group.addTask {
                            var last: SizeResult?
                            for await r in await measure(url) {
                                if Task.isCancelled { return (i, nil) }
                                last = r
                                await tally.update(i, r)
                            }
                            return (i, last)
                        }
                    }
                    for await (i, r) in group {
                        if Task.isCancelled || self == nil { group.cancelAll(); return }
                        tally.finish(i, r)
                        setText(Self.selectionSummary(count: count, breakdown: breakdown, bytes: fileBytes + tally.bytes(unit), unit: unit, pendingFolders: tally.pending, totalFolders: urls.count, unreadable: false))
                        if next < urls.count {
                            let j = next, url = urls[j]
                            next += 1
                            group.addTask {
                                var last: SizeResult?
                                for await r in await measure(url) {
                                    if Task.isCancelled { return (j, nil) }
                                    last = r
                                    await tally.update(j, r)
                                }
                                return (j, last)
                            }
                        }
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let total = fileBytes + tally.bytes(unit)
                let unreadable = tally.unreadable
                setText(Self.selectionSummary(count: count, breakdown: breakdown, bytes: total, unit: unit, pendingFolders: 0, totalFolders: urls.count, unreadable: unreadable))
                spinner.setBusy(false)
                self.announceCompletion("\(count.formatted()) selected, \(unreadable ? "at least " : "")\(unit.describe(total)), calculation complete", output: output)
            }
        }
    }
}

@MainActor
final class StatusSegmentView: NSView {
    let label = ClickableLabel(labelWithString: "")
    let spinner = NSProgressIndicator()
    private let stack = NSStackView()
    var shouldAnnounce: (() -> Bool)?
    var onClick: (() -> Void)? {
        didSet { label.onClick = onClick; label.window?.invalidateCursorRects(for: label) }
    }

    init(accessibilityLabel: String, help: String?) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityLabel(accessibilityLabel)
        label.setAccessibilityHelp(help)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel("Calculating")
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.xxs
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ output: StatusBarSegmentOutput) {
        let wasBusy = !spinner.isHidden
        label.stringValue = output.text
        label.toolTip = output.toolTip
        label.setAccessibilityValue(output.text)
        isHidden = output.isHidden
        spinner.isHidden = !output.isBusy
        if output.isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if wasBusy && !output.isBusy { NSAccessibility.post(element: label, notification: .valueChanged) }
        if let message = output.takeAnnouncement(), shouldAnnounce?() ?? true {
            StatusAnnouncements.post(message, label)
        }
    }
}

@MainActor
final class StatusBarView: NSView, ThemedSurface {
    private let slider = NSSlider(value: 64, minValue: 32, maxValue: 256, target: nil, action: nil)
    private let smallIcon = NSImageView()
    private let largeIcon = NSImageView()
    private let separator = NSBox()
    private let surface = ThemedSurfaceView(role: .statusBar)
    private let leadingStack = NSStackView()
    private let centerStack = NSStackView()
    private let trailingStack = NSStackView()
    private let rightCluster = NSStackView()

    @MainActor
    private final class Slot {
        var registrySequence = 0
        let qualifiedID: String
        let owner: String
        let spec: StatusBarSegmentSpec
        let driver: StatusBarSegmentDriver
        let output = StatusBarSegmentOutput()
        let view: StatusSegmentView
        init(qualifiedID: String, owner: String, spec: StatusBarSegmentSpec, driver: StatusBarSegmentDriver, view: StatusSegmentView) {
            self.qualifiedID = qualifiedID
            self.owner = owner
            self.spec = spec
            self.driver = driver
            self.view = view
        }
    }

    private var slots: [String: Slot] = [:]
    private var lastContext: StatusBarContext?
    private var registries: BrowserRegistries
    private var theme: Theme?

    var contextProvider: (() -> BrowserContext)?
    var onIconSizeChange: ((Double) -> Void)?

    var showsIconSlider = false {
        didSet { for v in [slider, smallIcon, largeIcon] as [NSView] { v.isHidden = !showsIconSlider } }
    }

    var iconSize: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = newValue; updateSliderAccessibility() }
    }

    private func updateSliderAccessibility() {
        slider.setAccessibilityValueDescription("\(Int(slider.doubleValue)) points")
    }

    init(registries: BrowserRegistries? = nil) {
        let registries = registries ?? .shared
        self.registries = registries
        super.init(frame: .zero)
        wantsLayer = true
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel("Icon size")
        smallIcon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        smallIcon.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        largeIcon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        largeIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        for v in [smallIcon, largeIcon] { v.translatesAutoresizingMaskIntoConstraints = false; v.setAccessibilityElement(false) }
        surface.translatesAutoresizingMaskIntoConstraints = false
        for (stack, spacing) in [(leadingStack, Spacing.s), (centerStack, Spacing.s), (trailingStack, Spacing.s), (rightCluster, Spacing.xxs)] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = spacing
            stack.distribution = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        rightCluster.addArrangedSubview(trailingStack)
        rightCluster.addArrangedSubview(smallIcon)
        rightCluster.addArrangedSubview(slider)
        rightCluster.addArrangedSubview(largeIcon)
        rightCluster.setCustomSpacing(Spacing.s, after: trailingStack)
        for v in [surface, separator, leadingStack, centerStack, rightCluster] as [NSView] { addSubview(v) }
        let centerX = centerStack.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultHigh)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.s),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerX,
            centerStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor, constant: Spacing.s),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: rightCluster.leadingAnchor, constant: -Spacing.s),
            rightCluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.s),
            rightCluster.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 90),
        ])
        showsIconSlider = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status bar")
        observeThemeChanges()
        bind(to: registries)
    }

    required init?(coder: NSCoder) { fatalError() }

    func bind(to registries: BrowserRegistries) {
        self.registries.statusBar.removeObserver(self)
        self.registries = registries
        registries.statusBar.addObserver(self) { [weak self] in self?.syncSegments() }
        syncSegments()
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        separator.isHidden = theme.surfaces.statusBar != .native
        smallIcon.contentTintColor = Theme.color(theme.colors.statusBarText)
        largeIcon.contentTintColor = Theme.color(theme.colors.statusBarText)
        for slot in slots.values { style(slot.view, theme) }
    }

    private func style(_ view: StatusSegmentView, _ theme: Theme) {
        view.label.textColor = Theme.color(theme.colors.statusBarText)
        view.label.font = theme.statusBarFont
    }

    var isActivePane: Bool {
        guard let wc = window?.windowController as? BrowserWindowController else { return true }
        return wc.activePane.statusBar === self
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        updateSliderAccessibility()
        onIconSizeChange?((sender.doubleValue / 8).rounded() * 8)
    }

    var text: String { slots[BrowserRegistry<StatusBarSegmentSpec>.qualify("size", owner: BrowserOwner.builtIn)]?.view.label.stringValue ?? "" }

    var segmentIDs: [String] { registries.statusBar.visibleEntries.map(\.qualifiedID).filter { slots[$0] != nil } }

    func segmentView(_ qualifiedID: String) -> StatusSegmentView? { slots[qualifiedID]?.view }

    func stop() {
        for slot in slots.values { slot.driver.stop() }
    }

    private func syncSegments() {
        let desired = registries.statusBar.visibleEntries
        let sequences = Dictionary(uniqueKeysWithValues: desired.map { ($0.qualifiedID, $0.sequence) })
        for (id, slot) in slots where sequences[id] != slot.registrySequence {
            slot.driver.stop()
            slot.view.removeFromSuperview()
            slots[id] = nil
        }
        for stack in [leadingStack, centerStack, trailingStack] { for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() } }
        for e in desired {
            let slot = slots[e.qualifiedID] ?? makeSlot(e)
            slots[e.qualifiedID] = slot
            switch e.item.alignment {
            case .leading: leadingStack.addArrangedSubview(slot.view)
            case .center: centerStack.addArrangedSubview(slot.view)
            case .trailing: trailingStack.addArrangedSubview(slot.view)
            }
        }
        if let theme { for slot in slots.values { style(slot.view, theme) } }
        if let lastContext { push(lastContext) }
    }

    private func makeSlot(_ e: BrowserRegistry<StatusBarSegmentSpec>.Entry) -> Slot {
        let spec = e.item
        let driver: StatusBarSegmentDriver = spec.makeDriver?() ?? TextSegmentDriver(text: spec.text ?? { _ in nil })
        let view = StatusSegmentView(accessibilityLabel: spec.accessibilityLabel, help: spec.accessibilityHelp)
        view.shouldAnnounce = { [weak self] in self?.isActivePane ?? false }
        let slot = Slot(qualifiedID: e.qualifiedID, owner: e.owner, spec: spec, driver: driver, view: view)
        slot.registrySequence = e.sequence
        slot.output.onChange = { [weak slot] in if let slot { slot.view.apply(slot.output) } }
        if let action = spec.action {
            view.onClick = { [weak self] in
                guard let self, let ctx = self.contextProvider?() else { return }
                action(ctx)
            }
        }
        return slot
    }

    func update(location: BrowserLocation, providedLocation: ProvidedLocation? = nil, model: FolderModel, selection: [FileItem], sizes: SizeCoordinator) {
        update(context: StatusBarContext(location: location, providedLocation: providedLocation, model: model, selection: selection, sizes: sizes))
    }

    func update(context ctx: StatusBarContext) {
        lastContext = ctx
        push(ctx)
    }

    private func push(_ context: StatusBarContext) {
        for slot in slots.values { slot.driver.update(context, output: slot.output) }
    }
}

final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)? {
        didSet {
            guard (oldValue == nil) != (onClick == nil) else { return }
            focusRingType = onClick == nil ? .none : .exterior
            noteFocusRingMaskChanged()
            window?.recalculateKeyViewLoop()
        }
    }

    var isActionable: Bool { onClick != nil }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override var acceptsFirstResponder: Bool { isActionable }

    override var canBecomeKeyView: Bool {
        isActionable && !isHiddenOrHasHiddenAncestor && NSApp.isFullKeyboardAccessEnabled
    }

    override func becomeFirstResponder() -> Bool { isActionable }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        if isActionable, flags.isEmpty, [49, 36, 76].contains(event.keyCode) {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func accessibilityRole() -> NSAccessibility.Role? { isActionable ? .button : .staticText }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
