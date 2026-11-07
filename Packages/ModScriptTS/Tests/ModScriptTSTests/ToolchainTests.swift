import XCTest
import JavaScriptCore
@testable import ModScriptTS

final class ToolchainTests: XCTestCase {
    let catalog = Catalog(namespaces: [
        .init("math", functions: [.init("double", parameters: [.init("value", "number")], result: "number")])
    ], hooks: [.init("calculate", handlerType: "CalculateHandler", parameters: [.init("input", "number")], result: "number")])

    func testDeclarations() {
        XCTAssertEqual(DeclarationGenerator.generate(catalog), """
        declare module "betterfinder" {
          export interface ModContext { readonly modID: string; readonly generation: number; }
          export namespace math {
            function double(value: number): number;
          }
          export type CalculateHandler = (input: number) => number;
        }

        """)
    }

    func testCleanTSAndTiming() throws {
        let toolchain = TSToolchain(catalog: catalog)
        let result = try toolchain.check(files: ["main.ts": "import { math } from 'betterfinder'; export const run = (input: number): number => math.double(input);"], entry: "main.ts", language: .ts, handlers: ["calculate": "run"])
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        XCTAssertNil(result.moduleSource)
        let load = toolchain.firstLoadTime
        print("TS_BENCH version=\(try toolchain.toolchainVersion) firstLoadSeconds=\(load) checkSeconds=\(toolchain.lastCheckTime)")
        _ = try toolchain.check(files: ["main.ts": "export const x = 1;"], entry: "main.ts", language: .ts)
        XCTAssertEqual(toolchain.firstLoadTime, load)
    }

    func testTypeErrorsAndJS() throws {
        let toolchain = TSToolchain(catalog: catalog)
        for (language, path, source) in [
            (ScriptLanguage.ts, "main.ts", "import { math } from 'betterfinder'; export const n: number = math.double('bad');"),
            (.js, "main.js", "// @ts-check\nimport { math } from 'betterfinder'; export const n = math.double('bad');"),
            (.js, "main.js", "import { math } from 'betterfinder'; export const n = math.double('bad');"),
            (.ts, "main.ts", "export function run(input) { return input; }")
        ] {
            let result = try toolchain.transpile(files: [path: source], entry: path, language: language)
            XCTAssertFalse(result.passed, source)
            XCTAssertNil(result.moduleSource)
            XCTAssertNil(result.executionSource)
            XCTAssertTrue(result.diagnostics.contains { $0.code < 90000 }, source)
        }
    }

    func testPolicyCorpus() throws {
        let toolchain = TSToolchain(catalog: catalog)
        let sources = [
            "eval('1')", "const e = eval; e('1')", "Function('return 1')", "new Function('return 1')",
            "with ({}) {}", "import('./helper')", "require('fs')",
            "const obj: any = {}; obj.__proto__ = {};", "const obj: any = {}; obj.prototype = {};",
            "const obj: any = {}; obj['__proto__'] = {};", "const obj: any = {}; obj.constructor('x');",
            "await Promise.resolve(1);", "for await (const x of []) {}",
            "globalThis.math = {};", "Object.setPrototypeOf({}, {});", "Object.defineProperty({}, 'prototype', {});", "Object.assign(globalThis, {math: {}});",
            "import x from '../../x';", "import x from 'npm-package';",
            "export * from '../../escape';", "// @ts-nocheck\nconst x: number = 'bad';",
            "// @ts-ignore\nconst x: number = 'bad';"
        ]
        for source in sources {
            let result = try toolchain.transpile(files: ["main.ts": source + "\nexport {};", "helper.ts": "export const x = 1;"], entry: "main.ts", language: .ts)
            XCTAssertTrue(result.diagnostics.contains { $0.code >= 90000 }, source)
            XCTAssertNil(result.moduleSource, source)
        }
    }

