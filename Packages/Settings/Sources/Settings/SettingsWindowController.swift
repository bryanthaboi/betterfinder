import AppKit
import Combine
import SwiftUI

@MainActor
public final class SettingsWindowController: NSWindowController {
    public enum Tab: Int, CaseIterable {
        case general, defaultFileManager, appearance, permissions, advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .defaultFileManager: return "Default"
            case .appearance: return "Appearance"
            case .permissions: return "Permissions"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .defaultFileManager: return "folder.badge.gearshape"
            case .appearance: return "paintpalette"
            case .permissions: return "lock.shield"
            case .advanced: return "slider.horizontal.3"
            }
        }

        public var paneID: String {
            switch self {
            case .general: return SettingsPaneID.general
            case .defaultFileManager: return SettingsPaneID.defaultFileManager
            case .appearance: return SettingsPaneID.appearance
            case .permissions: return SettingsPaneID.permissions
            case .advanced: return SettingsPaneID.advanced
            }
        }
    }

    private struct PaneSpec {
        var id: String
        var title: String
        var symbol: String
        var size: CGSize
        var view: AnyView
    }

    static let minimumPaneSize = CGSize(width: 820, height: 640)

    public static let shared = SettingsWindowController()

    public var sizeIndexController: SizeIndexControlling {
        didSet { rebuildTabs() }
    }

    public var modManagementController: ModManagementControlling? {
        didSet {
            modsModel = modManagementController.map { ModsPaneModel(controller: $0) }
            rebuildTabs()
        }
    }

    public var paneRegistry: SettingsPaneRegistry = .shared {
        didSet { observeRegistry() }
    }

    public private(set) var paneIDs: [String] = []

    private let tabController = NSTabViewController()
    private var modsModel: ModsPaneModel?
    private var registryObservation: AnyCancellable?
    private var dynamicPanes: [RegisteredSettingsPane] = []

    public init(sizeIndexController: SizeIndexControlling? = nil) {
        self.sizeIndexController = sizeIndexController ?? NoOpSizeIndexController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BetterFinderSettings")
        super.init(window: window)
        tabController.tabStyle = .toolbar
        window.contentViewController = tabController
        rebuildTabs()
        observeRegistry()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func show(tab: Tab? = nil) {
        if let tab { tabController.selectedTabViewItemIndex = tab.rawValue }
        present()
    }

    @discardableResult
    public func show(paneID: String) -> Bool {
        guard let index = paneIDs.firstIndex(of: paneID) else { return false }
        tabController.selectedTabViewItemIndex = index
        present()
        return true
    }

    private func present() {
        updateTitle()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func observeRegistry() {
        dynamicPanes = paneRegistry.panes
        registryObservation = paneRegistry.$panes.dropFirst().sink { [weak self] panes in
            MainActor.assumeIsolated {
                self?.dynamicPanes = panes
                self?.rebuildTabs()
            }
        }
        rebuildTabs()
    }

    public override func showWindow(_ sender: Any?) {
        updateTitle()
        super.showWindow(sender)
    }

    private func updateTitle() {
        let index = tabController.selectedTabViewItemIndex
        if let tab = Tab(rawValue: index), index < Tab.allCases.count {
            window?.title = tab.title
        } else if tabController.tabViewItems.indices.contains(index) {
            window?.title = tabController.tabViewItems[index].label
        } else {
            window?.title = "Settings"
        }
    }

    private func paneSpecs() -> [PaneSpec] {
        var extra: [(id: String, title: String)] = []
        if modsModel != nil { extra.append((SettingsPaneID.mods, "Mods")) }
        extra += dynamicPanes.map { ($0.descriptor.id, $0.descriptor.title) }
        var specs = Tab.allCases.map { PaneSpec(id: $0.paneID, title: $0.title, symbol: $0.symbol, size: Self.minimumPaneSize, view: AnyView(content(for: $0, extraPanes: extra))) }
        if let modsModel {
            specs.append(PaneSpec(
                id: SettingsPaneID.mods,
                title: "Mods",
                symbol: "puzzlepiece.extension",
                size: CGSize(width: 820, height: 600),
                view: AnyView(ModsPaneView(model: modsModel))
            ))
        }
        for pane in dynamicPanes {
            let d = pane.descriptor
            specs.append(PaneSpec(
                id: d.id,
                title: d.title,
                symbol: d.symbolName,
                size: CGSize(width: d.width, height: d.minHeight),
                view: AnyView(d.makeView())
            ))
        }
        return specs
    }

    static func paneSize(fitting sizes: [CGSize]) -> CGSize {
        sizes.reduce(minimumPaneSize) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
    }

    private func rebuildTabs() {
        let previousID = paneIDs.indices.contains(tabController.selectedTabViewItemIndex) ? paneIDs[tabController.selectedTabViewItemIndex] : nil
        let fallbackIndex = max(0, tabController.selectedTabViewItemIndex)
        while let item = tabController.tabViewItems.first { tabController.removeTabViewItem(item) }
        let specs = paneSpecs()
        let size = Self.paneSize(fitting: specs.map(\.size))
        for spec in specs {
            let host = NSHostingController(rootView: spec.view.frame(width: size.width, height: size.height))
            host.sizingOptions = [.preferredContentSize]
            host.title = spec.title
            let item = NSTabViewItem(viewController: host)
            item.label = spec.title
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.title)
            tabController.addTabViewItem(item)
        }
        paneIDs = specs.map(\.id)
        if let previousID, let index = paneIDs.firstIndex(of: previousID) {
            tabController.selectedTabViewItemIndex = index
        } else {
            tabController.selectedTabViewItemIndex = min(fallbackIndex, specs.count - 1)
        }
        updateTitle()
    }

    @ViewBuilder
    private func content(for tab: Tab, extraPanes: [(id: String, title: String)]) -> some View {
        switch tab {
        case .general: GeneralPane(openPane: { [weak self] in self?.show(paneID: $0) }, extraPanes: extraPanes)
        case .defaultFileManager: DefaultFileManagerPane()
        case .appearance: AppearancePane()
        case .permissions: PermissionsPane()
        case .advanced: AdvancedPane(sizeIndex: sizeIndexController)
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {}
