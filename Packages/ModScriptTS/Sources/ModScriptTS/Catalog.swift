import Foundation

public enum TSReservedNames {
    public static let words: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
        "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this",
        "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "implements", "interface", "package",
        "private", "protected", "public", "await",
    ]

    public static func scriptName(_ member: String) -> String {
        if member == "delete" { return "remove" }
        return words.contains(member) ? member + "_" : member
    }

    public static func scriptPath(_ catalogName: String) -> String {
        var parts = catalogName.split(separator: ".").map(String.init)
        if let last = parts.popLast() { parts.append(scriptName(last)) }
        return parts.joined(separator: ".")
    }

    static func parameterName(_ declared: String) -> String {
        let optional = declared.hasSuffix("?")
        let base = optional ? String(declared.dropLast()) : declared
        return (words.contains(base) ? base + "_" : base) + (optional ? "?" : "")
    }

    static func namespacePath(_ namespace: String) -> String {
        namespace.split(separator: ".").map { words.contains(String($0)) ? $0 + "_" : String($0) }.joined(separator: ".")
    }
}

public struct Catalog: Codable, Equatable {
    public struct Parameter: Codable, Equatable {
        public var name: String
        public var type: String
        public init(_ name: String, _ type: String) { self.name = name; self.type = type }
    }
    public struct Function: Codable, Equatable {
        public var name: String
        public var parameters: [Parameter]
        public var result: String
        public init(_ name: String, parameters: [Parameter], result: String) {
            self.name = name; self.parameters = parameters; self.result = result
        }
    }
    public struct Namespace: Codable, Equatable {
        public var name: String
        public var functions: [Function]
        public init(_ name: String, functions: [Function]) { self.name = name; self.functions = functions }
    }
    public struct Hook: Codable, Equatable {
        public var name: String
        public var handlerType: String
        public var parameters: [Parameter]
        public var result: String
        public init(_ name: String, handlerType: String, parameters: [Parameter], result: String) {
            self.name = name; self.handlerType = handlerType; self.parameters = parameters; self.result = result
        }
    }
    public var namespaces: [Namespace]
    public var hooks: [Hook]
    public var types: [String]
    public init(namespaces: [Namespace], hooks: [Hook], types: [String] = []) {
        self.namespaces = namespaces; self.hooks = hooks; self.types = types
    }

    enum CodingKeys: String, CodingKey { case namespaces, hooks, types }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namespaces = try c.decode([Namespace].self, forKey: .namespaces)
        hooks = try c.decode([Hook].self, forKey: .hooks)
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(namespaces, forKey: .namespaces)
        try c.encode(hooks, forKey: .hooks)
        if !types.isEmpty { try c.encode(types, forKey: .types) }
    }

    var callNames: [String: String] {
        var out = [String: String]()
        for namespace in namespaces {
            let path = TSReservedNames.namespacePath(namespace.name)
            for function in namespace.functions {
                out[path + "." + TSReservedNames.scriptName(function.name)] = namespace.name + "." + function.name
            }
        }
        return out
    }
}

public enum DeclarationGenerator {
    public static func generate(_ catalog: Catalog) -> String {
        func parameters(_ values: [Catalog.Parameter]) -> String {
            values.map { "\(TSReservedNames.parameterName($0.name)): \($0.type)" }.joined(separator: ", ")
        }
        var lines = ["declare module \"betterfinder\" {", "  export interface ModContext { readonly modID: string; readonly generation: number; }"]
        for block in catalog.types where !block.isEmpty { lines.append(block) }
        for namespace in catalog.namespaces.sorted(by: { $0.name < $1.name }) {
            lines.append("  export namespace \(TSReservedNames.namespacePath(namespace.name)) {")
            for function in namespace.functions.sorted(by: { $0.name < $1.name }) {
                lines.append("    function \(TSReservedNames.scriptName(function.name))(\(parameters(function.parameters))): \(function.result);")
            }
            lines.append("  }")
        }
        for hook in catalog.hooks.sorted(by: { $0.name < $1.name }) {
            lines.append("  export type \(hook.handlerType) = (\(parameters(hook.parameters))) => \(hook.result);")
        }
        return (lines + ["}", ""]).joined(separator: "\n")
    }
}
