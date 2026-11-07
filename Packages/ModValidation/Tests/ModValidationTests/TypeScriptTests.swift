import XCTest
import ModKit
@testable import ModValidation

final class TypeScriptValidationTests: XCTestCase {
    func columnMod(_ script: String, language: ScaffoldLanguage = .ts, edit: ((inout [String: Any]) -> Void)? = nil) -> URL {
        let path = language == .ts ? "scripts/main.ts" : "scripts/main.js"
        let dir = Support.scaffold(.column, language, overrides: [path: script])
        if let edit { Support.manifest(dir, edit: edit) }
        return dir
    }

    func testTypeErrorBecomesBFCodeWithPosition() async {
        let dir = columnMod("""
        import { media } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          const n: number = "oops";
          return await media.imageDimensions(input.items);
        };
        """)
        let r = await Support.run(.directory(dir))
        let d = r.receipt.diagnostics.first { $0.message.contains("TS2322") }
        XCTAssertEqual(d?.code, .tsTypeError)
        XCTAssertEqual(d?.severity, .error)
        XCTAssertEqual(d?.file, "scripts/main.ts")
        XCTAssertEqual(d?.line, 4)
        XCTAssertEqual(d?.column, 9)
        XCTAssertEqual(r.receipt[.types], .fail)
        XCTAssertEqual(r.receipt[.compile], .fail)
        XCTAssertFalse(r.receipt.staticOK)
    }

