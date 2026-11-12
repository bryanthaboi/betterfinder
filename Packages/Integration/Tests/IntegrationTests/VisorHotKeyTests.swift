import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Integration

@MainActor
final class VisorHotKeyTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "VisorHotKeyTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testVisorHotKeyKeepsItsOwnSettings() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let main = GlobalHotKey(defaults: defaults)
        let visor = GlobalHotKey(defaults: defaults, id: 2, comboDefaultsKey: GlobalHotKey.visorComboDefaultsKey, enabledDefaultsKey: GlobalHotKey.visorEnabledDefaultsKey, defaultCombo: .visorDefault)
        XCTAssertEqual(main.combo, .default)
        XCTAssertEqual(visor.combo, .visorDefault)
        XCTAssertEqual(HotKeyCombo.visorDefault.displayString, "⌥`")
        XCTAssertFalse(visor.isEnabled)

        let custom = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))
        try visor.setCombo(custom)
        XCTAssertEqual(GlobalHotKey(defaults: defaults).combo, .default)
        let reloaded = GlobalHotKey(defaults: defaults, id: 2, comboDefaultsKey: GlobalHotKey.visorComboDefaultsKey, enabledDefaultsKey: GlobalHotKey.visorEnabledDefaultsKey, defaultCombo: .visorDefault)
        XCTAssertEqual(reloaded.combo, custom)
        XCTAssertEqual(reloaded.defaultCombo, .visorDefault)

        defaults.set(true, forKey: GlobalHotKey.visorEnabledDefaultsKey)
        XCTAssertTrue(visor.isEnabled)
        XCTAssertFalse(main.isEnabled)
    }

    func testDoubleTapFiresOnTwoQuickCleanTaps() {
        let tap = ModifierDoubleTap(modifier: .option)
        tap.secondsSinceKeyDown = { 60 }
        var fired = 0
        tap.onTrigger = { fired += 1 }

        tap.handle(flags: .option, at: 10.00)
        tap.handle(flags: [], at: 10.08)
        XCTAssertEqual(fired, 0)
        tap.handle(flags: .option, at: 10.20)
        tap.handle(flags: [], at: 10.28)
        XCTAssertEqual(fired, 1)

        tap.handle(flags: .option, at: 10.40)
        tap.handle(flags: [], at: 10.48)
        XCTAssertEqual(fired, 1)
        tap.handle(flags: .option, at: 10.60)
        tap.handle(flags: [], at: 10.66)
        XCTAssertEqual(fired, 2)
    }

    func testDoubleTapIgnoresSlowHeldAndMixedPresses() {
        let tap = ModifierDoubleTap(modifier: .option)
        tap.secondsSinceKeyDown = { 60 }
        var fired = 0
        tap.onTrigger = { fired += 1 }

        tap.handle(flags: .option, at: 1.0)
        tap.handle(flags: [], at: 1.05)
        tap.handle(flags: .option, at: 2.0)
        tap.handle(flags: [], at: 2.05)
        XCTAssertEqual(fired, 0)

        tap.handle(flags: .option, at: 3.0)
        tap.handle(flags: [], at: 3.9)
        tap.handle(flags: .option, at: 4.0)
        tap.handle(flags: [], at: 4.05)
        XCTAssertEqual(fired, 0)

        tap.handle(flags: .option, at: 5.0)
        tap.handle(flags: [], at: 5.05)
        tap.handle(flags: [.option, .command], at: 5.1)
        tap.handle(flags: [], at: 5.15)
        tap.handle(flags: .option, at: 5.2)
        tap.handle(flags: [], at: 5.25)
        XCTAssertEqual(fired, 0)

        tap.handle(flags: .shift, at: 6.0)
        tap.handle(flags: [], at: 6.05)
        tap.handle(flags: .shift, at: 6.1)
        tap.handle(flags: [], at: 6.15)
        XCTAssertEqual(fired, 0)

        tap.secondsSinceKeyDown = { 0.01 }
        tap.handle(flags: .option, at: 7.0)
        tap.handle(flags: [], at: 7.05)
        tap.handle(flags: .option, at: 7.1)
        tap.handle(flags: [], at: 7.15)
        XCTAssertEqual(fired, 0)
    }
}
