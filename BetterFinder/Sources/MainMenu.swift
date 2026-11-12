import AppKit
import Browser
import Settings

@MainActor
enum MainMenu {
    private static weak var copyToOtherPaneItem: NSMenuItem?
    private static var presetObserver: NSObjectProtocol?

    static func copyToOtherPaneModifiers(windowsKeys: Bool) -> NSEvent.ModifierFlags {
        windowsKeys ? [.shift] : []
    }

    static func applyKeyPreset() {
        let windowsKeys = UserDefaults.standard.bool(forKey: SettingsKey.returnOpens)
        copyToOtherPaneItem?.keyEquivalentModifierMask = copyToOtherPaneModifiers(windowsKeys: windowsKeys)
    }

    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About betterfinder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let et = appMenu.addItem(withTitle: "Empty Trash…", action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "\u{8}")
        et.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(withTitle: "Clean Up Junk…", action: #selector(AppDelegate.showJunkCleanup(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide betterfinder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit betterfinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "betterfinder", to: main)

        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        file.addItem(item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"))
        let new = NSMenu(title: "New")
        new.addItem(item("Folder", #selector(BrowserWindowController.newFolder(_:)), "n", [.command, .shift]))
        new.addItem(.separator())
        new.addItem(item("Text Document", #selector(BrowserWindowController.newTextDocument(_:)), "n", [.command, .option]))
        new.addItem(item("Markdown Document", #selector(BrowserWindowController.newMarkdownDocument(_:)), ""))
        new.addItem(item("Empty File", #selector(BrowserWindowController.newEmptyFile(_:)), ""))
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.submenu = new
        file.addItem(newItem)
        file.addItem(.separator())
        file.addItem(item("Open", Selector(("openSelection:")), "o"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(.separator())
        file.addItem(item("Duplicate", Selector(("duplicate:")), "d"))
        file.addItem(item("Rename", Selector(("renameSelection:")), ""))
        file.addItem(item("Quick Look", Selector(("toggleQuickLook:")), "y"))
        file.addItem(item("Get Info", Selector(("getInfo:")), "i"))
        file.addItem(item("Find", Selector(("focusSearch:")), "f"))
        file.addItem(item("Open in Terminal", Selector(("openInTerminal:")), ""))
        file.addItem(item("New Folder with Selection", Selector(("newFolderWithSelection:")), "n", [.command, .control]))
        file.addItem(item("Add to Sidebar", Selector(("revealInSidebarFavorites:")), "t", [.command, .control]))
        file.addItem(.separator())
        let copyOther = item("Copy to Other Pane", Selector(("copyToOtherPane:")), String(Character(UnicodeScalar(NSF5FunctionKey)!)), [])
        file.addItem(copyOther)
        copyToOtherPaneItem = copyOther
        file.addItem(item("Move to Other Pane", Selector(("moveToOtherPane:")), String(Character(UnicodeScalar(NSF6FunctionKey)!)), []))
        file.addItem(.separator())
        file.addItem(item("Move to Trash", Selector(("moveToTrash:")), "\u{8}"))
        file.addItem(item("Recently Trashed…", #selector(AppDelegate.showRecentlyTrashed(_:)), ""))
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Move Item Here", Selector(("pasteAndMove:")), "v", [.command, .option]))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Copy Path", Selector(("copyPath:")), "c", [.command, .option]))
        edit.addItem(CopyPathMenu.submenuItem())
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(item("as List", Selector(("asList:")), "1"))
        view.addItem(item("as Columns", Selector(("asColumns:")), "2"))
        view.addItem(item("as Icons", Selector(("asIcons:")), "3"))
        view.addItem(.separator())
        view.addItem(item("Bigger Icons", Selector(("increaseIconSize:")), "="))
        view.addItem(item("Smaller Icons", Selector(("decreaseIconSize:")), "-"))
        view.addItem(item("Show Hidden Files", Selector(("toggleHiddenFiles:")), ".", [.command, .shift]))
        view.addItem(item("Keep Folders on Top", Selector(("toggleFoldersFirst:")), ";", [.command, .shift]))
        view.addItem(item("Dual Pane", Selector(("toggleDualPane:")), "d", [.command, .shift]))
        view.addItem(item("Switch Pane", Selector(("switchPane:")), "\t", [.option]))
        view.addItem(.separator())
        view.addItem(item("Command Palette", Selector(("showCommandPalette:")), "p", [.command, .shift]))
        view.addItem(item("Refresh", #selector(BrowserWindowController.refresh(_:)), "r"))
        view.addItem(.separator())
        view.addItem(item("Space Hog", #selector(AppDelegate.showSpaceHog(_:)), "h", [.command, .control]))
        view.addItem(.separator())
        view.delegate = PanelMenuUpdater.shared
        view.addItem(item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)), "t", [.command, .shift]))
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(view, title: "View", to: main)

        let go = NSMenu(title: "Go")
        go.addItem(item("Back", #selector(BrowserWindowController.goBack(_:)), "["))
        go.addItem(item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"))
        go.addItem(item("Enclosing Folder", #selector(BrowserWindowController.goUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))))
        go.addItem(item("Enclosing Folder in New Tab", #selector(BrowserWindowController.goUpInNewTab(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command, .option]))
        go.addItem(.separator())
        go.addItem(item("Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift]))
        go.addItem(item("Computer", #selector(BrowserWindowController.goComputer(_:)), "c", [.command, .shift]))
        go.addItem(item("Recents", Selector(("goRecents:")), "f", [.command, .shift]))
        go.addItem(item("Documents", Selector(("goDocuments:")), "o", [.command, .shift]))
        go.addItem(item("Desktop", Selector(("goDesktop:")), ""))
        go.addItem(item("Downloads", Selector(("goDownloads:")), "l", [.command, .option]))
        go.addItem(item("Applications", Selector(("goApplications:")), "a", [.command, .shift]))
        go.addItem(item("iCloud Drive", Selector(("goICloud:")), "i", [.command, .shift]))
        go.addItem(.separator())
        go.addItem(item("Go to Folder…", Selector(("goToFolder:")), "g", [.command, .shift]))
        go.addItem(item("Connect to Server…", Selector(("connectToServer:")), "k"))
        go.addItem(item("Edit Path", Selector(("focusPathBar:")), "l"))
        add(go, title: "Go", to: main)

        let mods = NSMenu(title: "Mods")
        mods.addItem(item("Manage Mods…", #selector(AppDelegate.manageMods(_:)), ""))
        mods.addItem(.separator())
        mods.addItem(item("Install Mod from File…", #selector(AppDelegate.installModFromFile(_:)), ""))
        mods.addItem(item("Load Unpacked Mod…", #selector(AppDelegate.loadUnpackedMod(_:)), ""))
        mods.addItem(item("Reload Mods", #selector(AppDelegate.reloadMods(_:)), "r", [.command, .option, .shift]))
        mods.addItem(.separator())
        mods.addItem(item("Safe Mode", #selector(AppDelegate.toggleModSafeMode(_:)), ""))
        mods.addItem(item("Mod Logs…", #selector(AppDelegate.showModLogs(_:)), ""))
        mods.addItem(.separator())
        mods.addItem(item("Start MCP Server", #selector(AppDelegate.toggleMCPServer(_:)), ""))
        mods.addItem(item("Copy MCP Config", #selector(AppDelegate.copyMCPConfig(_:)), ""))
        add(mods, title: "Mods", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item("Next Tab", Selector(("selectNextTab:")), "]", [.command, .shift]))
        window.addItem(item("Previous Tab", Selector(("selectPreviousTab:")), "[", [.command, .shift]))
        window.addItem(.separator())
        window.addItem(item("Show Visor", #selector(AppDelegate.toggleVisor(_:)), ""))
        window.addItem(item("Keep Visor Open", #selector(AppDelegate.toggleVisorPin(_:)), "p", [.command, .control]))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        window.addItem(item("File Operations", #selector(AppDelegate.showOperations(_:)), "o", [.command, .option]))
        let help = NSMenu(title: "Help")
        help.addItem(item("Welcome to betterfinder", #selector(AppDelegate.showOnboarding(_:)), ""))
        add(help, title: "Help", to: main)
        NSApp.helpMenu = help

        applyKeyPreset()
        if presetObserver == nil {
            presetObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { applyKeyPreset() }
            }
        }
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = menu
        menu.title = title
        main.addItem(top)
    }
}

@MainActor
final class PanelMenuUpdater: NSObject, NSMenuDelegate {
    static let shared = PanelMenuUpdater()
    static let itemTag = 7_263_001

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.itemTag { menu.removeItem(item) }
        guard let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? BrowserWindowController else { return }
        let entries = controller.registries.panels.visibleEntries
        guard !entries.isEmpty else { return }
        var index = menu.items.firstIndex { $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) } ?? menu.items.count
        for entry in entries {
            let item = NSMenuItem(title: "\(entry.item.title) Panel", action: #selector(togglePanel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Self.itemTag
            item.representedObject = entry.qualifiedID
            item.state = controller.isPanelOpen(entry.qualifiedID) ? .on : .off
            if let symbol = entry.item.symbolName { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.insertItem(item, at: index)
            index += 1
        }
        let separator = NSMenuItem.separator()
        separator.tag = Self.itemTag
        menu.insertItem(separator, at: index)
    }

    @objc func togglePanel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? BrowserWindowController else { return }
        controller.togglePanel(id)
    }
}
