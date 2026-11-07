import XCTest
@testable import ModKit

enum Fixture {
    static func manifestJSON(_ id: String = "image-dimensions") -> JSONValue {
        let data = ModExamples.example(id)!.package.data("manifest.json")!
        return try! JSONValue.parse(data)
    }

    static func script(_ id: String = "image-dimensions") -> Data {
        ModExamples.example(id)!.package.data("scripts/main.bfscript.json")!
    }

    static func mutate(_ base: JSONValue, _ edit: (inout [String: JSONValue]) -> Void) -> JSONValue {
        var o = base.objectValue!
        edit(&o)
        return .object(o)
    }

    static func package(manifest: JSONValue, script: Data? = nil, extra: [String: Data] = [:]) -> ModPackage {
        var files = extra
        files["manifest.json"] = manifest.canonicalData()
        files["scripts/main.bfscript.json"] = script ?? Fixture.script()
        return ModPackage(files: files)
    }

    static func codes(_ d: [ModDiagnostic]) -> [String] { d.map(\.code.rawValue) }

    static func program(_ functions: String) -> String { "{\"format\":1,\"functions\":{\(functions)}}" }

    static func hookFn(_ name: String, _ signature: String, _ body: String) -> String {
        "\"\(name)\":{\"signature\":\"\(signature)\",\"body\":[\(body)]}"
    }

    static func check(_ text: String) -> BFScriptReport { BFScript.process(text: text) }
}

extension XCTestCase {
    func assertDiag(_ diags: [ModDiagnostic], _ code: ModDiagnosticCode, pointer: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let hit = diags.contains { $0.code == code && (pointer == nil || $0.pointer == pointer) }
        XCTAssertTrue(hit, "expected \(code.rawValue)\(pointer.map { " at \($0)" } ?? "") in \(diags.map { "\($0.code.rawValue)@\($0.pointer ?? "-"): \($0.message)" })", file: file, line: line)
    }
}
