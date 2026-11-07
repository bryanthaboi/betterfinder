import AppKit
import Foundation

public extension Notification.Name {
    static let browserRegistryDidChange = Notification.Name("BrowserRegistryDidChange")
}

public enum BrowserRegistryKind: String, CaseIterable, Sendable {
    case toolbar, sidebar, contextMenu, column, statusBar, panel, preview, browserView, command, keyBinding, location, search
}

public enum BrowserOwner {
    public static let builtIn = "betterfinder"
}

public struct BrowserRegistryError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class BrowserRegistrationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public static func combined(_ tokens: [BrowserRegistrationToken]) -> BrowserRegistrationToken {
        BrowserRegistrationToken { for t in tokens { t.cancel() } }
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return onCancel != nil
    }

    public func cancel() {
        lock.lock()
        let handler = onCancel
        onCancel = nil
        lock.unlock()
        handler?()
    }
}

func runOnMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}

public protocol BrowserContribution {
    var id: String { get }
    var defaultOrder: Int { get }
    var isVisibleByDefault: Bool { get }
}

public extension BrowserContribution {
    var defaultOrder: Int { 0 }
    var isVisibleByDefault: Bool { true }
}

@MainActor
struct ContributionPreferences {
    let kind: BrowserRegistryKind

    private func key(_ suffix: String) -> String { "browserContribution.\(kind.rawValue).\(suffix)" }

    var hidden: Set<String> {
        get { Set(BrowserDefaults.store.stringArray(forKey: key("hidden")) ?? []) }
        nonmutating set { BrowserDefaults.store.set(Array(newValue).sorted(), forKey: key("hidden")) }
    }

    var shown: Set<String> {
        get { Set(BrowserDefaults.store.stringArray(forKey: key("shown")) ?? []) }
        nonmutating set { BrowserDefaults.store.set(Array(newValue).sorted(), forKey: key("shown")) }
    }

    var order: [String] {
        get { BrowserDefaults.store.stringArray(forKey: key("order")) ?? [] }
        nonmutating set { BrowserDefaults.store.set(newValue, forKey: key("order")) }
    }

    func isHidden(_ qualifiedID: String, defaultVisible: Bool) -> Bool {
        if hidden.contains(qualifiedID) { return true }
        return !defaultVisible && !shown.contains(qualifiedID)
    }

    func setHidden(_ qualifiedID: String, _ isHidden: Bool) {
        var h = hidden
        var s = shown
        if isHidden { h.insert(qualifiedID); s.remove(qualifiedID) } else { h.remove(qualifiedID); s.insert(qualifiedID) }
        hidden = h
        shown = s
    }

    func reset() {
        for suffix in ["hidden", "shown", "order"] { BrowserDefaults.store.removeObject(forKey: key(suffix)) }
    }
}

@MainActor
open class BrowserRegistry<Item: BrowserContribution> {
    public struct Entry {
        public let qualifiedID: String
        public let owner: String
        public let item: Item
        public let sequence: Int
    }

    public let kind: BrowserRegistryKind
    public private(set) var revision = 0
    public private(set) var entries: [Entry] = []

    private var nextSequence = 0
    private var observers: [ObjectIdentifier: @MainActor () -> Void] = [:]
    var preferences: ContributionPreferences { ContributionPreferences(kind: kind) }

    public init(kind: BrowserRegistryKind) {
        self.kind = kind
    }

    public static func qualify(_ id: String, owner: String) -> String { "\(owner)/\(id)" }

    public static func reference(_ ref: String, owner: String) -> String {
        ref.contains("/") ? ref : "\(owner)/\(ref)"
    }

    open func validate(_ item: Item, owner: String) -> String? {
        if item.id.isEmpty { return "A contribution id is required." }
        if item.id.contains("/") { return "Contribution ids can't contain “/”." }
        if owner.isEmpty { return "An owner is required." }
        return nil
    }

    open func didChange() {}

    public func entry(_ qualifiedID: String) -> Entry? {
        entries.first { $0.qualifiedID == qualifiedID }
    }

    public func item(_ qualifiedID: String) -> Item? { entry(qualifiedID)?.item }

    public func entries(owner: String) -> [Entry] { entries.filter { $0.owner == owner } }

    public var owners: [String] { Array(Set(entries.map(\.owner))).sorted() }

    public var orderedEntries: [Entry] {
        let order = preferences.order
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return entries.sorted { a, b in
            switch (index[a.qualifiedID], index[b.qualifiedID]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                if a.item.defaultOrder != b.item.defaultOrder { return a.item.defaultOrder < b.item.defaultOrder }
                return a.sequence < b.sequence
            }
        }
    }

