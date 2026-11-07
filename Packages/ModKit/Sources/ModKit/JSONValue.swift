import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var numberValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public func canonicalData() -> Data {
        var out = [UInt8]()
        write(into: &out)
        return Data(out)
    }

    public func canonicalString() -> String { String(decoding: canonicalData(), as: UTF8.self) }

    func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i): out.append(contentsOf: Array(String(i).utf8))
        case .double(let d):
            var s = "\(d)"
            if d == d.rounded(), abs(d) < 1e15, !s.contains("e"), !s.contains(".") { s += ".0" }
            out.append(contentsOf: Array(s.utf8))
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                v.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSONValue.writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                o[key]!.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: Array("\\\"".utf8))
            case "\\": out.append(contentsOf: Array("\\\\".utf8))
            case "\n": out.append(contentsOf: Array("\\n".utf8))
            case "\r": out.append(contentsOf: Array("\\r".utf8))
            case "\t": out.append(contentsOf: Array("\\t".utf8))
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: Array(String(format: "\\u%04x", scalar.value).utf8))
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o = [String: JSONValue]()
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    public init(nilLiteral: ()) { self = .null }
}

public struct JSONParseError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable { case syntax, duplicateKey, tooDeep, numberRange, invalidUTF8 }
    public var kind: Kind
    public var message: String
    public var line: Int
    public var column: Int
    public var pointer: String
}

public extension JSONValue {
    static let maxDepth = 64

    static func parse(_ data: Data) throws -> JSONValue {
        var p = JSONParser(bytes: [UInt8](data))
        return try p.parseDocument()
    }

    static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }
}

struct JSONParser {
    let bytes: [UInt8]
    var pos = 0
    var path: [String] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
        skipWS()
        let v = try parseValue(depth: 0)
        skipWS()
        if pos < bytes.count { throw fail(.syntax, "unexpected trailing content") }
        return v
    }

    func fail(_ kind: JSONParseError.Kind, _ message: String) -> JSONParseError {
        var line = 1, col = 1
        var i = 0
        while i < min(pos, bytes.count) {
            if bytes[i] == 0x0A { line += 1; col = 1 } else if bytes[i] & 0xC0 != 0x80 { col += 1 }
            i += 1
        }
        let pointer = path.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
            .map { "/" + $0 }.joined()
        return JSONParseError(kind: kind, message: message, line: line, column: col, pointer: pointer)
    }

    mutating func skipWS() {
        while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 { pos += 1 }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        if depth > JSONValue.maxDepth { throw fail(.tooDeep, "nesting deeper than \(JSONValue.maxDepth)") }
        guard pos < bytes.count else { throw fail(.syntax, "unexpected end of input") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else { throw fail(.syntax, "invalid literal") }
        pos += w.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        pos += 1
        var out = [String: JSONValue]()
        skipWS()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(out) }
        while true {
            skipWS()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail(.syntax, "expected object key") }
            let key = try parseString()
            path.append(key)
            if out[key] != nil { throw fail(.duplicateKey, "duplicate key '\(key)'") }
            skipWS()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail(.syntax, "expected ':'") }
            pos += 1
            skipWS()
            out[key] = try parseValue(depth: depth + 1)
            path.removeLast()
            skipWS()
            guard pos < bytes.count else { throw fail(.syntax, "unterminated object") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(out) }
            throw fail(.syntax, "expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        pos += 1
        var out = [JSONValue]()
        skipWS()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(out) }
        while true {
            skipWS()
            path.append(String(out.count))
            out.append(try parseValue(depth: depth + 1))
            path.removeLast()
            skipWS()
            guard pos < bytes.count else { throw fail(.syntax, "unterminated array") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(out) }
            throw fail(.syntax, "expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        pos += 1
        var buf = [UInt8]()
        while true {
            guard pos < bytes.count else { throw fail(.syntax, "unterminated string") }
            let b = bytes[pos]
            if b == UInt8(ascii: "\"") { pos += 1; break }
            if b < 0x20 { throw fail(.syntax, "control character in string") }
            if b == UInt8(ascii: "\\") {
                pos += 1
                guard pos < bytes.count else { throw fail(.syntax, "unterminated escape") }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try parseHex4()
                    if (0xD800...0xDBFF).contains(cp) {
                        guard pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") else {
                            throw fail(.syntax, "lone surrogate")
                        }
                        pos += 2
                        let lo = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(lo) else { throw fail(.syntax, "invalid surrogate pair") }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(cp) {
                        throw fail(.syntax, "lone surrogate")
                    }
                    guard let scalar = Unicode.Scalar(cp) else { throw fail(.syntax, "invalid code point") }
                    buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail(.syntax, "invalid escape")
                }
            } else {
                buf.append(b)
                pos += 1
            }
        }
        guard let s = String(validatingUTF8: buf.map { CChar(bitPattern: $0) } + [0]) else {
            throw fail(.invalidUTF8, "invalid UTF-8 in string")
        }
        if buf.contains(0) { throw fail(.syntax, "NUL in string") }
        return s
    }

    mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw fail(.syntax, "short unicode escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[pos]
            pos += 1
            var d: UInt32
            switch b {
            case 0x30...0x39: d = UInt32(b - 0x30)
            case 0x41...0x46: d = UInt32(b - 0x41 + 10)
            case 0x61...0x66: d = UInt32(b - 0x61 + 10)
            default: throw fail(.syntax, "invalid unicode escape")
            }
            v = v << 4 | d
        }
        return v
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = pos
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        guard pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 else { throw fail(.syntax, "invalid value") }
        if bytes[pos] == 0x30 {
            pos += 1
            if pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { throw fail(.syntax, "leading zero") }
        } else {
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
        }
        var isFloat = false
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            isFloat = true
            pos += 1
            guard pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 else { throw fail(.syntax, "invalid fraction") }
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            isFloat = true
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            guard pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 else { throw fail(.syntax, "invalid exponent") }
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
        }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        if isFloat {
            guard let d = Double(text), d.isFinite else { throw fail(.numberRange, "number out of range") }
            return .double(d)
        }
        guard let i = Int(text) else { throw fail(.numberRange, "integer out of range") }
        return .int(i)
    }
}

public enum JSONPointer {
    public static func escape(_ segment: String) -> String {
        segment.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    public static func make(_ segments: [String]) -> String {
        segments.map { "/" + escape($0) }.joined()
    }

    public static func appending(_ base: String, _ segment: String) -> String { base + "/" + escape(segment) }
    public static func appending(_ base: String, _ index: Int) -> String { base + "/" + String(index) }
}
