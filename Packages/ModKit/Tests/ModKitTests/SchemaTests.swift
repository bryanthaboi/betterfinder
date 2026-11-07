import XCTest
@testable import ModKit

final class SchemaTests: XCTestCase {
    func testSchemaResourcesAreValidJSONSchemaShapedDocuments() {
        for name in JSONSchema.Name.allCases {
            let s = JSONSchema.load(name)
            XCTAssertEqual(s.root["$schema"], "https://json-schema.org/draft/2020-12/schema")
            XCTAssertNotNil(s.root["$id"]?.stringValue)
            XCTAssertNotNil(s.root["$defs"]?.objectValue)
        }
    }

    func testEveryExampleManifestValidatesAgainstSchemaAndDecoder() {
        for ex in ModExamples.all {
            let data = ex.package.data("manifest.json")!
            let value = try! JSONValue.parse(data)
            XCTAssertEqual(JSONSchema.manifest.validate(value), [], ex.id)
            guard case .success = ModManifest.decode(data) else { return XCTFail("\(ex.id) decoder rejected") }
        }
    }

    func testEveryExampleScriptValidatesAgainstSchemaAndParser() {
        for ex in ModExamples.all {
            guard let data = ex.package.data("scripts/main.bfscript.json") else { continue }
            let value = try! JSONValue.parse(data)
            XCTAssertEqual(JSONSchema.bfscript.validate(value), [], ex.id)
            XCTAssertNotNil(BFScriptParser.parse(data: data, file: "x").program, ex.id)
        }
    }

    func testIndexListingExampleValidatesAndDecodes() throws {
        let data = try XCTUnwrap(ModExamples.indexListingExample)
        XCTAssertEqual(JSONSchema.indexListing.validate(try JSONValue.parse(data)), [])
        guard case .success(let listing) = ModIndexListing.decode(data) else { return XCTFail() }
        guard case .success(let manifest) = ModManifest.decode(ModExamples.example("image-dimensions")!.package.data("manifest.json")!) else { return XCTFail() }
        XCTAssertEqual(listing.consistency(with: manifest), [])
        XCTAssertEqual(String(decoding: listing.signedPayload, as: UTF8.self),
                       "{\"api\":\">=1.0.0 <2.0.0\",\"app\":\">=1.0.0 <2.0.0\",\"id\":\"alice.image-dimensions\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"version\":\"1.0.0\"}")
        var drifted = manifest
        drifted.version = SemVer(1, 0, 1)
        drifted.permissions.removeLast()
        let d = listing.consistency(with: drifted)
        assertDiag(d, .indexMismatch, pointer: "/version")
        assertDiag(d, .indexMismatch, pointer: "/permissions")
    }

    func testIndexListingNegativesAgree() throws {
        let base = try JSONValue.parse(try XCTUnwrap(ModExamples.indexListingExample))
        func both(_ edit: (inout [String: JSONValue]) -> Void, pointer: String, file: StaticString = #filePath, line: UInt = #line) {
            let v = Fixture.mutate(base, edit)
            XCTAssertTrue(JSONSchema.indexListing.validate(v).contains { $0.pointer == pointer }, "schema \(pointer)", file: file, line: line)
            guard case .failure(let d) = ModIndexListing.decode(v.canonicalData()) else { return XCTFail("decoder accepted \(pointer)", file: file, line: line) }
            XCTAssertEqual(d.pointer, pointer, file: file, line: line)
        }
        both({ $0["extra"] = 1 }, pointer: "/extra")
        both({ $0["categories"] = ["MISC"] }, pointer: "/categories/0")
        both({ $0["repo"] = "http://github.com/a/b" }, pointer: "/repo")
        both({ $0["release"] = Fixture.mutate($0["release"]!) { $0["commit"] = "abc" } }, pointer: "/release/commit")
        both({ $0["release"] = Fixture.mutate($0["release"]!) { $0["signature"] = "short" } }, pointer: "/release/signature")
        both({ $0["release"] = Fixture.mutate($0["release"]!) { $0["assetURL"] = "http://x/y" } }, pointer: "/release/assetURL")
        both({ $0["schemaVersion"] = 2 }, pointer: "/schemaVersion")
        both({ $0["thumbnail"] = "logo.jpg" }, pointer: "/thumbnail")
    }

    struct Case {
        var name: String
        var edit: (inout [String: JSONValue]) -> Void
        var pointer: String
    }

    func nested(_ key: String, _ edit: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
        { o in o[key] = Fixture.mutate(o[key]!, edit) }
    }

