import Foundation

public enum ModPermissionID {
    public static let separator = ":"
    public static let digestLength = 12

    public static func canonicalJSON(_ permission: ModPermission) -> Data { permission.modKitJSON() }

    public static func make(_ permission: ModPermission) -> String {
        from(kind: permission.kind.rawValue, canonicalJSON: canonicalJSON(permission))
    }

    public static func from(kind: String, canonicalJSON: Data) -> String {
        kind + separator + String(SHA256.hex(canonicalJSON).prefix(digestLength))
    }

    public static func kind(of id: String) -> ModPermissionKind? {
        guard let range = id.range(of: separator, options: .backwards) else { return nil }
        return ModPermissionKind(rawValue: String(id[..<range.lowerBound]))
    }

    public static func isWellFormed(_ id: String) -> Bool {
        guard let range = id.range(of: separator, options: .backwards) else { return false }
        let digest = id[range.upperBound...]
        return !id[..<range.lowerBound].isEmpty && digest.count == digestLength && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public extension ModPermission {
    var permissionID: String { ModPermissionID.make(self) }
}