    func testWrongArgumentTypeToCatalogFunction() async {
        let dir = columnMod("""
        import { media } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          return await media.imageDimensions("not a list");
        };
        """)
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .tsTypeError, containing: "TS2345"))
    }

    func testUnknownCatalogFunctionAndSyntaxError() async {
        let dir = columnMod("""
        import { media } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          return await media.imageSize(input.items);
        };
        """)
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .unknownFunction, containing: "TS2339"), "\(r.receipt.diagnostics)")
        let broken = columnMod("export const x = ;")
        let r2 = await Support.run(.directory(broken))
        XCTAssertTrue(r2.receipt.diagnostics.contains { $0.code == .tsSyntaxError })
    }

    func testUndeclaredCallsAndRootsAreGrantMismatches() async {
        let dir = columnMod("""
        import { media, process, storage, fs } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          await storage.set("k", 1);
          await process.archive.create(input.items, input.items[0], "x", "zip");
          await fs.root("downloads");
          return await media.imageDimensions(input.items);
        };
        """)
        let r = await Support.run(.directory(dir))
        let messages = r.receipt.diagnostics.filter { $0.code == .missingGrant }.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("storage.set requires grant storage") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("process.archive.create requires grant process.exec") })
        XCTAssertTrue(messages.contains { $0.contains("fs.root requires grant fs.read") })
        XCTAssertTrue(messages.contains { $0.contains("scripts/main.ts:4:9") })
        XCTAssertTrue(Support.hasCode(r, .undeclaredRoot, containing: "downloads"))
        XCTAssertEqual(r.receipt[.grants], .fail)
        XCTAssertFalse(r.receipt.staticOK)
    }

    func testDeclaredGrantThatScriptNeverUsesWarns() async {
        let dir = columnMod("""
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          return input.items.map((item) => ({ handle: item.handle, text: item.name }));
        };
        """)
        let r = await Support.run(.directory(dir))
        let unused = r.receipt.diagnostics.first { $0.code == .unusedGrant }
        XCTAssertEqual(unused?.severity, .warning)
        XCTAssertTrue(r.receipt.staticOK, "\(r.receipt.diagnostics)")
    }

    func testGrantCheckCoversAliasesAndNamespaceImports() async {
        let aliased = columnMod("""
        import { media, storage as kv } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          await kv.get("a");
          return await media.imageDimensions(input.items);
        };
        """)
        let r1 = await Support.run(.directory(aliased))
        XCTAssertTrue(Support.hasCode(r1, .missingGrant, containing: "storage.get"))
        let star = columnMod("""
        import * as bf from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          await bf.storage.get("a");
          return await bf.media.imageDimensions(input.items);
        };
        """)
        let r2 = await Support.run(.directory(star))
        XCTAssertTrue(Support.hasCode(r2, .missingGrant, containing: "storage.get"))
        XCTAssertFalse(Support.hasCode(r2, .missingGrant, containing: "media.imageDimensions"))
    }

    func testNamespaceUsedAsValueCannotBeAnalysed() async {
        let dir = columnMod("""
        import { media, storage } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        const hidden = storage;
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          await hidden.get("a");
          return await media.imageDimensions(input.items);
        };
        """)
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .dynamicCatalogAccess, containing: "used as a value"))
        XCTAssertEqual(r.receipt[.lint], .fail)
        let computed = columnMod("""
        import { media, storage } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const columnValues: ColumnValuesHandler = async (context, input) => {
          const key = "get";
          await storage[key]("a");
          return await media.imageDimensions(input.items);
        };
        """)
        let r2 = await Support.run(.directory(computed))
        XCTAssertTrue(Support.hasCode(r2, .dynamicCatalogAccess, containing: "computed property access"))
    }

    func testForbiddenConstructsImportsAndSuppressions() async {
        let cases: [(String, ModDiagnosticCode, String)] = [
            ("eval('1');", .scriptPolicyViolation, "Forbidden identifier: eval"),
            ("const f = new Function('return 1');", .scriptPolicyViolation, "Forbidden identifier: Function"),
            ("// @ts-ignore\nconst x: number = 'a';", .scriptPolicyViolation, "suppression"),
            ("import x from '../../escape';\nexport { x };", .scriptPolicyViolation, "policy 90003"),
            ("import x from 'left-pad';\nexport { x };", .scriptPolicyViolation, "policy 90003"),
            ("globalThis.x = 1;", .scriptPolicyViolation, "globalThis"),
        ]
        for (source, code, text) in cases {
            let body = """
            import { media } from "betterfinder";
            import type { ColumnValuesHandler } from "betterfinder";
            \(source)
            export const columnValues: ColumnValuesHandler = async (context, input) => {
              return await media.imageDimensions(input.items);
            };
            """
            let r = await Support.run(.directory(columnMod(body)))
            XCTAssertTrue(Support.hasCode(r, code, containing: text), "\(source): \(r.receipt.diagnostics)")
            XCTAssertEqual(r.receipt[.lint], .fail, source)
            XCTAssertFalse(r.receipt.staticOK, source)
        }
    }

    func testMissingHandlerExportAndWrongHandlerSignature() async {
        let missing = columnMod("export const other = 1;")
        let r1 = await Support.run(.directory(missing))
        let d = r1.receipt.diagnostics.filter { $0.code == .missingHandlerFunction }
        XCTAssertEqual(d.count, 1, "\(r1.receipt.diagnostics)")
        XCTAssertEqual(d.first?.pointer, "/hooks/0/handler")
        XCTAssertEqual(d.first?.file, "manifest.json")
        let wrong = columnMod("""
        export const columnValues = async (context: unknown, input: { nope: number }): Promise<string> => "x";
        """)
        let r2 = await Support.run(.directory(wrong))
        let mismatch = r2.receipt.diagnostics.first { $0.code == .handlerHookMismatch }
        XCTAssertEqual(mismatch?.pointer, "/hooks/0/handler")
        XCTAssertTrue(mismatch?.message.contains("column.values") == true)
    }

    func testTwoHandlersForTheSameHookAreEachChecked() async {
        let script = """
        import { media } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        export const first: ColumnValuesHandler = async (context, input) => media.imageDimensions(input.items);
        export const second: ColumnValuesHandler = async (context, input) => media.imageDimensions(input.items);
        """
        func mod(second: String) -> URL {
            columnMod(script.replacingOccurrences(of: "export const second: ColumnValuesHandler = async (context, input) => media.imageDimensions(input.items);", with: second)) { m in
                m["hooks"] = [
                    ["name": "column.values", "handler": "first", "version": 1],
                    ["name": "column.values", "handler": "second", "version": 1],
                ]
                m["contributes"] = ["columns": [
                    ["id": "a", "title": "A", "valueType": "string", "handler": "first"],
                    ["id": "b", "title": "B", "valueType": "string", "handler": "second"],
                ]]
            }
        }
        let good = await Support.run(.directory(mod(second: "export const second: ColumnValuesHandler = async (context, input) => media.imageDimensions(input.items);")))
        XCTAssertTrue(good.receipt.staticOK, "\(good.receipt.diagnostics)")
        let bad = await Support.run(.directory(mod(second: "export const second = async (context: unknown, input: number): Promise<number> => 1;")))
        let mismatch = bad.receipt.diagnostics.first { $0.code == .handlerHookMismatch }
        XCTAssertEqual(mismatch?.pointer, "/hooks/1/handler", "\(bad.receipt.diagnostics)")
        let absent = await Support.run(.directory(mod(second: "export const nothing = 1;")))
        XCTAssertEqual(absent.receipt.diagnostics.first { $0.code == .missingHandlerFunction }?.pointer, "/hooks/1/handler")
    }

    func testJavaScriptModsAreCheckedLikeTypeScript() async {
        let dir = columnMod("""
        import { media } from "betterfinder";

        /** @type {import("betterfinder").ColumnValuesHandler} */
        export const columnValues = async (context, input) => {
          return await media.imageDimensions(5);
        };
        """, language: .js)
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .tsTypeError, containing: "TS2345"))
        XCTAssertEqual(r.receipt.diagnostics.first { $0.code == .tsTypeError }?.file, "scripts/main.js")
    }

    func testTypeScriptSourceInJavaScriptModIsRejected() async {
        let dir = Support.scaffold(.column, .js, overrides: ["scripts/helper.ts": "export const x = 1;"])
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .forbiddenFileType, containing: "policy 90001"))
    }

    func testRelativeImportsBundleAndAnalyseHelperFiles() async {
        let dir = Support.scaffold(.column, .ts, overrides: [
            "scripts/main.ts": """
            import { media } from "betterfinder";
            import type { ColumnValuesHandler } from "betterfinder";
            import { touch } from "./lib/helper.js";
            export const columnValues: ColumnValuesHandler = async (context, input) => {
              await touch();
              return await media.imageDimensions(input.items);
            };
            """,
            "scripts/lib/helper.ts": """
            import { storage } from "betterfinder";
            export const touch = async (): Promise<void> => { await storage.set("a", 1); };
            """,
        ])
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .missingGrant, containing: "storage.set"), "\(r.receipt.diagnostics)")
        XCTAssertTrue(Support.hasCode(r, .missingGrant, containing: "scripts/lib/helper.ts:2"))
    }

    func testDeclarationFilesInPackageWarnButAreIgnored() async {
        let dir = Support.scaffold(.column, .ts, overrides: ["scripts/extra.d.ts": "declare const x: number;"])
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(r.receipt.diagnostics.contains { $0.severity == .warning && $0.file == "scripts/extra.d.ts" })
        XCTAssertTrue(r.receipt.staticOK)
    }

    func testManifestRuntimeEntryMismatchDoesNotRunTheCompiler() async {
        let dir = Support.scaffold(.column, .ts)
        Support.manifest(dir) { $0["entry"] = "scripts/missing.ts" }
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .pathMissing))
        XCTAssertEqual(r.receipt[.types], .notRun)
    }

    func testScriptSizeLimit() async {
        let big = "export const x = 1;\n" + String(repeating: "// padding padding padding padding padding\n", count: 30_000)
        let dir = Support.scaffold(.column, .ts, overrides: ["scripts/big.ts": big])
        let r = await Support.run(.directory(dir))
        XCTAssertTrue(Support.hasCode(r, .scriptSizeLimit))
    }

    func testTypeScriptDiagnosticsSortDeterministically() async {
        let dir = columnMod("""
        import { media } from "betterfinder";
        import type { ColumnValuesHandler } from "betterfinder";
        const b: number = "b";
        const a: number = "a";
        export const columnValues: ColumnValuesHandler = async (context, input) => media.imageDimensions(input.items);
        """)
        let r1 = await Support.run(.directory(dir))
        let r2 = await Support.run(.directory(dir))
        XCTAssertEqual(r1.receipt.diagnostics, r2.receipt.diagnostics)
        let lines = r1.receipt.diagnostics.compactMap(\.line)
        XCTAssertEqual(lines, lines.sorted())
    }
}
