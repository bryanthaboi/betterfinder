import XCTest
@testable import ModScriptTS

final class AnalysisTests: XCTestCase {
    let catalog = Catalog(
        namespaces: [
            .init("fs", functions: [
                .init("root", parameters: [.init("rootId", "string")], result: "Promise<FileRef | null>"),
                .init("stat", parameters: [.init("item", "FileRef")], result: "Promise<number>"),
            ]),
            .init("storage", functions: [
                .init("get", parameters: [.init("key", "string")], result: "Promise<string | null>"),
                .init("delete", parameters: [.init("key", "string"), .init("default", "string")], result: "Promise<void>"),
            ]),
            .init("process.archive", functions: [
                .init("create", parameters: [.init("items", "FileRef[]")], result: "Promise<string>"),
            ]),
        ],
        hooks: [.init("command.run", handlerType: "CommandRunHandler", parameters: [.init("context", "ModContext"), .init("input", "Input")], result: "Promise<Result> | Result")],
        types: [
            "  export interface FileRef { handle: string; size: number }",
            "  export interface Input { commandId: string }",
            "  export interface Result { message?: string }",
        ]
    )

    func analyze(_ source: String, files extra: [String: String] = [:]) throws -> TSResult {
        var files = extra
        files["main.ts"] = source
        return try TSToolchain(catalog: catalog).check(files: files, entry: "main.ts", language: .ts)
    }

    func testTypesBlockDeclaresSharedTypes() throws {
        let result = try analyze("import { fs, FileRef } from 'betterfinder'; export async function f(): Promise<FileRef | null> { return fs.root('docs'); }")
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        let bad = try analyze("import { FileRef } from 'betterfinder'; export const x: FileRef = { handle: 1, size: 2 };")
        XCTAssertFalse(bad.passed)
    }

    func testDeclarationsWithTypesAndReservedNames() {
        let text = DeclarationGenerator.generate(catalog)
        XCTAssertTrue(text.contains("  export interface FileRef { handle: string; size: number }"))
        XCTAssertTrue(text.contains("function remove(key: string, default_: string): Promise<void>;"))
        XCTAssertFalse(text.contains("function delete"))
        XCTAssertTrue(text.contains("export namespace process.archive {"))
        let reservedNamespace = Catalog(namespaces: [.init("class.delete", functions: [.init("new", parameters: [], result: "void")])], hooks: [])
        XCTAssertTrue(DeclarationGenerator.generate(reservedNamespace).contains("export namespace class_.remove_") == false)
        XCTAssertTrue(DeclarationGenerator.generate(reservedNamespace).contains("export namespace class_.delete_ {"))
        XCTAssertTrue(DeclarationGenerator.generate(reservedNamespace).contains("function new_(): void;"))
    }

    func testReservedMemberRoundTripsThroughTypeCheck() throws {
        let ok = try analyze("import { storage } from 'betterfinder'; export const run = async () => { await storage.remove('k', 'd'); };")
        XCTAssertTrue(ok.passed, "\(ok.diagnostics)")
        XCTAssertEqual(ok.calls.map(\.name), ["storage.remove"])
        XCTAssertEqual(ok.calls.map(\.catalogName), ["storage.delete"])
        let bad = try analyze("import { storage } from 'betterfinder'; export const run = async () => { await storage.delete('k', 'd'); };")
        XCTAssertFalse(bad.passed)
        XCTAssertTrue(TSReservedNames.scriptName("delete") == "remove")
        XCTAssertEqual(TSReservedNames.scriptName("default"), "default_")
        XCTAssertEqual(TSReservedNames.scriptName("get"), "get")
        XCTAssertEqual(TSReservedNames.scriptPath("storage.delete"), "storage.remove")
    }

    func testCallAnalysisCollectsDottedCallsWithPositions() throws {
        let source = """
        import { fs, storage, process } from 'betterfinder';
        export async function run(): Promise<void> {
          const a = await fs.root('docs');
          if (a) {
            await fs.stat(a);
            const g = async () => storage.get('x');
            await g();
          }
          await process.archive.create([]);
        }
        """
        let result = try analyze(source)
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        XCTAssertEqual(result.escapes, [])
        XCTAssertEqual(result.calls.map(\.name), ["fs.root", "fs.stat", "storage.get", "process.archive.create"])
        XCTAssertEqual(result.calls.map(\.line), [3, 5, 6, 9])
        XCTAssertEqual(result.calls[0].col, 19)
        XCTAssertEqual(result.calls[0].file, "main.ts")
        XCTAssertEqual(result.catalogCallNames, ["fs.root", "fs.stat", "process.archive.create", "storage.get"])
        XCTAssertEqual(result.literalRootIDs, ["docs"])
        XCTAssertEqual(result.rootSites["docs"], "main.ts:3:27")
        XCTAssertEqual(result.callSites["fs.root"], "main.ts:3:19")
        XCTAssertFalse(result.hasDynamicRoot)
    }

    func testAliasesNamespaceImportsAndCrossFileCalls() throws {
        let main = """
        import * as bf from 'betterfinder';
        import { fs as files } from 'betterfinder';
        import { helper } from './helper';
        export async function run(): Promise<void> {
          await bf.fs.root('one');
          await files.root('two');
          await helper();
        }
        """
        let helper = "import { storage } from 'betterfinder'; export const helper = async (): Promise<void> => { await storage.get('k'); };"
        let result = try analyze(main, files: ["helper.ts": helper])
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        XCTAssertEqual(result.escapes, [])
        XCTAssertEqual(result.catalogCallNames, ["fs.root", "storage.get"])
        XCTAssertEqual(result.literalRootIDs, ["one", "two"])
        XCTAssertEqual(result.calls.filter { $0.file == "helper.ts" }.map(\.name), ["storage.get"])
    }