    func testSchemaAndDecoderRejectTheSameMutations() {
        let sha = String(repeating: "a", count: 64)
        let cases: [Case] = [
            Case(name: "unknown root key", edit: { $0["bogus"] = 1 }, pointer: "/bogus"),
            Case(name: "missing license", edit: { $0["license"] = nil }, pointer: "/license"),
            Case(name: "missing hooks", edit: { $0["hooks"] = nil }, pointer: "/hooks"),
            Case(name: "bad id", edit: { $0["id"] = "A" }, pointer: "/id"),
            Case(name: "bad version", edit: { $0["version"] = "1.0" }, pointer: "/version"),
            Case(name: "bad api", edit: { $0["api"] = "latest" }, pointer: "/api"),
            Case(name: "bad app", edit: { $0["app"] = ">=1.0" }, pointer: "/app"),
            Case(name: "manifestVersion 2", edit: { $0["manifestVersion"] = 2 }, pointer: "/manifestVersion"),
            Case(name: "bad runtime", edit: { $0["runtime"] = "wasm/1" }, pointer: "/runtime"),
            Case(name: "name not string", edit: { $0["name"] = 1 }, pointer: "/name"),
            Case(name: "bad author", edit: { $0["author"] = "-x" }, pointer: "/author"),
            Case(name: "permission unknown kind", edit: { $0["permissions"] = [["kind": "nope"]] }, pointer: "/permissions/0/kind"),
            Case(name: "permission missing reason", edit: { $0["permissions"] = [["kind": "fs.read", "scope": "selection"]] }, pointer: "/permissions/0/reason"),
            Case(name: "permission extra key", edit: { $0["permissions"] = [["kind": "ui", "surfaces": ["column"], "x": 1]] }, pointer: "/permissions/0/x"),
            Case(name: "ui surface unknown", edit: { $0["permissions"] = [["kind": "ui", "surfaces": ["desktop"]]] }, pointer: "/permissions/0/surfaces/0"),
            Case(name: "fs.read destination", edit: { $0["permissions"] = [["kind": "fs.read", "scope": "destination", "reason": "r"]] }, pointer: "/permissions/0/scope"),
            Case(name: "root without rootId", edit: { $0["permissions"] = [["kind": "fs.write", "scope": "root", "reason": "r"]] }, pointer: "/permissions/0/rootId"),
            Case(name: "rootId without root", edit: { $0["permissions"] = [["kind": "fs.write", "scope": "selection", "rootId": "x", "reason": "r"]] }, pointer: "/permissions/0/rootId"),
            Case(name: "broker without operations", edit: { $0["permissions"] = [["kind": "process.exec", "mode": "broker", "reason": "r"]] }, pointer: "/permissions/0/operations"),
            Case(name: "unrestricted with operations", edit: { $0["permissions"] = [["kind": "process.exec", "mode": "unrestricted", "operations": ["git.status"], "reason": "r"]] }, pointer: "/permissions/0/operations"),
            Case(name: "net bad method", edit: { $0["permissions"] = [["kind": "net", "reason": "r", "endpoints": [["scheme": "https", "host": "a.example.com", "methods": ["TRACE"]]]]] }, pointer: "/permissions/0/endpoints/0/methods/0"),
            Case(name: "net bad port", edit: { $0["permissions"] = [["kind": "net", "reason": "r", "endpoints": [["scheme": "https", "host": "a.example.com", "port": 0, "methods": ["GET"]]]]] }, pointer: "/permissions/0/endpoints/0/port"),
            Case(name: "contribution extra key", edit: { $0["contributes"] = ["columns": [["id": "d", "title": "D", "valueType": "string", "handler": "h", "zzz": 1]]] }, pointer: "/contributes/columns/0/zzz"),
            Case(name: "contribution bad id", edit: { $0["contributes"] = ["columns": [["id": "Dim", "title": "D", "valueType": "string", "handler": "h"]]] }, pointer: "/contributes/columns/0/id"),
            Case(name: "column bad valueType", edit: { $0["contributes"] = ["columns": [["id": "d", "title": "D", "valueType": "blob", "handler": "h"]]] }, pointer: "/contributes/columns/0/valueType"),
            Case(name: "column width", edit: { $0["contributes"] = ["columns": [["id": "d", "title": "D", "valueType": "string", "handler": "h", "width": 5]]] }, pointer: "/contributes/columns/0/width"),
            Case(name: "unknown contribution kind", edit: { $0["contributes"] = ["widgets": []] }, pointer: "/contributes/widgets"),
            Case(name: "theme escape", edit: { $0["contributes"] = ["themes": [["id": "t", "title": "T", "path": "../t.json", "appearance": "any"]]] }, pointer: "/contributes/themes/0/path"),
            Case(name: "sidebar item no target", edit: { $0["contributes"] = ["sidebarSections": [["id": "s", "title": "S", "items": [["id": "x", "title": "X"]]]]] }, pointer: "/contributes/sidebarSections/0/items/0"),
            Case(name: "keybinding chord", edit: { $0["contributes"] = ["keybindings": [["id": "k", "key": "Cmd+Z", "command": "builtin.x"]]] }, pointer: "/contributes/keybindings/0/key"),
            Case(name: "hook version type", edit: { $0["hooks"] = [["name": "activate", "handler": "h", "version": "1"]] }, pointer: "/hooks/0/version"),
            Case(name: "hook extra", edit: { $0["hooks"] = [["name": "activate", "handler": "h", "version": 1, "x": 1]] }, pointer: "/hooks/0/x"),
            Case(name: "setting default type", edit: { $0["settings"] = [["key": "k", "type": "integer", "label": "L", "default": "x"]] }, pointer: "/settings/0/default"),
            Case(name: "setting enum no options", edit: { $0["settings"] = [["key": "k", "type": "enum", "label": "L", "default": "a"]] }, pointer: "/settings/0/options"),
            Case(name: "setting bool with minimum", edit: { $0["settings"] = [["key": "k", "type": "boolean", "label": "L", "default": true, "minimum": 0]] }, pointer: "/settings/0/minimum"),
            Case(name: "setting bad key", edit: { $0["settings"] = [["key": "K", "type": "boolean", "label": "L", "default": true]] }, pointer: "/settings/0/key"),
            Case(name: "dependency sha", edit: { $0["dependencies"] = [["id": "bob.lib", "version": "1.0.0", "sha256": "zz"]] }, pointer: "/dependencies/0/sha256"),
            Case(name: "dependency missing version", edit: { $0["dependencies"] = [["id": "bob.lib", "sha256": .string(sha)]] }, pointer: "/dependencies/0/version"),
            Case(name: "conflict bad id", edit: { $0["conflicts"] = ["X"] }, pointer: "/conflicts/0"),
        ]
        for c in cases {
            let value = Fixture.mutate(Fixture.manifestJSON(), c.edit)
            let violations = JSONSchema.manifest.validate(value)
            XCTAssertTrue(violations.contains { $0.pointer == c.pointer }, "schema should flag \(c.name) at \(c.pointer); got \(violations.map(\.pointer))")
            switch ModDecoding.decode(ModManifest.self, from: value) {
            case .success: XCTFail("decoder accepted \(c.name)")
            case .failure(let d): XCTAssertEqual(d.pointer, c.pointer, "decoder pointer for \(c.name)")
            }
        }
    }

