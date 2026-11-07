import AppKit
import Foundation

public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    public init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.init(key: key, command: modifiers.contains(.command), shift: modifiers.contains(.shift), option: modifiers.contains(.option), control: modifiers.contains(.control))
    }

    public init?(event: NSEvent) {
        guard event.type == .keyDown, let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        let key = KeyChord.specialName(forKeyCode: event.keyCode) ?? chars
        self.init(key: key, modifiers: event.modifierFlags)
    }

    public static func parse(_ text: String) -> KeyChord? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var chord = KeyChord(key: key)
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": chord.command = true
            case "shift", "⇧": chord.shift = true
            case "opt", "option", "alt", "⌥": chord.option = true
            case "ctrl", "control", "⌃": chord.control = true
            default: return nil
            }
        }
        guard !chord.key.isEmpty, chord.hasModifier || KeyChord.specialKeys.contains(chord.key) else { return nil }
        return chord
    }

    public var hasModifier: Bool { command || shift || option || control }

    static let specialKeys: Set<String> = Set(["return", "tab", "space", "escape", "delete", "up", "down", "left", "right"] + (1...12).map { "f\($0)" })

    static func specialName(forKeyCode code: UInt16) -> String? {
        switch code {
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 53: return "escape"
        case 51: return "delete"
        case 126: return "up"
        case 125: return "down"
        case 123: return "left"
        case 124: return "right"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        default: return nil
        }
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if command { f.insert(.command) }
        if shift { f.insert(.shift) }
        if option { f.insert(.option) }
        if control { f.insert(.control) }
        return f
    }

    public var description: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "return": s += "↩"
        case "tab": s += "⇥"
        case "space": s += "Space"
        case "escape": s += "⎋"
        case "delete": s += "⌫"
        case "up": s += "↑"
        case "down": s += "↓"
        case "left": s += "←"
        case "right": s += "→"
        default: s += key.uppercased()
        }
        return s
    }

    static func chord(forMenuItem item: NSMenuItem) -> KeyChord? {
        let raw = item.keyEquivalent
        guard !raw.isEmpty, let scalar = raw.unicodeScalars.first else { return nil }
        let mods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        let key: String
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: key = "up"
        case NSDownArrowFunctionKey: key = "down"
        case NSLeftArrowFunctionKey: key = "left"
        case NSRightArrowFunctionKey: key = "right"
        case NSF1FunctionKey...NSF12FunctionKey: key = "f\(Int(scalar.value) - NSF1FunctionKey + 1)"
        case 0x8, 0x7F: key = "delete"
        case 0xD, 0x3: key = "return"
        case 0x9: key = "tab"
        case 0x1B: key = "escape"
        case 0x20: key = "space"
        default: key = raw.lowercased()
        }
        var chord = KeyChord(key: key, modifiers: mods)
        if raw != raw.lowercased(), !chord.shift, raw.count == 1 { chord.shift = true }
        return chord
    }
}

public struct KeyBindingSpec: BrowserContribution {
    public var id: String
    public var chord: KeyChord
    public var commandID: String
    public var title: String?

    public init(id: String, chord: KeyChord, commandID: String, title: String? = nil) {
        self.id = id
        self.chord = chord
        self.commandID = commandID
        self.title = title
    }
}

public struct KeyBindingConflict: Hashable, Sendable {
    public enum Other: Hashable, Sendable {
        case builtIn(String)
        case contribution(String)
    }

    public var bindingID: String
    public var chord: KeyChord
    public var other: Other

    public var message: String {
        switch other {
        case .builtIn(let what): return "\(chord) is already used by \(what)."
        case .contribution(let id): return "\(chord) is already bound by \(id)."
        }
    }
}

@MainActor
public final class KeyBindingRegistry: BrowserRegistry<KeyBindingSpec> {
    public static let shared = KeyBindingRegistry()

    public private(set) var conflicts: [KeyBindingConflict] = []
    public var extraBuiltInChords: [KeyChord: String] = [:]
    public var menuProvider: @MainActor () -> NSMenu? = { NSApp.mainMenu }

    public init() { super.init(kind: .keyBinding) }

