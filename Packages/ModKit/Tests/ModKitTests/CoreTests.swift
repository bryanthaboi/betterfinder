import XCTest
@testable import ModKit

final class CoreTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testJSONParserRejectsDuplicatesAndTrailingGarbage() {
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":1,\"a\":2}")) { e in
            XCTAssertEqual((e as? JSONParseError)?.kind, .duplicateKey)
            XCTAssertEqual((e as? JSONParseError)?.pointer, "/a")
        }
        XCTAssertThrowsError(try JSONValue.parse("{} x"))
        XCTAssertThrowsError(try JSONValue.parse("[1,]"))
        XCTAssertThrowsError(try JSONValue.parse("01"))
        XCTAssertThrowsError(try JSONValue.parse("\"\\ud800\""))
        XCTAssertThrowsError(try JSONValue.parse(String(repeating: "[", count: 100) + String(repeating: "]", count: 100))) { e in
            XCTAssertEqual((e as? JSONParseError)?.kind, .tooDeep)
        }
        XCTAssertEqual(try JSONValue.parse("{\"a\":[1,2.5,\"x\",null,true]}"), ["a": [1, 2.5, "x", nil, true]])
        XCTAssertEqual(try JSONValue.parse("1.0"), .double(1.0))
        XCTAssertEqual(try JSONValue.parse("1"), .int(1))
    }

    func testJSONParserLineColumn() {
        XCTAssertThrowsError(try JSONValue.parse("{\n  \"a\": ,\n}")) { e in
            XCTAssertEqual((e as? JSONParseError)?.line, 2)
        }
    }

    func testCanonicalRoundTrip() throws {
        let v = try JSONValue.parse("{\"b\":[1,{\"z\":null,\"a\":\"q\\n\"}],\"a\":1.5}")
        XCTAssertEqual(try JSONValue.parse(v.canonicalData()), v)
        XCTAssertEqual(v.canonicalString(), "{\"a\":1.5,\"b\":[1,{\"a\":\"q\\n\",\"z\":null}]}")
    }

    func testSemVerParsing() {
        XCTAssertEqual(SemVer("1.2.3")?.description, "1.2.3")
        XCTAssertEqual(SemVer("1.2.3-beta.1+build.5")?.description, "1.2.3-beta.1+build.5")
        for bad in ["1.2", "01.2.3", "1.2.3.4", "1.2.x", "v1.2.3", "1.2.3-", "1.2.3-01", "", "1.2.3+", "-1.2.3"] {
            XCTAssertNil(SemVer(bad), bad)
        }
    }

    func testSemVerOrdering() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        let vs = ordered.map { SemVer($0)! }
        XCTAssertEqual(vs.sorted(), vs)
        XCTAssertEqual(SemVer("1.0.0+a"), SemVer("1.0.0+b"))
    }

    func testSemVerRanges() {
        let r = SemVerRange(">=1.0.0 <2.0.0")!
        XCTAssertTrue(r.contains(SemVer("1.0.0")!))
        XCTAssertTrue(r.contains(SemVer("1.9.9")!))
        XCTAssertFalse(r.contains(SemVer("2.0.0")!))
        XCTAssertFalse(r.contains(SemVer("0.9.9")!))
        XCTAssertFalse(r.contains(SemVer("1.5.0-beta")!))
        XCTAssertTrue(r.hasUpperBound)
        XCTAssertFalse(SemVerRange(">=1.0.0")!.hasUpperBound)
        XCTAssertTrue(SemVerRange("^1.2.3")!.contains(SemVer("1.9.0")!))
        XCTAssertFalse(SemVerRange("^1.2.3")!.contains(SemVer("2.0.0")!))
        XCTAssertTrue(SemVerRange("^0.2.3")!.contains(SemVer("0.2.9")!))
        XCTAssertFalse(SemVerRange("^0.2.3")!.contains(SemVer("0.3.0")!))
        XCTAssertTrue(SemVerRange("~1.2.3")!.contains(SemVer("1.2.9")!))
        XCTAssertFalse(SemVerRange("~1.2.3")!.contains(SemVer("1.3.0")!))
        XCTAssertTrue(SemVerRange("1.0.0")!.contains(SemVer("1.0.0")!))
        XCTAssertTrue(SemVerRange("<1.0.0 || >=2.0.0 <3.0.0")!.contains(SemVer("2.5.0")!))
        XCTAssertFalse(SemVerRange("<1.0.0 || >=2.0.0 <3.0.0")!.contains(SemVer("1.5.0")!))
        XCTAssertTrue(SemVerRange(">=1.0.0-beta.1 <2.0.0")!.contains(SemVer("1.0.0-beta.2")!))
        XCTAssertFalse(SemVerRange(">=1.0.0-beta.1 <2.0.0")!.contains(SemVer("1.1.0-beta.2")!))
        for bad in ["", ">=1.0", "1.x", "> = 1.0.0", ">=1.0.0 ||", "latest", "*"] { XCTAssertNil(SemVerRange(bad), bad) }
    }

    func testSemVerCodableErrors() {
        struct Box: Codable { var v: SemVer }
        XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data("{\"v\":\"1.2\"}".utf8)))
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data("{\"v\":\"1.2.3\"}".utf8)).v, SemVer(1, 2, 3))
    }

    func testDiagnosticCodeTableIsUniqueAndTitled() {
        let raws = ModDiagnosticCode.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for c in ModDiagnosticCode.allCases {
            XCTAssertFalse(c.title.isEmpty)
            XCTAssertTrue(ModPatterns.matches(c.rawValue, "^BF[0-9]{4}$"))
        }
    }

    func testDiagnosticJSONOmitsEmptyFields() throws {
        let d = ModDiagnostic(.typeMismatch, file: "a.json", pointer: "/x", message: "m")
        let s = String(decoding: d.modKitJSON(), as: UTF8.self)
        XCTAssertEqual(s, "{\"code\":\"BF2014\",\"file\":\"a.json\",\"message\":\"m\",\"pointer\":\"\\/x\",\"severity\":\"error\"}".replacingOccurrences(of: "\\/", with: "/"))
        XCTAssertEqual(try JSONDecoder().decode(ModDiagnostic.self, from: d.modKitJSON()), d)
    }

    func testReceiptShapeAndMerging() throws {
        let r = PreflightReceipt(treeHash: String(repeating: "a", count: 64), checks: [.schema: .pass, .manifest: .pass, .grants: .pass, .paths: .pass, .types: .pass, .lint: .pass, .compile: .pass], diagnostics: [])
        XCTAssertTrue(r.staticOK)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r[.dryRun], .notRun)
        let done = r.merging(check: .dryRun, status: .pass, diagnostics: [])
        XCTAssertTrue(done.ok)
        let failed = done.merging(check: .dryRun, status: .fail, diagnostics: [ModDiagnostic(.checkNotRun, severity: .error, message: "crash")])
        XCTAssertFalse(failed.ok)
        let json = try JSONValue.parse(r.modKitJSON())
        XCTAssertEqual(Set(json.objectValue!.keys), ["ok", "treeHash", "validator", "api", "toolchain", "checks", "diagnostics"])
        XCTAssertEqual(json["api"], .string(ModKitVersion.api))
        XCTAssertEqual(json["checks"]?["dryRun"], "notRun")
        XCTAssertEqual(try JSONDecoder().decode(PreflightReceipt.self, from: r.modKitJSON()), r)
    }
}