    func testRuntimeEntryRulesInSchema() {
        let noEntry = Fixture.mutate(Fixture.manifestJSON()) { $0["entry"] = nil }
        XCTAssertFalse(JSONSchema.manifest.validate(noEntry).isEmpty)
        let dataWithEntry = Fixture.mutate(Fixture.manifestJSON()) { $0["runtime"] = "data/1" }
        XCTAssertFalse(JSONSchema.manifest.validate(dataWithEntry).isEmpty)
        let ts = Fixture.mutate(Fixture.manifestJSON()) { $0["runtime"] = "ts/1"; $0["entry"] = "src/main.ts" }
        XCTAssertEqual(JSONSchema.manifest.validate(ts), [])
        let tsWrong = Fixture.mutate(Fixture.manifestJSON()) { $0["runtime"] = "ts/1"; $0["entry"] = "src/main.js" }
        XCTAssertFalse(JSONSchema.manifest.validate(tsWrong).isEmpty)
        let js = Fixture.mutate(Fixture.manifestJSON()) { $0["runtime"] = "js/1"; $0["entry"] = "main.mjs" }
        XCTAssertEqual(JSONSchema.manifest.validate(js), [])
    }

    func testSchemaValidatorKeywords() {
        func v(_ schema: String, _ instance: String) -> [SchemaViolation] {
            JSONSchema(try! JSONValue.parse(schema)).validate(try! JSONValue.parse(instance))
        }
        XCTAssertEqual(v("{\"type\":\"integer\"}", "1").count, 0)
        XCTAssertEqual(v("{\"type\":\"integer\"}", "1.5").first?.keyword, "type")
        XCTAssertEqual(v("{\"type\":\"integer\"}", "2.0").count, 0)
        XCTAssertEqual(v("{\"enum\":[1,2]}", "3").first?.keyword, "enum")
        XCTAssertEqual(v("{\"const\":\"a\"}", "\"b\"").first?.keyword, "const")
        XCTAssertEqual(v("{\"minLength\":2,\"maxLength\":3}", "\"a\"").first?.keyword, "minLength")
        XCTAssertEqual(v("{\"pattern\":\"^a+$\"}", "\"ab\"").first?.keyword, "pattern")
        XCTAssertEqual(v("{\"minimum\":1,\"maximum\":3}", "4").first?.keyword, "maximum")
        XCTAssertEqual(v("{\"uniqueItems\":true}", "[1,2,1]").first?.pointer, "/2")
        XCTAssertEqual(v("{\"items\":{\"type\":\"string\"}}", "[\"a\",1]").first?.pointer, "/1")
        XCTAssertEqual(v("{\"prefixItems\":[{\"type\":\"string\"}],\"items\":{\"type\":\"integer\"}}", "[\"a\",1,\"x\"]").first?.pointer, "/2")
        XCTAssertEqual(v("{\"properties\":{\"a\":{}},\"additionalProperties\":false}", "{\"a\":1,\"b\":2}").first?.pointer, "/b")
        XCTAssertEqual(v("{\"required\":[\"a\"]}", "{}").first?.pointer, "/a")
        XCTAssertEqual(v("{\"patternProperties\":{\"^x\":{\"type\":\"integer\"}},\"additionalProperties\":false}", "{\"xa\":\"s\"}").first?.pointer, "/xa")
        XCTAssertEqual(v("{\"propertyNames\":{\"pattern\":\"^a\"}}", "{\"b\":1}").first?.keyword, "pattern")
        XCTAssertEqual(v("{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"number\"}]}", "true").first?.keyword, "oneOf")
        XCTAssertEqual(v("{\"oneOf\":[{\"type\":\"number\"},{\"type\":\"integer\"}]}", "1").first?.keyword, "oneOf")
        XCTAssertEqual(v("{\"anyOf\":[{\"type\":\"string\"}]}", "1").first?.keyword, "anyOf")
        XCTAssertEqual(v("{\"allOf\":[{\"minimum\":1},{\"maximum\":2}]}", "3").first?.keyword, "maximum")
        XCTAssertEqual(v("{\"not\":{\"type\":\"string\"}}", "\"x\"").first?.keyword, "not")
        XCTAssertEqual(v("{\"if\":{\"properties\":{\"a\":{\"const\":1}},\"required\":[\"a\"]},\"then\":{\"required\":[\"b\"]},\"else\":{\"required\":[\"c\"]}}", "{\"a\":1}").first?.pointer, "/b")
        XCTAssertEqual(v("{\"if\":{\"properties\":{\"a\":{\"const\":1}},\"required\":[\"a\"]},\"then\":{\"required\":[\"b\"]},\"else\":{\"required\":[\"c\"]}}", "{\"a\":2}").first?.pointer, "/c")
        XCTAssertEqual(v("{\"$defs\":{\"n\":{\"type\":\"integer\"}},\"properties\":{\"a\":{\"$ref\":\"#/$defs/n\"}}}", "{\"a\":\"x\"}").first?.pointer, "/a")
        XCTAssertEqual(v("{\"minItems\":1,\"maxItems\":2}", "[]").first?.keyword, "minItems")
        XCTAssertEqual(v("{\"maxProperties\":1}", "{\"a\":1,\"b\":2}").first?.keyword, "maxProperties")
    }

