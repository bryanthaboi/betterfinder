import AppKit

extension BrowserWindowManager {
    func tabGroup(of controller: BrowserWindowController) -> [BrowserWindowController] {
        guard let window = controller.window else { return [controller] }
        let windows = window.tabbedWindows ?? [window]
        return windows.compactMap { w in controllers.first { $0.window === w } }
    }

    var standardWindowGroups: [[BrowserWindowController]] {
        var seen = Set<ObjectIdentifier>()
        var groups: [[BrowserWindowController]] = []
        for c in standardControllers where !seen.contains(ObjectIdentifier(c)) {
            let group = tabGroup(of: c)
            for g in group { seen.insert(ObjectIdentifier(g)) }
            groups.append(group)
        }
        return groups
    }

    var visorAvailable: Bool { visor?.isEnabled ?? false }

    func mergeAllWindows(into host: BrowserWindowController) {
        guard !host.isVisor, let hostWindow = host.window else { return }
        var previous = hostWindow.tabbedWindows?.last ?? hostWindow
        for group in standardWindowGroups where !group.contains(where: { $0 === host }) {
            for c in group {
                guard let w = c.window else { continue }
                w.tabGroup?.removeWindow(w)
                previous.addTabbedWindow(w, ordered: .above)
                previous = w
            }
        }
        hostWindow.makeKeyAndOrderFront(nil)
    }

    func splitTabsIntoWindows(_ host: BrowserWindowController) {
        guard !host.isVisor, let hostWindow = host.window else { return }
        var origin = hostWindow.frame.origin
        for c in tabGroup(of: host) where c !== host {
            guard let w = c.window else { continue }
            w.moveTabToNewWindow(nil)
            origin = NSPoint(x: origin.x + 24, y: origin.y - 24)
            w.setFrameOrigin(origin)
            w.orderFront(nil)
        }
        hostWindow.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func transfer(_ c: BrowserWindowController, toVisor: Bool, nextTo host: BrowserWindowController?) -> BrowserWindowController? {
        guard c.isVisor != toVisor else { return c }
        let destination = c.destination
        let selection = c.activePane.selectedURLs
        let local: BrowserLocation
        if case .local(let l) = destination { local = l } else { local = .folder(FileManager.default.homeDirectoryForCurrentUser) }
        let moved: BrowserWindowController
        if let host, host.isVisor == toVisor {
            moved = openTab(at: local, select: selection, nextTo: host)
        } else if toVisor {
            guard let visor else { return nil }
            moved = visor.openWindow(at: local, select: selection)
        } else {
            moved = openStandardWindow(at: local, select: selection)
        }
        if case .provided(let p) = destination { moved.activePane.navigate(to: p, record: false) }
        c.close()
        return moved
    }

    func moveToVisor(_ list: [BrowserWindowController]) {
        guard let visor, !list.isEmpty else { return }
        var host = visor.controllers.isEmpty ? nil : visor.frontController
        for c in list where !c.isVisor { host = transfer(c, toVisor: true, nextTo: host) ?? host }
        visor.show()
        host?.window?.makeKeyAndOrderFront(nil)
    }

    func moveOutOfVisor(_ list: [BrowserWindowController]) {
        var host: BrowserWindowController?
        for c in list where c.isVisor { host = transfer(c, toVisor: false, nextTo: host) ?? host }
        NSApp.activate(ignoringOtherApps: true)
        host?.window?.makeKeyAndOrderFront(nil)
    }

    func closeAllStandardWindows(except keep: BrowserWindowController? = nil) {
        let keepGroup = keep.map { tabGroup(of: $0) } ?? []
        for c in standardControllers where !keepGroup.contains(where: { $0 === c }) { c.window?.performClose(nil) }
    }
}

extension BrowserWindowController {
    var arrangementManager: BrowserWindowManager { manager ?? .shared }

    func buildWindowsMenu(into menu: NSMenu) {
        menu.removeAllItems()
        let m = arrangementManager
        func add(_ title: String, _ action: Selector, symbol: String, enabled: Bool) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let tabs = m.tabGroup(of: self).count
        if isVisor {
            add("Move Tab out of Visor", #selector(moveTabOutOfVisor(_:)), symbol: "macwindow", enabled: true)
            add("Move All Visor Tabs to a Window", #selector(moveVisorOut(_:)), symbol: "macwindow.on.rectangle", enabled: true)
        } else {
            add("Merge All Windows into Tabs", #selector(mergeAllIntoTabs(_:)), symbol: "rectangle.stack", enabled: m.standardWindowGroups.count > 1)
            add("Split Tabs into Windows", #selector(splitTabsIntoWindows(_:)), symbol: "rectangle.split.3x1", enabled: tabs > 1)
            add("Move Tab to New Window", #selector(moveTabToOwnWindow(_:)), symbol: "macwindow.badge.plus", enabled: tabs > 1)
            if m.visorAvailable {
                menu.addItem(.separator())
                add("Move Tab to Visor", #selector(moveTabToVisor(_:)), symbol: "rectangle.bottomthird.inset.filled", enabled: true)
                add("Move Window to Visor", #selector(moveWindowToVisor(_:)), symbol: "rectangle.bottomhalf.inset.filled", enabled: true)
                add("Move All Windows to Visor", #selector(moveAllWindowsToVisor(_:)), symbol: "rectangle.stack.badge.plus", enabled: true)
            }
        }
        menu.addItem(.separator())
        add("Close All Windows", #selector(closeAllWindows(_:)), symbol: "xmark.rectangle", enabled: !m.standardControllers.isEmpty)
    }

    func closeButtonMenu() -> NSMenu {
        let menu = NSMenu()
        let close = NSMenuItem(title: isVisor ? "Close Visor Tab" : "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        close.target = window
        menu.addItem(close)
        if !isVisor {
            let others = NSMenuItem(title: "Close Other Windows", action: arrangementManager.standardWindowGroups.count > 1 ? #selector(closeOtherWindows(_:)) : nil, keyEquivalent: "")
            others.target = self
            menu.addItem(others)
        }
        let all = NSMenuItem(title: "Close All betterfinder Windows", action: #selector(closeAllWindows(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        return menu
    }

    @objc func moveTabToOwnWindow(_ sender: Any?) { window?.moveTabToNewWindow(nil) }
    @objc func mergeAllIntoTabs(_ sender: Any?) { arrangementManager.mergeAllWindows(into: self) }
    @objc func splitTabsIntoWindows(_ sender: Any?) { arrangementManager.splitTabsIntoWindows(self) }
    @objc func moveTabToVisor(_ sender: Any?) { arrangementManager.moveToVisor([self]) }
    @objc func moveWindowToVisor(_ sender: Any?) { arrangementManager.moveToVisor(arrangementManager.tabGroup(of: self)) }
    @objc func moveAllWindowsToVisor(_ sender: Any?) { arrangementManager.moveToVisor(arrangementManager.standardWindowGroups.flatMap { $0 }) }
    @objc func moveTabOutOfVisor(_ sender: Any?) { arrangementManager.moveOutOfVisor([self]) }
    @objc func moveVisorOut(_ sender: Any?) { arrangementManager.moveOutOfVisor(arrangementManager.visor?.controllers ?? []) }
    @objc func closeAllWindows(_ sender: Any?) { arrangementManager.closeAllStandardWindows() }
    @objc func closeOtherWindows(_ sender: Any?) { arrangementManager.closeAllStandardWindows(except: self) }
}
