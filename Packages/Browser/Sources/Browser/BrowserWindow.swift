import AppKit
import Theming

@MainActor
final class BrowserWindow: NSWindow {
    var onFirstResponderChange: ((NSResponder?) -> Void)?
    var onKeyBinding: ((NSEvent) -> Bool)?
    var onTabDoubleClick: ((NSPoint) -> Bool)?
    var allowsOffscreenFrame = false
    var closeButtonMenu: (() -> NSMenu?)?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    var closeButtonView: NSView? {
        ThemedWindowChrome.chrome(for: self)?.closeButtonView ?? standardWindowButton(.closeButton).flatMap { $0.isHidden ? nil : $0 }
    }

    func isOnCloseButton(_ point: NSPoint) -> Bool {
        guard let button = closeButtonView, button.window === self else { return false }
        return button.convert(button.bounds, to: nil).contains(point)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, onTabDoubleClick?(event.locationInWindow) == true { return }
        let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if secondary, isOnCloseButton(event.locationInWindow), let menu = closeButtonMenu?(), let view = closeButtonView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok { onFirstResponderChange?(firstResponder) }
        return ok
    }
    struct Shortcut {
        let key: String?
        let keyCode: UInt16?
        let mods: NSEvent.ModifierFlags
        let action: Selector
    }

    static let shortcuts: [Shortcut] = [
        Shortcut(key: "1", keyCode: 18, mods: .command, action: #selector(BrowserWindowController.asList(_:))),
        Shortcut(key: "2", keyCode: 19, mods: .command, action: #selector(BrowserWindowController.asColumns(_:))),
        Shortcut(key: "3", keyCode: 20, mods: .command, action: #selector(BrowserWindowController.asIcons(_:))),
        Shortcut(key: "l", keyCode: nil, mods: .command, action: #selector(BrowserWindowController.focusPathBar(_:))),
        Shortcut(key: "g", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.goToFolder(_:))),
        Shortcut(key: "f", keyCode: nil, mods: .command, action: #selector(BrowserWindowController.focusSearch(_:))),
        Shortcut(key: "d", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.toggleDualPane(_:))),
        Shortcut(key: nil, keyCode: 47, mods: [.command, .shift], action: #selector(BrowserWindowController.toggleHiddenFiles(_:))),
        Shortcut(key: nil, keyCode: 41, mods: [.command, .shift], action: #selector(BrowserWindowController.toggleFoldersFirst(_:))),
        Shortcut(key: "i", keyCode: nil, mods: .command, action: #selector(BrowserWindowController.getInfo(_:))),
        Shortcut(key: "i", keyCode: nil, mods: [.command, .option], action: #selector(BrowserWindowController.miniInfo(_:))),
        Shortcut(key: "c", keyCode: nil, mods: [.command, .option], action: #selector(BrowserWindowController.copyPath(_:))),
        Shortcut(key: nil, keyCode: 30, mods: [.command, .shift], action: #selector(NSWindow.selectNextTab(_:))),
        Shortcut(key: nil, keyCode: 33, mods: [.command, .shift], action: #selector(NSWindow.selectPreviousTab(_:))),
        Shortcut(key: "f", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.goRecents(_:))),
        Shortcut(key: "o", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.goDocuments(_:))),
        Shortcut(key: "l", keyCode: nil, mods: [.command, .option], action: #selector(BrowserWindowController.goDownloads(_:))),
        Shortcut(key: "a", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.goApplications(_:))),
        Shortcut(key: "i", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.goICloud(_:))),
        Shortcut(key: "=", keyCode: 24, mods: .command, action: #selector(BrowserWindowController.increaseIconSize(_:))),
        Shortcut(key: "-", keyCode: 27, mods: .command, action: #selector(BrowserWindowController.decreaseIconSize(_:))),
        Shortcut(key: "t", keyCode: nil, mods: [.command, .control], action: #selector(BrowserPaneController.revealInSidebarFavorites(_:))),
        Shortcut(key: "n", keyCode: nil, mods: [.command, .control], action: #selector(BrowserPaneController.newFolderWithSelection(_:))),
        Shortcut(key: "y", keyCode: nil, mods: .command, action: #selector(BrowserPaneController.toggleQuickLook(_:))),
        Shortcut(key: "v", keyCode: nil, mods: [.command, .option], action: #selector(BrowserPaneController.pasteAndMove(_:))),
        Shortcut(key: "p", keyCode: nil, mods: [.command, .shift], action: #selector(BrowserWindowController.showCommandPalette(_:))),
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased()
        for s in Self.shortcuts where s.mods == mods {
            let match = (s.keyCode != nil && s.keyCode == event.keyCode) || (s.key != nil && chars == s.key)
            guard match else { continue }
            if NSApp.sendAction(s.action, to: nil, from: self) { return true }
        }
        if onKeyBinding?(event) == true { return true }
        return false
    }
}
