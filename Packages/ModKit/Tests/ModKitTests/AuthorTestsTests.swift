import XCTest
@testable import ModKit

final class AuthorTestsTests: XCTestCase {
    func manifest(runtime: String = "js/1") -> ModManifest {
        let base = Fixture.manifestJSON("image-dimensions")
        let edited = Fixture.mutate(base) {
            $0["runtime"] = .string(runtime)
            if runtime == "data/1" { $0["entry"] = nil }
            if runtime != "data/1" { $0["entry"] = .string(runtime == "ts/1" ? "main.ts" : "main.js") }
            $0["hooks"] = .array([
                ["name": "column.values", "handler": "dimensions", "version": 1],
                ["name": "command.run", "handler": "runA", "version": 1],
                ["name": "command.run", "handler": "runB", "version": 1],
            ])
        }
        guard case .success(let m) = ModDecoding.decode(ModManifest.self, from: edited) else { fatalError("manifest") }
        return m
    }

    func package(_ tests: [String: String]) -> ModPackage {
        var files = [String: Data]()
        for (k, v) in tests { files[k] = Data(v.utf8) }
        files["main.js"] = Data("export {}".utf8)
        return ModPackage(files: files)
    }

    let goodColumn = """
    {"hook":"column.values","input":{"column":"dimensions","items":[],"revision":1},"expect":{"equals":[]}}
    """

    func codes(_ tests: [String: String], runtime: String = "js/1") -> [String] {
        Fixture.codes(ModAuthorTests.validate(package: package(tests), manifest: manifest(runtime: runtime)))
    }

    func testValidTestsProduceCasesAndNoDiagnostics() {
        let tests = [
            "tests/a.bftest.json": goodColumn,
            "tests/b.bftest.json": """
            {"name":"msg","hook":"command.run","handler":"runA","input":{"commandId":"x","selection":[]},"expect":{"contains":{"message":"done"}}}
            """,
            "tests/c.bftest.json": """
            {"hook":"command.run","handler":"runB","input":{"commandId":"x","selection":[]},"expect":{"error":true}}
            """,
        ]
        let loaded = ModAuthorTests.load(package: package(tests), manifest: manifest())
        XCTAssertEqual(loaded.diagnostics, [])
        XCTAssertEqual(loaded.cases.map(\.path), ["tests/a.bftest.json", "tests/b.bftest.json", "tests/c.bftest.json"])
        XCTAssertEqual(loaded.cases.map(\.handler), ["dimensions", "runA", "runB"])
    }

    func testNonTestFilesAreIgnored() {
        XCTAssertEqual(codes(["tests/readme.json": "{", "tests/sub/x.bftest.json": "{", "x.bftest.json": "{"]), [])
        XCTAssertFalse(ModAuthorTests.isTestPath("tests/.bftest.json"))
        XCTAssertTrue(ModAuthorTests.isTestPath("tests/a.bftest.json"))
    }