    func testSchemaViolationsMapToStableCodes() {
        let value = Fixture.mutate(Fixture.manifestJSON()) { $0["bogus"] = 1; $0["license"] = nil; $0["name"] = 5; $0["id"] = "A"; $0["manifestVersion"] = 3 }
        let diags = JSONSchema.diagnostics(JSONSchema.manifest.validate(value), file: "manifest.json", manifest: true)
        assertDiag(diags, .unknownKey, pointer: "/bogus")
        assertDiag(diags, .missingKey, pointer: "/license")
        assertDiag(diags, .wrongType, pointer: "/name")
        assertDiag(diags, .invalidModID, pointer: "/id")
        assertDiag(diags, .unsupportedManifestVersion, pointer: "/manifestVersion")
    }

    func testBFScriptSchemaRejectsMalformedPrograms() {
        func bad(_ text: String) -> Bool { !JSONSchema.bfscript.validate(try! JSONValue.parse(text)).isEmpty }
        XCTAssertTrue(bad("{\"format\":2,\"functions\":{}}"))
        XCTAssertTrue(bad("{\"format\":1,\"functions\":{\"a\":{\"signature\":\"activate@1\",\"body\":[{\"return\":null,\"x\":1}]}}}"))
        XCTAssertTrue(bad("{\"format\":1,\"functions\":{\"a\":{\"signature\":\"activate@1\",\"body\":[{\"forEach\":\"x\",\"in\":{\"get\":[\"input\"]},\"body\":[]}]}}}"))
        XCTAssertTrue(bad("{\"format\":1,\"functions\":{\"a\":{\"signature\":\"activate@1\",\"body\":[{\"return\":{\"eval\":\"1\"}}]}}}"))
        XCTAssertFalse(bad("{\"format\":1,\"functions\":{\"a\":{\"signature\":\"activate@1\",\"body\":[{\"return\":null}]}}}"))
    }
}
