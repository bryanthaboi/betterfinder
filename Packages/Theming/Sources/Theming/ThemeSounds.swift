import AppKit

public enum ThemeSoundEvent: String, CaseIterable, Sendable {
    case trash, emptyTrash, copyComplete, moveComplete, newFolder, drop, open, error, alert, windowOpen, windowClose

    public var displayName: String {
        switch self {
        case .trash: return "Move to Trash"
        case .emptyTrash: return "Empty Trash"
        case .copyComplete: return "Copy Complete"
        case .moveComplete: return "Move Complete"
        case .newFolder: return "New Folder"
        case .drop: return "Drop"
        case .open: return "Open Item"
        case .error: return "Error"
        case .alert: return "Alert"
        case .windowOpen: return "Window Open"
        case .windowClose: return "Window Close"
        }
    }
}

@MainActor
public enum ThemeSounds {
    private static let enabledKey = "themeSoundsEnabled"
    private static var cache: [String: NSSound] = [:]

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var volume: Float = 1

    public static func soundSpec(for event: ThemeSoundEvent, theme: Theme) -> String? {
        guard let s = theme.sounds[event.rawValue], !s.isEmpty else { return nil }
        return s
    }

    public static func sound(for event: ThemeSoundEvent, theme: Theme? = nil, manager: ThemeManager? = nil, registry: SoundSetRegistry? = nil) -> NSSound? {
        let mgr = manager ?? ThemeManager.shared
        let t = theme ?? mgr.current
        guard let spec = soundSpec(for: event, theme: t) else { return nil }
        let key = "\(t.id)|\(spec)|\(event.rawValue)"
        if let s = cache[key] { return s }
        let sound: NSSound?
        if spec.hasPrefix(SoundSetRegistry.specPrefix) {
            sound = (registry ?? .shared).sound(forSpec: spec, event: event)
        } else if spec.lowercased().hasPrefix("system:") {
            sound = NSSound(named: NSSound.Name(String(spec.dropFirst(7))))?.copy() as? NSSound
        } else if let url = mgr.assetURL(spec, for: t.id) {
            sound = NSSound(contentsOf: url, byReference: true)
        } else {
            sound = nil
        }
        if let sound { cache[key] = sound }
        return sound
    }

    @discardableResult
    public static func play(_ event: ThemeSoundEvent, theme: Theme? = nil, manager: ThemeManager? = nil, registry: SoundSetRegistry? = nil) -> Bool {
        guard isEnabled, let s = sound(for: event, theme: theme, manager: manager, registry: registry) else { return false }
        if s.isPlaying { s.stop() }
        s.volume = volume
        return s.play()
    }

    public static func clearCache() {
        cache.removeAll()
    }
}
