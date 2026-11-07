import XCTest
@testable import ModScriptTS

final class RegressionToolchainLifetimeTests: XCTestCase {
    let catalog = Catalog(
        namespaces: [.init("fs", functions: [.init("stat", parameters: [.init("item", "string")], result: "Promise<number>")])],
        hooks: [.init("command.run", handlerType: "CommandRunHandler", parameters: [.init("context", "ModContext"), .init("input", "Input")], result: "Promise<Result> | Result")],
        types: ["  export interface Input { commandId: string }", "  export interface Result { message?: string }"]
    )

    let source = "import { fs } from 'betterfinder'; export async function run() { return { message: String(await fs.stat('a')) }; }"

    func testCompileClearsRequestGlobals() throws {
        let t = TSToolchain(catalog: catalog)
        let r = try t.check(files: ["main.ts": source], entry: "main.ts", language: .ts)
        XCTAssertTrue(r.passed, "\(r.diagnostics)")
        XCTAssertTrue(t.isLoaded)
        XCTAssertEqual(t.definedRequestGlobals, [])
        let bad = try t.check(files: ["main.ts": "export const x: number = 'y';"], entry: "main.ts", language: .ts)
        XCTAssertFalse(bad.passed)
        XCTAssertEqual(t.definedRequestGlobals, [])
    }

    func testUnloadReleasesContextAndReloadsOnDemand() throws {
        let t = TSToolchain(catalog: catalog)
        let first = try t.transpile(files: ["main.ts": source], entry: "main.ts", language: .ts)
        let version = try t.toolchainVersion
        t.unload()
        XCTAssertFalse(t.isLoaded)
        XCTAssertEqual(try t.toolchainVersion, version)
        XCTAssertFalse(t.isLoaded)
        let second = try t.transpile(files: ["main.ts": source], entry: "main.ts", language: .ts)
        XCTAssertTrue(t.isLoaded)
        XCTAssertEqual(first, second)
    }

    func testUnloadIfIdleRespectsCondition() throws {
        let t = TSToolchain(catalog: catalog)
        _ = try t.check(files: ["main.ts": source], entry: "main.ts", language: .ts)
        XCTAssertFalse(t.unloadIfIdle { false })
        XCTAssertTrue(t.isLoaded)
        XCTAssertTrue(t.unloadIfIdle { true })
        XCTAssertFalse(t.isLoaded)
        XCTAssertFalse(t.unloadIfIdle { true })
    }
}
