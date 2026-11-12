import AppKit
import FSCore

@MainActor
enum ContextMenuBuilder {
    static func menu(for pane: BrowserPaneController) -> NSMenu {
        let menu = builtInMenu(for: pane)
        if let filter = pane.itemFilter {
            let clear = NSMenuItem(title: "Clear Filter (\(filter.title))", action: #selector(BrowserPaneController.clearItemFilter(_:)), keyEquivalent: "")
            clear.target = pane
            menu.insertItem(clear, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        let context = BrowserContext(pane: pane)
        let extra = pane.registries.contextMenu.menuItems(for: context, registries: pane.registries)
        guard !extra.isEmpty else { return menu }
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        for item in extra { menu.addItem(item) }
        return menu
    }

    static func builtInMenu(for pane: BrowserPaneController) -> NSMenu {
        let menu = NSMenu()
        let sel = pane.selectedItems
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target ?? pane
            menu.addItem(item)
        }
        func addInfo() {
            add("Get Info", #selector(BrowserPaneController.getInfo(_:)), "i")
            let mini = NSMenuItem(title: "Mini Info", action: #selector(BrowserPaneController.miniInfo(_:)), keyEquivalent: "i")
            mini.keyEquivalentModifierMask = [.command, .option]
            mini.isAlternate = true
            mini.target = pane
            menu.addItem(mini)
        }
        let dual = pane.windowController?.isDualPane == true
        let trash = pane.isShowingTrash
        if sel.isEmpty {
            if trash {
                add("Recently Trashed…", #selector(BrowserPaneController.showRecentlyTrashed(_:)))
                menu.addItem(.separator())
            }
            menu.addItem(newMenuItem(pane))
            menu.addItem(.separator())
            if pane.destinationFolder != nil {
                add("Paste", #selector(BrowserPaneController.paste(_:)), "v")
                menu.addItem(.separator())
                addInfo()
                add("Open in Terminal", #selector(BrowserPaneController.openInTerminal(_:)))
                add("Copy Path", #selector(BrowserPaneController.copyPath(_:)), "c", [.command, .option])
                menu.addItem(CopyPathMenu.submenuItem(target: pane))
                add("Add to Sidebar", #selector(BrowserPaneController.revealInSidebarFavorites(_:)), "t", [.command, .control])
                menu.addItem(.separator())
            }
            menu.addItem(viewMenuItem(pane))
            menu.addItem(sortMenuItem(pane))
            add(BrowserDefaults.showHidden ? "Hide Hidden Files" : "Show Hidden Files", #selector(BrowserPaneController.toggleHiddenFiles(_:)), ".", [.command, .shift])
            return menu
        }
        if pane.canPutBack {
            add("Put Back", #selector(BrowserPaneController.putBack(_:)))
            add("Recently Trashed…", #selector(BrowserPaneController.showRecentlyTrashed(_:)))
            menu.addItem(.separator())
        } else if trash {
            add("Recently Trashed…", #selector(BrowserPaneController.showRecentlyTrashed(_:)))
            menu.addItem(.separator())
        }
        add("Open", #selector(BrowserPaneController.openSelection(_:)), "o")
        if sel.count == 1, !sel[0].isBrowsableFolder {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu(for: sel[0].url)
            menu.addItem(openWith)
        }
        if sel.contains(where: \.isBrowsableFolder) {
            add("Open in New Tab", #selector(BrowserPaneController.openInNewTab(_:)))
            add("Open in New Window", #selector(BrowserPaneController.openInNewWindow(_:)))
        }
        if sel.count == 1, sel[0].isPackage {
            add("Show Package Contents", #selector(BrowserPaneController.showPackageContents(_:)))
        }
        if pane.location.isVirtual {
            add("Show in Enclosing Folder", #selector(BrowserPaneController.showInEnclosingFolder(_:)), "r")
        }
        menu.addItem(.separator())
        add("Move to Trash", #selector(BrowserPaneController.moveToTrash(_:)), "\u{8}")
        menu.addItem(.separator())
        addInfo()
        if sel.count == 1 { add("Rename", #selector(BrowserPaneController.renameSelection(_:))) }
        add("Duplicate", #selector(BrowserPaneController.duplicate(_:)), "d")
        add("Quick Look", #selector(BrowserPaneController.toggleQuickLook(_:)), "y")
        menu.addItem(.separator())
        menu.addItem(newMenuItem(pane))
        if pane.destinationFolder != nil {
            add("New Folder with Selection", #selector(BrowserPaneController.newFolderWithSelection(_:)), "n", [.command, .control])
        }
        menu.addItem(.separator())
        add("Cut", #selector(BrowserPaneController.cut(_:)), "x")
        add("Copy", #selector(BrowserPaneController.copy(_:)), "c")
        add("Paste", #selector(BrowserPaneController.paste(_:)), "v")
        add("Copy Path", #selector(BrowserPaneController.copyPath(_:)), "c", [.command, .option])
        if pane.remoteController == nil { menu.addItem(CopyPathMenu.submenuItem(target: pane)) }
        if dual {
            menu.addItem(.separator())
            add("Copy to Other Pane", #selector(BrowserPaneController.copyToOtherPane(_:)), String(Character(UnicodeScalar(NSF5FunctionKey)!)), BrowserDefaults.returnOpens ? [.shift] : [])
            add("Move to Other Pane", #selector(BrowserPaneController.moveToOtherPane(_:)), String(Character(UnicodeScalar(NSF6FunctionKey)!)), [])
        }
        menu.addItem(.separator())
        let share = NSSharingServicePicker(items: sel.map { $0.url as NSURL }).standardShareMenuItem
        menu.addItem(share)
        let tags = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tags.submenu = tagsMenu(pane)
        menu.addItem(tags)
        menu.addItem(.separator())
        add("Open in Terminal", #selector(BrowserPaneController.openInTerminal(_:)))
        if sel.count == 1, sel[0].isBrowsableFolder {
            add("Add to Sidebar", #selector(BrowserPaneController.revealInSidebarFavorites(_:)), "t", [.command, .control])
        }
        return menu
    }

    static func newMenuItem(_ pane: BrowserPaneController) -> NSMenuItem {
        let item = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        item.submenu = newMenu(pane)
        return item
    }

    static func newMenu(_ pane: BrowserPaneController) -> NSMenu {
        let m = NSMenu(title: "New")
        let folder = NSMenuItem(title: "Folder", action: #selector(BrowserPaneController.newFolder(_:)), keyEquivalent: "n")
        folder.keyEquivalentModifierMask = [.command, .shift]
        folder.target = pane
        m.addItem(folder)
        m.addItem(.separator())
        for (i, t) in FileTemplate.all.enumerated() {
            if i == FileTemplate.primary.count { m.addItem(.separator()) }
            let item = NSMenuItem(title: t.title, action: #selector(BrowserPaneController.newFile(_:)), keyEquivalent: i == 0 ? "n" : "")
            if i == 0 { item.keyEquivalentModifierMask = [.command, .option] }
            item.representedObject = t
            item.target = pane
            m.addItem(item)
        }
        return m
    }

    static func tagsMenu(_ pane: BrowserPaneController) -> NSMenu {
        let m = NSMenu()
        var names = TagColors.systemTags
        for t in BrowserDefaults.knownTags where !names.contains(t) { names.append(t) }
        for t in names {
            let item = NSMenuItem(title: t, action: #selector(BrowserPaneController.toggleTag(_:)), keyEquivalent: "")
            item.image = TagColors.dot(TagColors.color(for: t), size: 12)
            item.representedObject = t
            item.target = pane
            m.addItem(item)
        }
        return m
    }

    static func viewMenuItem(_ pane: BrowserPaneController) -> NSMenuItem {
        let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let m = NSMenu()
        for mode in BrowserViewMode.allCases {
            let i = NSMenuItem(title: mode.title, action: #selector(BrowserPaneController.viewModeMenu(_:)), keyEquivalent: "\(mode.rawValue + 1)")
            i.tag = mode.rawValue
            i.target = pane
            m.addItem(i)
        }
        item.submenu = m
        return item
    }

    static func sortMenuItem(_ pane: BrowserPaneController) -> NSMenuItem {
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let m = NSMenu()
        for key in SortKey.menuKeys where key != .location || pane.location.isVirtual {
            let i = NSMenuItem(title: key.title, action: #selector(BrowserPaneController.sortByMenu(_:)), keyEquivalent: "")
            i.representedObject = key.rawValue
            i.target = pane
            m.addItem(i)
        }
        m.addItem(.separator())
        let ff = NSMenuItem(title: "Keep Folders on Top", action: #selector(BrowserPaneController.toggleFoldersFirst(_:)), keyEquivalent: "")
        ff.target = pane
        m.addItem(ff)
        item.submenu = m
        return item
    }

    static func openWithMenu(for url: URL) -> NSMenu {
        let m = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in apps.prefix(30) {
            let name = FileManager.default.displayName(atPath: app.path)
            let item = NSMenuItem(title: app == defaultApp ? "\(name) (default)" : name, action: #selector(OpenWithHandler.open(_:)), keyEquivalent: "")
            item.image = IconCache.shared.fileIcon(app, size: 16)
            item.representedObject = [url, app]
            item.target = OpenWithHandler.shared
            m.addItem(item)
            if app == defaultApp && apps.count > 1 { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(OpenWithHandler.chooseOther(_:)), keyEquivalent: "")
        other.representedObject = url
        other.target = OpenWithHandler.shared
        m.addItem(other)
        return m
    }
}

@MainActor
final class OpenWithHandler: NSObject {
    static let shared = OpenWithHandler()

    @objc func open(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1], configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func chooseOther(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
