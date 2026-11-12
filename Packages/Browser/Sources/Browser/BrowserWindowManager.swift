import AppKit
import Integration

public enum BrowserOpenIntent: Sendable {
    case explicitNewWindow
    case request
}

public enum BrowserOpenRoute: Sendable, Equatable {
    case newWindow
    case tabInActiveWindow
}

@MainActor
public final class BrowserWindowManager {
    public static let shared = BrowserWindowManager()

    private(set) var controllers: [BrowserWindowController] = []
    private weak var lastActive: BrowserWindowController?
    weak var visor: VisorController?

    static func owner(of controller: BrowserWindowController) -> BrowserWindowManager {
        controller.manager ?? .shared
    }

    var standardControllers: [BrowserWindowController] { controllers.filter { !$0.isVisor } }

    var focusedController: BrowserWindowController? {
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController, controllers.contains(where: { $0 === key }) { return key }
        return activeController
    }

    nonisolated public static func route(intent: BrowserOpenIntent, tabsPreferred: Bool, hasWindow: Bool) -> BrowserOpenRoute {
        guard intent == .request, tabsPreferred, hasWindow else { return .newWindow }
        return .tabInActiveWindow
    }

    var activeController: BrowserWindowController? {
        let standard = standardControllers
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController, standard.contains(where: { $0 === key }) { return key }
        if let lastActive, standard.contains(where: { $0 === lastActive }) { return lastActive }
        return standard.last
    }

    @discardableResult
    public func open(at location: BrowserLocation, select: [URL] = [], intent: BrowserOpenIntent = .request) -> BrowserWindowController {
        let host = activeController
        switch Self.route(intent: intent, tabsPreferred: BrowserDefaults.openFoldersInTabs, hasWindow: host != nil) {
        case .newWindow:
            return openWindow(at: location, select: select)
        case .tabInActiveWindow:
            if host?.window?.isMiniaturized == true { host?.window?.deminiaturize(nil) }
            return openTab(at: location, select: select, nextTo: host)
        }
    }

    public var registries: BrowserRegistries

    public init(registries: BrowserRegistries? = nil) {
        self.registries = registries ?? .shared
    }

    public var isEmpty: Bool { standardControllers.isEmpty }

    private func make(_ location: BrowserLocation, visor: Bool = false) -> BrowserWindowController {
        let wc = BrowserWindowController(location: location, registries: registries, visor: visor)
        wc.manager = self
        controllers.append(wc)
        wc.onClose = { [weak self, weak wc] in
            guard let self, let wc else { return }
            if wc.isVisor { self.visor?.controllerClosed(wc) }
            self.controllers.removeAll { $0 === wc }
        }
        wc.onBecomeActive = { [weak self, weak wc] in
            guard let wc, !wc.isVisor else { return }
            self?.lastActive = wc
        }
        return wc
    }

    func openVisor(at location: BrowserLocation) -> BrowserWindowController {
        make(location, visor: true)
    }

    @discardableResult
    public func openWindow(at location: BrowserLocation = .folder(FileManager.default.homeDirectoryForCurrentUser), select: [URL] = []) -> BrowserWindowController {
        let wc = make(location)
        if let frontmost = NSApp.keyWindow, (frontmost.windowController as? BrowserWindowController)?.isVisor == false {
            wc.window?.setFrameTopLeftPoint(NSPoint(x: frontmost.frame.minX + 24, y: frontmost.frame.maxY - 24))
        } else if standardControllers.count == 1 {
            if wc.window?.setFrameUsingName("BrowserWindow") != true { wc.window?.center() }
        } else {
            wc.window?.center()
        }
        wc.showWindow(nil)
        if !select.isEmpty { wc.select(select) }
        return wc
    }

    @discardableResult
    public func openWindow(at provided: ProvidedLocation) -> BrowserWindowController {
        let wc = openWindow(at: .folder(FileManager.default.homeDirectoryForCurrentUser))
        wc.activePane.navigate(to: provided, record: false)
        return wc
    }

    @discardableResult
    public func openTab(at provided: ProvidedLocation, nextTo existing: BrowserWindowController?) -> BrowserWindowController {
        let wc = openTab(at: .folder(FileManager.default.homeDirectoryForCurrentUser), nextTo: existing)
        wc.activePane.navigate(to: provided, record: false)
        return wc
    }

    @discardableResult
    public func openTab(at location: BrowserLocation, select: [URL] = [], nextTo existing: BrowserWindowController?) -> BrowserWindowController {
        openTab(at: location, select: select, nextTo: existing, ordered: .above)
    }

    @discardableResult
    func openTab(at location: BrowserLocation, select: [URL] = [], nextTo existing: BrowserWindowController?, ordered: NSWindow.OrderingMode) -> BrowserWindowController {
        guard let host = existing?.window else { return openWindow(at: location, select: select) }
        let wc = make(location, visor: existing?.isVisor ?? false)
        if let w = wc.window {
            if wc.isVisor { w.setFrame(host.frame, display: false) }
            host.addTabbedWindow(w, ordered: ordered)
            w.makeKeyAndOrderFront(nil)
        }
        if !select.isEmpty { wc.select(select) }
        return wc
    }

    static func shows(_ controller: BrowserWindowController, _ location: BrowserLocation) -> Bool {
        guard case .local(let l) = controller.destination else { return false }
        return l.isSame(as: location)
    }

    func existing(showing location: BrowserLocation) -> BrowserWindowController? {
        let standard = standardControllers
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController, standard.contains(where: { $0 === key }), Self.shows(key, location) { return key }
        return standard.first { Self.shows($0, location) }
    }

    public func handle(_ request: IncomingOpenRequest) {
        switch request {
        case .openFolder(let url):
            if let w = existing(showing: .folder(url)) {
                w.window?.makeKeyAndOrderFront(nil)
            } else {
                open(at: .folder(url.standardizedFileURL))
            }
        case .reveal(let url):
            let parent = url.standardizedFileURL.deletingLastPathComponent()
            if let w = existing(showing: .folder(parent)) {
                w.window?.makeKeyAndOrderFront(nil)
                w.select([url.standardizedFileURL])
            } else {
                open(at: .folder(parent), select: [url.standardizedFileURL])
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func handle(urls: [URL]) {
        let reveals = urls.filter { if case .reveal = IncomingOpenRequest.classify($0) { return true }; return false }
        let folders = urls.filter { if case .openFolder = IncomingOpenRequest.classify($0) { return true }; return false }
        for f in folders { handle(.openFolder(f)) }
        let grouped = Dictionary(grouping: reveals) { $0.standardizedFileURL.deletingLastPathComponent().pathKey }
        for (_, items) in grouped {
            let parent = items[0].standardizedFileURL.deletingLastPathComponent()
            if let w = existing(showing: .folder(parent)) {
                w.window?.makeKeyAndOrderFront(nil)
                w.select(items.map(\.standardizedFileURL))
            } else {
                open(at: .folder(parent), select: items.map(\.standardizedFileURL))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
