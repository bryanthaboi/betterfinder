import AppKit
import Integration

public enum VisorSettings {
    public static let doubleTapKey = "visorDoubleTapOption"
    public static let allSpacesKey = "visorAllSpaces"
    public static let aboveDockKey = "visorAboveDock"
    public static let pinnedKey = "visorPinned"
    public static let heightKey = "visorHeight"

    static var store: UserDefaults { BrowserDefaults.store }
    static var doubleTap: Bool { store.bool(forKey: doubleTapKey) }
    static var allSpaces: Bool { store.object(forKey: allSpacesKey) as? Bool ?? true }
    static var aboveDock: Bool { store.bool(forKey: aboveDockKey) }

    static var pinned: Bool {
        get { store.bool(forKey: pinnedKey) }
        set { store.set(newValue, forKey: pinnedKey) }
    }

    static var height: CGFloat? {
        get { let v = store.double(forKey: heightKey); return v > 0 ? CGFloat(v) : nil }
        set { store.set(newValue.map(Double.init) ?? 0, forKey: heightKey) }
    }
}

public extension Notification.Name {
    static let visorPinDidChange = Notification.Name("VisorPinDidChange")
    static let visorVisibilityDidChange = Notification.Name("VisorVisibilityDidChange")
}

enum VisorLayout {
    static let minHeight: CGFloat = 240
    static let defaultFraction: CGFloat = 0.45
    static let tabbingIdentifier = "BetterFinderVisor"

    static func area(screenFrame: NSRect, visibleFrame: NSRect, aboveDock: Bool) -> NSRect {
        guard aboveDock else { return visibleFrame }
        return NSRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: max(0, visibleFrame.maxY - screenFrame.minY))
    }

    static func height(stored: CGFloat?, available: CGFloat) -> CGFloat {
        let wanted = stored ?? (available * defaultFraction).rounded()
        return max(min(wanted, available), min(minHeight, available))
    }

    static func frame(screenFrame: NSRect, visibleFrame: NSRect, storedHeight: CGFloat?, aboveDock: Bool) -> NSRect {
        let area = area(screenFrame: screenFrame, visibleFrame: visibleFrame, aboveDock: aboveDock)
        return NSRect(x: area.minX, y: area.minY, width: area.width, height: height(stored: storedHeight, available: area.height))
    }

    static func hiddenFrame(for shown: NSRect, screenFrame: NSRect) -> NSRect {
        NSRect(x: shown.minX, y: screenFrame.minY - shown.height, width: shown.width, height: shown.height)
    }

    static func level(aboveDock: Bool) -> NSWindow.Level {
        aboveDock ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1) : .normal
    }

    static func collectionBehavior(allSpaces: Bool) -> NSWindow.CollectionBehavior {
        allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenNone]
    }
}

@MainActor
public final class VisorController {
    public static let shared = VisorController()

    public struct Screen {
        public var frame: NSRect
        public var visibleFrame: NSRect

        public init(frame: NSRect, visibleFrame: NSRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    public var initialLocation: @MainActor () -> BrowserLocation = { .folder(FileManager.default.homeDirectoryForCurrentUser) }
    public var screenProvider: @MainActor () -> Screen? = {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
    public var animationDuration: TimeInterval = 0.18
    var activate: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var frontmostApplication: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public private(set) var isShown = false
    let manager: BrowserWindowManager
    private let hotKey: GlobalHotKey?
    private let doubleTap = ModifierDoubleTap(modifier: .option)
    private var previousApp: NSRunningApplication?
    private var order: [BrowserWindowController] = []
    private weak var selected: BrowserWindowController?
    private var generation = 0
    private var raised: [(window: NSWindow, level: NSWindow.Level)] = []
    private var observers: [NSObjectProtocol] = []
    private var screen: Screen?

    public init(manager: BrowserWindowManager? = nil, hotKey: GlobalHotKey? = nil) {
        self.manager = manager ?? .shared
        self.hotKey = hotKey
        self.manager.visor = self
    }

    public func install() {
        let key = hotKey ?? .visor
        key.onTrigger = { [weak self] in self?.toggle() }
        key.restoreFromDefaults()
        doubleTap.onTrigger = { [weak self] in self?.toggle() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationResignedActive() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { self?.windowBecameKey(window) } }
        })
        settingsChanged()
    }

