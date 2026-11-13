import AppKit
import XCTest
import Integration
@testable import Browser

final class TerminalEmulatorTests: XCTestCase {
    func testPrintsWrapsAndScrollsIntoScrollback() {
        let t = TerminalEmulator(cols: 5, rows: 2)
        t.feed("abcdefg\r\nxy\r\nz")
        XCTAssertEqual(t.screenText, "xy\nz")
        XCTAssertEqual(t.scrollback.map(\.text), ["abcde", "fg   "])
        XCTAssertTrue(t.scrollback[0].wrapped)
        XCTAssertEqual(t.cursorX, 1)
        XCTAssertEqual(t.cursorY, 1)
    }

    func testCursorMovementAndErase() {
        let t = TerminalEmulator(cols: 10, rows: 3)
        t.feed("hello\r\nworld")
        t.feed("\u{1B}[1;3H")
        t.feed("\u{1B}[K")
        XCTAssertEqual(t.screenText, "he\nworld\n")
        t.feed("\u{1B}[2J\u{1B}[H")
        XCTAssertEqual(t.screenText, "\n\n")
        XCTAssertEqual(t.cursorX, 0)
        XCTAssertEqual(t.cursorY, 0)
    }

    func testSGRColorsAndReset() {
        let t = TerminalEmulator(cols: 10, rows: 1)
        t.feed("\u{1B}[1;31ma\u{1B}[38;5;200mb\u{1B}[38;2;1;2;3;48;5;4mc\u{1B}[0md")
        let cells = t.lines[0].cells
        XCTAssertTrue(cells[0].attrs.bold)
        XCTAssertEqual(cells[0].attrs.fg, TerminalColor(kind: .indexed(1)))
        XCTAssertEqual(cells[1].attrs.fg, TerminalColor(kind: .indexed(200)))
        XCTAssertEqual(cells[2].attrs.fg, TerminalColor(kind: .rgb(1, 2, 3)))
        XCTAssertEqual(cells[2].attrs.bg, TerminalColor(kind: .indexed(4)))
        XCTAssertEqual(cells[3].attrs, TerminalAttributes())
    }

    func testAlternateScreenRestoresMainScreen() {
        let t = TerminalEmulator(cols: 8, rows: 2)
        t.feed("shell$ ")
        t.feed("\u{1B}[?1049h\u{1B}[Hvim")
        XCTAssertTrue(t.usingAlternateScreen)
        XCTAssertEqual(t.screenText, "vim\n")
        t.feed("\u{1B}[?1049l")
        XCTAssertFalse(t.usingAlternateScreen)
        XCTAssertEqual(t.screenText, "shell$\n")
        XCTAssertEqual(t.cursorX, 7)
    }

