import AppKit
import FSCore

@MainActor
enum TabBarLayout {
    struct Tab {
        let window: NSWindow
        let frame: NSRect
    }

    enum Target: Equatable {
        case tab(Int)
        case gap(Int)
    }

    static let gapReach: CGFloat = 14

    private static func descendants(of view: NSView, className: String, into out: inout [NSView]) {
        for sub in view.subviews {
            if sub.className == className { out.append(sub) } else { descendants(of: sub, className: className, into: &out) }
        }
    }

    static func tabBar(in window: NSWindow) -> NSView? {
        guard let root = window.contentView?.superview else { return nil }
        var found: [NSView] = []
        descendants(of: root, className: "NSTabBar", into: &found)
        return found.first { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 0 }
    }

    static func tabs(in window: NSWindow) -> [Tab] {
        guard let bar = tabBar(in: window) else { return [] }
        let group = window.tabbedWindows ?? [window]
        var buttons: [NSView] = []
        descendants(of: bar, className: "NSTabButton", into: &buttons)
        var frames = buttons.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        if NSApp.userInterfaceLayoutDirection == .rightToLeft { frames.reverse() }
        guard frames.count == group.count else { return [] }
        return zip(group, frames).map { Tab(window: $0, frame: $1) }
    }

    static func gapX(_ index: Int, frames: [NSRect]) -> CGFloat {
        let reversed = frames.count > 1 && frames[0].minX > frames[1].minX
        let last = frames[frames.count - 1]
        if index <= 0 { return reversed ? frames[0].maxX : frames[0].minX }
        if index >= frames.count { return reversed ? last.minX : last.maxX }
        let before = frames[index - 1]
        let after = frames[index]
        return reversed ? (before.minX + after.maxX) / 2 : (before.maxX + after.minX) / 2
    }

    static func target(at point: NSPoint, frames: [NSRect], foldersOnly: Bool) -> Target? {
        guard !frames.isEmpty else { return nil }
        let minY = frames.map(\.minY).min() ?? 0
        let maxY = frames.map(\.maxY).max() ?? 0
        guard point.y >= minY, point.y <= maxY else { return nil }
        let ordered = frames.enumerated().sorted { $0.element.minX < $1.element.minX }
        let left = ordered.first!.element.minX
        let right = ordered.last!.element.maxX
        if foldersOnly {
            if point.x < left { return .gap(ordered.first!.offset == 0 ? 0 : frames.count) }
            if point.x > right { return .gap(ordered.last!.offset == frames.count - 1 ? frames.count : 0) }
            for i in 0...frames.count where abs(point.x - gapX(i, frames: frames)) <= gapReach { return .gap(i) }
        }
        if let hit = frames.firstIndex(where: { point.x >= $0.minX && point.x <= $0.maxX }) { return .tab(hit) }
        return nil
    }
}

@MainActor
final class TabDropHighlight: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 5
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension BrowserWindowController: NSDraggingDestination {
    struct TabDrop {
        let target: TabBarLayout.Target
        let tabs: [TabBarLayout.Tab]
        let operation: NSDragOperation
        let destination: URL?
        let folders: [URL]
    }

    static func browsableFolders(_ urls: [URL]) -> [URL]? {
        guard !urls.isEmpty else { return nil }
        var out: [URL] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true, values.isPackage != true else { return nil }
            out.append(url)
        }
        return out
    }

    func tabDrop(for info: NSDraggingInfo) -> TabDrop? {
        guard let window else { return nil }
        let tabs = TabBarLayout.tabs(in: window)
        guard !tabs.isEmpty else { return nil }
        let folders = Self.browsableFolders(DropSupport.fileURLs(info))
        guard let target = TabBarLayout.target(at: info.draggingLocation, frames: tabs.map(\.frame), foldersOnly: folders != nil) else { return nil }
        switch target {
        case .gap:
            return TabDrop(target: target, tabs: tabs, operation: .generic, destination: nil, folders: folders ?? [])
        case .tab(let index):
            guard let destination = (tabs[index].window.windowController as? BrowserWindowController)?.activePane.destinationFolder else { return nil }
            let operation = DropSupport.operation(for: info, destination: destination)
            guard !operation.isEmpty else { return nil }
            return TabDrop(target: target, tabs: tabs, operation: operation, destination: destination, folders: [])
        }
    }

    private func showTabHighlight(_ drop: TabDrop?) {
        guard let drop, let window, let bar = TabBarLayout.tabBar(in: window) else {
            tabDropHighlight?.removeFromSuperview()
            tabDropHighlight = nil
            return
        }
        let frames = drop.tabs.map(\.frame)
        let rect: NSRect
        switch drop.target {
        case .tab(let index):
            rect = frames[index].insetBy(dx: 2, dy: 2)
        case .gap(let index):
            let height = frames[0].height
            rect = NSRect(x: TabBarLayout.gapX(index, frames: frames) - 1.5, y: frames[0].minY + 2, width: 3, height: max(0, height - 4))
        }
        let highlight = tabDropHighlight ?? TabDropHighlight(frame: .zero)
        if highlight.superview !== bar { bar.addSubview(highlight) }
        highlight.frame = bar.convert(rect, from: nil)
        tabDropHighlight = highlight
    }

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = tabDrop(for: sender)
        showTabHighlight(drop)
        return drop?.operation ?? []
    }

    public func draggingExited(_ sender: NSDraggingInfo?) {
        showTabHighlight(nil)
    }

    public func draggingEnded(_ sender: NSDraggingInfo) {
        showTabHighlight(nil)
    }

    public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        tabDrop(for: sender) != nil
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let drop = tabDrop(for: sender)
        showTabHighlight(nil)
        guard let drop else { return false }
        switch drop.target {
        case .tab:
            guard let destination = drop.destination else { return false }
            return DropSupport.perform(sender, destination: destination)
        case .gap(let index):
            return openTabs(for: drop.folders, at: index, among: drop.tabs.map(\.window))
        }
    }

    @discardableResult
    func openTabs(for folders: [URL], at index: Int, among windows: [NSWindow]) -> Bool {
        guard !folders.isEmpty, !windows.isEmpty else { return false }
        var anchor = (index <= 0 ? windows[0] : windows[min(index, windows.count) - 1]).windowController as? BrowserWindowController
        var ordering: NSWindow.OrderingMode = index <= 0 ? .below : .above
        for folder in folders {
            guard let host = anchor else { return false }
            anchor = BrowserWindowManager.owner(of: host).openTab(at: .folder(folder), nextTo: host, ordered: ordering)
            ordering = .above
        }
        return true
    }

    func handleTabDoubleClick(at point: NSPoint) -> Bool {
        guard let window, let hit = TabBarLayout.tabs(in: window).first(where: { $0.frame.contains(point) }),
              let target = hit.window.windowController as? BrowserWindowController else { return false }
        if hit.window !== window { hit.window.makeKeyAndOrderFront(nil) }
        target.toggleDualPane(nil)
        return true
    }
}
