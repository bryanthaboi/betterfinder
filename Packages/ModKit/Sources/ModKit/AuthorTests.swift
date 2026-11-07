import Foundation

public struct ModAuthorTestExpectation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case equals(JSONValue)
        case contains(JSONValue)
        case matches(String)
        case error(String?)
    }

    public var kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public static func equals(_ v: JSONValue) -> ModAuthorTestExpectation { .init(.equals(v)) }
    public static func contains(_ v: JSONValue) -> ModAuthorTestExpectation { .init(.contains(v)) }
    public static func matches(_ pattern: String) -> ModAuthorTestExpectation { .init(.matches(pattern)) }
    public static func error(_ needle: String? = nil) -> ModAuthorTestExpectation { .init(.error(needle)) }

    public var keyword: String {
        switch kind {
        case .equals: return "equals"
        case .contains: return "contains"
        case .matches: return "matches"
        case .error: return "error"
        }
    }

    public var jsonValue: JSONValue {
        switch kind {
        case .equals(let v): return .object(["equals": v])
        case .contains(let v): return .object(["contains": v])
        case .matches(let p): return .object(["matches": .string(p)])
        case .error(let n): return .object(["error": n.map(JSONValue.string) ?? .bool(true)])
        }
    }
}

public struct ModAuthorTest: Codable, Equatable, Sendable {
    public var name: String?
    public var hook: String
    public var version: Int
    public var handler: String?
    public var input: JSONValue
    public var expect: ModAuthorTestExpectation

    public init(name: String? = nil, hook: String, version: Int = 1, handler: String? = nil, input: JSONValue, expect: ModAuthorTestExpectation) {
        self.name = name; self.hook = hook; self.version = version; self.handler = handler
        self.input = input; self.expect = expect
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case name, hook, version, handler, input, expect }
    enum ExpectKeys: String, CodingKey, CaseIterable { case equals, contains, matches, error }