    public func uninstall() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        doubleTap.stop()
        (hotKey ?? .visor).onTrigger = nil
    }

    public var isPinned: Bool {
        get { VisorSettings.pinned }
        set {
            guard newValue != VisorSettings.pinned else { return }
            VisorSettings.pinned = newValue
            NotificationCenter.default.post(name: .visorPinDidChange, object: self)
        }
    }

    public func togglePinned() { isPinned.toggle() }

    var controllers: [BrowserWindowController] { manager.controllers.filter(\.isVisor) }

    var frontController: BrowserWindowController? {
        let all = controllers
        func known(_ window: NSWindow?) -> BrowserWindowController? {
            (window?.windowController as? BrowserWindowController).flatMap { c in all.first { $0 === c } }
        }
        if let key = known(NSApp.keyWindow) { return key }
        if isShown, let visible = all.first(where: { $0.window?.isVisible == true }), let picked = known(visible.window?.tabGroup?.selectedWindow) { return picked }
        if let selected, all.contains(where: { $0 === selected }) { return selected }
        return all.first
    }

    var shownFrame: NSRect? {
        guard let screen = screen ?? screenProvider() else { return nil }
        return VisorLayout.frame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, storedHeight: VisorSettings.height, aboveDock: VisorSettings.aboveDock)
    }

    private func applyBehaviors() {
        let level = VisorLayout.level(aboveDock: VisorSettings.aboveDock)
        let behavior = VisorLayout.collectionBehavior(allSpaces: VisorSettings.allSpaces)
        for c in controllers {
            guard let w = c.window else { continue }
            if w.level != level { w.level = level }
            if w.collectionBehavior != behavior { w.collectionBehavior = behavior }
        }
        if !isShown || !VisorSettings.aboveDock { restoreRaised() }
    }

    private func settingsChanged() {
        let wantsDoubleTap = (hotKey ?? .visor).isEnabled && VisorSettings.doubleTap
        if wantsDoubleTap != doubleTap.isRunning {
            if wantsDoubleTap { doubleTap.start() } else { doubleTap.stop() }
        }
        applyBehaviors()
        if isShown { reposition() }
    }

    public func toggle() {
        if isShown, let window = frontController?.window, window.isKeyWindow, NSApp.isActive {
            hide(returnFocus: true)
        } else {
            show()
        }
    }

    private func groupedOrder() -> [BrowserWindowController] {
        let all = controllers
        var out: [BrowserWindowController] = []
        func add(_ c: BrowserWindowController?) {
            guard let c, all.contains(where: { $0 === c }), !out.contains(where: { $0 === c }) else { return }
            out.append(c)
        }
        if isShown, let front = frontController?.window {
            for w in front.tabbedWindows ?? [front] { add(w.windowController as? BrowserWindowController) }
        }
        for c in order { add(c) }
        for c in all { add(c) }
        return out
    }

    private func regroup(_ list: [BrowserWindowController], frame: NSRect) {
        guard let first = list.first?.window else { return }
        for c in list { c.window?.setFrame(frame, display: false) }
        first.orderFront(nil)
        var previous = first
        for c in list.dropFirst() {
            guard let w = c.window else { continue }
            if previous.tabbedWindows?.contains(w) != true { previous.addTabbedWindow(w, ordered: .above) }
            previous = w
        }
    }

    public func show() {
        guard let screen = screenProvider() else { return }
        self.screen = screen
        if let front = frontmostApplication(), front != .current {
            previousApp = front
        } else if !isShown {
            previousApp = nil
        }
        if controllers.isEmpty { _ = manager.openVisor(at: initialLocation()) }
        applyBehaviors()
        guard let target = shownFrame else { return }
        let list = groupedOrder()
        guard let chosen = (selected.flatMap { s in list.first { $0 === s } }) ?? list.first, let window = chosen.window else { return }
        generation += 1
        if isShown {
            for c in list { c.window?.setFrame(target, display: true) }
        } else {
            let start = VisorLayout.hiddenFrame(for: target, screenFrame: screen.frame)
            let fades = reduceMotion()
            regroup(list, frame: fades ? target : start)
            if fades { window.alphaValue = 0 }
            isShown = true
            animate(window, to: target, alpha: 1) {
                for c in list where c.window !== window { c.window?.setFrame(target, display: false) }
            }
        }
        isShown = true
        order = list
        selected = chosen
        activate()
        window.makeKeyAndOrderFront(nil)
        chosen.activePane.focusVisibleContent()
        NotificationCenter.default.post(name: .visorVisibilityDidChange, object: self)
    }

    public func hide(returnFocus: Bool = false) {
        guard isShown else { return }
        let list = groupedOrder()
        let front = frontController
        isShown = false
        order = list
        selected = front
        restoreRaised()
        let app = previousApp
        previousApp = nil
        generation += 1
        let token = generation
        NotificationCenter.default.post(name: .visorVisibilityDidChange, object: self)
        guard let window = front?.window, let screen = screen ?? screenProvider() else {
            for c in list { c.window?.orderOut(nil) }
            return
        }
        let fades = reduceMotion()
        let end = fades ? window.frame : VisorLayout.hiddenFrame(for: window.frame, screenFrame: screen.frame)
        animate(window, to: end, alpha: fades ? 0 : 1) { [weak self] in
            guard let self, self.generation == token else { return }
            for c in list { c.window?.orderOut(nil) }
            window.alphaValue = 1
        }
        if returnFocus, let app, !app.isTerminated { app.activate() }
    }

    private func animate(_ window: NSWindow, to frame: NSRect, alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
        guard animationDuration > 0 else {
            window.setFrame(frame, display: true)
            window.alphaValue = alpha
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }

    func reposition() {
        guard isShown, let current = screenProvider() else { return }
        screen = current
        guard let target = shownFrame else { return }
        for c in controllers where c.window?.frame != target { c.window?.setFrame(target, display: true) }
    }

    func constrainedSize(_ proposed: NSSize, for window: NSWindow) -> NSSize {
        guard let screen = screen ?? screenProvider() else { return proposed }
        let area = VisorLayout.area(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, aboveDock: VisorSettings.aboveDock)
        return NSSize(width: area.width, height: VisorLayout.height(stored: proposed.height, available: area.height))
    }

    func userResized(_ window: NSWindow) {
        guard isShown else { return }
        VisorSettings.height = window.frame.height
        reposition()
    }

    func controllerClosed(_ controller: BrowserWindowController) {
        order.removeAll { $0 === controller }
        guard controllers.allSatisfy({ $0 === controller }) else { return }
        guard isShown else { return }
        isShown = false
        previousApp = nil
        restoreRaised()
        NotificationCenter.default.post(name: .visorVisibilityDidChange, object: self)
    }

    private func applicationResignedActive() {
        guard isShown, !isPinned else { return }
        hide(returnFocus: false)
    }

    private func windowBecameKey(_ window: NSWindow) {
        if let c = window.windowController as? BrowserWindowController, c.isVisor {
            if isShown { selected = c }
            return
        }
        guard isShown, VisorSettings.aboveDock else { return }
        let level = VisorLayout.level(aboveDock: true)
        guard window.level.rawValue <= level.rawValue, !raised.contains(where: { $0.window === window }) else { return }
        raised.append((window, window.level))
        window.level = NSWindow.Level(rawValue: level.rawValue + 1)
    }

    private func restoreRaised() {
        for entry in raised { entry.window.level = entry.level }
        raised.removeAll()
    }

    var raisedWindows: [NSWindow] { raised.map(\.window) }
}
