import AppKit
import XCTest
import Integration
@testable import Browser

@MainActor
final class WindowArrangementTests: XCTestCase {
    private var savedStore: UserDefaults!
    private var suite = ""
    private var dir: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suite = "WindowArrangementTests.\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suite)!
        BrowserDefaults.viewMode = .list
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("Arrange-\(UUID().uuidString)", isDirectory: true)
        for name in ["A", "B", "C"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true) }
    }

    override func tearDown() async throws {
        BrowserDefaults.store.removePersistentDomain(forName: suite)
        BrowserDefaults.store = savedStore
        try? FileManager.default.removeItem(at: dir)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeVisor(_ manager: BrowserWindowManager, enabled: Bool) -> VisorController {
        let hotKey = GlobalHotKey(defaults: BrowserDefaults.store, id: 79, comboDefaultsKey: "test.visorCombo", enabledDefaultsKey: "test.visorEnabled", defaultCombo: .visorDefault)
        BrowserDefaults.store.set(enabled, forKey: "test.visorEnabled")
        let visor = VisorController(manager: manager, hotKey: hotKey)
        visor.animationDuration = 0
        let dir = dir!
        visor.initialLocation = { .folder(dir) }
        visor.screenProvider = { VisorController.Screen(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: NSRect(x: 0, y: 70, width: 1600, height: 900)) }
        visor.activate = {}
        visor.frontmostApplication = { nil }
        visor.reduceMotion = { false }
        return visor
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }
    private func enabled(_ menu: NSMenu, _ title: String) -> Bool { menu.items.first { $0.title == title }?.action != nil }

    func testMergeAndSplitStandardWindows() throws {
        let m = BrowserWindowManager()
        defer { for c in m.controllers { c.close() } }
        let a = m.openWindow(at: .folder(dir.appendingPathComponent("A")))
        _ = m.openWindow(at: .folder(dir.appendingPathComponent("B")))
        _ = m.openWindow(at: .folder(dir.appendingPathComponent("C")))
        XCTAssertEqual(m.standardWindowGroups.count, 3)

        let menu = NSMenu()
        a.buildWindowsMenu(into: menu)
        XCTAssertTrue(enabled(menu, "Merge All Windows into Tabs"))
        XCTAssertFalse(enabled(menu, "Split Tabs into Windows"))
        XCTAssertFalse(titles(menu).contains("Move Tab to Visor"))

        a.mergeAllIntoTabs(nil)
        XCTAssertTrue(spin { m.standardWindowGroups.count == 1 })
        XCTAssertEqual(a.window?.tabbedWindows?.count, 3)

        a.buildWindowsMenu(into: menu)
        XCTAssertFalse(enabled(menu, "Merge All Windows into Tabs"))
        XCTAssertTrue(enabled(menu, "Split Tabs into Windows"))

        a.splitTabsIntoWindows(nil)
        XCTAssertTrue(spin { m.standardWindowGroups.count == 3 })
        XCTAssertEqual(m.standardControllers.count, 3)
    }

    func testMoveTabsAndWindowsIntoAndOutOfVisor() throws {
        let m = BrowserWindowManager()
        let visor = makeVisor(m, enabled: true)
        defer { for c in m.controllers { c.close() } }
        let a = m.openWindow(at: .folder(dir.appendingPathComponent("A")))
        m.openTab(at: .folder(dir.appendingPathComponent("B")), nextTo: a)
        let c = m.openWindow(at: .folder(dir.appendingPathComponent("C")))

        let menu = NSMenu()
        c.buildWindowsMenu(into: menu)
        XCTAssertTrue(titles(menu).contains("Move Tab to Visor"))
        XCTAssertTrue(titles(menu).contains("Move All Windows to Visor"))

        c.moveTabToVisor(nil)
        XCTAssertTrue(spin { visor.controllers.count == 1 })
        XCTAssertTrue(visor.isShown)
        XCTAssertTrue(BrowserWindowManager.shows(visor.controllers[0], .folder(dir.appendingPathComponent("C"))))
        XCTAssertEqual(m.standardControllers.count, 2)

        a.moveWindowToVisor(nil)
        XCTAssertTrue(spin { visor.controllers.count == 3 && m.standardControllers.isEmpty })
        let visorTab = visor.controllers[0]
        XCTAssertEqual(visorTab.window?.tabbedWindows?.count, 3)

        visorTab.buildWindowsMenu(into: menu)
        XCTAssertEqual(titles(menu).prefix(2), ["Move Tab out of Visor", "Move All Visor Tabs to a Window"])

        visorTab.moveVisorOut(nil)
        XCTAssertTrue(spin { visor.controllers.isEmpty && m.standardControllers.count == 3 })
        XCTAssertEqual(m.standardWindowGroups.count, 1)
    }

    func testMovingOutOfVisorBypassesOpenAllWindowsInVisor() throws {
        let m = BrowserWindowManager()
        let visor = makeVisor(m, enabled: true)
        defer { for c in m.controllers { c.close() } }
        BrowserDefaults.store.set(true, forKey: VisorSettings.opensWindowsKey)
        let v = m.openWindow(at: .folder(dir.appendingPathComponent("A")))
        XCTAssertTrue(v.isVisor)
        v.moveTabOutOfVisor(nil)
        XCTAssertTrue(spin { visor.controllers.isEmpty && m.standardControllers.count == 1 })
    }

    func testVisorItemsHiddenWhenVisorOff() {
        let m = BrowserWindowManager()
        _ = makeVisor(m, enabled: false)
        defer { for c in m.controllers { c.close() } }
        let a = m.openWindow(at: .folder(dir))
        let menu = NSMenu()
        a.buildWindowsMenu(into: menu)
        XCTAssertFalse(titles(menu).contains { $0.contains("Visor") })
    }

    func testCloseButtonMenuAndCloseAll() throws {
        let m = BrowserWindowManager()
        defer { for c in m.controllers { c.close() } }
        let a = m.openWindow(at: .folder(dir.appendingPathComponent("A")))
        _ = m.openWindow(at: .folder(dir.appendingPathComponent("B")))
        _ = m.openWindow(at: .folder(dir.appendingPathComponent("C")))
        let window = try XCTUnwrap(a.window as? BrowserWindow)
        window.displayIfNeeded()
        let close = try XCTUnwrap(window.closeButtonView)
        let center = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        XCTAssertTrue(window.isOnCloseButton(center))
        XCTAssertFalse(window.isOnCloseButton(NSPoint(x: 500, y: 300)))
        let menu = try XCTUnwrap(window.closeButtonMenu?())
        XCTAssertEqual(titles(menu), ["Close Window", "Close Other Windows", "Close All betterfinder Windows"])

        a.closeOtherWindows(nil)
        XCTAssertTrue(spin { m.standardControllers.count == 1 })
        XCTAssertTrue(m.standardControllers.first === a)
        a.closeAllWindows(nil)
        XCTAssertTrue(spin { m.standardControllers.isEmpty })
    }

    func testToolbarHasWindowsButton() throws {
        let m = BrowserWindowManager()
        defer { for c in m.controllers { c.close() } }
        let a = m.openWindow(at: .folder(dir))
        let ids = a.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        XCTAssertTrue(ids.contains("windows"), "\(ids)")
    }
}
