import Foundation

public struct SemVer: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]
    public var build: [String]

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = [], build: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public init?(_ string: String) {
        guard let v = SemVer.parse(string) else { return nil }
        self = v
    }

    public static func parse(_ string: String) -> SemVer? {
        var rest = Substring(string)
        var build = [String]()
        if let plus = rest.firstIndex(of: "+") {
            let b = rest[rest.index(after: plus)...]
            rest = rest[..<plus]
            let ids = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isIdentChar) }) else { return nil }
            build = ids
        }
        var pre = [String]()
        if let dash = rest.firstIndex(of: "-") {
            let p = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
            let ids = p.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.isEmpty else { return nil }
            for id in ids {
                guard !id.isEmpty, id.allSatisfy(isIdentChar) else { return nil }
                if id.allSatisfy(\.isASCIIDigit), id.count > 1, id.first == "0" { return nil }
            }
            pre = ids
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums = [Int]()
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCIIDigit), !(p.count > 1 && p.first == "0"), p.count <= 9, let n = Int(p) else { return nil }
            nums.append(n)
        }
        return SemVer(nums[0], nums[1], nums[2], prerelease: pre, build: build)
    }

    private static func isIdentChar(_ c: Character) -> Bool { c.isASCIIDigit || (c.isASCII && c.isLetter) || c == "-" }

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { s += "+" + build.joined(separator: ".") }
        return s
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) {
            if x == y { continue }
            let xn = Int(x), yn = Int(y)
            switch (xn, yn) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    public static func == (a: SemVer, b: SemVer) -> Bool {
        a.major == b.major && a.minor == b.minor && a.patch == b.patch && a.prerelease == b.prerelease
    }

    public func hash(into h: inout Hasher) {
        h.combine(major); h.combine(minor); h.combine(patch); h.combine(prerelease)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = SemVer.parse(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "BF1008|invalid semantic version '\(s)'"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

public struct SemVerRange: Equatable, Hashable, Sendable, CustomStringConvertible, Codable {
    public enum Op: String, Sendable { case ge = ">=", gt = ">", le = "<=", lt = "<", eq = "=" }

    public struct Comparator: Equatable, Hashable, Sendable {
        public var op: Op
        public var version: SemVer

        public func matches(_ v: SemVer) -> Bool {
            switch op {
            case .ge: return v >= version
            case .gt: return v > version
            case .le: return v <= version
            case .lt: return v < version
            case .eq: return v == version
            }
        }
    }

    public var alternatives: [[Comparator]]
    public let source: String

    public init?(_ string: String) {
        guard let r = SemVerRange.parse(string) else { return nil }
        self = r
    }

    public static func parse(_ string: String) -> SemVerRange? {
        guard !string.isEmpty, string.count <= 128, string.allSatisfy({ !$0.isNewline }) else { return nil }
        var alts = [[Comparator]]()
        for part in string.components(separatedBy: "||") {
            let tokens = part.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !tokens.isEmpty else { return nil }
            var set = [Comparator]()
            for token in tokens {
                guard let comps = comparators(token) else { return nil }
                set.append(contentsOf: comps)
            }
            alts.append(set)
        }
        var r = SemVerRange(alternatives: alts, source: string)
        r.alternatives = alts
        return r
    }

    private init(alternatives: [[Comparator]], source: String) {
        self.alternatives = alternatives
        self.source = source
    }

    private static func comparators(_ token: String) -> [Comparator]? {
        for (prefix, op) in [(">=", Op.ge), ("<=", .le), (">", .gt), ("<", .lt), ("=", .eq)] where token.hasPrefix(prefix) {
            guard let v = SemVer.parse(String(token.dropFirst(prefix.count))) else { return nil }
            return [Comparator(op: op, version: v)]
        }
        if token.hasPrefix("^") {
            guard let v = SemVer.parse(String(token.dropFirst())) else { return nil }
            let upper: SemVer
            if v.major > 0 { upper = SemVer(v.major + 1, 0, 0) }
            else if v.minor > 0 { upper = SemVer(0, v.minor + 1, 0) }
            else { upper = SemVer(0, 0, v.patch + 1) }
            return [Comparator(op: .ge, version: v), Comparator(op: .lt, version: upper)]
        }
        if token.hasPrefix("~") {
            guard let v = SemVer.parse(String(token.dropFirst())) else { return nil }
            return [Comparator(op: .ge, version: v), Comparator(op: .lt, version: SemVer(v.major, v.minor + 1, 0))]
        }
        guard let v = SemVer.parse(token) else { return nil }
        return [Comparator(op: .eq, version: v)]
    }

    public func contains(_ v: SemVer) -> Bool {
        alternatives.contains { set in
            guard set.allSatisfy({ $0.matches(v) }) else { return false }
            if v.isPrerelease {
                return set.contains { $0.version.isPrerelease && $0.version.major == v.major && $0.version.minor == v.minor && $0.version.patch == v.patch }
            }
            return true
        }
    }

    public var hasUpperBound: Bool {
        alternatives.allSatisfy { set in set.contains { $0.op == .lt || $0.op == .le || $0.op == .eq } }
    }

    public var description: String { source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let r = SemVerRange.parse(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "BF1008|invalid semantic version range '\(s)'"))
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(source)
    }
}
