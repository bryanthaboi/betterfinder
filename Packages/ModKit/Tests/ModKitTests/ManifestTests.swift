import XCTest
@testable import ModKit

final class ManifestTests: XCTestCase {
    func decode(_ v: JSONValue) -> Result<ModManifest, ModDiagnostic> { ModManifest.decode(v.canonicalData()) }

    func failure(_ v: JSONValue, file: StaticString = #filePath, line: UInt = #line) -> ModDiagnostic {
        switch decode(v) {
        case .success: XCTFail("expected decode failure", file: file, line: line); return ModDiagnostic(.invalidValue, message: "")
        case .failure(let d): return d
        }
    }

    func testExamplesDecodeAndRoundTrip() throws {
        for ex in ModExamples.all {
            let data = ex.package.data("manifest.json")!
            guard case .success(let m) = ModManifest.decode(data) else { return XCTFail("\(ex.id) failed to decode") }
            let again = try JSONDecoder().decode(ModManifest.self, from: JSONEncoder().encode(m))
            XCTAssertEqual(again, m, ex.id)
        }
    }

    func testPlanManifestFields() {
        guard case .success(let m) = decode(Fixture.manifestJSON()) else { return XCTFail() }
        XCTAssertEqual(m.id, "alice.image-dimensions")
        XCTAssertEqual(m.runtime, .jscIR)
        XCTAssertEqual(m.entry, "scripts/main.bfscript.json")
        XCTAssertEqual(m.contributes.columns.first?.handler, "dimensions")
        XCTAssertEqual(m.permissions.first?.kind, .fsRead)
        XCTAssertEqual(m.qualifiedID("dimensions"), "alice.image-dimensions/dimensions")
    }

