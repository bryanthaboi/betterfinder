import CryptoKit
import Foundation
import ModKit

extension JSONValue {
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let json = try? JSONValue.parse(data) else { return .null }
        return json
    }

    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: canonicalData())
    }

    var compactString: String { canonicalString() }

    func prettyString() -> String {
        guard let object = try? JSONSerialization.jsonObject(with: canonicalData(), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return canonicalString() }
        return String(decoding: data, as: UTF8.self)
    }
}

extension String { var j: JSONValue { .string(self) } }
extension Int { var j: JSONValue { .int(self) } }
extension Bool { var j: JSONValue { .bool(self) } }
extension Array where Element == String { var j: JSONValue { .array(map { .string($0) }) } }
extension Array where Element == JSONValue { var j: JSONValue { .array(self) } }

func obj(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
    var out = [String: JSONValue]()
    for (k, v) in pairs { out[k] = v }
    return .object(out)
}

enum Hex {
    static func random(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        if status != errSecSuccess {
            for i in buffer.indices { buffer[i] = UInt8.random(in: 0...255) }
        }
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String { CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

struct ISO8601 {
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
