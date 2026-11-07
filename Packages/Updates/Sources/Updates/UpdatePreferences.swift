import Foundation

public enum UpdatesDefaultsKey {
    public static let autoCheck = "autoCheckForUpdates"
    public static let lastChecked = "lastUpdateCheck"
    public static let skippedVersion = "skippedUpdateVersion"
    public static let etag = "updateFeedETag"
    public static let cachedRelease = "updateFeedCachedRelease"
    public static let crashReportsEnabled = "crashReportsEnabled"
    public static let lastSeenCrash = "lastSeenCrashTimestamp"
}

public enum UpdatesDefaults {
    public static let registered: [String: Any] = [
        UpdatesDefaultsKey.autoCheck: true,
        UpdatesDefaultsKey.crashReportsEnabled: true,
    ]
}

public final class UpdatePreferences: @unchecked Sendable {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var automaticallyChecks: Bool {
        get { defaults.object(forKey: UpdatesDefaultsKey.autoCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UpdatesDefaultsKey.autoCheck) }
    }

    public var lastChecked: Date? {
        get {
            let t = defaults.double(forKey: UpdatesDefaultsKey.lastChecked)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue { defaults.set(newValue.timeIntervalSince1970, forKey: UpdatesDefaultsKey.lastChecked) }
            else { defaults.removeObject(forKey: UpdatesDefaultsKey.lastChecked) }
        }
    }

    public var skippedVersion: SemanticVersion? {
        get { defaults.string(forKey: UpdatesDefaultsKey.skippedVersion).flatMap(SemanticVersion.init) }
        set {
            if let newValue { defaults.set(newValue.description, forKey: UpdatesDefaultsKey.skippedVersion) }
            else { defaults.removeObject(forKey: UpdatesDefaultsKey.skippedVersion) }
        }
    }

    public var etag: String? {
        get { defaults.string(forKey: UpdatesDefaultsKey.etag) }
        set {
            if let newValue { defaults.set(newValue, forKey: UpdatesDefaultsKey.etag) }
            else { defaults.removeObject(forKey: UpdatesDefaultsKey.etag) }
        }
    }

    public var cachedReleaseData: Data? {
        get { defaults.data(forKey: UpdatesDefaultsKey.cachedRelease) }
        set {
            if let newValue { defaults.set(newValue, forKey: UpdatesDefaultsKey.cachedRelease) }
            else { defaults.removeObject(forKey: UpdatesDefaultsKey.cachedRelease) }
        }
    }

    public var crashReportsEnabled: Bool {
        get { defaults.object(forKey: UpdatesDefaultsKey.crashReportsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UpdatesDefaultsKey.crashReportsEnabled) }
    }

    public var lastSeenCrash: Date? {
        get {
            let t = defaults.double(forKey: UpdatesDefaultsKey.lastSeenCrash)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue { defaults.set(newValue.timeIntervalSince1970, forKey: UpdatesDefaultsKey.lastSeenCrash) }
            else { defaults.removeObject(forKey: UpdatesDefaultsKey.lastSeenCrash) }
        }
    }

    public func isDue(now: Date = Date()) -> Bool {
        guard automaticallyChecks else { return false }
        guard let last = lastChecked else { return true }
        return now.timeIntervalSince(last) >= Self.checkInterval
    }

    public func isSkipped(_ version: SemanticVersion) -> Bool {
        guard let skipped = skippedVersion else { return false }
        return version <= skipped
    }

    public func clearFeedCache() {
        etag = nil
        cachedReleaseData = nil
    }
}