    public init(from decoder: Decoder) throws {
        let r = try StrictReader(decoder, CodingKeys.self)
        name = try r.opt(.name)
        if let n = name, n.isEmpty || n.count > 120 { throw r.fail(.name, .invalidValue, "name must be 1-120 characters") }
        hook = try r.string(.hook, pattern: "^[a-z][a-zA-Z0-9.-]{0,63}$", what: "hook")
        version = try r.opt(.version) ?? 1
        if !(1...99).contains(version) { throw r.fail(.version, .invalidValue, "version out of range") }
        handler = try r.optString(.handler, pattern: ModPatterns.handler, what: "handler")
        guard r.has(.input) else { throw r.fail(.input, .missingKey, "missing required key 'input'") }
        input = try r.req(.input)
        let e = try r.c.nestedContainer(keyedBy: AnyKey.self, forKey: .expect)
        let epath = r.path + [AnyKey("expect")]
        let keys = e.allKeys.map(\.stringValue).sorted()
        if let bad = keys.first(where: { ExpectKeys(rawValue: $0) == nil }) {
            throw ModDecodeFailure.corrupted(epath + [AnyKey(bad)], .unknownKey, "unknown key '\(bad)'")
        }
        guard keys.count == 1, let key = ExpectKeys(rawValue: keys[0]) else {
            throw ModDecodeFailure.corrupted(epath, .invalidValue, "expect needs exactly one of equals, contains, matches, error")
        }
        switch key {
        case .equals: expect = .equals(try e.decode(JSONValue.self, forKey: AnyKey("equals")))
        case .contains: expect = .contains(try e.decode(JSONValue.self, forKey: AnyKey("contains")))
        case .matches:
            let p = try e.decode(String.self, forKey: AnyKey("matches"))
            if p.isEmpty || p.count > 512 { throw ModDecodeFailure.corrupted(epath + [AnyKey("matches")], .invalidValue, "matches pattern must be 1-512 characters") }
            expect = .matches(p)
        case .error:
            let v = try e.decode(JSONValue.self, forKey: AnyKey("error"))
            switch v {
            case .bool(true): expect = .error(nil)
            case .string(let s) where !s.isEmpty && s.count <= 256: expect = .error(s)
            default: throw ModDecodeFailure.corrupted(epath + [AnyKey("error")], .invalidValue, "error must be true or a non-empty string up to 256 characters")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var o = [String: JSONValue]()
        if let name { o["name"] = .string(name) }
        o["hook"] = .string(hook)
        if version != 1 { o["version"] = .int(version) }
        if let handler { o["handler"] = .string(handler) }
        o["input"] = input
        o["expect"] = expect.jsonValue
        try JSONValue.object(o).encode(to: encoder)
    }

    public static func decode(_ data: Data, file: String = "test.bftest.json") -> Result<ModAuthorTest, ModDiagnostic> {
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch let e as JSONParseError {
            return .failure(ModDiagnostic(.invalidJSON, file: file, pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message))
        } catch { return .failure(ModDiagnostic(.invalidJSON, file: file, message: "\(error)")) }
        return ModDecoding.decode(ModAuthorTest.self, from: value, file: file)
    }

    public var title: String { name ?? hook }
}

public struct ModAuthorTestCase: Equatable, Sendable {
    public var path: String
    public var test: ModAuthorTest
    public var handler: String

    public var displayName: String { test.name.map { "\(path): \($0)" } ?? path }
}

public enum ModAuthorTestOutcome: Equatable, Sendable {
    case value(JSONValue)
    case failure(code: String, message: String)
}

public enum ModAuthorTestVerdict: Equatable, Sendable {
    case pass
    case fail(String)

    public var passed: Bool { if case .pass = self { return true }; return false }
}

public enum ModAuthorTests {
    public static let directory = "tests/"
    public static let suffix = ".bftest.json"
    public static let maxFiles = 64
    public static let maxFileBytes = 65_536

    public static func isTestPath(_ path: String) -> Bool {
        path.hasPrefix(directory) && path.hasSuffix(suffix) && !path.dropFirst(directory.count).contains("/") && path.count > directory.count + suffix.count
    }

    public static func testPaths(in package: ModPackage) -> [String] {
        package.files.keys.filter(isTestPath).sorted()
    }

    public static func load(package: ModPackage, manifest: ModManifest, catalog: ModCatalog = .v1) -> (cases: [ModAuthorTestCase], diagnostics: [ModDiagnostic]) {
        var cases = [ModAuthorTestCase]()
        var diags = [ModDiagnostic]()
        let paths = testPaths(in: package)
        if paths.count > maxFiles {
            diags.append(ModDiagnostic(.sizeBound, file: directory, message: "\(paths.count) author tests; limit is \(maxFiles)"))
        }
        var names = [String: String]()
        for path in paths.prefix(maxFiles) {
            let data = package.data(path) ?? Data()
            if data.count > maxFileBytes {
                diags.append(ModDiagnostic(.sizeBound, file: path, message: "test is \(data.count) bytes; limit is \(maxFileBytes)"))
                continue
            }
            let value: JSONValue
            do { value = try JSONValue.parse(data) } catch let e as JSONParseError {
                diags.append(ModDiagnostic(.invalidJSON, file: path, pointer: e.pointer.isEmpty ? nil : e.pointer, line: e.line, column: e.column, message: e.message))
                continue
            } catch {
                diags.append(ModDiagnostic(.invalidJSON, file: path, message: "\(error)"))
                continue
            }
            let schema = JSONSchema.diagnostics(JSONSchema.authorTest.validate(value), file: path, manifest: false).map { d -> ModDiagnostic in
                var d = d
                if d.pointer == "/expect" && d.code == .sizeBound { d.code = .invalidValue; d.message = "expect needs exactly one of equals, contains, matches, error" }
                if d.pointer == "/expect/error" && d.code == .schemaViolation { d.code = .invalidValue; d.message = "error must be true or a non-empty string up to 256 characters" }
                return d
            }
            if !schema.isEmpty { diags += schema; continue }
            let test: ModAuthorTest
            switch ModDecoding.decode(ModAuthorTest.self, from: value, file: path) {
            case .success(let t): test = t
            case .failure(let e): diags.append(e); continue
            }
            if let n = test.name {
                if let other = names[n] { diags.append(ModDiagnostic(.duplicateID, file: path, pointer: "/name", message: "test name '\(n)' is already used by \(other)")) }
                else { names[n] = path }
            }
            let before = diags.count
            let handler = semantic(test, path: path, manifest: manifest, catalog: catalog, into: &diags)
            if diags.count == before, let handler { cases.append(ModAuthorTestCase(path: path, test: test, handler: handler)) }
        }
        return (cases, diags)
    }

    public static func validate(package: ModPackage, manifest: ModManifest, catalog: ModCatalog = .v1) -> [ModDiagnostic] {
        let paths = testPaths(in: package)
        guard !paths.isEmpty else { return [] }
        if manifest.runtime == .data {
            return paths.map { ModDiagnostic(.handlerInDataMod, file: $0, message: "data/1 mods have no handlers, so author tests cannot run", fix: "Remove the test or use a scripted runtime") }
        }
        return load(package: package, manifest: manifest, catalog: catalog).diagnostics
    }

    static func semantic(_ t: ModAuthorTest, path: String, manifest: ModManifest, catalog: ModCatalog, into d: inout [ModDiagnostic]) -> String? {
        func err(_ code: ModDiagnosticCode, _ ptr: String, _ msg: String, fix: String? = nil) {
            d.append(ModDiagnostic(code, file: path, pointer: ptr, message: msg, fix: fix))
        }
        guard !catalog.hooks(named: t.hook).isEmpty else {
            err(.unknownHook, "/hook", "unknown hook '\(t.hook)'", fix: "Known: " + catalog.hookNames.joined(separator: ", "))
            return nil
        }
        guard let sig = catalog.hook(named: t.hook, version: t.version) else {
            err(.unsupportedHookVersion, "/version", "hook '\(t.hook)' has no version \(t.version); latest is \(catalog.latestHookVersions[t.hook] ?? 0)")
            return nil
        }
        let declared = manifest.hooks.filter { $0.name == t.hook && $0.version == t.version }
        var handler: String?
        if declared.isEmpty {
            err(.unknownReference, "/hook", "manifest binds no handler to hook '\(t.hook)'", fix: "Add the hook to manifest.hooks or remove the test")
        } else if let h = t.handler {
            if declared.contains(where: { $0.handler == h }) { handler = h }
            else { err(.unknownReference, "/handler", "handler '\(h)' is not bound to hook '\(t.hook)'", fix: "Bound: " + declared.map(\.handler).joined(separator: ", ")) }
        } else if declared.count == 1 {
            handler = declared[0].handler
        } else {
            err(.invalidValue, "/handler", "hook '\(t.hook)' has \(declared.count) handlers; name one with \"handler\"", fix: "Add \"handler\": \"" + declared[0].handler + "\"")
        }

        if let m = ModTypeConformance.check(t.input, sig.input, catalog: catalog) {
            err(.typeMismatch, "/input" + m.pointer, "input does not match \(sig.input) of hook \(sig.signatureID): \(m.message)")
        }
        switch t.expect.kind {
        case .equals(let v):
            if let m = ModTypeConformance.check(v, sig.output, catalog: catalog) {
                err(.typeMismatch, "/expect/equals" + m.pointer, "expected value does not match output \(sig.output) of \(sig.signatureID): \(m.message)")
            }
        case .contains(let v):
            if let m = ModTypeConformance.check(v, sig.output, catalog: catalog, partial: true) {
                err(.typeMismatch, "/expect/contains" + m.pointer, "expected fragment does not match output \(sig.output) of \(sig.signatureID): \(m.message)")
            }
        case .matches(let p):
            if !ModTypeConformance.isStringLike(sig.output, catalog: catalog) {
                err(.typeMismatch, "/expect/matches", "output \(sig.output) of \(sig.signatureID) is not a string, so 'matches' cannot apply")
            }
            if (try? NSRegularExpression(pattern: p)) == nil {
                err(.invalidValue, "/expect/matches", "'\(p)' is not a valid regular expression")
            }
        case .error:
            break
        }
        return handler
    }
}

public enum ModAuthorTestEvaluator {
    public static func evaluate(_ expectation: ModAuthorTestExpectation, outcome: ModAuthorTestOutcome) -> ModAuthorTestVerdict {
        switch (expectation.kind, outcome) {
        case (.error(let needle), .failure(let code, let message)):
            guard let needle else { return .pass }
            return code == needle || message.contains(needle) ? .pass : .fail("expected an error matching '\(needle)', got \(code): \(message)")
        case (.error, .value(let v)):
            return .fail("expected an error, got value \(v.canonicalString())")
        case (_, .failure(let code, let message)):
            return .fail("handler failed with \(code): \(message)")
        case (.equals(let expected), .value(let actual)):
            return equal(expected, actual) ? .pass : .fail("expected \(expected.canonicalString()), got \(actual.canonicalString())")
        case (.contains(let expected), .value(let actual)):
            return contains(actual, expected) ? .pass : .fail("\(actual.canonicalString()) does not contain \(expected.canonicalString())")
        case (.matches(let pattern), .value(let actual)):
            guard case .string(let s) = actual else { return .fail("expected a string to match '\(pattern)', got \(actual.typeName)") }
            guard let re = try? NSRegularExpression(pattern: pattern) else { return .fail("'\(pattern)' is not a valid regular expression") }
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil ? .pass : .fail("'\(s)' does not match '\(pattern)'")
        }
    }

    public static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int, .double), (.double, .int), (.int, .int), (.double, .double): return a.numberValue == b.numberValue
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)): return x.count == y.count && x.allSatisfy { k, v in y[k].map { equal(v, $0) } ?? false }
        default: return a == b
        }
    }

    public static func contains(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
        switch (actual, expected) {
        case (.object(let a), .object(let e)): return e.allSatisfy { k, v in a[k].map { contains($0, v) } ?? false }
        case (.array(let a), .array(let e)): return e.allSatisfy { item in a.contains { contains($0, item) } }
        case (.string(let a), .string(let e)): return a.contains(e)
        default: return equal(actual, expected)
        }
    }
}