    func testScrollRegionInsertDeleteLines() {
        let t = TerminalEmulator(cols: 4, rows: 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.feed("\u{1B}[2;3r\u{1B}[3;1H\n")
        XCTAssertEqual(t.screenText, "1\n3\n\n4")
        XCTAssertTrue(t.scrollback.isEmpty)
        t.feed("\u{1B}[r\u{1B}[2;1H\u{1B}[L")
        XCTAssertEqual(t.screenText, "1\n\n3\n")
    }

    func testWideCharactersAndCombiningMarks() {
        let t = TerminalEmulator(cols: 6, rows: 1)
        t.feed("日本e\u{301}")
        XCTAssertEqual(t.lines[0].cells[0].width, 2)
        XCTAssertEqual(t.lines[0].cells[1].width, 0)
        XCTAssertEqual(t.lines[0].cells[4].text, "e\u{301}")
        XCTAssertEqual(t.cursorX, 5)
    }

    func testSplitUTF8AcrossFeeds() {
        let t = TerminalEmulator(cols: 6, rows: 1)
        let bytes = Array("é✓".utf8)
        t.feed(Array(bytes[0..<1]))
        t.feed(Array(bytes[1..<3]))
        t.feed(Array(bytes[3...]))
        XCTAssertEqual(t.screenText, "é✓")
    }

    func testResponsesAndModes() {
        let t = TerminalEmulator(cols: 10, rows: 5)
        var replies: [String] = []
        t.respond = { replies.append(String(decoding: $0, as: UTF8.self)) }
        t.feed("ab\u{1B}[6n\u{1B}[c\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l\u{1B}]0;my title\u{07}")
        XCTAssertEqual(replies.first, "\u{1B}[1;3R")
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(t.applicationCursorKeys)
        XCTAssertTrue(t.bracketedPaste)
        XCTAssertFalse(t.cursorVisible)
        XCTAssertEqual(t.title, "my title")
    }

    func testResizeKeepsCursorLineAndRestoresScrollback() {
        let t = TerminalEmulator(cols: 10, rows: 4)
        t.feed("a\r\nb\r\nc\r\nd")
        t.resize(cols: 6, rows: 2)
        XCTAssertEqual(t.screenText, "c\nd")
        XCTAssertEqual(t.cursorY, 1)
        t.resize(cols: 6, rows: 4)
        XCTAssertEqual(t.screenText, "a\nb\nc\nd")
        XCTAssertEqual(t.cursorY, 3)
    }

    @MainActor
    func testKeyEncoding() {
        func enc(_ code: UInt16, _ chars: String? = nil, _ mods: NSEvent.ModifierFlags = [], app: Bool = false) -> String? {
            TerminalView.encode(keyCode: code, characters: chars, ignoringModifiers: chars, modifiers: mods, applicationCursor: app).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(enc(36, "\r"), "\r")
        XCTAssertEqual(enc(51, "\u{7F}"), "\u{7F}")
        XCTAssertEqual(enc(51, "\u{7F}", .option), "\u{1B}\u{7F}")
        XCTAssertEqual(enc(126), "\u{1B}[A")
        XCTAssertEqual(enc(126, app: true), "\u{1B}OA")
        XCTAssertEqual(enc(123, nil, .option), "\u{1B}b")
        XCTAssertEqual(enc(124, nil, .shift), "\u{1B}[1;2C")
        XCTAssertEqual(enc(48, "\t", .shift), "\u{1B}[Z")
        XCTAssertEqual(enc(8, "c", .control), "\u{03}")
        XCTAssertEqual(enc(0, "å", .option), "å")
        XCTAssertEqual(enc(96), "\u{1B}[15~")
    }

    func testShellQuoting() {
        XCTAssertEqual(TerminalSession.shellQuote("/tmp/it's here"), "'/tmp/it'\\''s here'")
    }

    func testShellDetection() {
        let found = TerminalShells.detect(etcShells: "# comment\n/bin/bash\n/bin/zsh\n/bin/missing\n", directories: ["/opt/x"], isExecutable: { ["/bin/bash", "/bin/zsh", "/opt/x/fish"].contains($0) })
        XCTAssertEqual(found.map(\.path), ["/bin/zsh", "/bin/bash", "/opt/x/fish"])
        XCTAssertEqual(found.last?.name, "fish (/opt/x)")
    }
}

@MainActor
final class VisorTerminalTests: XCTestCase {
    private var savedStore: UserDefaults!
    private var suite = ""
    private var dir: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        savedStore = BrowserDefaults.store
        suite = "VisorTerminalTests.\(UUID().uuidString)"
        BrowserDefaults.store = UserDefaults(suiteName: suite)!
        BrowserDefaults.viewMode = .list
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VisorTerminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        BrowserDefaults.store.removePersistentDomain(forName: suite)
        BrowserDefaults.store = savedStore
        try? FileManager.default.removeItem(at: dir)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeVisor(_ manager: BrowserWindowManager) -> VisorController {
        let hotKey = GlobalHotKey(defaults: BrowserDefaults.store, id: 78, comboDefaultsKey: "test.visorCombo", enabledDefaultsKey: "test.visorEnabled", defaultCombo: .visorDefault)
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

    func testRealShellRunsInPTY() throws {
        let session = TerminalSession(shellPath: "/bin/sh", directory: dir, cols: 60, rows: 10)
        session.start()
        defer { session.terminate() }
        session.send("printf 'cwd=%s\\n' \"$PWD\"; echo $TERM\r")
        XCTAssertTrue(spin(until: { session.emulator.screenText.contains("xterm-256color") }), session.emulator.screenText)
        XCTAssertTrue(session.emulator.screenText.contains("cwd=") && session.emulator.screenText.contains("\(dir.lastPathComponent)\n"), session.emulator.screenText)
        session.changeDirectory(to: dir.appendingPathComponent("Sub"))
        XCTAssertTrue(spin(until: { session.currentDirectory?.lastPathComponent == "Sub" }))
        session.send("exit\r")
        XCTAssertTrue(spin(until: { session.exited }))
    }

    func testOpenInTerminalRoutesToVisorSplitOnlyWhenEnabled() throws {
        let manager = BrowserWindowManager()
        let visor = makeVisor(manager)
        defer { for c in manager.controllers { c.close() } }
        XCTAssertFalse(visor.routesOpenInTerminal)
        BrowserDefaults.store.set(true, forKey: VisorSettings.terminalKey)
        XCTAssertFalse(visor.routesOpenInTerminal)
        BrowserDefaults.store.set(true, forKey: "test.visorEnabled")
        XCTAssertTrue(visor.routesOpenInTerminal)
        BrowserDefaults.store.set("/bin/sh", forKey: TerminalShells.shellPathKey)

        visor.openTerminal(at: dir.appendingPathComponent("Sub"))
        let front = try XCTUnwrap(visor.frontController)
        XCTAssertTrue(front.isTerminalShown)
        let panel = try XCTUnwrap(front.terminalPanel)
        XCTAssertEqual(panel.sessions.count, 1)
        XCTAssertEqual(panel.sessions[0].shellPath, "/bin/sh")
        XCTAssertTrue(spin(until: { panel.sessions[0].currentDirectory?.lastPathComponent == "Sub" }))
        let terminalWidth = panel.view.frame.width
        let total = front.window!.frame.width
        XCTAssertEqual(terminalWidth / total, 0.5, accuracy: 0.05)

        panel.newSession(directory: dir)
        XCTAssertEqual(panel.sessions.count, 2)
        XCTAssertTrue(panel.active === panel.sessions[1])
        panel.selectNext(1)
        XCTAssertTrue(panel.active === panel.sessions[0])

        front.hideTerminal()
        XCTAssertFalse(front.isTerminalShown)
        XCTAssertEqual(panel.sessions.count, 2)
        front.toggleTerminal(nil)
        XCTAssertTrue(front.isTerminalShown)

        panel.close(panel.sessions[1])
        panel.sessions[0].send("exit\r")
        XCTAssertTrue(spin(until: { front.terminalPanel == nil }))
        XCTAssertFalse(front.isTerminalShown)
    }

    func testNewWindowsOpenAsVisorTabsWhenEnabled() throws {
        let manager = BrowserWindowManager()
        let visor = makeVisor(manager)
        defer { for c in manager.controllers { c.close() } }
        let plain = manager.openWindow(at: .folder(dir))
        XCTAssertFalse(plain.isVisor)
        BrowserDefaults.store.set(true, forKey: VisorSettings.opensWindowsKey)
        let first = manager.openWindow(at: .folder(dir))
        XCTAssertTrue(first.isVisor)
        XCTAssertTrue(visor.isShown)
        let second = manager.open(at: .folder(dir.appendingPathComponent("Sub")))
        XCTAssertTrue(second.isVisor)
        XCTAssertEqual(visor.controllers.count, 2)
        XCTAssertEqual(manager.standardControllers.count, 1)
        XCTAssertEqual(first.window?.tabbedWindows?.count, 2)
    }
}
