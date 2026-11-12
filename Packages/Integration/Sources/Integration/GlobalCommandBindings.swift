import AppKit
import Carbon.HIToolbox
import Foundation

public struct SystemReservedHotKey: Hashable, Sendable {
    public var combo: HotKeyCombo
    public var name: String
}

public enum SystemReservedHotKeys {
    private static let c = UInt32(cmdKey)
    private static let s = UInt32(shiftKey)
    private static let o = UInt32(optionKey)
    private static let k = UInt32(controlKey)

    private static func entry(_ key: Int, _ mods: UInt32, _ name: String) -> SystemReservedHotKey {
        SystemReservedHotKey(combo: HotKeyCombo(keyCode: UInt32(key), modifiers: mods), name: name)
    }

    public static let all: [SystemReservedHotKey] = [
        entry(kVK_Space, c, "Spotlight"),
        entry(kVK_Space, c | o, "Finder search"),
        entry(kVK_Space, k, "Select previous input source"),
        entry(kVK_Space, k | o, "Select next input source"),
        entry(kVK_Space, k | c, "Emoji & Symbols"),
        entry(kVK_Tab, c, "App switcher"),
        entry(kVK_Tab, c | s, "App switcher"),
        entry(kVK_ANSI_Grave, c, "Cycle windows"),
        entry(kVK_ANSI_Grave, c | s, "Cycle windows"),
        entry(kVK_ANSI_Q, c, "Quit"),
        entry(kVK_ANSI_Q, c | k, "Lock screen"),
        entry(kVK_ANSI_Q, c | s, "Log out"),
        entry(kVK_ANSI_Q, c | s | o, "Log out immediately"),
        entry(kVK_ANSI_H, c, "Hide"),
        entry(kVK_ANSI_H, c | o, "Hide others"),
        entry(kVK_ANSI_M, c, "Minimize"),
        entry(kVK_ANSI_W, c, "Close window"),
        entry(kVK_ANSI_Comma, c, "Settings"),
        entry(kVK_Escape, c | o, "Force Quit"),
        entry(kVK_ANSI_F, c | k, "Full screen"),
        entry(kVK_ANSI_D, c | o, "Show or hide Dock"),
        entry(kVK_ANSI_3, c | s, "Screenshot"),
        entry(kVK_ANSI_4, c | s, "Screenshot selection"),
        entry(kVK_ANSI_5, c | s, "Screenshot and recording options"),
        entry(kVK_ANSI_3, c | s | k, "Screenshot to clipboard"),
        entry(kVK_ANSI_4, c | s | k, "Screenshot selection to clipboard"),
        entry(kVK_ANSI_8, c | o | k, "Zoom"),
        entry(kVK_UpArrow, k, "Mission Control"),
        entry(kVK_DownArrow, k, "Application windows"),
        entry(kVK_LeftArrow, k, "Move left a space"),
        entry(kVK_RightArrow, k, "Move right a space"),
        entry(kVK_ANSI_1, k, "Switch to Desktop 1"),
        entry(kVK_ANSI_2, k, "Switch to Desktop 2"),
        entry(kVK_ANSI_3, k, "Switch to Desktop 3"),
        entry(kVK_ANSI_4, k, "Switch to Desktop 4"),
    ]

    public static func match(_ combo: HotKeyCombo) -> SystemReservedHotKey? {
        let normalized = HotKeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers & modifierMask)
        return all.first { $0.combo == normalized }
    }

    public static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
}

public struct GlobalCommandBinding: Hashable, Sendable {
    public var commandID: String
    public var combo: HotKeyCombo

    public init(commandID: String, combo: HotKeyCombo) {
        self.commandID = commandID
        self.combo = combo
    }
}

public enum HotKeyCollision: Equatable, Sendable {
    case invalid(String)
    case systemReserved(String)
    case globalHotKey
    case modBinding(owner: String, commandID: String)

    public var message: String {
        switch self {
        case .invalid(let m): return m
        case .systemReserved(let n): return "Reserved by macOS (\(n))."
        case .globalHotKey: return "Already used by betterfinder's own global shortcut."
        case .modBinding(let owner, let command): return "Already used by \(owner) (\(command))."
        }
    }
}

public enum GlobalBindingError: LocalizedError, Equatable {
    case collision(HotKeyCollision)
    case registrationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .collision(let c): return c.message
        case .registrationFailed(let s): return "macOS refused the shortcut (error \(s)); another app probably owns it."
        }
    }
}

