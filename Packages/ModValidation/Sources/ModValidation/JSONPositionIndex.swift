import Foundation
import ModKit

struct JSONPositionIndex {
    private(set) var positions: [String: (line: Int, column: Int)] = [:]

    init(_ data: Data) {
        let s = Array(String(decoding: data, as: UTF8.self).utf16)
        var i = 0
        var line = 1
        var lineStart = 0
        var table = [String: (line: Int, column: Int)]()

        func skipSpace() {
            while i < s.count {
                let c = s[i]
                if c == 10 { line += 1; lineStart = i + 1; i += 1 }
                else if c == 32 || c == 9 || c == 13 { i += 1 }
                else { break }
            }
        }
        func position() -> (line: Int, column: Int) { (line, i - lineStart + 1) }
        func parseString() -> String? {
            guard i < s.count, s[i] == 34 else { return nil }
            let a = i + 1
            i += 1
            var hasEscape = false
            while i < s.count, s[i] != 34 {
                if s[i] == 92 { hasEscape = true; i += 1 }
                if i < s.count, s[i] == 10 { return nil }
                i += 1
            }
            guard i < s.count else { return nil }
            let raw = String(decoding: s[a..<i], as: UTF16.self)
            i += 1
            if hasEscape, let d = try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8), options: [.fragmentsAllowed]) as? String { return d }
            return raw
        }
        func parseValue(_ pointer: String, depth: Int) -> Bool {
            skipSpace()
            guard i < s.count, depth < 64 else { return false }
            let c = s[i]
            if c == 123 {
                i += 1
                skipSpace()
                if i < s.count, s[i] == 125 { i += 1; return true }
                while true {
                    skipSpace()
                    let keyPos = position()
                    guard let key = parseString() else { return false }
                    let child = JSONPointer.appending(pointer, key)
                    table[child] = keyPos
                    skipSpace()
                    guard i < s.count, s[i] == 58 else { return false }
                    i += 1
                    guard parseValue(child, depth: depth + 1) else { return false }
                    skipSpace()
                    guard i < s.count else { return false }
                    if s[i] == 44 { i += 1; continue }
                    if s[i] == 125 { i += 1; return true }
                    return false
                }
            }
            if c == 91 {
                i += 1
                skipSpace()
                if i < s.count, s[i] == 93 { i += 1; return true }
                var index = 0
                while true {
                    skipSpace()
                    let child = JSONPointer.appending(pointer, index)
                    table[child] = position()
                    guard parseValue(child, depth: depth + 1) else { return false }
                    skipSpace()
                    guard i < s.count else { return false }
                    if s[i] == 44 { i += 1; index += 1; continue }
                    if s[i] == 93 { i += 1; return true }
                    return false
                }
            }
            if c == 34 { return parseString() != nil }
            let a = i
            while i < s.count, ![44, 125, 93, 32, 9, 10, 13].contains(s[i]) { i += 1 }
            return i > a
        }

        skipSpace()
        table[""] = position()
        _ = parseValue("", depth: 0)
        positions = table
    }

    func locate(_ pointer: String) -> (line: Int, column: Int)? {
        var p = pointer
        while true {
            if let hit = positions[p] { return hit }
            guard let slash = p.lastIndex(of: "/") else { return positions[""] }
            p = String(p[..<slash])
        }
    }
}
