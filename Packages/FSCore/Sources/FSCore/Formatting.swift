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
        if let important = v?.volumeAvailableCapacityForImportantUsage { return important }
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