public struct GlobalBindingToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

@MainActor
public protocol HotKeyBackend: AnyObject {
    var onPressed: ((UInt32) -> Void)? { get set }
    func register(_ combo: HotKeyCombo, id: UInt32) throws
    func unregister(id: UInt32)
}

@MainActor
public final class CarbonHotKeyBackend: HotKeyBackend {
    public var onPressed: ((UInt32) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4246_4D4B

    public init() {}

    public func register(_ combo: HotKeyCombo, id: UInt32) throws {
        try installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw GlobalBindingError.registrationFailed(status) }
        refs[id] = ref
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard got == noErr, id.signature == CarbonHotKeyBackend.signature else { return OSStatus(eventNotHandledErr) }
                let target = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
                let hotID = id.id
                Task { @MainActor in target.onPressed?(hotID) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        guard status == noErr else { throw GlobalBindingError.registrationFailed(status) }
        handlerRef = ref
    }
}

@MainActor
public final class GlobalCommandBindingRegistry {
    public static let shared = GlobalCommandBindingRegistry()

    private struct Entry {
        var token: GlobalBindingToken
        var hotKeyID: UInt32
        var owner: String
        var binding: GlobalCommandBinding
        var handler: @MainActor () -> Void
    }

    private let backend: HotKeyBackend
    private let reservedByApp: @MainActor () -> [HotKeyCombo]
    private var entries: [Entry] = []
    private var nextID: UInt32 = 1

    public init(
        backend: HotKeyBackend? = nil,
        reservedByApp: (@MainActor () -> [HotKeyCombo])? = nil
    ) {
        self.backend = backend ?? CarbonHotKeyBackend()
        self.reservedByApp = reservedByApp ?? {
            [GlobalHotKey.shared, GlobalHotKey.visor].filter(\.isEnabled).map(\.combo)
        }
        self.backend.onPressed = { [weak self] id in
            guard let self, let entry = self.entries.first(where: { $0.hotKeyID == id }) else { return }
            entry.handler()
        }
    }

    public func check(_ combo: HotKeyCombo, ignoring token: GlobalBindingToken? = nil) -> HotKeyCollision? {
        let held = combo.modifiers & SystemReservedHotKeys.modifierMask
        guard held & UInt32(controlKey | cmdKey) != 0 else {
            return .invalid("Shortcuts need ⌃ or ⌘ so they don't interfere with typing.")
        }
        if combo.modifiers & ~SystemReservedHotKeys.modifierMask != 0 {
            return .invalid("Unsupported modifier keys.")
        }
        if let reserved = SystemReservedHotKeys.match(combo) { return .systemReserved(reserved.name) }
        if reservedByApp().contains(where: { $0.keyCode == combo.keyCode && $0.modifiers & SystemReservedHotKeys.modifierMask == held }) {
            return .globalHotKey
        }
        if let other = entries.first(where: { $0.token != token && $0.binding.combo.keyCode == combo.keyCode && $0.binding.combo.modifiers & SystemReservedHotKeys.modifierMask == held }) {
            return .modBinding(owner: other.owner, commandID: other.binding.commandID)
        }
        return nil
    }

    @discardableResult
    public func register(_ binding: GlobalCommandBinding, owner: String, handler: @escaping @MainActor () -> Void) throws -> GlobalBindingToken {
        if let collision = check(binding.combo) { throw GlobalBindingError.collision(collision) }
        let id = nextID
        nextID &+= 1
        try backend.register(binding.combo, id: id)
        let token = GlobalBindingToken()
        entries.append(Entry(token: token, hotKeyID: id, owner: owner, binding: binding, handler: handler))
        return token
    }

    @discardableResult
    public func remove(_ token: GlobalBindingToken) -> Bool {
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }
        backend.unregister(id: entries[index].hotKeyID)
        entries.remove(at: index)
        return true
    }

    @discardableResult
    public func removeAll(owner: String) -> Int {
        let tokens = entries.filter { $0.owner == owner }.map(\.token)
        for t in tokens { remove(t) }
        return tokens.count
    }

    public func bindings(owner: String? = nil) -> [(token: GlobalBindingToken, owner: String, binding: GlobalCommandBinding)] {
        entries.filter { owner == nil || $0.owner == owner }.map { ($0.token, $0.owner, $0.binding) }
    }
}