    func testStructuralErrors() {
        XCTAssertEqual(codes(["tests/a.bftest.json": "{"]), ["BF1001"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","expect":{"equals":[]}}"#]), ["BF1003"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","input":{},"expect":{"equals":[]},"extra":1}"#]), ["BF1002"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","input":{},"expect":{}}"#]), ["BF1005"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","input":{},"expect":{"equals":1,"contains":1}}"#]), ["BF1005"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","input":{},"expect":{"nope":1}}"#]), ["BF1002"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","input":{},"expect":{"error":false}}"#]), ["BF1005"])
    }

    func testUnknownHookAndVersion() {
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"nope.hook","input":{},"expect":{"equals":1}}"#]), ["BF7005"])
        XCTAssertEqual(codes(["tests/a.bftest.json": #"{"hook":"column.values","version":9,"input":{},"expect":{"equals":1}}"#]), ["BF7006"])
    }

    func testHookMustBeBoundAndHandlerResolved() {
        let unbound = #"{"hook":"search.query","input":{"provider":"p","query":"q","limit":1},"expect":{"equals":{"results":[]}}}"#
        XCTAssertTrue(codes(["tests/a.bftest.json": unbound]).contains("BF7001"))
        let ambiguous = #"{"hook":"command.run","input":{"commandId":"x","selection":[]},"expect":{"error":true}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": ambiguous]), ["BF1005"])
        let wrong = #"{"hook":"command.run","handler":"zzz","input":{"commandId":"x","selection":[]},"expect":{"error":true}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": wrong]), ["BF7001"])
    }

    func testInputAndOutputTypesAreCheckedAgainstCatalog() {
        let badInput = #"{"hook":"column.values","input":{"column":1,"items":[],"revision":1},"expect":{"equals":[]}}"#
        let d = ModAuthorTests.validate(package: package(["tests/a.bftest.json": badInput]), manifest: manifest())
        XCTAssertEqual(Fixture.codes(d), ["BF2014"])
        XCTAssertEqual(d.first?.pointer, "/input/column")
        let missing = #"{"hook":"column.values","input":{"column":"c","items":[]},"expect":{"equals":[]}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": missing]), ["BF2014"])
        let badOutput = #"{"hook":"column.values","input":{"column":"c","items":[],"revision":1},"expect":{"equals":"text"}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": badOutput]), ["BF2014"])
        let unknownField = #"{"hook":"command.run","handler":"runA","input":{"commandId":"x","selection":[]},"expect":{"contains":{"bogus":1}}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": unknownField]), ["BF2014"])
        let okPartial = #"{"hook":"command.run","handler":"runA","input":{"commandId":"x","selection":[]},"expect":{"contains":{}}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": okPartial]), [])
    }

    func testMatchesNeedsStringOutputAndValidRegex() {
        let onList = #"{"hook":"column.values","input":{"column":"c","items":[],"revision":1},"expect":{"matches":"x"}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": onList]), ["BF2014"])
        let badRegex = #"{"hook":"command.run","handler":"runA","input":{"commandId":"x","selection":[]},"expect":{"matches":"("}}"#
        XCTAssertTrue(codes(["tests/a.bftest.json": badRegex]).contains("BF1005") || codes(["tests/a.bftest.json": badRegex]).contains("BF2014"))
    }

    func testDuplicateNamesAndSizeAndDataRuntime() {
        let named = #"{"name":"same","hook":"column.values","input":{"column":"c","items":[],"revision":1},"expect":{"equals":[]}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": named, "tests/b.bftest.json": named]), ["BF1011"])
        let huge = #"{"hook":"column.values","input":{"column":"\#(String(repeating: "x", count: 70_000))","items":[],"revision":1},"expect":{"equals":[]}}"#
        XCTAssertEqual(codes(["tests/a.bftest.json": huge]), ["BF1009"])
        XCTAssertEqual(codes(["tests/a.bftest.json": goodColumn], runtime: "data/1"), ["BF5012"])
    }

    func testStaticPreflightWiring() {
        let good = ModStaticPreflight.run(package: Fixture.package(manifest: Fixture.manifestJSON(), extra: ["tests/a.bftest.json": Data(goodColumn.utf8)]))
        XCTAssertFalse(good.receipt.diagnostics.contains { $0.file == "tests/a.bftest.json" })
        let bad = ModStaticPreflight.run(package: Fixture.package(manifest: Fixture.manifestJSON(), extra: ["tests/a.bftest.json": Data(#"{"hook":"nope","input":1,"expect":{"equals":1}}"#.utf8)]))
        XCTAssertEqual(bad.receipt[.manifest], .fail)
        XCTAssertTrue(bad.receipt.diagnostics.contains { $0.code == .unknownHook && $0.file == "tests/a.bftest.json" })
    }

    func testEvaluator() {
        typealias E = ModAuthorTestEvaluator
        XCTAssertTrue(E.evaluate(.equals(.int(1)), outcome: .value(.double(1.0))).passed)
        XCTAssertFalse(E.evaluate(.equals(.int(1)), outcome: .value(.int(2))).passed)
        XCTAssertTrue(E.evaluate(.equals(["a": [1, 2]]), outcome: .value(["a": [1, 2]])).passed)
        XCTAssertFalse(E.evaluate(.equals(["a": [1, 2]]), outcome: .value(["a": [2, 1]])).passed)
        XCTAssertTrue(E.evaluate(.contains(["a": 1]), outcome: .value(["a": 1, "b": 2])).passed)
        XCTAssertTrue(E.evaluate(.contains([["id": "x"]]), outcome: .value([["id": "y"], ["id": "x", "v": 1]])).passed)
        XCTAssertFalse(E.evaluate(.contains(["a": 2]), outcome: .value(["a": 1])).passed)
        XCTAssertTrue(E.evaluate(.contains("ell"), outcome: .value("hello")).passed)
        XCTAssertTrue(E.evaluate(.matches("^h.l+o$"), outcome: .value("hello")).passed)
        XCTAssertFalse(E.evaluate(.matches("^x"), outcome: .value("hello")).passed)
        XCTAssertFalse(E.evaluate(.matches("x"), outcome: .value(3)).passed)
        XCTAssertTrue(E.evaluate(.error(), outcome: .failure(code: "boom", message: "m")).passed)
        XCTAssertTrue(E.evaluate(.error("boom"), outcome: .failure(code: "boom", message: "m")).passed)
        XCTAssertTrue(E.evaluate(.error("bad thing"), outcome: .failure(code: "x", message: "a bad thing happened")).passed)
        XCTAssertFalse(E.evaluate(.error("other"), outcome: .failure(code: "x", message: "y")).passed)
        XCTAssertFalse(E.evaluate(.error(), outcome: .value(.null)).passed)
        XCTAssertFalse(E.evaluate(.equals(.null), outcome: .failure(code: "x", message: "y")).passed)
    }

    func testRoundTrip() throws {
        let t = ModAuthorTest(name: "n", hook: "command.run", version: 1, handler: "runA", input: ["commandId": "x"], expect: .error("e"))
        let data = t.modKitJSON()
        guard case .success(let back) = ModAuthorTest.decode(data) else { return XCTFail() }
        XCTAssertEqual(back, t)
        let schema = JSONSchema.authorTest.validate(try JSONValue.parse(data))
        XCTAssertEqual(schema, [])
    }

    func testTypeConformancePartial() {
        let catalog = ModCatalog.v1
        XCTAssertNil(ModTypeConformance.check(["message": "x"], .ref("CommandResult"), catalog: catalog))
        XCTAssertNotNil(ModTypeConformance.check(["message": 1], .ref("CommandResult"), catalog: catalog))
        XCTAssertTrue(ModTypeConformance.isStringLike(.optional(.string)))
        XCTAssertFalse(ModTypeConformance.isStringLike(.list(.string)))
    }
}
