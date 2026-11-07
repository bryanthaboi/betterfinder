import AppKit
import Carbon.HIToolbox
import Foundation
import Integration
import ModKit
import Settings
import SwiftUI
import Theming

enum ModSettingsBridge {
    static func schema(_ settings: [ModSetting]) -> ModSettingsSchema {
        ModSettingsSchema(fields: settings.map { s in
            let kind: ModSettingsSchema.Kind
            switch s.type {
            case .boolean: kind = .boolean(defaultValue: s.default.boolValue)
            case .integer: kind = .integer(minimum: s.minimum.map { Int($0) }, maximum: s.maximum.map { Int($0) }, step: nil, defaultValue: s.default.intValue)
            case .number: kind = .number(minimum: s.minimum, maximum: s.maximum, step: nil, defaultValue: s.default.numberValue)
            case .string: kind = .string(maxLength: s.maxLength ?? ModSettingsSchema.defaultStringLength, placeholder: nil, multiline: false, defaultValue: s.default.stringValue)
            case .enum: kind = .enumeration(options: (s.options ?? []).map { .init(value: $0.value, title: $0.label) }, defaultValue: s.default.stringValue)
            }
            return ModSettingsSchema.Field(key: s.key, title: s.label, description: s.description, kind: kind)
        })
    }
}

@MainActor
public protocol ModAssetRegistering: AnyObject {
    func register(manifest: ModManifest, snapshot: URL, settings: ModSettingsStore?, owner: String) throws -> [ModRegistrationToken]
}

@MainActor
public final class ModSystemAssetRegistrar: ModAssetRegistering {
    public let themes: ThemeContributionRegistry?
    public let icons: IconSetRegistry
    public let sounds: SoundSetRegistry
    public let settingsPanes: SettingsPaneRegistry?

    public convenience init() {
        self.init(themes: .shared, icons: .shared, sounds: .shared, settingsPanes: .shared)
    }

    public init(themes: ThemeContributionRegistry?, icons: IconSetRegistry, sounds: SoundSetRegistry, settingsPanes: SettingsPaneRegistry?) {
        self.themes = themes
        self.icons = icons
        self.sounds = sounds
        self.settingsPanes = settingsPanes
    }

    public func register(manifest: ModManifest, snapshot: URL, settings: ModSettingsStore?, owner: String) throws -> [ModRegistrationToken] {
        var tokens = [ModRegistrationToken]()
        let c = manifest.contributes
        do {
            if !c.themes.isEmpty, let themes {
                let urls = c.themes.map { snapshot.appendingPathComponent($0.path) }
                let t = try themes.register(themeFiles: urls, owner: owner)
                tokens.append(ModRegistrationToken { Task { @MainActor in themes.remove(t) } })
            }
            for set in c.iconSets {
                let provider = ModDirectoryIconSet(setID: "\(manifest.id)/\(set.id)", directory: snapshot.appendingPathComponent(set.path, isDirectory: true))
                let t = icons.register(provider, owner: owner)
                let icons = icons
                tokens.append(ModRegistrationToken { icons.remove(t) })
            }
            for set in c.sounds {
                let provider = ModDirectorySoundSet.make(setID: "\(manifest.id)/\(set.id)", directory: snapshot.appendingPathComponent(set.path, isDirectory: true))
                let t = sounds.register(provider, owner: owner)
                let sounds = sounds
                tokens.append(ModRegistrationToken { Task { @MainActor in sounds.remove(t) } })
            }
            if let settingsPanes, let settings {
                for pane in c.settingsPanes {
                    let fields = settings.schema.fields.filter { pane.settings.contains($0.key) }
                    let sub = try ModSettingsStore(modID: manifest.id, schema: ModSettingsSchema(fields: fields))
                    let descriptor = SettingsPaneDescriptor(id: "mod.\(manifest.id).\(pane.id)", title: pane.title, symbolName: pane.icon ?? "slider.horizontal.3") {
                        ModSettingsFormView(model: ModSettingsFormModel(store: sub))
                    }
                    let t = try settingsPanes.register(descriptor, owner: owner)
                    tokens.append(ModRegistrationToken { Task { @MainActor in settingsPanes.remove(t) } })
                }
            }
        } catch {
            tokens.forEach { $0.cancel() }
            throw error
        }
        return tokens
    }
}

public final class ModDirectoryIconSet: IconSetProvider, @unchecked Sendable {
    public let setID: String
    private let inner: StaticIconSetProvider

    public init(setID: String, directory: URL) {
        self.setID = setID
        var special = [SpecialFolder: NSImage]()
        var types = [String: NSImage]()
        var kinds = [IconFileKind: NSImage]()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["png", "pdf", "icns", "tiff"].contains(f.pathExtension.lowercased()) {
            let base = f.deletingPathExtension().lastPathComponent
            guard let image = NSImage(contentsOf: f) else { continue }
            if base.hasPrefix("kind."), let k = IconFileKind(rawValue: String(base.dropFirst(5))) { kinds[k] = image }
            else if base.hasPrefix("type.") { types[String(base.dropFirst(5))] = image }
            else if let s = SpecialFolder(rawValue: base) { special[s] = image }
        }
        inner = StaticIconSetProvider(setID: setID, specialFolders: special, contentTypes: types, kinds: kinds)
    }

