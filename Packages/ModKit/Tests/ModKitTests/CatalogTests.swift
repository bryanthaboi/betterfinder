import XCTest
@testable import ModKit

final class CatalogTests: XCTestCase {
    let catalog = ModCatalog.v1

    func testJSONRoundTrip() throws {
        let data = catalog.jsonData
        let decoded = try ModCatalog.decode(jsonData: data)
        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(decoded.jsonData, data)
        XCTAssertEqual(decoded.digest, catalog.digest)
        XCTAssertEqual(decoded.function(named: "fs.readText"), catalog.function(named: "fs.readText"))
        XCTAssertEqual(decoded.hook(signature: "column.values@1"), catalog.hook(signature: "column.values@1"))
        let json = try JSONValue.parse(data)
        XCTAssertEqual(json["catalogVersion"], .string(ModKitVersion.api))
        XCTAssertNotNil(json["functions"]?.arrayValue)
    }

    func testJSONIsDeterministic() {
        XCTAssertEqual(ModCatalog.v1.jsonData, ModCatalog.v1.jsonData)
        XCTAssertEqual(catalog.digest.count, 64)
    }

    func testEveryBridgeNamespaceHasFunctions() {
        let required = ["ui", "commands", "fs", "operations", "search", "locations", "preview", "media", "net", "process", "settings", "storage", "credentials", "events", "log"]
        XCTAssertEqual(catalog.namespaces.map(\.name), required)
        for ns in required { XCTAssertFalse(catalog.functions(in: ns).isEmpty, ns) }
        for f in catalog.functions { XCTAssertTrue(required.contains(f.namespace), f.name) }
    }

    func testEveryPlanHookIsCatalogued() {
        let required = ["activate", "deactivate", "selection.changed", "location.changed", "theme.changed", "settings.changed", "command.run",
                        "column.values", "search.query", "preview.render", "location.list",
                        "fileop.before.copy", "fileop.before.move", "fileop.before.trash", "fileop.before.rename",
                        "fileop.after.copy", "fileop.after.move", "fileop.after.trash", "fileop.after.rename"]
        XCTAssertEqual(Set(catalog.hookNames), Set(required))
        for h in catalog.hooks {
            XCTAssertEqual(h.version, 1)
            XCTAssertGreaterThan(h.deadlineMs, 0)
        }
    }

    func testFileOpHooksRequireScopedGrants() {
        for op in FileOperationName.allCases {
            XCTAssertEqual(catalog.hook(named: "fileop.before.\(op.rawValue)", version: 1)?.requires, [GrantRequirement(.operationsIntercept, fileOperation: op)])
            XCTAssertEqual(catalog.hook(named: "fileop.after.\(op.rawValue)", version: 1)?.requires, [GrantRequirement(.operationsObserve, fileOperation: op)])
            XCTAssertEqual(catalog.hook(named: "fileop.before.\(op.rawValue)", version: 1)?.failure, .pause)
            XCTAssertEqual(catalog.hook(named: "fileop.after.\(op.rawValue)", version: 1)?.failure, .ignore)
        }
        XCTAssertEqual(catalog.hook(named: "selection.changed", version: 1)?.requires.first?.kind, .uiSelection)
    }

    func testAllTypeReferencesResolve() {
        func refs(_ t: ModTypeExpr) -> [String] {
            switch t {
            case .ref(let n): return [n]
            case .list(let i), .optional(let i): return refs(i)
            default: return []
            }
        }
        var used = [String]()
        for t in catalog.types {
            used += (t.fields ?? []).flatMap { refs($0.type) }
            used += t.aliasOf.map(refs) ?? []
        }
        for f in catalog.functions { used += f.params.flatMap { refs($0.type) } + refs(f.returns) }
        for h in catalog.hooks { used += refs(h.input) + refs(h.output) }
        for n in used { XCTAssertNotNil(catalog.type(named: n), "dangling type \(n)") }
        XCTAssertEqual(Set(catalog.types.map(\.name)).count, catalog.types.count)
        XCTAssertEqual(Set(catalog.functions.map(\.name)).count, catalog.functions.count)
    }

    func testEveryTypeIsReachable() {
        func refs(_ t: ModTypeExpr) -> [String] {
            switch t {
            case .ref(let n): return [n]
            case .list(let i), .optional(let i): return refs(i)
            default: return []
            }
        }
        var used = Set<String>(["HookContext"])
        var work = [String]()
        for f in catalog.functions { work += f.params.flatMap { refs($0.type) } + refs(f.returns) }
        for h in catalog.hooks { work += refs(h.input) + refs(h.output) }
        while let n = work.popLast() {
            guard used.insert(n).inserted, let def = catalog.type(named: n) else { continue }
            work += (def.fields ?? []).flatMap { refs($0.type) } + (def.aliasOf.map(refs) ?? [])
        }
        XCTAssertEqual(Set(catalog.types.map(\.name)).subtracting(used), [])
    }