    func testDynamicRootArgumentIsFlagged() throws {
        let result = try analyze("import { fs } from 'betterfinder'; export async function run(id: string) { return fs.root(id); }")
        XCTAssertTrue(result.hasDynamicRoot)
        XCTAssertEqual(result.literalRootIDs, [])
        let template = try analyze("import { fs } from 'betterfinder'; export async function run() { return fs.root(`docs`); }")
        XCTAssertEqual(template.literalRootIDs, ["docs"])
    }

    func testEscapesAreReported() throws {
        let cases: [(String, String)] = [
            ("import { fs } from 'betterfinder'; const f = fs.root; export const run = () => f('x');", "used as a value"),
            ("import { fs } from 'betterfinder'; const { root } = fs; export const run = () => root('x');", "used as a value"),
            ("import { fs } from 'betterfinder'; export const run = (k: string) => fs['ro' + k]('x');", "computed"),
            ("import { fs } from 'betterfinder'; export { fs };", "re-export"),
            ("export * from 'betterfinder';", "re-exporting"),
            ("import { fs } from 'betterfinder'; export const run = () => [fs].length;", "used as a value"),
        ]
        for (source, reason) in cases {
            let result = try analyze(source)
            XCTAssertTrue(result.escapes.contains { $0.reason.contains(reason) }, "\(source) -> \(result.escapes)")
        }
        let clean = try analyze("import { fs, type FileRef } from 'betterfinder'; export const run = (x: FileRef) => fs.stat(x);")
        XCTAssertEqual(clean.escapes, [])
    }

    func testAnalysisIsDeterministicAndPresentEvenWithTypeErrors() throws {
        let source = "import { fs } from 'betterfinder'; export const a: number = 'x'; export const run = () => fs.root('docs');"
        let first = try analyze(source)
        XCTAssertFalse(first.passed)
        XCTAssertEqual(first.catalogCallNames, ["fs.root"])
        XCTAssertEqual(first, try analyze(source))
        let transpiled = try TSToolchain(catalog: catalog).transpile(files: ["main.ts": "import { fs } from 'betterfinder'; export const run = () => fs.root('docs');"], entry: "main.ts", language: .ts)
        XCTAssertTrue(transpiled.passed)
        XCTAssertEqual(transpiled.catalogCallNames, ["fs.root"])
    }

    func testJSLanguageAnalysis() throws {
        let result = try TSToolchain(catalog: catalog).check(files: ["main.js": "import { fs } from 'betterfinder'; export async function run() { return fs.root('docs'); }"], entry: "main.js", language: .js)
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        XCTAssertEqual(result.literalRootIDs, ["docs"])
    }

    func testPublicInitializersAndBackwardsCompatibleDecoding() throws {
        let d = TSDiagnostic(code: 2322, file: "a.ts", line: 1, col: 2, message: "m", category: .error)
        XCTAssertEqual(d, TSDiagnostic(code: 2322, file: "a.ts", line: 1, col: 2, message: "m"))
        let ok = TSResult(diagnostics: [])
        XCTAssertTrue(ok.passed)
        XCTAssertFalse(TSResult(diagnostics: [d]).passed)
        XCTAssertTrue(TSResult(diagnostics: [TSDiagnostic(code: 1, message: "w", category: .warning)]).passed)
        let legacy = #"{"diagnostics":[],"handlerExports":{"a":"b"},"moduleSource":null,"executionSource":null}"#
        let decoded = try JSONDecoder().decode(TSResult.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded, TSResult(diagnostics: [], handlerExports: ["a": "b"]))
        let legacyCatalog = #"{"namespaces":[],"hooks":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(Catalog.self, from: Data(legacyCatalog.utf8)), Catalog(namespaces: [], hooks: []))
        let roundTrip = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(roundTrip, catalog)
        let call = TSCatalogCall(name: "fs.root", file: "main.ts", line: 1, col: 1)
        XCTAssertEqual(call.catalogName, "fs.root")
        XCTAssertEqual(call.site, "main.ts:1:1")
    }

    func testToolchainsCanBeDroppedRepeatedlyWithoutCrashing() throws {
        for i in 0..<6 {
            let toolchain = TSToolchain(catalog: catalog)
            if i % 2 == 0 { _ = try toolchain.check(files: ["main.ts": "export {};"], entry: "main.ts", language: .ts) }
        }
        weak var weakToolchain: TSToolchain?
        try autoreleasepool {
            let toolchain = TSToolchain(catalog: catalog)
            weakToolchain = toolchain
            _ = try toolchain.toolchainVersion
        }
        XCTAssertNil(weakToolchain)
    }

    func testFieldsOfCatalogTypesAreNotEscapes() throws {
        let result = try analyze("""
        import { fs } from 'betterfinder';
        export async function f(): Promise<number> {
            const ref = await fs.root('docs');
            if (ref === null) return 0;
            const size = ref.size;
            const { handle } = ref;
            return [ref].map(r => r.size).length + size + handle.length;
        }
        """)
        XCTAssertTrue(result.escapes.isEmpty, "\(result.escapes)")
        XCTAssertEqual(result.catalogCallNames, ["fs.root"])
    }
}