    public var visibleEntries: [Entry] {
        let prefs = preferences
        return orderedEntries.filter { !prefs.isHidden($0.qualifiedID, defaultVisible: $0.item.isVisibleByDefault) }
    }

    public func isHidden(_ qualifiedID: String) -> Bool {
        guard let e = entry(qualifiedID) else { return preferences.hidden.contains(qualifiedID) }
        return preferences.isHidden(qualifiedID, defaultVisible: e.item.isVisibleByDefault)
    }

    public func setHidden(_ qualifiedID: String, _ hidden: Bool) {
        preferences.setHidden(qualifiedID, hidden)
        notify()
    }

    public func setOrder(_ qualifiedIDs: [String]) {
        preferences.order = qualifiedIDs
        notify()
    }

    public func move(_ qualifiedID: String, toIndex index: Int) {
        var ids = orderedEntries.map(\.qualifiedID)
        guard let from = ids.firstIndex(of: qualifiedID) else { return }
        ids.remove(at: from)
        ids.insert(qualifiedID, at: min(max(0, index), ids.count))
        setOrder(ids)
    }

    public func resetPreferences() {
        preferences.reset()
        notify()
    }

    @discardableResult
    public func register(_ item: Item, owner: String) -> BrowserRegistrationToken {
        if validate(item, owner: owner) != nil { return BrowserRegistrationToken {} }
        let qid = Self.qualify(item.id, owner: owner)
        entries.removeAll { $0.qualifiedID == qid && $0.owner == owner }
        let seq = takeSequence()
        entries.append(Entry(qualifiedID: qid, owner: owner, item: item, sequence: seq))
        notify()
        return token(for: [(qid, seq)])
    }

    @discardableResult
    public func registerBatch(_ items: [Item], owner: String) throws -> BrowserRegistrationToken {
        try checkBatch(items, owner: owner)
        var created: [(String, Int)] = []
        for item in items {
            let qid = Self.qualify(item.id, owner: owner)
            entries.removeAll { $0.qualifiedID == qid && $0.owner == owner }
            let seq = takeSequence()
            entries.append(Entry(qualifiedID: qid, owner: owner, item: item, sequence: seq))
            created.append((qid, seq))
        }
        notify()
        return token(for: created)
    }

    @discardableResult
    public func replaceAll(_ items: [Item], owner: String) throws -> BrowserRegistrationToken {
        try checkBatch(items, owner: owner)
        entries.removeAll { $0.owner == owner }
        var created: [(String, Int)] = []
        for item in items {
            let qid = Self.qualify(item.id, owner: owner)
            let seq = takeSequence()
            entries.append(Entry(qualifiedID: qid, owner: owner, item: item, sequence: seq))
            created.append((qid, seq))
        }
        notify()
        return token(for: created)
    }

    public func removeAll(owner: String) {
        let before = entries.count
        entries.removeAll { $0.owner == owner }
        if entries.count != before { notify() }
    }

    public func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    public func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    public func notify() {
        revision += 1
        didChange()
        for handler in observers.values { handler() }
        NotificationCenter.default.post(name: .browserRegistryDidChange, object: self, userInfo: ["kind": kind.rawValue])
    }

    private func takeSequence() -> Int {
        nextSequence += 1
        return nextSequence
    }

    private func checkBatch(_ items: [Item], owner: String) throws {
        var seen = Set<String>()
        for item in items {
            if let problem = validate(item, owner: owner) { throw BrowserRegistryError(problem) }
            let qid = Self.qualify(item.id, owner: owner)
            guard seen.insert(qid).inserted else { throw BrowserRegistryError("Duplicate \(kind.rawValue) contribution “\(item.id)” in one batch.") }
        }
    }

    private func token(for created: [(String, Int)]) -> BrowserRegistrationToken {
        BrowserRegistrationToken { [weak self] in
            runOnMainActor {
                guard let self else { return }
                let before = self.entries.count
                for (qid, seq) in created { self.entries.removeAll { $0.qualifiedID == qid && $0.sequence == seq } }
                if self.entries.count != before { self.notify() }
            }
        }
    }
}

public struct BrowserImageSource: Hashable, Sendable {
    public var symbolName: String?
    public var pngData: Data?

    public init(symbolName: String? = nil, pngData: Data? = nil) {
        self.symbolName = symbolName
        self.pngData = pngData
    }

    public static func symbol(_ name: String) -> BrowserImageSource { BrowserImageSource(symbolName: name) }

    @MainActor
    func image(accessibilityDescription: String?) -> NSImage? {
        if let name = symbolName, let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) { return img }
        if let data = pngData, let img = NSImage(data: data) {
            img.accessibilityDescription = accessibilityDescription
            return img
        }
        return nil
    }
}
