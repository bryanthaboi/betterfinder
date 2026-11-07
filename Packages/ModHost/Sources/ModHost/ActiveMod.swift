import Foundation
import ModHostProtocol
import ModKit
import Settings

public struct ModLogEntry: Sendable, Equatable, Codable {
    public var time: Date
    public var level: String
    public var message: String

    public init(time: Date, level: String, message: String) { self.time = time; self.level = level; self.message = message }
}

public final class ModLogBuffer: @unchecked Sendable {
    public static let capacity = 500
    private let lock = NSLock()
    private var entries: [ModLogEntry] = []
    private var tokens: Double = 50
    private var refilled = Date()
    private let file: URL?
    private let home = NSHomeDirectory()

    init(file: URL?) { self.file = file }

    public var all: [ModLogEntry] { lock.lock(); defer { lock.unlock() }; return entries }

    public static func read(file: URL, limit: Int = capacity) -> [ModLogEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let f = ISO8601DateFormatter()
        var out = [ModLogEntry]()
        for line in text.split(separator: "\n").suffix(limit) {
            guard let sp = line.firstIndex(of: " "), let time = f.date(from: String(line[..<sp])) else { continue }
            let rest = line[line.index(after: sp)...]
            guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else { continue }
            let level = String(rest[rest.index(after: rest.startIndex)..<close])
            let message = rest[rest.index(after: close)...].drop { $0 == " " }
            out.append(ModLogEntry(time: time, level: level, message: String(message)))
        }
        return out
    }

    func redact(_ s: String) -> String {
        var out = s.replacingOccurrences(of: home, with: "~")
        out = String(out.unicodeScalars.map { $0.value < 0x20 && $0 != "\n" && $0 != "\t" ? " " : Character($0) })
        return String(out.prefix(2048))
    }

    @discardableResult
    func append(_ level: String, _ message: String, rateLimited: Bool = true) -> Bool {
        lock.lock()
        let now = Date()
        tokens = min(50, tokens + now.timeIntervalSince(refilled) * 20)
        refilled = now
        if rateLimited {
            guard tokens >= 1 else { lock.unlock(); return false }
            tokens -= 1
        }
        let e = ModLogEntry(time: now, level: level, message: redact(message))
        entries.append(e)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        lock.unlock()
        if let file {
            let line = "\(ISO8601DateFormatter().string(from: e.time)) [\(e.level)] \(e.message)\n"
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                if h.offsetInFile > 1 << 20 { h.truncateFile(atOffset: 0) }
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: file.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
            }
        }
        return true
    }
}

final class ModStorage: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var values: [String: JSONValue]?

    init(url: URL) { self.url = url }

    private func loadLocked() -> [String: JSONValue] {
        if let values { return values }
        let v = (try? Data(contentsOf: url)).flatMap { try? JSONValue.parse($0) }?.objectValue ?? [:]
        values = v
        return v
    }

    func get(_ key: String) -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()[key] ?? .null
    }

    func keys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().keys.sorted()
    }

    func set(_ key: String, _ value: JSONValue?, quota: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var v = loadLocked()
        v[key] = value
        let data = JSONValue.object(v).canonicalData()
        guard data.count <= quota else { throw ModCallError("quotaExceeded", "storage would use \(data.count) bytes; quota is \(quota)") }
        try ModFiles.writePrivate(data, to: url)
        values = v
    }
}

public enum ModRunMode: Sendable, Equatable { case live, dryRun }

final class ActiveMod: @unchecked Sendable {
    let id: String
    let manifest: ModManifest
    let generation: Int
    let snapshot: URL
    let mode: ModRunMode
    let handles: ModHandleTable
    let logs: ModLogBuffer
    let storage: ModStorage
    let settings: ModSettingsStore?
    private let lock = NSLock()
    private var grantList: [ModPermission]
    private var quarantined: [String: Int] = [:]
    private var notifyTimes: [Date] = []
    private var enabledCommands: [String: Bool] = [:]

    init(manifest: ModManifest, generation: Int, snapshot: URL, mode: ModRunMode, grants: [ModPermission], logs: ModLogBuffer, storageURL: URL, settings: ModSettingsStore?) {
        self.id = manifest.id
        self.manifest = manifest
        self.generation = generation
        self.snapshot = snapshot
        self.mode = mode
        self.grantList = grants
        self.handles = ModHandleTable(modId: manifest.id)
        self.logs = logs
        self.storage = ModStorage(url: storageURL)
        self.settings = settings
    }

    var grants: [ModPermission] {
        get { lock.lock(); defer { lock.unlock() }; return grantList }
        set { lock.lock(); grantList = newValue; lock.unlock() }
    }

    func handlers(for hook: String) -> [ModHookDecl] { manifest.hooks.filter { $0.name == hook } }

    func quarantine(_ handler: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        quarantined[handler, default: 0] += 1
        return quarantined.values.reduce(0, +)
    }

    func isQuarantined(_ handler: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (quarantined[handler] ?? 0) > 0
    }

    func allowNotify() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        notifyTimes = notifyTimes.filter { now.timeIntervalSince($0) < 10 }
        guard notifyTimes.count < 5 else { return false }
        notifyTimes.append(now)
        return true
    }

    func setCommandEnabled(_ id: String, _ enabled: Bool) {
        lock.lock(); enabledCommands[id] = enabled; lock.unlock()
    }

    func isCommandEnabled(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabledCommands[id] ?? true
    }

    var storageQuota: Int {
        grants.first { $0.kind == .storage }?.quotaBytes ?? 1 << 20
    }
}

final class ModInvocation: @unchecked Sendable {
    let id: String
    let mod: ActiveMod
    let hook: ModHookSignature
    let handler: String
    let gesture: Bool
    let depth: Int
    let parent: ModInvocation?
    let started = Date()
    private let lock = NSLock()
    private var tokens: [UUID] = []
    private var finished = false

    init(id: String = "i_" + UUID().uuidString, mod: ActiveMod, hook: ModHookSignature, handler: String, gesture: Bool, parent: ModInvocation?) {
        self.id = id
        self.mod = mod
        self.hook = hook
        self.handler = handler
        self.gesture = gesture || (parent?.gesture ?? false)
        self.depth = (parent?.depth ?? -1) + 1
        self.parent = parent
    }

    func track(_ token: UUID) { lock.lock(); tokens.append(token); lock.unlock() }

    func finish() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        finished = true
        let t = tokens
        tokens = []
        return t
    }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