    func testUnknownRootKey() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["bogus"] = 1 })
        XCTAssertEqual(d.code, .unknownKey)
        XCTAssertEqual(d.pointer, "/bogus")
    }

    func testUnknownNestedKeyHasFullPointer() {
        var m = Fixture.manifestJSON()
        m = Fixture.mutate(m) { o in
            var perms = o["permissions"]!.arrayValue!
            var p = perms[0].objectValue!
            p["extra"] = true
            perms[0] = .object(p)
            o["permissions"] = .array(perms)
        }
        let d = failure(m)
        XCTAssertEqual(d.code, .unknownKey)
        XCTAssertEqual(d.pointer, "/permissions/0/extra")
    }

    func testUnknownKeyInContributionItem() {
        let m = Fixture.mutate(Fixture.manifestJSON()) {
            $0["contributes"] = ["columns": [["id": "d", "title": "D", "valueType": "string", "handler": "h", "nope": 1]]]
        }
        let d = failure(m)
        XCTAssertEqual(d.code, .unknownKey)
        XCTAssertEqual(d.pointer, "/contributes/columns/0/nope")
    }

    func testPermissionKindSpecificClosedKeys() {
        let m = Fixture.mutate(Fixture.manifestJSON()) {
            $0["permissions"] = [["kind": "ui", "surfaces": ["column"], "reason": "x"]]
        }
        let d = failure(m)
        XCTAssertEqual(d.code, .unknownKey)
        XCTAssertEqual(d.pointer, "/permissions/0/reason")
    }

    func testMissingRequiredKey() {
        var o = Fixture.manifestJSON().objectValue!
        o["license"] = nil
        let d = failure(.object(o))
        XCTAssertEqual(d.code, .missingKey)
        XCTAssertEqual(d.pointer, "/license")
    }

    func testMissingNestedRequiredKey() {
        let m = Fixture.mutate(Fixture.manifestJSON()) {
            $0["permissions"] = [["kind": "fs.read", "scope": "selection"]]
        }
        let d = failure(m)
        XCTAssertEqual(d.code, .missingKey)
        XCTAssertEqual(d.pointer, "/permissions/0/reason")
    }

    func testWrongType() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["name"] = 5 })
        XCTAssertEqual(d.code, .wrongType)
        XCTAssertEqual(d.pointer, "/name")
        let d2 = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["hooks"] = [["name": "activate", "handler": "h", "version": "1"]] })
        XCTAssertEqual(d2.code, .wrongType)
        XCTAssertEqual(d2.pointer, "/hooks/0/version")
    }

    func testNullForRequiredAndOptional() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["entry"] = .null })
        XCTAssertEqual(d.pointer, "/entry")
    }

    func testBadIDs() {
        for bad in ["ab", "Alice.x", "alice x", ".alice", "-alice.x", String(repeating: "a", count: 97)] {
            let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["id"] = .string(bad) })
            XCTAssertEqual(d.code, .invalidModID, bad)
            XCTAssertEqual(d.pointer, "/id")
        }
    }

    func testBadVersionAndRange() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["version"] = "1.0" })
        XCTAssertEqual(d.code, .invalidVersionOrRange)
        XCTAssertEqual(d.pointer, "/version")
        let r = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["api"] = "latest" })
        XCTAssertEqual(r.code, .invalidVersionOrRange)
        XCTAssertEqual(r.pointer, "/api")
    }

    func testManifestVersionAndRuntimeAreClosed() {
        let v = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["manifestVersion"] = 2 })
        XCTAssertEqual(v.code, .unsupportedManifestVersion)
        XCTAssertEqual(v.pointer, "/manifestVersion")
        let r = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["runtime"] = "wasm/1" })
        XCTAssertEqual(r.code, .invalidValue)
        XCTAssertEqual(r.pointer, "/runtime")
        for rt in ["data/1", "jsc-ir/1", "js/1", "ts/1"] { XCTAssertNotNil(ModRuntime(rawValue: rt)) }
    }

    func testUnknownPermissionKind() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["permissions"] = [["kind": "root.everything"]] })
        XCTAssertEqual(d.code, .invalidValue)
        XCTAssertEqual(d.pointer, "/permissions/0/kind")
    }

    func testRootScopeRequiresRootId() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["permissions"] = [["kind": "fs.read", "scope": "root", "reason": "r"]] })
        XCTAssertEqual(d.code, .missingKey)
        XCTAssertEqual(d.pointer, "/permissions/0/rootId")
        let e = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["permissions"] = [["kind": "fs.read", "scope": "selection", "rootId": "x", "reason": "r"]] })
        XCTAssertEqual(e.pointer, "/permissions/0/rootId")
    }

    func testFSReadCannotUseDestinationScope() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["permissions"] = [["kind": "fs.read", "scope": "destination", "reason": "r"]] })
        XCTAssertEqual(d.pointer, "/permissions/0/scope")
    }

    func testBrokerRequiresOperations() {
        let d = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["permissions"] = [["kind": "process.exec", "mode": "broker", "reason": "r"]] })
        XCTAssertEqual(d.code, .missingKey)
        let e = failure(Fixture.mutate(Fixture.manifestJSON()) { $0["permissions"] = [["kind": "process.exec", "mode": "unrestricted", "operations": ["git.status"], "reason": "r"]] })
        XCTAssertEqual(e.pointer, "/permissions/0/operations")
    }

    func testNetPermissionDecoding() throws {
        let ok = Fixture.mutate(Fixture.manifestJSON()) {
            $0["permissions"] = [["kind": "net", "reason": "fetch", "endpoints": [["scheme": "https", "host": "api.example.com", "port": 443, "methods": ["GET", "POST"]]]]]
        }
        guard case .success(let m) = decode(ok) else { return XCTFail() }
        XCTAssertEqual(m.permissions[0].endpoints?[0].host, "api.example.com")
        let bad = failure(Fixture.mutate(Fixture.manifestJSON()) {
            $0["permissions"] = [["kind": "net", "reason": "r", "endpoints": [["scheme": "https", "host": "Bad Host", "methods": ["GET"]]]]]
        })
        XCTAssertEqual(bad.pointer, "/permissions/0/endpoints/0/host")
        let port = failure(Fixture.mutate(Fixture.manifestJSON()) {
            $0["permissions"] = [["kind": "net", "reason": "r", "endpoints": [["scheme": "https", "host": "a.example.com", "port": 70000, "methods": ["GET"]]]]]
        })
        XCTAssertEqual(port.pointer, "/permissions/0/endpoints/0/port")
        let method = failure(Fixture.mutate(Fixture.manifestJSON()) {
            $0["permissions"] = [["kind": "net", "reason": "r", "endpoints": [["scheme": "https", "host": "a.example.com", "methods": ["TRACE"]]]]]
        })
        XCTAssertEqual(method.pointer, "/permissions/0/endpoints/0/methods/0")
    }

    func testSidebarItemNeedsExactlyOneTarget() {
        func item(_ extra: [String: JSONValue]) -> JSONValue {
            var o: [String: JSONValue] = ["id": "x", "title": "X"]
            for (k, v) in extra { o[k] = v }
            return Fixture.mutate(Fixture.manifestJSON()) { $0["contributes"] = ["sidebarSections": [["id": "s", "title": "S", "items": [.object(o)]]]] }
        }
        XCTAssertEqual(failure(item([:])).pointer, "/contributes/sidebarSections/0/items/0")
        XCTAssertEqual(failure(item(["knownFolder": "home", "location": "loc"])).pointer, "/contributes/sidebarSections/0/items/0")
        XCTAssertEqual(failure(item(["knownFolder": "usr"])).pointer, "/contributes/sidebarSections/0/items/0/knownFolder")
    }

    func testPathFieldsRejectEscapes() {
        for bad in ["../x.json", "/abs.json", "a//b.json", "a/../b.json", "a\\b.json", "./a.json"] {
            let m = Fixture.mutate(Fixture.manifestJSON()) { $0["contributes"] = ["themes": [["id": "t", "title": "T", "path": .string(bad), "appearance": "any"]]] }
            let d = failure(m)
            XCTAssertEqual(d.code, .pathNotContained, bad)
            XCTAssertEqual(d.pointer, "/contributes/themes/0/path")
        }
    }

    func testSettingsDecoding() throws {
        let settings: JSONValue = [
            ["key": "enabled", "type": "boolean", "label": "On", "default": true],
            ["key": "count", "type": "integer", "label": "Count", "default": 3, "minimum": 1, "maximum": 10],
            ["key": "ratio", "type": "number", "label": "Ratio", "default": 0.5, "minimum": 0, "maximum": 1],
            ["key": "title", "type": "string", "label": "Title", "default": "hi", "maxLength": 10],
            ["key": "mode", "type": "enum", "label": "Mode", "default": "a", "options": [["value": "a", "label": "A"], ["value": "b", "label": "B"]]],
        ]
        guard case .success(let m) = decode(Fixture.mutate(Fixture.manifestJSON()) { $0["settings"] = settings }) else { return XCTFail() }
        XCTAssertEqual(m.settings.map(\.type), [.boolean, .integer, .number, .string, .enum])
        func bad(_ s: JSONValue) -> ModDiagnostic { failure(Fixture.mutate(Fixture.manifestJSON()) { $0["settings"] = [s] }) }
        XCTAssertEqual(bad(["key": "k", "type": "integer", "label": "L", "default": "x"]).pointer, "/settings/0/default")
        XCTAssertEqual(bad(["key": "k", "type": "integer", "label": "L", "default": 20, "maximum": 10]).pointer, "/settings/0/default")
        XCTAssertEqual(bad(["key": "k", "type": "integer", "label": "L", "default": 1.5]).pointer, "/settings/0/default")
        XCTAssertEqual(bad(["key": "k", "type": "enum", "label": "L", "default": "z", "options": [["value": "a", "label": "A"]]]).pointer, "/settings/0/default")
        XCTAssertEqual(bad(["key": "k", "type": "enum", "label": "L", "default": "a"]).pointer, "/settings/0/options")
        XCTAssertEqual(bad(["key": "k", "type": "boolean", "label": "L", "default": true, "minimum": 0]).pointer, "/settings/0/minimum")
        XCTAssertEqual(bad(["key": "k", "type": "string", "label": "L", "default": "abcdef", "maxLength": 3]).pointer, "/settings/0/default")
        XCTAssertEqual(bad(["key": "k", "type": "integer", "label": "L", "default": 5, "minimum": 9, "maximum": 2]).pointer, "/settings/0/minimum")
        XCTAssertEqual(bad(["key": "K", "type": "boolean", "label": "L", "default": true]).pointer, "/settings/0/key")
        XCTAssertEqual(bad(["key": "k", "type": "secret", "label": "L", "default": ""]).pointer, "/settings/0/type")
    }

    func testDependencyDecoding() {
        let sha = String(repeating: "a", count: 64)
        guard case .success(let m) = decode(Fixture.mutate(Fixture.manifestJSON()) { $0["dependencies"] = [["id": "bob.lib", "version": "1.2.3", "sha256": .string(sha)]] }) else { return XCTFail() }
        XCTAssertEqual(m.dependencies[0].version, SemVer(1, 2, 3))
        XCTAssertEqual(failure(Fixture.mutate(Fixture.manifestJSON()) { $0["dependencies"] = [["id": "bob.lib", "version": "1.2.3", "sha256": "xyz"]] }).pointer, "/dependencies/0/sha256")
        XCTAssertEqual(failure(Fixture.mutate(Fixture.manifestJSON()) { $0["conflicts"] = ["Bad Id"] }).pointer, "/conflicts/0")
    }

    func testKeybindingChordFormat() {
        func chord(_ c: String) -> Bool {
            if case .success = decode(Fixture.mutate(Fixture.manifestJSON()) { $0["contributes"] = ["keybindings": [["id": "k", "key": .string(c), "command": "builtin.x"]]] }) { return true }
            return false
        }
        XCTAssertTrue(chord("cmd+shift+z"))
        XCTAssertTrue(chord("opt+f5"))
        XCTAssertFalse(chord("Cmd+Z"))
        XCTAssertFalse(chord("cmd+"))
        XCTAssertFalse(chord("cmd+zz"))
    }

    func testInvalidJSONReportsPosition() {
        guard case .failure(let d) = ModManifest.decode(Data("{\n \"id\": }".utf8)) else { return XCTFail() }
        XCTAssertEqual(d.code, .invalidJSON)
        XCTAssertEqual(d.line, 2)
        guard case .failure(let dup) = ModManifest.decode(Data("{\"id\":\"a\",\"id\":\"b\"}".utf8)) else { return XCTFail() }
        XCTAssertEqual(dup.code, .invalidJSON)
        XCTAssertEqual(dup.pointer, "/id")
        guard case .failure(let arr) = ModManifest.decode(Data("[]".utf8)) else { return XCTFail() }
        XCTAssertEqual(arr.code, .wrongType)
    }
}
