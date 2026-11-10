import Foundation

public enum SizeFormatter {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func exact(_ bytes: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: bytes)) ?? "\(bytes)") + " bytes"
    }
}

public enum VolumeInfo {
    public static func availableCapacity(for url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if !DemoEnvironment.isEnabled, let important = v?.volumeAvailableCapacityForImportantUsage { return important }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    public static func isVolumeRoot(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isVolumeKey])
        return v?.isVolume ?? false
    }

    public static func isNetworkVolume(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        return v?.volumeIsLocal == false
    }
}

public struct VolumeDetails: Equatable, Sendable {
    public enum Connection: String, Equatable, Sendable { case `internal`, external, network, diskImage }

    public var name: String
    public var mountPoint: String
    public var device: String
    public var format: String
    public var totalBytes: Int64?
    public var availableBytes: Int64?
    public var connection: Connection
    public var isReadOnly: Bool
    public var isEjectable: Bool

    public init(name: String, mountPoint: String, device: String = "", format: String = "", totalBytes: Int64? = nil, availableBytes: Int64? = nil,
                connection: Connection = .internal, isReadOnly: Bool = false, isEjectable: Bool = false) {
        self.name = name
        self.mountPoint = mountPoint
        self.device = device
        self.format = format
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.connection = connection
        self.isReadOnly = isReadOnly
        self.isEjectable = isEjectable
    }

    public var usedBytes: Int64? {
        guard let totalBytes, let availableBytes else { return nil }
        return max(0, totalBytes - availableBytes)
    }

    public var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    public var kindText: String {
        let what: String
        switch connection {
        case .internal: what = "Internal volume"
        case .external: what = "External volume"
        case .network: what = "Network volume"
        case .diskImage: what = "Disk image"
        }
        return format.isEmpty ? what : "\(what) (\(format))"
    }

    public var spaceText: String {
        switch (availableBytes, totalBytes) {
        case let (free?, total?): return "\(SizeFormatter.string(free)) free of \(SizeFormatter.string(total))"
        case let (nil, total?): return SizeFormatter.string(total)
        case let (free?, nil): return "\(SizeFormatter.string(free)) free"
        default: return "--"
        }
    }
}

extension VolumeInfo {
    public static func details(for url: URL) -> VolumeDetails? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeURLKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let mount = v.volume?.path ?? url.path
        var fs = statfs()
        var device = ""
        var imageBacked = false
        if statfs(mount, &fs) == 0 {
            device = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            imageBacked = !(v.volumeIsInternal ?? false) && (v.volumeIsLocal ?? true) && (v.volumeIsReadOnly ?? false) && mount.hasPrefix("/Volumes/")
                && !(v.volumeIsRemovable ?? false)
        }
        let connection: VolumeDetails.Connection
        if v.volumeIsLocal == false { connection = .network }
        else if v.volumeIsInternal == true { connection = .internal }
        else if imageBacked { connection = .diskImage }
        else { connection = .external }
        return VolumeDetails(
            name: v.volumeLocalizedName ?? v.volumeName ?? FileManager.default.displayName(atPath: mount), mountPoint: mount, device: device,
            format: v.volumeLocalizedFormatDescription ?? "", totalBytes: v.volumeTotalCapacity.map(Int64.init), availableBytes: availableCapacity(for: url),
            connection: connection, isReadOnly: v.volumeIsReadOnly ?? false, isEjectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false)
        )
    }
}
