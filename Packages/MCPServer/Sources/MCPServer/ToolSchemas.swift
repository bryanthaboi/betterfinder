import Foundation
import ModKit

enum S {
    static let hashPattern = "^[0-9a-f]{64}$"
    static let opaquePattern = "^[A-Za-z0-9._:-]{1,128}$"
    static let tokenPattern = "^[0-9a-f]{48}$"

    static func string(_ doc: String, pattern: String? = nil, min: Int? = nil, max: Int? = nil, values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(doc)]
        if let pattern { o["pattern"] = .string(pattern) }
        if let min { o["minLength"] = .int(min) }
        if let max { o["maxLength"] = .int(max) }
        if let values { o["enum"] = values.j }
        return .object(o)
    }

    static func integer(_ doc: String, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer", "description": .string(doc)]
        if let min { o["minimum"] = .int(min) }
        if let max { o["maximum"] = .int(max) }
        return .object(o)
    }

    static func boolean(_ doc: String) -> JSONValue { obj(["type": "boolean", "description": doc.j]) }

    static func array(_ items: JSONValue, _ doc: String, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "array", "items": items, "description": .string(doc)]
        if let min { o["minItems"] = .int(min) }
        if let max { o["maxItems"] = .int(max) }
        return .object(o)
    }

    static func object(_ properties: KeyValuePairs<String, JSONValue>, required: [String] = [], closed: Bool = true, doc: String? = nil) -> JSONValue {
        var props = [String: JSONValue]()
        for (k, v) in properties { props[k] = v }
        var o: [String: JSONValue] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = required.j }
        if closed { o["additionalProperties"] = false }
        if let doc { o["description"] = .string(doc) }
        return .object(o)
    }

    static let anyJSON: JSONValue = obj(["description": "any JSON value"])
    static let hash = string("64 lowercase hex characters", pattern: hashPattern)
    static func opaque(_ doc: String) -> JSONValue { string(doc, pattern: opaquePattern) }
    static let workspace = string("workspace id: the mod id, author.name", pattern: ModPatterns.modID, min: 3, max: 96)

    static let diagnostic = object([
        "severity": string("error, warning or info", values: ["error", "warning", "info"]),
        "code": string("diagnostic code such as BF2014"),
        "file": string("file the diagnostic points at"),
        "pointer": string("JSON pointer inside the file"),
        "line": integer("1-based line"),
        "column": integer("1-based column"),
        "message": string("what is wrong"),
        "fix": string("suggested fix"),
    ], required: ["severity", "code", "message"], closed: false)

    static let artifact = object([
        "id": opaque("artifact id"),
        "path": string("absolute path of the artifact on this machine"),
        "sha256": hash,
        "bytes": integer("size in bytes", min: 0),
    ], required: ["id", "path", "sha256", "bytes"])

    static let report = object([
        "ok": boolean("true only when every check including the dry run passed"),
        "staticOK": boolean("true when every static check passed"),
        "treeHash": hash,
        "validator": string("validator version"),
        "api": string("mod API version"),
        "toolchain": string("toolchain identifier"),
        "checks": object([:], closed: false),
        "diagnostics": array(diagnostic, "diagnostics, errors first"),
        "mod": object([:], closed: false),
        "receipt": opaque("receipt id; present when no check reported an error"),
    ], required: ["ok", "treeHash", "validator", "api", "checks", "diagnostics"], closed: false)

    static let confirmFields: KeyValuePairs<String, JSONValue> = [
        "confirm": boolean("false or omitted: dry run that returns a review and a confirmationToken. true: perform the action; requires confirmationToken"),
        "confirmationToken": string("token from the dry run of this exact action; single use, expires", pattern: tokenPattern),
    ]

    static let pendingFields: [String: JSONValue] = [
        "pending": opaque("present on a dry run: the action has not happened"),
        "confirmationToken": string("echo this with confirm:true after the user approved the review"),
        "review": anyJSON,
        "expiresAt": string("when the confirmationToken expires"),
    ]

    static func envelope(data: JSONValue) -> JSONValue {
        object([
            "ok": boolean("whether the call succeeded"),
            "data": data,
            "error": object([
                "code": string("stable error code"),
                "message": string("what went wrong"),
                "diagnostics": array(diagnostic, "validator diagnostics when relevant"),
                "details": anyJSON,
            ], required: ["code", "message"]),
        ], required: ["ok"])
    }

    static func dataObject(_ properties: KeyValuePairs<String, JSONValue>, required: [String] = [], withPending: Bool = false) -> JSONValue {
        var props = [String: JSONValue]()
        for (k, v) in properties { props[k] = v }
        if withPending { for (k, v) in pendingFields { props[k] = v } }
        var o: [String: JSONValue] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = required.j }
        return .object(o)
    }
}
