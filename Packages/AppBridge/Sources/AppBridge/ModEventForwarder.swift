import AppKit
import Browser
import FSCore
import Foundation
import ModHost
import Theming

@MainActor
final class ModEventDriver: StatusBarSegmentDriver {
    weak var forwarder: ModEventForwarder?
    private var lastLocation: ModEnvironmentState.Location?
    private var lastSelection: [String]?

    init(forwarder: ModEventForwarder?) { self.forwarder = forwarder }

    func update(_ context: StatusBarContext, output: StatusBarSegmentOutput) {
        output.setHidden(true)
        guard let forwarder else { return }
        let loc = ModEnvironmentState.location(for: context.location, provided: context.providedLocation)
        if loc != lastLocation {
            lastLocation = loc
            forwarder.paneChanged(location: context.location, provided: context.providedLocation)
        }
        let keys = context.selection.map(\.url.path)
        if keys != lastSelection {
            lastSelection = keys
            forwarder.selectionChanged(context.selection, location: context.location, provided: context.providedLocation)
        }
    }

    func stop() {}
}

@MainActor
public final class ModEventForwarder {
    public static let owner = "betterfinder.appbridge"
    public static let segmentID = "modEvents"

    public let environment: ModEnvironmentState
    public var debounce: TimeInterval = 0.12
    public var onSelection: (([URL], Int) -> Void)?
    public var onLocation: ((ModEnvironmentState.Location, Int) -> Void)?
    public var onTheme: ((String, Bool) -> Void)?

    public private(set) var selectionRevision = 0
    public private(set) var locationRevision = 0
    public private(set) var lastItems: [FileItem] = []
    public private(set) var lastBrowserLocation: BrowserLocation = .computer
    public private(set) var lastProvided: ProvidedLocation?

    private let registries: BrowserRegistries
    private var token: BrowserRegistrationToken?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var pendingSelection: DispatchWorkItem?

    public init(registries: BrowserRegistries = .shared, environment: ModEnvironmentState) {
        self.registries = registries
        self.environment = environment
    }

    public func install() {
        guard token == nil else { return }
        let spec = StatusBarSegmentSpec(id: Self.segmentID, alignment: .trailing, accessibilityLabel: "Mod events", makeDriver: { [weak self] in ModEventDriver(forwarder: self) }, defaultOrder: 10_000)
        token = registries.statusBar.register(spec, owner: Self.owner)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let wc = (note.object as? NSWindow)?.windowController as? BrowserWindowController else { return }
                self?.paneChanged(location: wc.location, provided: wc.providedLocation)
            }
        })
        observers.append(nc.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAppearanceCheck() }
        })
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceChanged() } }
        }
        appearanceChanged(notify: false)
    }

    public func uninstall() {
        token?.cancel()
        token = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        appearanceObservation = nil
        pendingSelection?.cancel()
    }

    public var currentContext: BrowserContext {
        BrowserContext(location: lastBrowserLocation, providedLocation: lastProvided, selection: lastItems, isDualPane: false, windowNumber: NSApp?.keyWindow?.windowNumber)
    }

    private func scheduleAppearanceCheck() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.appearanceChanged() } }
    }

    func appearanceChanged(notify: Bool = true) {
        let dark = ModEnvironmentState.isDarkAppearance()
        let name = ThemeManager.shared.current.name
        if environment.setAppearance(dark: dark, theme: name), notify { onTheme?(name, dark) }
    }

    func paneChanged(location: BrowserLocation, provided: ProvidedLocation?) {
        lastBrowserLocation = location
        lastProvided = provided
        let loc = ModEnvironmentState.location(for: location, provided: provided)
        guard environment.setLocation(loc) else { return }
        locationRevision += 1
        onLocation?(loc, locationRevision)
    }

    func selectionChanged(_ items: [FileItem], location: BrowserLocation, provided: ProvidedLocation?) {
        lastItems = items
        lastBrowserLocation = location
        lastProvided = provided
        let urls = items.map(\.url)
        environment.setSelection(urls)
        pendingSelection?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.selectionRevision += 1
                self.onSelection?(urls, self.selectionRevision)
            }
        }
        pendingSelection = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