    override public func validate(_ item: KeyBindingSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.commandID.isEmpty { return "A key binding needs a command id." }
        if !item.chord.hasModifier && !KeyChord.specialKeys.contains(item.chord.key) { return "Key bindings without a modifier must use a special key." }
        return nil
    }

    override public func didChange() {
        conflicts = computeConflicts()
    }

    public var builtInChords: [KeyChord: String] {
        var map: [KeyChord: String] = [:]
        for s in BrowserWindow.shortcuts {
            let key = s.key ?? s.keyCode.flatMap { Self.keyForCode($0) }
            guard let key else { continue }
            map[KeyChord(key: key, modifiers: s.mods)] = NSStringFromSelector(s.action)
        }
        for (chord, name) in Self.pointerKeys { map[chord] = name }
        if let menu = menuProvider() { Self.collect(menu, into: &map, path: "") }
        for (chord, name) in extraBuiltInChords { map[chord] = name }
        return map
    }

    static let pointerKeys: [KeyChord: String] = [
        KeyChord(key: "return"): "Open / Rename",
        KeyChord(key: "space"): "Quick Look",
        KeyChord(key: "tab"): "Switch pane",
        KeyChord(key: "f2"): "Rename",
        KeyChord(key: "f5"): "Copy to other pane",
        KeyChord(key: "f6"): "Move to other pane",
        KeyChord(key: "escape"): "End search",
        KeyChord(key: "delete", command: true): "Move to Trash",
        KeyChord(key: "down", command: true): "Open",
        KeyChord(key: "return", command: true): "Open",
        KeyChord(key: "p", command: true, shift: true): "Command Palette",
    ]

    private static func keyForCode(_ code: UInt16) -> String? {
        switch code {
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 24: return "="
        case 27: return "-"
        case 30: return "]"
        case 33: return "["
        case 47: return "."
        default: return nil
        }
    }

    private static func collect(_ menu: NSMenu, into map: inout [KeyChord: String], path: String) {
        for item in menu.items {
            let name = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
            if let chord = KeyChord.chord(forMenuItem: item), map[chord] == nil { map[chord] = name }
            if let sub = item.submenu { collect(sub, into: &map, path: name) }
        }
    }

    public func builtInConflict(for chord: KeyChord) -> String? { builtInChords[chord] }

    public func detectConflicts(for spec: KeyBindingSpec, owner: String) -> [KeyBindingConflict] {
        let qid = Self.qualify(spec.id, owner: owner)
        var out: [KeyBindingConflict] = []
        if let name = builtInConflict(for: spec.chord) { out.append(KeyBindingConflict(bindingID: qid, chord: spec.chord, other: .builtIn(name))) }
        for e in entries where e.qualifiedID != qid && e.item.chord == spec.chord {
            out.append(KeyBindingConflict(bindingID: qid, chord: spec.chord, other: .contribution(e.qualifiedID)))
        }
        return out
    }

    private func computeConflicts() -> [KeyBindingConflict] {
        let builtIns = builtInChords
        var out: [KeyBindingConflict] = []
        var claimed: [KeyChord: String] = [:]
        for e in entries.sorted(by: { $0.sequence < $1.sequence }) {
            if let name = builtIns[e.item.chord] {
                out.append(KeyBindingConflict(bindingID: e.qualifiedID, chord: e.item.chord, other: .builtIn(name)))
            } else if let first = claimed[e.item.chord] {
                out.append(KeyBindingConflict(bindingID: e.qualifiedID, chord: e.item.chord, other: .contribution(first)))
            } else {
                claimed[e.item.chord] = e.qualifiedID
            }
        }
        return out
    }

    public func refreshConflicts() {
        conflicts = computeConflicts()
        notify()
    }

    public func isActive(_ qualifiedID: String) -> Bool {
        !conflicts.contains { $0.bindingID == qualifiedID } && !isHidden(qualifiedID)
    }

    public func binding(for chord: KeyChord) -> Entry? {
        entries.first { $0.item.chord == chord && isActive($0.qualifiedID) }
    }

    public func chord(forCommand qualifiedCommandID: String) -> KeyChord? {
        entries.first { Self.reference($0.item.commandID, owner: $0.owner) == qualifiedCommandID && isActive($0.qualifiedID) }?.item.chord
    }
}
