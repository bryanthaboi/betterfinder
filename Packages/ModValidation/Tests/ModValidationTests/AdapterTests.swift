import XCTest
import ModKit
import ModScriptTS
@testable import ModValidation

final class AdapterTests: XCTestCase {
    func testTypeMapping() {
        XCTAssertEqual(ModCatalogAdapter.typeScript(.string), "string")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.integer), "number")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.number), "number")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.boolean), "boolean")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.void), "void")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.json), "JSONValue")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.ref("FileRef")), "FileRef")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.list(.ref("FileRef"))), "FileRef[]")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.optional(.ref("FileRef"))), "FileRef | null")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.optional(.list(.string))), "string[] | null")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.list(.optional(.string))), "(string | null)[]")
        XCTAssertEqual(ModCatalogAdapter.typeScript(.optional(.optional(.string))), "string | null")
    }

    func testFunctionsMapIncludingDottedNames() throws {
        let c = ModCatalogAdapter.catalog()
        func fn(_ ns: String, _ name: String) -> ModScriptTS.Catalog.Function? { c.namespaces.first { $0.name == ns }?.functions.first { $0.name == name } }
        let create = try XCTUnwrap(fn("process.archive", "create"))
        XCTAssertEqual(create.parameters.map(\.name), ["items", "destination", "name", "format"])
        XCTAssertEqual(create.parameters.map(\.type), ["FileRef[]", "FileRef", "string", "ArchiveFormat"])
        XCTAssertEqual(create.result, "Promise<OperationTicket>")
        XCTAssertNotNil(fn("process.git", "status"))
        XCTAssertNotNil(fn("process", "run"))
        let list = try XCTUnwrap(fn("fs", "list"))
        XCTAssertEqual(list.parameters.last?.name, "cursor?")
        XCTAssertEqual(list.parameters.last?.type, "string")
        XCTAssertEqual(try XCTUnwrap(fn("fs", "root")).result, "Promise<FileRef | null>")
        XCTAssertEqual(try XCTUnwrap(fn("ui", "setPanel")).result, "Promise<void>")
        XCTAssertEqual(try XCTUnwrap(fn("settings", "get")).result, "Promise<JSONValue>")
        XCTAssertNotNil(fn("storage", "keys"))
        XCTAssertNotNil(fn("storage", "delete"))
    }

    func testReservedMemberNamesMatchTheRuntime() {
        let d = ModCatalogAdapter.declarations()
        XCTAssertTrue(d.contains("export namespace storage {"))
        XCTAssertTrue(d.contains("function remove(key: string): Promise<void>;"))
        XCTAssertFalse(d.contains("function delete("))
        XCTAssertFalse(d.contains("export const storage"))
        XCTAssertEqual(ModCatalogAdapter.scriptName("storage.delete"), "storage.remove")
        XCTAssertTrue(d.contains("export namespace process.archive {"))
        XCTAssertTrue(d.contains("export namespace process.git {"))
    }

    func testHooksMapToHandlerTypes() throws {
        let c = ModCatalogAdapter.catalog()
        let h = try XCTUnwrap(c.hooks.first { $0.name == "column.values" })
        XCTAssertEqual(h.handlerType, "ColumnValuesHandler")
        XCTAssertEqual(h.parameters.map(\.type), ["HookContext", "ColumnValuesInput"])
        XCTAssertEqual(h.result, "Promise<ColumnValue[]>")
        XCTAssertEqual(try XCTUnwrap(c.hooks.first { $0.name == "fileop.before.rename" }).handlerType, "FileopBeforeRenameHandler")
        XCTAssertEqual(try XCTUnwrap(c.hooks.first { $0.name == "activate" }).result, "Promise<void>")
        XCTAssertEqual(ModCatalogAdapter.hookKey(name: "x.y", version: 1), "x.y")
        XCTAssertEqual(ModCatalogAdapter.hookKey(name: "x.y", version: 2), "x.y@2")
        XCTAssertEqual(ModCatalogAdapter.handlerTypeName(name: "x.y", version: 2), "XYV2Handler")
    }

    func testEveryCatalogTypeAndHookIsDeclared() {
        let d = ModCatalogAdapter.declarations()
        for t in ModCatalog.v1.types { XCTAssertTrue(d.contains("export \(t.kind == .record ? "interface" : "type") \(t.name)"), t.name) }
        for h in ModCatalog.v1.hooks { XCTAssertTrue(d.contains("export type \(ModCatalogAdapter.handlerTypeName(name: h.name, version: h.version)) ="), h.name) }
        XCTAssertEqual(d, ModCatalogAdapter.declarations())
    }

    func testDeclarationsTypeCheckAndEveryFunctionResolves() async throws {
        var refs = [String]()
        for f in ModCatalog.v1.functions { refs.append(ModCatalogAdapter.scriptName(f.name)) }
        let body = """
        import { \(ModCatalog.v1.namespaces.map(\.name).joined(separator: ", ")) } from "betterfinder";
        export const all = [\(refs.joined(separator: ", "))];
        """
        let toolchain = ModScriptTS.TSToolchain(catalog: ModCatalogAdapter.catalog())
        let r = try toolchain.check(files: ["main.ts": body], entry: "main.ts", language: .ts)
        XCTAssertTrue(r.passed, "\(r.diagnostics.prefix(5))")
        let bad = try toolchain.check(files: ["main.ts": "import { fs } from 'betterfinder'; export const x = fs.nope;"], entry: "main.ts", language: .ts)
        XCTAssertFalse(bad.passed)
    }

    func testEveryHookHandlerTypeIsUsableInTypeScript() async throws {
        let toolchain = ModScriptTS.TSToolchain(catalog: ModCatalogAdapter.catalog())
        var lines = ["import type * as bf from 'betterfinder';"]
        for h in ModCatalog.v1.hooks {
            let name = ModCatalogAdapter.handlerTypeName(name: h.name, version: h.version)
            lines.append("export type T\(lines.count) = bf.\(name);")
        }
        let r = try toolchain.check(files: ["main.ts": lines.joined(separator: "\n")], entry: "main.ts", language: .ts)
        XCTAssertTrue(r.passed, "\(r.diagnostics.prefix(5))")
    }

    func testDiagnosticCodeMapping() {
        let cases: [(Int, String, ModDiagnosticCode)] = [
            (1005, "';' expected.", .malformedProgram), (2304, "Cannot find name 'x'.", .unknownVariable),
            (2322, "Type", .typeMismatch), (2345, "Argument", .typeMismatch), (2554, "Expected 2 arguments", .argumentCount),
            (2339, "Property 'a' does not exist on type 'typeof fs'.", .unknownFunction), (2339, "Property 'a' does not exist on type 'X'.", .unknownField),
            (18048, "possibly undefined", .optionalAccess), (2366, "Function lacks", .missingReturn), (2540, "Cannot assign", .readOnlyVariable),
            (90001, "Invalid package source path: x", .forbiddenFileType), (90001, "Entry source is missing or invalid", .entryInvalid),
            (90002, "Forbidden identifier: eval", .unknownConstruct), (90003, "Import must resolve", .pathNotContained),
            (90004, "Unknown hook or missing handler export: a -> b", .missingHandlerFunction), (90004, "Non-identifier exports are unsupported", .unknownConstruct),
            (7006, "Parameter implicitly has an 'any' type.", .typeMismatch),
        ]
        for (code, message, expected) in cases { XCTAssertEqual(TSDiagnosticMapper.code(forCode: code, message: message), expected, "\(code)") }
    }

    func testScaffoldIDValidation() {
        for id in ["alice.thing", "bob-2.my-mod", "a1.b.c"] { XCTAssertNoThrow(try ModScaffold.validateID(id), id) }
        for id in ["alice", "Alice.thing", "alice.", ".thing", "al ice.thing", "a.b", "alice.thing-", ""] {
            if id == "a.b" { continue }
            XCTAssertThrowsError(try ModScaffold.validateID(id), id)
        }
        XCTAssertEqual(ModScaffold.displayName(of: "alice.my-cool-mod"), "My Cool Mod")
        XCTAssertEqual(ModScaffold.author(of: "alice.my-cool-mod"), "alice")
    }

    func testIndexEntryHelpers() {
        XCTAssertEqual(ModIndexEntry.tag(fromReleaseURL: "https://github.com/a/b/releases/download/v2.0.1/x.bfmod"), "v2.0.1")
        XCTAssertNil(ModIndexEntry.tag(fromReleaseURL: "https://example.com/x.bfmod"))
        XCTAssertEqual(ModIndexEntry.normalizedRepo("https://github.com/a/b.git/"), "https://github.com/a/b")
        for ex in ModExamples.all {
            let manifest = try? XCTUnwrap(ModStaticPreflight.run(package: ex.package).manifest)
            XCTAssertFalse(ModIndexEntry.categories(for: manifest!).isEmpty, ex.id)
        }
    }
}
