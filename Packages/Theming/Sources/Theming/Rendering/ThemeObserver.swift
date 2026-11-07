import AppKit
import Foundation
import ObjectiveC

@MainActor
public enum ThemeAccessibility {
    public static var increaseContrastOverride: Bool?
    public static var reduceMotionOverride: Bool?

    public static var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    public static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public static func contrastOutlineColor(against fill: NSColor) -> NSColor {
        NSColor.contrastRatio(.black, fill) >= NSColor.contrastRatio(.white, fill) ? .black : .white
    }
}

@MainActor
public final class ThemeObserver {
    nonisolated(unsafe) private var token: NSObjectProtocol?
    nonisolated(unsafe) private var displayToken: NSObjectProtocol?
    private let handler: (Theme) -> Void

    public init(fireImmediately: Bool = true, manager: ThemeManager? = nil, _ handler: @escaping (Theme) -> Void) {
        self.handler = handler
        let source = manager ?? ThemeManager.shared
        token = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] note in
            let theme = note.object as? Theme
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handler(theme ?? source.current)
            }
        }
        displayToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handler(source.current)
            }
        }
        if fireImmediately { handler(source.current) }
    }

    public func invalidate() {
        if let token { NotificationCenter.default.removeObserver(token) }
        if let displayToken { NSWorkspace.shared.notificationCenter.removeObserver(displayToken) }
        token = nil
        displayToken = nil
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        if let displayToken { NSWorkspace.shared.notificationCenter.removeObserver(displayToken) }
    }

    private static let associationKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    @discardableResult
    public static func bind<Owner: AnyObject>(_ owner: Owner, fireImmediately: Bool = true, _ handler: @escaping (Owner, Theme) -> Void) -> ThemeObserver {
        let observer = ThemeObserver(fireImmediately: false) { [weak owner] theme in
            guard let owner else { return }
            handler(owner, theme)
        }
        var list = objc_getAssociatedObject(owner, associationKey) as? [ThemeObserver] ?? []
        list.append(observer)
        objc_setAssociatedObject(owner, associationKey, list, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if fireImmediately { handler(owner, ThemeManager.shared.current) }
        return observer
    }

    public static func unbindAll(from owner: AnyObject) {
        (objc_getAssociatedObject(owner, associationKey) as? [ThemeObserver])?.forEach { $0.invalidate() }
        objc_setAssociatedObject(owner, associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

@MainActor
public protocol ThemeApplying: AnyObject {
    func apply(theme: Theme)
}

@MainActor
public extension ThemeApplying {
    @discardableResult
    func observeTheme(fireImmediately: Bool = true) -> ThemeObserver {
        ThemeObserver.bind(self, fireImmediately: fireImmediately) { owner, theme in owner.apply(theme: theme) }
    }
}
