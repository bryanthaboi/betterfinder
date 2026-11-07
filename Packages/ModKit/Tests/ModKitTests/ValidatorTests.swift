import XCTest
@testable import ModKit

final class ValidatorTests: XCTestCase {
    func run(_ manifest: JSONValue, script: Data? = nil, extra: [String: Data] = [:], host: ModHostVersions = .current) -> ModPreflightOutcome {
        ModStaticPreflight.run(package: Fixture.package(manifest: manifest, script: script, extra: extra), host: host)
    }

    func edit(_ id: String = "image-dimensions", _ f: (inout [String: JSONValue]) -> Void) -> JSONValue {
        Fixture.mutate(Fixture.manifestJSON(id), f)
    }

    func codes(_ o: ModPreflightOutcome) -> [String] { o.receipt.diagnostics.map(\.code.rawValue) }

    func testCleanExampleReceipt() {
        let o = run(Fixture.manifestJSON())
        XCTAssertEqual(o.receipt.diagnostics, [])
        XCTAssertTrue(o.receipt.staticOK)
        XCTAssertFalse(o.receipt.ok)
        XCTAssertEqual(o.receipt.api, "1.0.0")
        XCTAssertEqual(o.receipt.toolchain, ModKitVersion.toolchain)
        XCTAssertEqual(o.receipt.treeHash.count, 64)
        for c in PreflightCheck.staticChecks { XCTAssertEqual(o.receipt[c], .pass, c.rawValue) }
        XCTAssertEqual(o.receipt[.dryRun], .notRun)
        XCTAssertNotNil(o.compiledScript)
        XCTAssertEqual(o.manifest?.id, "alice.image-dimensions")
        XCTAssertTrue(o.receipt.merging(check: .dryRun, status: .pass, diagnostics: []).ok)
    }

