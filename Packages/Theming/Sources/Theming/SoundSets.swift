import AppKit
import Foundation

public extension Notification.Name {
    static let soundSetDidChange = Notification.Name("BetterFinderSoundSetDidChange")
}

@MainActor
public protocol SoundSetProvider: AnyObject {
    var setID: String { get }
    func sound(for event: ThemeSoundEvent) -> NSSound?
}

@MainActor
public final class StaticSoundSetProvider: SoundSetProvider {
    public let setID: String
    private let urls: [ThemeSoundEvent: URL]

    public init(setID: String, urls: [ThemeSoundEvent: URL]) {
        self.setID = setID
        self.urls = urls
    }

    public func sound(for event: ThemeSoundEvent) -> NSSound? {
        guard let url = urls[event] else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }
}

public struct SoundProviderToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

@MainActor
public final class SoundSetRegistry {
    public static let shared = SoundSetRegistry()
    public static let specPrefix = "set:"

    private struct Entry {
        var token: SoundProviderToken
        var owner: String
        var provider: SoundSetProvider
    }

    private var entries: [Entry] = []

    public init() {}

    @discardableResult
    public func register(_ provider: SoundSetProvider, owner: String) -> SoundProviderToken {
        let token = SoundProviderToken()
        entries.append(Entry(token: token, owner: owner, provider: provider))
        changed()
        return token
    }

    @discardableResult
    public func remove(_ token: SoundProviderToken) -> Bool {
        let before = entries.count
        entries.removeAll { $0.token == token }
        guard entries.count != before else { return false }
        changed()
        return true
    }

    @discardableResult
    public func removeAll(owner: String) -> Int {
        let before = entries.count
        entries.removeAll { $0.owner == owner }
        let removed = before - entries.count
        if removed > 0 { changed() }
        return removed
    }

    public func provider(forSet setID: String) -> SoundSetProvider? {
        entries.last { $0.provider.setID == setID }?.provider
    }

    public var registeredSetIDs: [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.provider.setID) { seen.append(e.provider.setID) }
        return seen
    }

    public func sound(forSpec spec: String, event: ThemeSoundEvent) -> NSSound? {
        guard spec.hasPrefix(Self.specPrefix) else { return nil }
        let setID = String(spec.dropFirst(Self.specPrefix.count))
        guard !setID.isEmpty, let provider = provider(forSet: setID) else { return nil }
        return provider.sound(for: event)
    }

    private func changed() {
        ThemeSounds.clearCache()
        NotificationCenter.default.post(name: .soundSetDidChange, object: self)
    }
}