    func testFunctionPoliciesAreComplete() {
        for f in catalog.functions {
            XCTAssertGreaterThan(f.deadlineMs, 0, f.name)
            XCTAssertFalse(f.summary.isEmpty, f.name)
            for (i, p) in f.params.enumerated() where p.optional {
                XCTAssertTrue(f.params[(i + 1)...].allSatisfy(\.optional), "\(f.name): optional params must trail")
            }
            for r in f.requires {
                if let op = r.brokerOperation { XCTAssertNotNil(catalog.brokerOperation(named: op), f.name) }
            }
        }
        XCTAssertEqual(catalog.function(named: "process.archive.create")?.requires.contains(.broker("archive.create")), true)
        XCTAssertEqual(catalog.brokerOperation(named: "archive.create")?.function, "process.archive.create")
        for b in catalog.brokerOperations { XCTAssertNotNil(catalog.function(named: b.function)) }
        XCTAssertEqual(catalog.function(named: "process.run")?.gesture, true)
        XCTAssertEqual(catalog.function(named: "fs.readText")?.cancellable, true)
        XCTAssertEqual(catalog.function(named: "net.fetch")?.requires, [GrantRequirement(.net)])
    }

    func testPermissionsAndContributionsMirrorTheManifestTypes() {
        XCTAssertEqual(catalog.permissions.map(\.kind), ModPermissionKind.allCases)
        XCTAssertEqual(catalog.contributions.map(\.key), ModContributionKind.allCases.map(\.rawValue))
        for kind in ModContributionKind.allCases {
            if let hook = kind.hookName { XCTAssertFalse(catalog.hooks(named: hook).isEmpty, hook) }
        }
        XCTAssertEqual(catalog.diagnostics.count, ModDiagnosticCode.allCases.count)
    }

    func testMarkdownReferenceListsEverything() {
        let md = catalog.markdownReference()
        XCTAssertEqual(md, ModCatalog.markdownReference())
        for f in catalog.functions { XCTAssertTrue(md.contains("`\(f.name)`"), f.name) }
        for h in catalog.hooks { XCTAssertTrue(md.contains("`\(h.signatureID)`"), h.signatureID) }
        for t in catalog.types { XCTAssertTrue(md.contains("### `\(t.name)`"), t.name) }
        for c in ModDiagnosticCode.allCases { XCTAssertTrue(md.contains("`\(c.rawValue)`"), c.rawValue) }
        for p in ModPermissionKind.allCases { XCTAssertTrue(md.contains("`\(p.rawValue)`"), p.rawValue) }
        XCTAssertTrue(md.contains(catalog.digest))
        XCTAssertTrue(md.hasPrefix("# betterfinder mod API 1.0.0"))
    }

    func testTypeExprJSONSyntax() throws {
        let cases: [(String, ModTypeExpr)] = [
            ("\"string\"", .string), ("\"FileRef\"", .ref("FileRef")), ("{\"list\":\"FileRef\"}", .list(.ref("FileRef"))),
            ("{\"optional\":{\"list\":\"string\"}}", .optional(.list(.string))),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ModTypeExpr.parse(try JSONValue.parse(text)), expected)
            XCTAssertEqual(expected.jsonValue, try JSONValue.parse(text))
        }
        XCTAssertNil(ModTypeExpr.parse(try JSONValue.parse("{\"set\":\"string\"}")))
        XCTAssertNil(ModTypeExpr.parse(try JSONValue.parse("\"lowercaseRef\"")))
        XCTAssertEqual(ModTypeExpr.list(.optional(.string)).description, "(string?)[]")
        XCTAssertEqual(ModTypeExpr.optional(.list(.ref("A"))).description, "A[]?")
    }

    func testCatalogJSONExposesGeneratorFriendlyData() throws {
        let json = try JSONValue.parse(catalog.jsonData)
        let fn = json["functions"]?.arrayValue?.first { $0["name"] == "media.imageDimensions" }
        XCTAssertEqual(fn?["returns"], try JSONValue.parse("{\"list\":\"ColumnValue\"}"))
        XCTAssertEqual(fn?["requires"]?[0]?["kind"], "fs.read")
        XCTAssertEqual(fn?["params"]?[0]?["type"], try JSONValue.parse("{\"list\":\"FileRef\"}"))
        let hook = json["hooks"]?.arrayValue?.first { $0["name"] == "column.values" }
        XCTAssertEqual(hook?["input"], "ColumnValuesInput")
        XCTAssertEqual(hook?["failure"], "degrade")
        XCTAssertEqual(hook?["multiple"], true)
    }
}
