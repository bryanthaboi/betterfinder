import AppKit
import Foundation

@MainActor
public final class BrowserRegistries {
    public static let shared: BrowserRegistries = BrowserRegistries(
        toolbar: .shared, sidebar: .shared, contextMenu: .shared, columns: .shared, statusBar: .shared, panels: .shared, previews: .shared,
        browserViews: .shared, commands: .shared, keyBindings: .shared, locations: .shared, searchProviders: .shared
    )

    public let toolbar: ToolbarRegistry
    public let sidebar: SidebarSectionRegistry
    public let contextMenu: ContextMenuRegistry
    public let columns: ColumnRegistry
    public let statusBar: StatusBarRegistry
    public let panels: PanelRegistry
    public let previews: PreviewRegistry
    public let browserViews: BrowserViewRegistry
    public let commands: CommandRegistry
    public let keyBindings: KeyBindingRegistry
    public let locations: LocationRegistry
    public let searchProviders: SearchProviderRegistry

    public convenience init() {
        self.init(
            toolbar: ToolbarRegistry(), sidebar: SidebarSectionRegistry(), contextMenu: ContextMenuRegistry(), columns: ColumnRegistry(), statusBar: StatusBarRegistry(),
            panels: PanelRegistry(), previews: PreviewRegistry(), browserViews: BrowserViewRegistry(), commands: CommandRegistry(), keyBindings: KeyBindingRegistry(),
            locations: LocationRegistry(), searchProviders: SearchProviderRegistry()
        )
    }

    private init(toolbar: ToolbarRegistry, sidebar: SidebarSectionRegistry, contextMenu: ContextMenuRegistry, columns: ColumnRegistry, statusBar: StatusBarRegistry,
                 panels: PanelRegistry, previews: PreviewRegistry, browserViews: BrowserViewRegistry, commands: CommandRegistry, keyBindings: KeyBindingRegistry,
                 locations: LocationRegistry, searchProviders: SearchProviderRegistry) {
        self.toolbar = toolbar
        self.sidebar = sidebar
        self.contextMenu = contextMenu
        self.columns = columns
        self.statusBar = statusBar
        self.panels = panels
        self.previews = previews
        self.browserViews = browserViews
        self.commands = commands
        self.keyBindings = keyBindings
        self.locations = locations
        self.searchProviders = searchProviders
        commands.keyBindings = keyBindings
        commands.panels = panels
        installBuiltIns()
    }

    public var allRegistryKinds: [BrowserRegistryKind] { BrowserRegistryKind.allCases }

    public func removeAll(owner: String) {
        toolbar.removeAll(owner: owner)
        sidebar.removeAll(owner: owner)
        contextMenu.removeAll(owner: owner)
        columns.removeAll(owner: owner)
        statusBar.removeAll(owner: owner)
        panels.removeAll(owner: owner)
        previews.removeAll(owner: owner)
        browserViews.removeAll(owner: owner)
        commands.removeAll(owner: owner)
        keyBindings.removeAll(owner: owner)
        locations.removeAll(owner: owner)
        searchProviders.removeAll(owner: owner)
    }

    private func installBuiltIns() {
        if commands.entries(owner: BrowserOwner.builtIn).isEmpty { BuiltInCommands.register(into: commands) }
        if statusBar.entries(owner: BrowserOwner.builtIn).isEmpty { statusBar.register(SizeSummaryDriver.spec, owner: BrowserOwner.builtIn) }
        if toolbar.entries(owner: BrowserOwner.builtIn).isEmpty { toolbar.register(Self.dualPaneToolbarItem, owner: BrowserOwner.builtIn) }
    }

    static let dualPaneToolbarItem = ToolbarItemSpec(
        id: "dualPane", title: "Dual Pane", toolTip: "Toggle Dual Pane (⌘⇧D)", symbolName: "rectangle.split.2x1", accessibilityLabel: "Dual Pane",
        placement: .after("viewMode"), commandID: "view.toggleDualPane",
        appearance: { ctx in
            ToolbarItemAppearance(
                title: ctx.isDualPane ? "Single Pane" : "Dual Pane",
                symbolName: ctx.isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                toolTip: "Toggle Dual Pane (⌘⇧D)",
                accessibilityLabel: ctx.isDualPane ? "Single Pane" : "Dual Pane"
            )
        },
        toolbarIdentifier: "dualPane"
    )
}
