import AppKit
import Browser
import FSCore
import Foundation
import ModHost

public final class ModEnvironmentState: @unchecked Sendable {
    public struct Location: Equatable, Sendable {
        public var id: String
        public var title: String
        public var provider: String?
        public var url: URL? = nil
    }

    private let lock = NSLock()
    private var darkValue = false
    private var themeName = ""
    private var locationValue: Location?
    private var selectionURLs: [URL] = []

    public init() {}

    public var dark: Bool { lock.withLock { darkValue } }
    public var theme: String { lock.withLock { themeName } }
    public var location: Location? { lock.withLock { locationValue } }
    public var selection: [URL] { lock.withLock { selectionURLs } }

    @discardableResult
    func setAppearance(dark: Bool, theme: String) -> Bool {
        lock.withLock {
            let changed = darkValue != dark || themeName != theme
            darkValue = dark
            themeName = theme
            return changed
        }
    }

    @discardableResult
    func setLocation(_ l: Location) -> Bool {
        lock.withLock {
            let changed = locationValue != l
            locationValue = l
            return changed
        }
    }

    func setSelection(_ urls: [URL]) { lock.withLock { selectionURLs = urls } }

    public var snapshot: ModHostEnvironment {
        lock.withLock {
            ModHostEnvironment(
                locale: Locale.current.identifier, dark: darkValue, currentLocation: locationValue.map { ($0.id, $0.title, $0.provider) },
                currentFolder: locationValue?.provider == nil ? locationValue?.url : nil
            )
        }
    }

    public static func location(for location: BrowserLocation, provided: ProvidedLocation?) -> Location {
        if let p = provided { return Location(id: "\(p.providerID):\(p.id)", title: p.title, provider: p.providerID) }
        if let url = location.url { return Location(id: url.standardizedFileURL.path, title: location.displayName, provider: nil, url: url.standardizedFileURL) }
        return Location(id: "virtual:\(location.displayName)", title: location.displayName, provider: nil)
    }

    @MainActor
    public static func isDarkAppearance() -> Bool {
        (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
