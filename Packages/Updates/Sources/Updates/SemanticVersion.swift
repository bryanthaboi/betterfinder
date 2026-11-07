import Foundation

public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: [String]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "v" || first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let tail = text[text.index(after: dash)...]
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if pre.contains(where: \.isEmpty) { return nil }
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 6 else { return nil }
        var nums: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            nums.append(n)
        }
        numbers = nums
        prerelease = pre
    }

    public var description: String {
        let base = numbers.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    static func compare(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> Int {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<count {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        let n = max(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<n {
            guard i < lhs.prerelease.count else { return -1 }
            guard i < rhs.prerelease.count else { return 1 }
            let a = lhs.prerelease[i], b = rhs.prerelease[i]
            if a == b { continue }
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y ? -1 : 1
            case (_?, nil): return -1
            case (nil, _?): return 1
            case (nil, nil): return a < b ? -1 : 1
            }
        }
        return 0
    }
}
