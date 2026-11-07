import AppKit
import Integration

@MainActor
public final class BrowserWindowManager {
    public static let shared = BrowserWindowManager()

    private(set) var controllers: [BrowserWindowController] = []

    public var registries: BrowserRegistries

    public init(registries: BrowserRegistries? = nil) {
        self.registries = registries ?? .shared
    }

    public var isEmpty: Bool { controllers.isEmpty }

    private func make(_ location: BrowserLocation) -> BrowserWindowController {
        let wc = BrowserWindowController(location: location, registries: registries)
        controllers.append(wc)
        wc.onClose = { [weak self, weak wc] in
            self?.controllers.removeAll { $0 === wc }
        }
        return wc
    }

    @discardableResult
    public func openWindow(at location: BrowserLocation = .folder(FileManager.default.homeDirectoryForCurrentUser), select: [URL] = []) -> BrowserWindowController {
        let wc = make(location)
        if let frontmost = NSApp.keyWindow, frontmost.windowController is BrowserWindowController {
            wc.window?.setFrameTopLeftPoint(NSPoint(x: frontmost.frame.minX + 24, y: frontmost.frame.maxY - 24))
        } else if controllers.count == 1 {
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
        guard let host = existing?.window else { return openWindow(at: location, select: select) }
        let wc = make(location)
        if let w = wc.window {
            host.addTabbedWindow(w, ordered: .above)
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
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController, controllers.contains(where: { $0 === key }), Self.shows(key, location) { return key }
        return controllers.first { Self.shows($0, location) }
    }

    public func handle(_ request: IncomingOpenRequest) {
        switch request {
        case .openFolder(let url):
            if let w = existing(showing: .folder(url)) {
                w.window?.makeKeyAndOrderFront(nil)
            } else {
                openWindow(at: .folder(url.standardizedFileURL))
            }
        case .reveal(let url):
            let parent = url.standardizedFileURL.deletingLastPathComponent()
            if let w = existing(showing: .folder(parent)) {
                w.window?.makeKeyAndOrderFront(nil)
                w.select([url.standardizedFileURL])
            } else {
                openWindow(at: .folder(parent), select: [url.standardizedFileURL])
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
                openWindow(at: .folder(parent), select: items.map(\.standardizedFileURL))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