    public func icon(for request: IconRequest, size: CGFloat) -> NSImage? { inner.icon(for: request, size: size) }
}

@MainActor
public enum ModDirectorySoundSet {
    public static func make(setID: String, directory: URL) -> StaticSoundSetProvider {
        var urls = [ThemeSoundEvent: URL]()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["aiff", "aif", "wav", "caf", "mp3", "m4a"].contains(f.pathExtension.lowercased()) {
            if let e = ThemeSoundEvent(rawValue: f.deletingPathExtension().lastPathComponent) { urls[e] = f }
        }
        return StaticSoundSetProvider(setID: setID, urls: urls)
    }
}

public enum ModKeyChord {
    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "delete": kVK_Delete, "escape": kVK_Escape,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    ]

    public static func hotKeyCombo(_ chord: String) -> HotKeyCombo? {
        var parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast(), let code = keyCodes[key.isEmpty ? "=" : key] else { return nil }
        var mods = 0
        for p in parts {
            switch p {
            case "cmd": mods |= cmdKey
            case "ctrl": mods |= controlKey
            case "opt": mods |= optionKey
            case "shift": mods |= shiftKey
            default: return nil
            }
        }
        return HotKeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }
}

@MainActor
public final class ModGlobalKeybindingSink: ModUIRegistrySink {
    public let inner: ModUIRegistrySink
    public let registry: GlobalCommandBindingRegistry
    private var runners: [String: ModCommandRunning] = [:]

    public convenience init(wrapping inner: ModUIRegistrySink) {
        self.init(wrapping: inner, registry: .shared)
    }

    public init(wrapping inner: ModUIRegistrySink, registry: GlobalCommandBindingRegistry) {
        self.inner = inner
        self.registry = registry
    }

    public func registerToolbarItem(_ item: ModToolbarContribution, owner: String) throws -> ModRegistrationToken { try inner.registerToolbarItem(item, owner: owner) }
    public func registerSidebarSection(_ section: ModSidebarContribution, owner: String) throws -> ModRegistrationToken { try inner.registerSidebarSection(section, owner: owner) }
    public func registerContextMenuItem(_ item: ModContextMenuContribution, owner: String) throws -> ModRegistrationToken { try inner.registerContextMenuItem(item, owner: owner) }
    public func registerColumn(_ column: ModColumnContribution, provider: ModColumnValuesProviding, owner: String) throws -> ModRegistrationToken { try inner.registerColumn(column, provider: provider, owner: owner) }
    public func registerStatusBarItem(_ item: ModStatusBarContribution, owner: String) throws -> ModRegistrationToken { try inner.registerStatusBarItem(item, owner: owner) }
    public func registerPanel(_ panel: ModPanelContribution, owner: String) throws -> ModRegistrationToken { try inner.registerPanel(panel, owner: owner) }
    public func registerPreview(_ preview: ModPreviewContribution, provider: ModPreviewProviding, owner: String) throws -> ModRegistrationToken { try inner.registerPreview(preview, provider: provider, owner: owner) }
    public func registerView(_ view: ModViewContribution, owner: String) throws -> ModRegistrationToken { try inner.registerView(view, owner: owner) }
    public func registerLocation(_ location: ModLocationContribution, provider: ModLocationProviding, owner: String) throws -> ModRegistrationToken { try inner.registerLocation(location, provider: provider, owner: owner) }
    public func registerSearchProvider(_ provider: ModSearchProviderContribution, search: ModSearchProviding, owner: String) throws -> ModRegistrationToken { try inner.registerSearchProvider(provider, search: search, owner: owner) }
    public func apply(_ update: ModUIUpdate) { inner.apply(update) }

    public func registerCommand(_ command: ModCommandContribution, runner: ModCommandRunning, owner: String) throws -> ModRegistrationToken {
        let t = try inner.registerCommand(command, runner: runner, owner: owner)
        runners[command.id.qualified] = runner
        let key = command.id.qualified
        return ModRegistrationToken { [weak self] in
            t.cancel()
            Task { @MainActor in self?.runners.removeValue(forKey: key) }
        }
    }

    public func registerKeybinding(_ binding: ModKeybindingContribution, owner: String) throws -> ModRegistrationToken {
        guard !binding.command.isBuiltIn, let combo = ModKeyChord.hotKeyCombo(binding.chord), let runner = runners[binding.command.qualified] else {
            return try inner.registerKeybinding(binding, owner: owner)
        }
        let registry = registry
        let t = try registry.register(GlobalCommandBinding(commandID: binding.command.qualified, combo: combo), owner: owner) {
            Task { _ = try? await runner.run(selection: [], args: nil) }
        }
        return ModRegistrationToken { Task { @MainActor in registry.remove(t) } }
    }
}
