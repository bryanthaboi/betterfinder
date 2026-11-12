import AppKit
import Carbon.HIToolbox
import Foundation

public struct HotKeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_N),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    public static let visorDefault = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_Grave),
        modifiers: UInt32(optionKey)
    )

    public init?(event: NSEvent) {
        let mods = Self.carbonModifiers(event.modifierFlags)
        let required = UInt32(controlKey | optionKey | cmdKey)
        guard mods & required != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    public var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let table: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return table[Int(code)] ?? "Key \(code)"
    }
}

@MainActor
public final class GlobalHotKey {
    public static let shared = GlobalHotKey()
    public static let visor = GlobalHotKey(
        id: 2,
        comboDefaultsKey: visorComboDefaultsKey,
        enabledDefaultsKey: visorEnabledDefaultsKey,
        defaultCombo: .visorDefault
    )
    public static let comboDefaultsKey = "globalHotKeyCombo"
    public static let enabledDefaultsKey = "globalHotKeyEnabled"
    public static let visorComboDefaultsKey = "visorHotKeyCombo"
    public static let visorEnabledDefaultsKey = "visorHotKeyEnabled"

    public var onTrigger: (() -> Void)?
    public private(set) var isRegistered = false
    public private(set) var combo: HotKeyCombo
    public let defaultCombo: HotKeyCombo

    private let defaults: UserDefaults
    private let hotKeyID: UInt32
    private let comboKey: String
    private let enabledKey: String
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4246_4B48

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, id: 1, comboDefaultsKey: Self.comboDefaultsKey, enabledDefaultsKey: Self.enabledDefaultsKey, defaultCombo: .default)
    }

    public init(defaults: UserDefaults = .standard, id: UInt32, comboDefaultsKey: String, enabledDefaultsKey: String, defaultCombo: HotKeyCombo) {
        self.defaults = defaults
        self.hotKeyID = id
        self.comboKey = comboDefaultsKey
        self.enabledKey = enabledDefaultsKey
        self.defaultCombo = defaultCombo
        if let data = defaults.data(forKey: comboDefaultsKey),
           let saved = try? JSONDecoder().decode(HotKeyCombo.self, from: data) {
            combo = saved
        } else {
            combo = defaultCombo
        }
    }

    public var isEnabled: Bool { defaults.bool(forKey: enabledKey) }

    public func restoreFromDefaults() {
        if isEnabled { try? register() } else { unregister() }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try register()
            defaults.set(true, forKey: enabledKey)
        } else {
            unregister()
            defaults.set(false, forKey: enabledKey)
        }
    }

    public func setCombo(_ newCombo: HotKeyCombo) throws {
        let previous = combo
        combo = newCombo
        if isRegistered || isEnabled {
            do { try register() } catch {
                combo = previous
                if isEnabled { try? register() }
                throw error
            }
        }
        if let data = try? JSONEncoder().encode(newCombo) { defaults.set(data, forKey: comboKey) }
    }

    public func register() throws {
        unregister()
        try installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw IntegrationError.hotKeyRegistrationFailed(status) }
        hotKeyRef = ref
        isRegistered = true
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isRegistered = false
    }

    private static var registered: [UInt32: GlobalHotKey] = [:]

    private func pressed(_ id: UInt32) {
        (id == hotKeyID ? self : Self.registered[id])?.onTrigger?()
    }

    private func installHandlerIfNeeded() throws {
        Self.registered[hotKeyID] = self
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard got == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
                let target = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                let pressed = id.id
                Task { @MainActor in target.pressed(pressed) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        guard status == noErr else { throw IntegrationError.hotKeyRegistrationFailed(status) }
        handlerRef = ref
    }
}