    func testTreeHashTracksContent() {
        let a = run(Fixture.manifestJSON()).receipt.treeHash
        let b = run(Fixture.manifestJSON(), script: Fixture.script("markdown-previewer")).receipt.treeHash
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, run(Fixture.manifestJSON()).receipt.treeHash)
    }

    func testMissingManifestAndBadJSON() {
        let none = ModStaticPreflight.run(package: ModPackage(files: [:]))
        assertDiag(none.receipt.diagnostics, .missingManifest)
        XCTAssertFalse(none.receipt.staticOK)
        let bad = ModStaticPreflight.run(package: ModPackage(files: ["manifest.json": Data("{".utf8)]))
        assertDiag(bad.receipt.diagnostics, .invalidJSON)
        XCTAssertEqual(bad.receipt[.schema], .fail)
        XCTAssertEqual(bad.receipt[.manifest], .notRun)
        let big = ModStaticPreflight.run(package: ModPackage(files: ["manifest.json": Data(repeating: 0x20, count: 300_000)]))
        assertDiag(big.receipt.diagnostics, .sizeBound)
    }

    func testSchemaFailureReportsAllPointers() {
        let o = run(edit { $0["bogus"] = 1; $0["license"] = nil; $0["name"] = 5 })
        assertDiag(o.receipt.diagnostics, .unknownKey, pointer: "/bogus")
        assertDiag(o.receipt.diagnostics, .missingKey, pointer: "/license")
        assertDiag(o.receipt.diagnostics, .wrongType, pointer: "/name")
        XCTAssertEqual(o.receipt[.schema], .fail)
        XCTAssertNil(o.manifest)
        XCTAssertFalse(o.receipt.ok)
    }

    func testApiAndAppCompatibility() {
        let api = run(edit { $0["api"] = ">=2.0.0 <3.0.0" })
        assertDiag(api.receipt.diagnostics, .apiIncompatible, pointer: "/api")
        let app = run(edit { $0["app"] = ">=2.0.0 <3.0.0" })
        assertDiag(app.receipt.diagnostics, .appIncompatible, pointer: "/app")
        let newHost = ModHostVersions(app: SemVer(2, 1, 0), api: SemVer(1, 4, 0))
        XCTAssertFalse(codes(run(Fixture.manifestJSON(), host: newHost)).contains("BF6001"))
        XCTAssertTrue(codes(run(Fixture.manifestJSON(), host: newHost)).contains("BF6002"))
        let open = run(edit { $0["api"] = ">=1.0.0" })
        assertDiag(open.receipt.diagnostics, .unboundedRange, pointer: "/api")
        XCTAssertEqual(open.receipt.diagnostics.first { $0.code == .unboundedRange }?.severity, .warning)
        XCTAssertTrue(open.receipt.staticOK)
    }

    func testIdNamespacing() {
        assertDiag(run(edit { $0["id"] = "bob.image-dimensions" }).receipt.diagnostics, .idAuthorMismatch, pointer: "/id")
        assertDiag(run(edit { $0["id"] = "betterfinder.thing"; $0["author"] = "betterfinder" }).receipt.diagnostics, .reservedNamespace, pointer: "/id")
        assertDiag(run(edit { $0["id"] = "com.apple.thing"; $0["author"] = "com" }).receipt.diagnostics, .reservedNamespace)
    }

    func testRuntimeEntryRules() {
        assertDiag(run(edit("pinned-folders") { $0["entry"] = "scripts/x.bfscript.json" }).receipt.diagnostics, .entryForbidden, pointer: "/entry")
        let noEntry = run(edit { $0["entry"] = nil })
        XCTAssertTrue(noEntry.receipt.diagnostics.contains { $0.code == .missingKey || $0.code == .entryInvalid })
        let ts = run(edit { $0["runtime"] = "ts/1"; $0["entry"] = "scripts/main.bfscript.json" })
        XCTAssertTrue(ts.receipt.diagnostics.contains { $0.pointer == "/entry" })
        let wrongExt = run(edit { $0["entry"] = "scripts/main.json" })
        assertDiag(wrongExt.receipt.diagnostics, .entryInvalid, pointer: "/entry")
    }

    func testDataRuntimeCannotDeclareHandlersOrHooks() {
        let o = run(edit("pinned-folders") {
            $0["hooks"] = [["name": "activate", "handler": "h", "version": 1]]
            $0["contributes"] = Fixture.mutate($0["contributes"]!) { $0["columns"] = [["id": "c", "title": "C", "valueType": "string", "handler": "h"]] }
        })
        assertDiag(o.receipt.diagnostics, .handlerInDataMod, pointer: "/hooks/0")
        assertDiag(o.receipt.diagnostics, .handlerInDataMod, pointer: "/contributes/columns/0")
    }

    func testJSAndTSRunStaticChecksOnly() {
        let js = ModStaticPreflight.run(
            package: ModPackage(files: [
                "manifest.json": edit { $0["runtime"] = "js/1"; $0["entry"] = "src/main.js" }.canonicalData(),
                "src/main.js": Data("export async function dimensions(){}".utf8),
            ]),
            externalAnalysis: ScriptAnalysis(handlers: ["dimensions": "column.values@1"], catalogCalls: ["media.imageDimensions"], callsKnown: true)
        )
        XCTAssertEqual(js.receipt.diagnostics, [])
        XCTAssertEqual(js.receipt[.types], .notRun)
        XCTAssertEqual(js.receipt[.compile], .notRun)
        XCTAssertFalse(js.receipt.staticOK)
        XCTAssertNil(js.compiledScript)
        let mismatch = ModStaticPreflight.run(
            package: ModPackage(files: [
                "manifest.json": edit { $0["runtime"] = "js/1"; $0["entry"] = "src/main.js" }.canonicalData(),
                "src/main.js": Data("export async function other(){}".utf8),
            ]),
            externalAnalysis: ScriptAnalysis(handlers: ["other": ""], catalogCalls: [], callsKnown: true)
        )
        assertDiag(mismatch.receipt.diagnostics, .missingHandlerFunction, pointer: "/hooks/0/handler")
        let unknown = ModStaticPreflight.run(package: ModPackage(files: [
            "manifest.json": edit { $0["runtime"] = "ts/1"; $0["entry"] = "src/main.ts" }.canonicalData(),
            "src/main.ts": Data("export async function dimensions(){}".utf8),
        ]))
        XCTAssertFalse(unknown.receipt.diagnostics.contains { $0.code == .unusedGrant })
        XCTAssertFalse(unknown.receipt.diagnostics.contains { $0.code == .missingGrant && $0.message.contains("script call") })
    }


    func testMissingGrantForContributionHookAndCall() {
        let noUI = run(edit { $0["permissions"] = [["kind": "fs.read", "scope": "selection", "reason": "r"]] })
        assertDiag(noUI.receipt.diagnostics, .missingGrant, pointer: "/contributes/columns/0")
        let noFS = run(edit { $0["permissions"] = [["kind": "ui", "surfaces": ["column"]]] })
        let fsMissing = noFS.receipt.diagnostics.first { $0.code == .missingGrant }
        XCTAssertTrue(fsMissing?.message.contains("media.imageDimensions") == true, "\(noFS.receipt.diagnostics)")
        XCTAssertEqual(noFS.receipt[.grants], .fail)
        let wrongScope = run(edit { $0["permissions"] = [["kind": "fs.write", "scope": "destination", "reason": "r"], ["kind": "ui", "surfaces": ["column"]]] })
        assertDiag(wrongScope.receipt.diagnostics, .missingGrant)
    }

    func testBrokerOperationGrantRequired() {
        let o = run(edit("zip-selection") {
            $0["permissions"] = [
                ["kind": "fs.read", "scope": "selection", "reason": "r"], ["kind": "fs.write", "scope": "destination", "reason": "r"],
                ["kind": "process.exec", "mode": "broker", "operations": ["git.status"], "reason": "r"], ["kind": "ui", "surfaces": ["toolbar"]],
            ]
        }, script: Fixture.script("zip-selection"))
        let miss = o.receipt.diagnostics.first { $0.code == .missingGrant }
        XCTAssertTrue(miss?.message.contains("archive.create") == true, "\(o.receipt.diagnostics)")
        let unrestricted = run(edit("zip-selection") {
            $0["permissions"] = [
                ["kind": "fs.read", "scope": "selection", "reason": "r"], ["kind": "fs.write", "scope": "destination", "reason": "r"],
                ["kind": "process.exec", "mode": "unrestricted", "reason": "r"], ["kind": "ui", "surfaces": ["toolbar"]],
            ]
        }, script: Fixture.script("zip-selection"))
        XCTAssertFalse(unrestricted.receipt.diagnostics.contains { $0.code == .missingGrant })
        assertDiag(unrestricted.receipt.diagnostics, .highTrustExec, pointer: "/permissions/2")
    }

    func testUnusedGrantsWarn() {
        let o = run(edit {
            $0["permissions"] = [
                ["kind": "fs.read", "scope": "selection", "reason": "r"], ["kind": "ui", "surfaces": ["column", "toolbar"]],
                ["kind": "storage"], ["kind": "net", "reason": "r", "endpoints": [["scheme": "https", "host": "api.example.com", "methods": ["GET"]]]],
            ]
        })
        assertDiag(o.receipt.diagnostics, .unusedGrant, pointer: "/permissions/1/surfaces/1")
        assertDiag(o.receipt.diagnostics, .unusedGrant, pointer: "/permissions/2")
        assertDiag(o.receipt.diagnostics, .unusedGrant, pointer: "/permissions/3")
        XCTAssertEqual(o.receipt.diagnostics.filter { $0.code == .unusedGrant }.count, 3)
        XCTAssertTrue(o.receipt.staticOK)
        XCTAssertEqual(o.receipt.diagnostics.filter { $0.code == .unusedGrant }.allSatisfy { $0.severity == .warning }, true)
    }

    func testDuplicateGrantWarns() {
        let p: JSONValue = ["kind": "fs.read", "scope": "selection", "reason": "r"]
        let o = run(edit { $0["permissions"] = [p, p, ["kind": "ui", "surfaces": ["column"]]] })
        assertDiag(o.receipt.diagnostics, .duplicateGrant, pointer: "/permissions/1")
    }

    func testNetworkGrantChecks() {
        func net(_ host: String, scheme: String = "https", allowPrivate: Bool? = nil) -> ModPreflightOutcome {
            var perm: [String: JSONValue] = ["kind": "net", "reason": "r", "endpoints": [["scheme": .string(scheme), "host": .string(host), "methods": ["GET"]]]]
            if let allowPrivate { perm["allowPrivate"] = .bool(allowPrivate) }
            return run(edit { $0["permissions"] = [.object(perm), ["kind": "fs.read", "scope": "selection", "reason": "r"], ["kind": "ui", "surfaces": ["column"]]] })
        }
        for host in ["localhost", "192.168.1.5", "10.0.0.1", "127.0.0.1", "172.16.4.4", "nas.local", "printer", "169.254.1.1", "foo.internal"] {
            assertDiag(net(host).receipt.diagnostics, .privateNetworkDenied, pointer: "/permissions/0/endpoints/0/host")
        }
        XCTAssertFalse(codes(net("192.168.1.5", allowPrivate: true)).contains("BF4004"))
        XCTAssertFalse(codes(net("api.example.com")).contains("BF4004"))
        XCTAssertFalse(codes(net("8.8.8.8")).contains("BF4004"))
        XCTAssertFalse(codes(net("172.32.0.1")).contains("BF4004"))
        assertDiag(net("api.example.com", scheme: "http").receipt.diagnostics, .insecureTransport)
    }

    func testBrokerOperationAndFileOperationNamesValidated() {
        let b = run(edit("zip-selection") {
            $0["permissions"] = [["kind": "process.exec", "mode": "broker", "operations": ["rm.rf"], "reason": "r"]]
        }, script: Fixture.script("zip-selection"))
        assertDiag(b.receipt.diagnostics, .unknownBrokerOperation, pointer: "/permissions/0/operations/0")
        let f = run(edit { $0["permissions"] = [["kind": "operations.observe", "operations": ["explode"], "reason": "r"]] })
        assertDiag(f.receipt.diagnostics, .invalidGrantShape, pointer: "/permissions/0/operations/0")
    }

    func testBlankReasonAndQuotaBounds() {
        let o = run(edit { $0["permissions"] = [["kind": "fs.read", "scope": "selection", "reason": "  "], ["kind": "ui", "surfaces": ["column"]], ["kind": "storage", "quotaBytes": 5]] })
        assertDiag(o.receipt.diagnostics, .invalidGrantShape, pointer: "/permissions/0/reason")
        assertDiag(o.receipt.diagnostics, .sizeBound, pointer: "/permissions/2/quotaBytes")
        let long = run(edit { $0["permissions"] = [["kind": "fs.read", "scope": "selection", "reason": .string(String(repeating: "x", count: 500))], ["kind": "ui", "surfaces": ["column"]]] })
        XCTAssertTrue(long.receipt.diagnostics.contains { $0.pointer == "/permissions/0/reason" })
    }

    func testUndeclaredRoot() {
        let o = run(edit("recent-downloads") {
            $0["permissions"] = [["kind": "fs.read", "scope": "root", "rootId": "documents", "reason": "r"], ["kind": "ui", "surfaces": ["sidebar", "location"]]]
        }, script: Fixture.script("recent-downloads"))
        assertDiag(o.receipt.diagnostics, .undeclaredRoot)
    }

    func testUISelectionAndOperationGrantsForHooks() {
        let selection = Fixture.program(Fixture.hookFn("sel", "selection.changed@1", #"{"return":null}"#))
        let m = edit { $0["contributes"] = [:]; $0["hooks"] = [["name": "selection.changed", "handler": "sel", "version": 1]]; $0["permissions"] = [] }
        let miss = run(m, script: Data(selection.utf8))
        assertDiag(miss.receipt.diagnostics, .missingGrant, pointer: "/hooks/0")
        let ok = run(edit { $0["contributes"] = [:]; $0["hooks"] = [["name": "selection.changed", "handler": "sel", "version": 1]]
            $0["permissions"] = [["kind": "ui.selection", "level": "names", "reason": "show count"]] }, script: Data(selection.utf8))
        XCTAssertEqual(ok.receipt.diagnostics, [])
        let guardScript = Fixture.program(Fixture.hookFn("g", "fileop.before.trash@1", #"{"return":{"record":{"decision":"deny","reason":"protected"}}}"#))
        let guardM = edit { $0["contributes"] = [:]; $0["hooks"] = [["name": "fileop.before.trash", "handler": "g", "version": 1]]
            $0["permissions"] = [["kind": "operations.intercept", "operations": ["move"], "reason": "guard"]] }
        let wrongOp = run(guardM, script: Data(guardScript.utf8))
        assertDiag(wrongOp.receipt.diagnostics, .missingGrant)
        let guardOK = edit { $0["contributes"] = [:]; $0["hooks"] = [["name": "fileop.before.trash", "handler": "g", "version": 1]]
            $0["permissions"] = [["kind": "operations.intercept", "operations": ["trash"], "reason": "guard"]] }
        XCTAssertEqual(run(guardOK, script: Data(guardScript.utf8)).receipt.diagnostics, [])
    }

    func testReplacesRequiresOverrideGrant() {
        let m = edit("zip-selection") {
            $0["contributes"] = Fixture.mutate($0["contributes"]!) { c in
                c["toolbar"] = [["id": "zip", "title": "Zip", "command": "zip-selection", "replaces": "builtin.toolbar.new-folder"]]
            }
        }
        assertDiag(run(m, script: Fixture.script("zip-selection")).receipt.diagnostics, .missingGrant, pointer: "/contributes/toolbar/0/replaces")
    }


    func testHookDeclarationChecks() {
        let unknown = run(edit { $0["hooks"] = [["name": "column.values", "handler": "dimensions", "version": 1], ["name": "nope.nope", "handler": "x", "version": 1]] })
        assertDiag(unknown.receipt.diagnostics, .unknownHook, pointer: "/hooks/1/name")
        let version = run(edit { $0["hooks"] = [["name": "column.values", "handler": "dimensions", "version": 7]] })
        assertDiag(version.receipt.diagnostics, .unsupportedHookVersion, pointer: "/hooks/0/version")
        let dup = run(edit { $0["hooks"] = [["name": "column.values", "handler": "dimensions", "version": 1], ["name": "column.values", "handler": "dimensions", "version": 1]] })
        assertDiag(dup.receipt.diagnostics, .duplicateHook, pointer: "/hooks/1")
        let single = Fixture.program(Fixture.hookFn("a", "activate@1", #"{"return":null}"#) + "," + Fixture.hookFn("b", "activate@1", #"{"return":null}"#))
        let twice = run(edit { $0["contributes"] = [:]; $0["permissions"] = []; $0["hooks"] = [["name": "activate", "handler": "a", "version": 1], ["name": "activate", "handler": "b", "version": 1]] }, script: Data(single.utf8))
        assertDiag(twice.receipt.diagnostics, .duplicateHook, pointer: "/hooks/1")
    }

    func testHandlerBindingChecks() {
        let unbound = run(edit { $0["hooks"] = [] })
        assertDiag(unbound.receipt.diagnostics, .handlerHookMismatch, pointer: "/contributes/columns/0/handler")
        let missingFn = run(edit { $0["hooks"] = [["name": "column.values", "handler": "ghost", "version": 1]] })
        assertDiag(missingFn.receipt.diagnostics, .missingHandlerFunction, pointer: "/hooks/0/handler")
        let wrongSig = run(edit { $0["hooks"] = [["name": "preview.render", "handler": "dimensions", "version": 1]] })
        assertDiag(wrongSig.receipt.diagnostics, .handlerHookMismatch, pointer: "/hooks/0/handler")
        let unused = run(edit { $0["hooks"] = [["name": "column.values", "handler": "dimensions", "version": 1], ["name": "column.values", "handler": "other", "version": 1]] })
        assertDiag(unused.receipt.diagnostics, .unusedHook, pointer: "/hooks/1")
    }

    func testUnboundScriptFunctionWarns() {
        let two = Fixture.program(Fixture.hookFn("dimensions", "column.values@1", #"{"return":{"list":[]}}"#) + "," + Fixture.hookFn("extra", "activate@1", #"{"return":null}"#))
        let o = run(Fixture.manifestJSON(), script: Data(two.utf8))
        XCTAssertTrue(o.receipt.diagnostics.contains { $0.code == .unusedFunction && $0.pointer == "/functions/extra" })
    }

    func testReferenceChecks() {
        let o = run(edit("zip-selection") {
            $0["contributes"] = Fixture.mutate($0["contributes"]!) { c in
                c["toolbar"] = [["id": "zip", "title": "Zip", "command": "ghost"]]
                c["contextMenu"] = [["id": "cm", "title": "CM", "command": "builtin.copy", "target": "items"]]
                c["sidebarSections"] = [["id": "s", "title": "S", "items": [["id": "i", "title": "I", "location": "nowhere"]]]]
                c["views"] = [["id": "v", "title": "V", "layout": "list", "columns": ["nocol"]]]
                c["settingsPanes"] = [["id": "p", "title": "P", "settings": ["nokey"]]]
            }
            $0["permissions"] = [
                ["kind": "fs.read", "scope": "selection", "reason": "r"], ["kind": "fs.write", "scope": "destination", "reason": "r"],
                ["kind": "process.exec", "mode": "broker", "operations": ["archive.create"], "reason": "r"],
                ["kind": "ui", "surfaces": ["toolbar", "contextMenu", "sidebar", "view"]],
            ]
        }, script: Fixture.script("zip-selection"))
        assertDiag(o.receipt.diagnostics, .unknownReference, pointer: "/contributes/toolbar/0/command")
        assertDiag(o.receipt.diagnostics, .unknownReference, pointer: "/contributes/sidebarSections/0/items/0/location")
        assertDiag(o.receipt.diagnostics, .unknownReference, pointer: "/contributes/views/0/columns/0")
        assertDiag(o.receipt.diagnostics, .unknownReference, pointer: "/contributes/settingsPanes/0/settings/0")
        XCTAssertFalse(o.receipt.diagnostics.contains { $0.pointer == "/contributes/contextMenu/0/command" })
    }

    func testDuplicateIdsAndKeybindings() {
        let o = run(edit("zip-selection") {
            $0["contributes"] = Fixture.mutate($0["contributes"]!) { c in
                c["toolbar"] = [["id": "zip", "title": "Zip", "command": "zip-selection"], ["id": "zip", "title": "Zip2", "command": "zip-selection"]]
                c["keybindings"] = [["id": "a", "key": "cmd+k", "command": "builtin.x"], ["id": "b", "key": "cmd+k", "command": "builtin.y"], ["id": "c", "key": "k", "command": "builtin.z"]]
            }
        }, script: Fixture.script("zip-selection"))
        assertDiag(o.receipt.diagnostics, .duplicateID, pointer: "/contributes/toolbar/1/id")
        assertDiag(o.receipt.diagnostics, .duplicateKeybinding, pointer: "/contributes/keybindings/1/key")
        assertDiag(o.receipt.diagnostics, .keybindingNoModifier, pointer: "/contributes/keybindings/2/key")
    }

    func testSettingsAndDependencyChecks() {
        let sha = JSONValue.string(String(repeating: "b", count: 64))
        let o = run(edit {
            $0["settings"] = [["key": "apiToken", "type": "string", "label": "Token", "default": ""], ["key": "apiToken", "type": "boolean", "label": "Dup", "default": true]]
            $0["dependencies"] = [["id": "alice.image-dimensions", "version": "1.0.0", "sha256": sha], ["id": "bob.lib", "version": "1.0.0", "sha256": sha], ["id": "bob.lib", "version": "1.0.0", "sha256": sha]]
            $0["conflicts"] = ["bob.lib", "alice.image-dimensions"]
        })
        assertDiag(o.receipt.diagnostics, .secretInSettings, pointer: "/settings/0/key")
        assertDiag(o.receipt.diagnostics, .duplicateID, pointer: "/settings/1/key")
        assertDiag(o.receipt.diagnostics, .selfDependency, pointer: "/dependencies/0/id")
        assertDiag(o.receipt.diagnostics, .duplicateID, pointer: "/dependencies/2/id")
        assertDiag(o.receipt.diagnostics, .dependencyConflict, pointer: "/dependencies/1/id")
        assertDiag(o.receipt.diagnostics, .dependencyConflict, pointer: "/conflicts/1")
    }

    func testSizeBounds() {
        var hooks = [JSONValue]()
        for i in 0..<130 { hooks.append(["name": "column.values", "handler": .string("h\(i)"), "version": 1]) }
        let o = run(edit { $0["hooks"] = .array(hooks) })
        assertDiag(o.receipt.diagnostics, .sizeBound, pointer: "/hooks")
    }


    func testPathChecks() {
        let theme = edit { $0["contributes"] = ["themes": [["id": "t", "title": "T", "path": "themes/dark.json", "appearance": "dark"]]] }
        assertDiag(run(theme).receipt.diagnostics, .pathMissing, pointer: "/contributes/themes/0/path")
        XCTAssertFalse(codes(run(theme, extra: ["themes/dark.json": Data("{}".utf8)])).contains("BF5004"))
        let icons = edit { $0["contributes"] = ["iconSets": [["id": "i", "title": "I", "path": "icons"]], "sounds": [["id": "s", "title": "S", "path": "sounds"]]] }
        let r = run(icons, extra: ["icons/a.png": Data([1, 2, 3, 4])])
        assertDiag(r.receipt.diagnostics, .pathMissing, pointer: "/contributes/sounds/0/path")
        XCTAssertFalse(r.receipt.diagnostics.contains { $0.pointer == "/contributes/iconSets/0/path" })
        let entry = ModStaticPreflight.run(package: ModPackage(files: ["manifest.json": Fixture.manifestJSON().canonicalData()]))
        assertDiag(entry.receipt.diagnostics, .pathMissing, pointer: "/entry")
        XCTAssertEqual(entry.receipt[.paths], .fail)
    }

    func testEntryEscapeIsRejected() {
        let o = run(edit { $0["entry"] = "../outside.bfscript.json" })
        XCTAssertTrue(o.receipt.diagnostics.contains { $0.code == .pathNotContained || $0.code == .invalidValue })
        XCTAssertTrue(o.receipt.diagnostics.contains { $0.pointer == "/entry" })
    }

    func testPackageInventoryChecks() {
        let collide = ModPackage(files: ["a/File.txt": Data("1".utf8), "a/file.txt": Data("2".utf8)])
        XCTAssertTrue(collide.inventoryDiagnostics.contains { $0.code == .duplicatePath })
        let shebang = ModPackage(files: ["run.sh": Data("#!/bin/sh\nrm -rf /".utf8)])
        XCTAssertTrue(shebang.inventoryDiagnostics.contains { $0.code == .forbiddenFileType })
        let macho = ModPackage(files: ["bin": Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0])])
        XCTAssertTrue(macho.inventoryDiagnostics.contains { $0.code == .forbiddenFileType })
        let escape = ModPackage(files: ["../evil": Data("x".utf8), "/abs": Data("y".utf8)])
        XCTAssertEqual(escape.inventoryDiagnostics.filter { $0.code == .pathNotContained }.count, 2)
        var limits = ModCatalogLimits.v1
        limits.maxPackageFiles = 1
        XCTAssertTrue(ModPackage(files: ["a": Data("1".utf8), "b": Data("2".utf8)], limits: limits).inventoryDiagnostics.contains { $0.code == .packageTooLarge })
        let o = run(Fixture.manifestJSON(), extra: ["payload.sh": Data("#!/bin/sh".utf8)])
        assertDiag(o.receipt.diagnostics, .forbiddenFileType)
        XCTAssertEqual(o.receipt[.paths], .fail)
        XCTAssertFalse(o.receipt.staticOK)
    }

    func testLoadFromDirectoryRejectsLinksAndExecutables() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("modkit-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Fixture.manifestJSON().canonicalData().write(to: dir.appendingPathComponent("manifest.json"))
        try Fixture.script().write(to: dir.appendingPathComponent("scripts/main.bfscript.json"))
        XCTAssertEqual(ModStaticPreflight.run(package: ModPackage.load(directory: dir)).receipt.diagnostics, [])
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let tool = dir.appendingPathComponent("tool")
        try Data("x".utf8).write(to: tool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try Data("junk".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let pkg = ModPackage.load(directory: dir)
        XCTAssertNil(pkg.data(".DS_Store"))
        XCTAssertTrue(pkg.inventoryDiagnostics.contains { $0.code == .forbiddenFileType && $0.file == "link" })
        XCTAssertTrue(pkg.inventoryDiagnostics.contains { $0.code == .forbiddenFileType && $0.file == "tool" })
        XCTAssertFalse(ModStaticPreflight.run(package: pkg).receipt.staticOK)
    }

    func testScriptErrorsSurfaceAsTypeCheckFailure() {
        let o = run(Fixture.manifestJSON(), script: Data(Fixture.program(Fixture.hookFn("dimensions", "column.values@1", #"{"return":"x"}"#)).utf8))
        XCTAssertEqual(o.receipt[.types], .fail)
        XCTAssertEqual(o.receipt[.compile], .fail)
        assertDiag(o.receipt.diagnostics, .typeMismatch, pointer: "/functions/dimensions/body/0/return")
        XCTAssertNil(o.compiledScript)
        XCTAssertFalse(o.receipt.ok)
        let sorted = o.receipt.diagnostics.map(\.severity)
        XCTAssertEqual(sorted, sorted.sorted(by: >))
    }

    func testMissingEntryFileLeavesScriptChecksNotRun() {
        let o = ModStaticPreflight.run(package: ModPackage(files: ["manifest.json": Fixture.manifestJSON().canonicalData()]))
        XCTAssertEqual(o.receipt[.types], .notRun)
        XCTAssertEqual(o.receipt[.compile], .notRun)
        XCTAssertFalse(o.receipt.staticOK)
    }


    func manifest(_ id: String, deps: [(String, String)] = [], conflicts: [String] = [], version: String = "1.0.0") -> ModManifest {
        let author = String(id.split(separator: ".")[0])
        return ModManifest(
            id: id, name: id, author: author, version: SemVer(version)!, api: SemVerRange(">=1.0.0 <2.0.0")!, app: SemVerRange(">=1.0.0 <2.0.0")!,
            runtime: .data, license: "MIT",
            dependencies: deps.map { ModDependency(id: $0.0, version: SemVer($0.1)!, sha256: String(repeating: "c", count: 64)) }, conflicts: conflicts
        )
    }

    func testInstallSetCycleConflictAndUnsatisfied() {
        let a = manifest("alice.a", deps: [("alice.b", "1.0.0")])
        let b = manifest("alice.b", deps: [("alice.a", "1.0.0")])
        assertDiag(ModInstallSetValidator.validate([InstalledMod(manifest: a), InstalledMod(manifest: b)]), .dependencyCycle)
        let three = ModInstallSetValidator.validate([
            InstalledMod(manifest: manifest("alice.a", deps: [("alice.b", "1.0.0")])), InstalledMod(manifest: manifest("alice.b", deps: [("alice.c", "1.0.0")])),
            InstalledMod(manifest: manifest("alice.c", deps: [("alice.a", "1.0.0")])),
        ])
        XCTAssertEqual(three.filter { $0.code == .dependencyCycle }.count, 1)
        let conflict = ModInstallSetValidator.validate([InstalledMod(manifest: manifest("alice.a", conflicts: ["alice.b"])), InstalledMod(manifest: manifest("alice.b"))])
        assertDiag(conflict, .installedConflict)
        assertDiag(ModInstallSetValidator.validate([InstalledMod(manifest: manifest("alice.a", deps: [("alice.zzz", "1.0.0")]))]), .dependencyUnsatisfied)
        assertDiag(ModInstallSetValidator.validate([InstalledMod(manifest: manifest("alice.a", deps: [("alice.b", "1.0.0")])), InstalledMod(manifest: manifest("alice.b", version: "1.1.0"))]), .dependencyUnsatisfied)
        let hash = ModInstallSetValidator.validate([InstalledMod(manifest: manifest("alice.a", deps: [("alice.b", "1.0.0")])), InstalledMod(manifest: manifest("alice.b"), archiveSHA256: String(repeating: "d", count: 64))])
        assertDiag(hash, .dependencyUnsatisfied, pointer: "/dependencies/0/sha256")
        let ok = ModInstallSetValidator.validate([InstalledMod(manifest: manifest("alice.a", deps: [("alice.b", "1.0.0")])), InstalledMod(manifest: manifest("alice.b"), archiveSHA256: String(repeating: "c", count: 64))])
        XCTAssertEqual(ok, [])
    }
}
