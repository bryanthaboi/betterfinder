import Foundation
import FSCore

struct ItemFilter: Equatable, Sendable {
    enum Rule: Equatable, Sendable {
        case kind(String)
        case pattern(String)
    }

    let rule: Rule
    private let needle: [Character]

    init(kind: String) {
        rule = .kind(kind)
        needle = []
    }

    init(pattern: String) {
        rule = .pattern(pattern)
        needle = Array(pattern.lowercased())
    }

    var title: String {
        switch rule {
        case .kind(let kind): return kind
        case .pattern(let pattern): return pattern
        }
    }

    func matches(_ item: FileItem) -> Bool {
        switch rule {
        case .kind(let kind): return item.kindDescription == kind
        case .pattern: return Self.glob(needle, Array(item.name.lowercased()))
        }
    }

    func apply(_ items: [FileItem]) -> [FileItem] { items.filter(matches) }

    static func isPatternStart(_ text: String) -> Bool { text.hasPrefix("*") || text.hasPrefix("?") }

    static func glob(_ pattern: String, matches name: String) -> Bool {
        glob(Array(pattern.lowercased()), Array(name.lowercased()))
    }

    static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0
        var t = 0
        var star = -1
        var mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                mark = t
                p += 1
            } else if star >= 0 {
                p = star + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