    func testPathsAndHookValidation() throws {
        let toolchain = TSToolchain(catalog: catalog)
        for files in [["../main.ts": "export {};"], ["main.ts": "export {};", "/escape.ts": ""], ["__bf_hook_check.ts": "export {};", "main.ts": "export {};"]] {
            XCTAssertFalse(try toolchain.check(files: files, entry: "main.ts", language: .ts).passed)
        }
        let files = ["main.ts": "export const run = (value: string): string => value;"]
        for handlers in [["calculate": "missing"], ["unknown": "run"], ["calculate": "run"]] {
            let result = try toolchain.transpile(files: files, entry: "main.ts", language: .ts, handlers: handlers)
            XCTAssertFalse(result.passed)
            XCTAssertNil(result.moduleSource)
        }
    }

    func testBundleExecutionAndDeterminism() throws {
        let toolchain = TSToolchain(catalog: catalog)
        let files = [
            "main.ts": "import { plus } from './lib/helper.js'; import { math } from 'betterfinder'; export const run = (input: number): number => math.double(plus(input)); export default run;",
            "lib/helper.ts": "import { amount } from '../amount'; export const plus = (n: number): number => n + amount;",
            "amount.ts": "export const amount = 3;"
        ]
        let result = try toolchain.transpile(files: files, entry: "main.ts", language: .ts, handlers: ["calculate": "run"])
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        XCTAssertEqual(result.handlerExports, ["calculate": "run"])
        XCTAssertEqual(result, try toolchain.transpile(files: files, entry: "main.ts", language: .ts, handlers: ["calculate": "run"]))
        XCTAssertEqual(result, try TSToolchain(catalog: catalog).transpile(files: files, entry: "main.ts", language: .ts, handlers: ["calculate": "run"]))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("const __bf = {math:{double: n => n * 2}};")
        let expression = try XCTUnwrap(result.executionSource)
        XCTAssertEqual(js.evaluateScript("(\(expression)).run(4)")?.toInt32(), 14)
        XCTAssertNil(js.exception)
        XCTAssertTrue(try XCTUnwrap(result.moduleSource).contains("export { __bf_export"))
        let errors = ["main.ts": "export const n: number = 'bad'; eval('1');"]
        XCTAssertEqual(try toolchain.check(files: errors, entry: "main.ts", language: .ts), try toolchain.check(files: errors, entry: "main.ts", language: .ts))
    }

    func testPrebundledBareModuleAndJSBundle() throws {
        let toolchain = TSToolchain(catalog: catalog)
        let result = try toolchain.transpile(files: ["main.js": "import { value } from 'included'; export const run = () => value;", "included.js": "export const value = 7;"], entry: "main.js", language: .js)
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("const __bf = {};")
        XCTAssertEqual(js.evaluateScript("(\(try XCTUnwrap(result.executionSource))).run()")?.toInt32(), 7)
        XCTAssertNil(js.exception)
    }
    func testMJSAndReexports() throws {
        let toolchain = TSToolchain(catalog: catalog)
        let result = try toolchain.transpile(files: [
            "main.mjs": "export { run } from './helper.mjs';",
            "helper.mjs": "export const run = () => 12;"
        ], entry: "main.mjs", language: .js)
        XCTAssertTrue(result.passed, "\(result.diagnostics)")
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("const __bf = {};")
        XCTAssertEqual(js.evaluateScript("(\(try XCTUnwrap(result.executionSource))).run()")?.toInt32(), 12)
        XCTAssertNil(js.exception)
    }

    func testScriptFilesDoNotShareImplicitGlobals() throws {
        let result = try TSToolchain(catalog: catalog).check(files: [
            "main.ts": "const value = helper;", "helper.ts": "const helper = 12;"
        ], entry: "main.ts", language: .ts)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.diagnostics.contains { $0.code == 2304 })
    }

    func testConcurrentCallsReuseCompiler() throws {
        let toolchain = TSToolchain(catalog: catalog)
        let lock = NSLock()
        var results: [TSResult] = []
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            do {
                let result = try toolchain.check(files: ["main.ts": "export const value = 1;"], entry: "main.ts", language: .ts)
                lock.lock(); results.append(result); lock.unlock()
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.passed && $0 == results.first })
    }

}
