import XCTest
import JavaScriptCore
@testable import ModKit

final class BFScriptTests: XCTestCase {
    func hook(_ sig: String, _ body: String) -> BFScriptReport {
        Fixture.check(Fixture.program(Fixture.hookFn("h", sig, body)))
    }

    func testExamplesCompileWithNoDiagnostics() {
        for ex in ModExamples.all {
            guard let data = ex.package.data("scripts/main.bfscript.json") else { continue }
            let r = BFScript.process(data: data, file: "main.bfscript.json")
            XCTAssertEqual(r.diagnostics, [], ex.id)
            XCTAssertTrue(r.ok, ex.id)
        }
    }

    func testPlanExampleCompilesToBridgeCall() {
        let r = BFScript.process(data: Fixture.script(), file: "main.bfscript.json")
        XCTAssertEqual(r.compiledJS, """
        "use strict";

        export async function dimensions(context, input) {
          return (await __bf.call("media.imageDimensions", [input.items], context));
        }

        """)
        XCTAssertEqual(r.analysis.handlers, ["dimensions": "column.values@1"])
        XCTAssertEqual(r.analysis.catalogCalls, ["media.imageDimensions"])
    }

    func testCompilerSnapshotsForExamples() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Snapshots")
        let record = ProcessInfo.processInfo.environment["BF_RECORD_SNAPSHOTS"] == "1"
        for ex in ModExamples.all {
            guard let data = ex.package.data("scripts/main.bfscript.json") else { continue }
            let js = try XCTUnwrap(BFScript.process(data: data, file: "main.bfscript.json").compiledJS)
            let url = dir.appendingPathComponent("\(ex.id).js")
            if record {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try js.write(to: url, atomically: true, encoding: .utf8)
            }
            let expected = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(js, expected, "snapshot drift for \(ex.id); rerun with BF_RECORD_SNAPSHOTS=1 if intended")
        }
    }

    func testCompilerIsDeterministic() {
        let a = BFScript.process(data: Fixture.script("markdown-previewer"), file: "x").compiledJS
        let b = BFScript.process(data: Fixture.script("markdown-previewer"), file: "x").compiledJS
        XCTAssertEqual(a, b)
    }

    func testWrongArgumentType() {
        let r = hook("column.values@1", #"{"return":{"await":{"call":"media.imageDimensions","args":["not a list"]}}}"#)
        assertDiag(r.diagnostics, .typeMismatch, pointer: "/functions/h/body/0/return/await/args/0")
        XCTAssertNil(r.compiledJS)
        XCTAssertFalse(r.ok)
    }

    func testWrongReturnType() {
        let r = hook("column.values@1", #"{"return":"text"}"#)
        assertDiag(r.diagnostics, .typeMismatch, pointer: "/functions/h/body/0/return")
        XCTAssertTrue(r.diagnostics.first { $0.code == .typeMismatch }?.message.contains("ColumnValue[]") == true)
    }

    func testUnknownFunction() {
        let r = hook("column.values@1", #"{"return":{"await":{"call":"media.nope","args":[]}}}"#)
        assertDiag(r.diagnostics, .unknownFunction, pointer: "/functions/h/body/0/return/await")
        XCTAssertNotNil(r.diagnostics.first { $0.code == .unknownFunction }?.fix)
        let ns = hook("column.values@1", #"{"return":{"await":{"call":"zzz.nope","args":[]}}}"#)
        assertDiag(ns.diagnostics, .unknownFunction)
    }

    func testArgumentCount() {
        let r = hook("column.values@1", #"{"return":{"await":{"call":"media.imageDimensions","args":[]}}}"#)
        assertDiag(r.diagnostics, .argumentCount)
        let many = hook("activate@1", #"{"do":{"await":{"call":"log.write","args":["info","m",null,1]}}},{"return":null}"#)
        assertDiag(many.diagnostics, .argumentCount)
    }

    func testMissingReturn() {
        let r = hook("column.values@1", #"{"let":"x","value":1},{"do":{"await":{"call":"log.write","args":["info",{"toString":{"get":["x"]}}]}}}"#)
        assertDiag(r.diagnostics, .missingReturn, pointer: "/functions/h/body")
        let oneBranch = hook("column.values@1", #"{"if":true,"then":[{"return":{"list":[]}}]}"#)
        assertDiag(oneBranch.diagnostics, .missingReturn)
        let both = hook("column.values@1", #"{"if":true,"then":[{"return":{"list":[]}}],"else":[{"return":{"list":[]}}]}"#)
        XCTAssertFalse(both.diagnostics.contains { $0.code == .missingReturn })
        let failing = hook("column.values@1", #"{"fail":"nope"}"#)
        XCTAssertFalse(failing.diagnostics.contains { $0.code == .missingReturn })
    }

    func testVoidHooksNeedNoReturnButRejectValues() {
        XCTAssertTrue(hook("activate@1", #"{"checkCancelled":true}"#).ok)
        assertDiag(hook("activate@1", #"{"return":1}"#).diagnostics, .typeMismatch)
        XCTAssertTrue(hook("activate@1", #"{"return":null}"#).ok)
    }

    func testUnboundedLoops() {
        let none = hook("activate@1", #"{"forEach":"x","in":{"list":[1]},"body":[]}"#)
        assertDiag(none.diagnostics, .unboundedLoop, pointer: "/functions/h/body/0")
        let zero = hook("activate@1", #"{"forEach":"x","in":{"list":[1]},"max":0,"body":[]}"#)
        assertDiag(zero.diagnostics, .unboundedLoop, pointer: "/functions/h/body/0/max")
        let str = hook("activate@1", #"{"forEach":"x","in":{"list":[1]},"max":"many","body":[]}"#)
        assertDiag(str.diagnostics, .unboundedLoop)
    }

    func testLoopBoundLimits() {
        let big = hook("activate@1", #"{"forEach":"x","in":{"list":[1]},"max":10001,"body":[{"checkCancelled":true}]}"#)
        assertDiag(big.diagnostics, .loopBoundExceeded, pointer: "/functions/h/body/0/max")
        let product = hook("activate@1", #"{"forEach":"a","in":{"list":[1]},"max":1000,"body":[{"checkCancelled":true},{"forEach":"b","in":{"list":[1]},"max":1001,"body":[{"checkCancelled":true}]},{"forEach":"c","in":{"list":[1]},"max":2,"body":[{"checkCancelled":true}]}]}"#)
        assertDiag(product.diagnostics, .loopBoundExceeded)
        let deep = hook("activate@1", #"{"forEach":"a","in":{"list":[1]},"max":2,"body":[{"forEach":"b","in":{"list":[1]},"max":2,"body":[{"forEach":"c","in":{"list":[1]},"max":2,"body":[{"forEach":"d","in":{"list":[1]},"max":2,"body":[]}]}]}]}"#)
        assertDiag(deep.diagnostics, .scriptSizeLimit)
        let ok = hook("activate@1", #"{"forEach":"a","in":{"list":[1]},"max":10000,"body":[{"checkCancelled":true}]}"#)
        XCTAssertFalse(ok.diagnostics.contains { $0.severity == .error })
    }

    func testForEachRequiresList() {
        assertDiag(hook("activate@1", #"{"forEach":"x","in":5,"max":3,"body":[]}"#).diagnostics, .notIterable)
    }

    func testRecursionAndCallDepth() {
        let direct = Fixture.program("""
        "a":{"signature":{"params":[],"returns":"integer"},"body":[{"return":{"await":{"fn":"a","args":[]}}}]},
        \(Fixture.hookFn("h", "activate@1", #"{"do":{"await":{"fn":"a","args":[]}}},{"return":null}"#))
        """)
        assertDiag(Fixture.check(direct).diagnostics, .recursion)
        let mutual = Fixture.program("""
        "a":{"signature":{"params":[],"returns":"integer"},"body":[{"return":{"await":{"fn":"b","args":[]}}}]},
        "b":{"signature":{"params":[],"returns":"integer"},"body":[{"return":{"await":{"fn":"a","args":[]}}}]},
        \(Fixture.hookFn("h", "activate@1", #"{"do":{"await":{"fn":"a","args":[]}}},{"return":null}"#))
        """)
        assertDiag(Fixture.check(mutual).diagnostics, .recursion)
        var fns = [String]()
        for i in 0..<10 {
            let call = i == 9 ? "1" : #"{"await":{"fn":"f\#(i + 1)","args":[]}}"#
            fns.append(#""f\#(i)":{"signature":{"params":[],"returns":"integer"},"body":[{"return":\#(call)}]}"#)
        }
        fns.append(Fixture.hookFn("h", "activate@1", #"{"do":{"await":{"fn":"f0","args":[]}}},{"return":null}"#))
        assertDiag(Fixture.check(Fixture.program(fns.joined(separator: ","))).diagnostics, .callDepthExceeded)
    }

    func testHelperFunctionsTypeCheckAndCompile() {
        let src = Fixture.program("""
        "double":{"signature":{"params":[{"name":"n","type":"integer"}],"returns":"integer"},"body":[{"return":{"mul":[{"get":["n"]},2]}}]},
        \(Fixture.hookFn("h", "command.run@1", #"{"let":"d","value":{"await":{"fn":"double","args":[{"length":{"get":["input","selection"]}}]}}},{"return":{"record":{"message":{"toString":{"get":["d"]}}}}}"#))
        """)
        let r = Fixture.check(src)
        XCTAssertEqual(r.diagnostics, [])
        XCTAssertTrue(r.compiledJS?.contains("async function fn_double(context, v_n)") == true)
        XCTAssertTrue(r.compiledJS?.contains("__bf.i(v_n * 2)") == true)
        let wrong = Fixture.program("""
        "double":{"signature":{"params":[{"name":"n","type":"integer"}],"returns":"integer"},"body":[{"return":{"mul":[{"get":["n"]},2]}}]},
        \(Fixture.hookFn("h", "activate@1", #"{"do":{"await":{"fn":"double","args":["x"]}}},{"return":null}"#))
        """)
        assertDiag(Fixture.check(wrong).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"do":{"await":{"fn":"ghost","args":[]}}}"#).diagnostics, .unknownFunction)
    }

    func testCallsMustBeAwaited() {
        assertDiag(hook("column.values@1", #"{"return":{"call":"media.imageDimensions","args":[{"get":["input","items"]}]}}"#).diagnostics, .callNotAwaited)
        assertDiag(hook("activate@1", #"{"do":{"call":"log.write","args":["info","m"]}}"#).diagnostics, .callNotAwaited)
        assertDiag(hook("activate@1", #"{"do":{"await":5}}"#).diagnostics, .callNotAwaited)
    }

    func testSignatureErrors() {
        assertDiag(hook("nope.hook@1", #"{"return":null}"#).diagnostics, .unknownSignature, pointer: "/functions/h/signature")
        assertDiag(hook("column.values@2", #"{"return":null}"#).diagnostics, .unsupportedSignatureVersion)
        assertDiag(hook("column.values", #"{"return":null}"#).diagnostics, .malformedProgram)
    }

    func testUnknownConstructsAreErrors() {
        assertDiag(hook("activate@1", #"{"eval":"1+1"}"#).diagnostics, .unknownConstruct, pointer: "/functions/h/body/0")
        assertDiag(hook("activate@1", #"{"return":{"eval":"x"}}"#).diagnostics, .unknownConstruct)
        assertDiag(hook("activate@1", #"{"return":null,"extra":1}"#).diagnostics, .unknownConstruct, pointer: "/functions/h/body/0/extra")
        assertDiag(hook("activate@1", #"{"let":"x","let":"y","value":1}"#).diagnostics, .invalidJSON)
        assertDiag(hook("activate@1", #"{"let":"x","set":"x","value":1}"#).diagnostics, .unknownConstruct)
        assertDiag(hook("activate@1", #"{"return":[1,2]}"#).diagnostics, .unknownConstruct)
        assertDiag(hook("activate@1", #"{"return":{"get":["input"],"add":[1,2]}}"#).diagnostics, .unknownConstruct)
        let badFormat = Fixture.check(#"{"format":2,"functions":{}}"#)
        assertDiag(badFormat.diagnostics, .unsupportedFormat, pointer: "/format")
        assertDiag(Fixture.check(#"{"format":1,"functions":{},"extra":true}"#).diagnostics, .unknownConstruct, pointer: "/extra")
        assertDiag(Fixture.check("[]").diagnostics, .malformedProgram)
        assertDiag(Fixture.check("{").diagnostics, .invalidJSON)
    }

    func testReservedAndInvalidNames() {
        assertDiag(hook("activate@1", #"{"let":"input","value":1}"#).diagnostics, .reservedName)
        assertDiag(hook("activate@1", #"{"let":"Bad","value":1}"#).diagnostics, .invalidIdentifier)
        assertDiag(hook("activate@1", #"{"return":{"get":["input","constructor"]}}"#).diagnostics, .reservedName)
        assertDiag(hook("activate@1", #"{"return":{"record":{"__proto__":1}}}"#).diagnostics, .invalidIdentifier)
        assertDiag(hook("activate@1", #"{"return":{"record":{"prototype":1}}}"#).diagnostics, .reservedName)
        assertDiag(Fixture.check(Fixture.program(Fixture.hookFn("class", "activate@1", #"{"return":null}"#))).diagnostics, .reservedName)
    }

    func testVariablesAndScoping() {
        assertDiag(hook("activate@1", #"{"return":{"get":["ghost"]}}"#).diagnostics, .unknownVariable)
        assertDiag(hook("activate@1", #"{"let":"x","value":1},{"let":"x","value":2}"#).diagnostics, .duplicateVariable)
        assertDiag(hook("activate@1", #"{"let":"x","value":1},{"if":true,"then":[{"let":"x","value":2}]}"#).diagnostics, .duplicateVariable)
        assertDiag(hook("activate@1", #"{"set":"ghost","value":1}"#).diagnostics, .unknownVariable)
        assertDiag(hook("activate@1", #"{"set":"input","value":1}"#).diagnostics, .readOnlyVariable)
        assertDiag(hook("activate@1", #"{"if":true,"then":[{"let":"inner","value":1}]},{"return":{"get":["inner"]}}"#).diagnostics, .unknownVariable)
        assertDiag(hook("activate@1", #"{"let":"x","value":1},{"set":"x","value":"s"}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"list":[]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":null}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","type":"string","value":1}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":1},{"append":"x","value":1}"#).diagnostics, .notIterable)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"await":{"call":"log.write","args":["info","m"]}}}"#).diagnostics, .typeMismatch)
    }

    func testFieldAndEnumChecks() {
        assertDiag(hook("column.values@1", #"{"return":{"get":["input","nothing"]}}"#).diagnostics, .unknownField)
        assertDiag(hook("activate@1", #"{"return":{"record":{"x":1}}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("command.run@1", #"{"return":{"record":{"bogus":"x"}}}"#).diagnostics, .unknownField)
        assertDiag(hook("command.run@1", #"{"return":{"record":{"message":5}}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("fileop.before.trash@1", #"{"return":{"record":{"decision":"maybe"}}}"#).diagnostics, .typeMismatch)
        XCTAssertTrue(hook("fileop.before.trash@1", #"{"return":{"record":{"decision":"deny","reason":"protected"}}}"#).ok)
        assertDiag(hook("fileop.before.trash@1", #"{"return":{"record":{"reason":"x"}}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"return":{"get":["input","reason","x"]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"if":{"eq":[{"get":["input","reason"]},"yesterday"]},"then":[]}"#).diagnostics, .typeMismatch)
        XCTAssertTrue(hook("activate@1", #"{"if":{"eq":[{"get":["input","reason"]},"startup"]},"then":[{"return":null}]}"#).ok)
        XCTAssertTrue(hook("activate@1", #"{"if":{"eq":["reload",{"get":["input","reason"]}]},"then":[{"return":null}]}"#).ok)
    }

    func testOptionalsRequireUnwrap() {
        assertDiag(hook("command.run@1", #"{"return":{"record":{"message":{"get":["input","args"]}}}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("selection.changed@1", #"{"let":"p","value":{"get":["input","items"]}},{"return":{"get":["p"]}}"#).diagnostics, .typeMismatch)
        let optionalRead = hook("activate@1", #"{"let":"s","value":{"get":["input","previousVersion"]}},{"return":{"get":["s","x"]}}"#)
        assertDiag(optionalRead.diagnostics, .optionalAccess)
        assertDiag(hook("column.values@1", #"{"let":"s","value":{"get":["input","items",0,"path"]}},{"let":"t","type":"string","value":{"get":["s"]}},{"return":{"list":[]}}"#).diagnostics, .optionalAccess)
        XCTAssertTrue(hook("column.values@1", #"{"let":"s","type":"string","value":{"coalesce":[{"get":["input","items",0,"path"]},"none"]}},{"return":{"list":[{"record":{"handle":{"get":["s"]}}}]}}"#).ok)
        assertDiag(hook("activate@1", #"{"return":{"coalesce":[1,2]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"return":{"unwrap":1}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"return":{"isNull":1}}"#).diagnostics, .typeMismatch)
    }

    func testOperatorTyping() {
        assertDiag(hook("activate@1", #"{"let":"x","value":{"add":[1,"a"]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"concat":["a",1]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"and":[true,1]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"mod":[1.5,2]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"lt":[1,"a"]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"eq":[1,"a"]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"length":5}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"if":1,"then":[]}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"cond":[true,1,"a"]}}"#).diagnostics, .typeMismatch)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"add":[1]}}"#).diagnostics, .argumentCount)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"substring":["abc",1]}}"#).diagnostics, .argumentCount)
        assertDiag(hook("activate@1", #"{"let":"x","value":{"index":[5,0]}}"#).diagnostics, .typeMismatch)
        let good = hook("activate@1", #"""
        {"let":"a","value":{"add":[1,2,3]}},{"let":"b","value":{"div":[{"get":["a"]},2]}},{"let":"c","value":{"concat":["x",{"toString":{"get":["a"]}},"y"]}},
        {"let":"d","value":{"cond":[{"and":[{"lt":[{"get":["a"]},10]},{"not":false}]},"s","t"]}},{"let":"e","value":{"split":[{"upper":{"get":["c"]}},"X"]}},
        {"let":"f","value":{"join":[{"get":["e"]},"-"]}},{"let":"g","value":{"substring":[{"get":["f"]},0,1]}},{"let":"h","value":{"replace":[{"get":["g"]},"a","b"]}},
        {"let":"i","value":{"slice":[{"get":["e"]},0,1]}},{"let":"j","value":{"index":[{"get":["i"]},0]}},{"let":"k","value":{"contains":[{"get":["i"]},{"get":["j"]}]}},
        {"let":"l","value":{"floor":{"get":["b"]}}},{"let":"m","value":{"mod":[{"get":["l"]},2]}},{"let":"n","value":{"startsWith":[{"get":["h"]},"b"]}},
        {"do":{"await":{"call":"log.write","args":["info",{"concat":[{"get":["d"]},{"toString":{"get":["k"]}},{"toString":{"get":["m"]}},{"toString":{"get":["n"]}},{"trim":" x "},{"lower":"Q"}]}]}}}
        """#)
        XCTAssertEqual(good.diagnostics.filter { $0.severity == .error }, [])
        XCTAssertTrue(good.ok)
    }

    func testNoUnwarnedGoodProgram() {
        XCTAssertEqual(hook("activate@1", #"{"do":{"await":{"call":"log.write","args":["info","hi"]}}}"#).diagnostics, [])
    }

    func testLintUnreachableCode() {
        let r = hook("activate@1", #"{"return":null},{"do":{"await":{"call":"log.write","args":["info","never"]}}}"#)
        assertDiag(r.diagnostics, .unreachableCode, pointer: "/functions/h/body/1")
        XCTAssertTrue(r.ok)
        let both = hook("activate@1", #"{"if":true,"then":[{"return":null}],"else":[{"fail":"x"}]},{"checkCancelled":true}"#)
        assertDiag(both.diagnostics, .unreachableCode, pointer: "/functions/h/body/1")
        let afterIf = hook("activate@1", #"{"if":true,"then":[{"return":null}]},{"checkCancelled":true}"#)
        XCTAssertFalse(afterIf.diagnostics.contains { $0.code == .unreachableCode })
    }

    func testLintMissingCancellationCheck() {
        let r = hook("activate@1", #"{"forEach":"x","in":{"list":[1,2]},"max":100,"body":[{"do":{"await":{"call":"log.write","args":["info","m"]}}}]}"#)
        assertDiag(r.diagnostics, .missingCancellationCheck, pointer: "/functions/h/body/0")
        XCTAssertTrue(r.ok)
        let withCheck = hook("activate@1", #"{"forEach":"x","in":{"list":[1,2]},"max":100,"body":[{"checkCancelled":true}]}"#)
        XCTAssertFalse(withCheck.diagnostics.contains { $0.code == .missingCancellationCheck })
        let tiny = hook("activate@1", #"{"forEach":"x","in":{"list":[1]},"max":1,"body":[]}"#)
        XCTAssertFalse(tiny.diagnostics.contains { $0.code == .missingCancellationCheck })
    }

    func testLintUnusedVariableAndHelper() {
        assertDiag(hook("activate@1", #"{"let":"unused","value":1}"#).diagnostics, .unusedVariable, pointer: "/functions/h/body/0")
        let helper = Fixture.program("""
        "spare":{"signature":{"params":[],"returns":"integer"},"body":[{"return":1}]},
        \(Fixture.hookFn("h", "activate@1", #"{"return":null}"#))
        """)
        assertDiag(Fixture.check(helper).diagnostics, .unusedFunction, pointer: "/functions/spare")
    }

    func testScriptSizeLimits() {
        let big = String(repeating: "a", count: 2 * 1024 * 1024)
        assertDiag(BFScript.process(data: Data(big.utf8), file: "x").diagnostics, .scriptSizeLimit)
        var expr = "1"
        for _ in 0..<40 { expr = "{\"not\":\(expr)}" }
        assertDiag(hook("activate@1", "{\"let\":\"x\",\"value\":\(expr)}").diagnostics, .scriptSizeLimit)
        var block = #"{"return":null}"#
        for _ in 0..<20 { block = #"{"if":true,"then":["# + block + "]}" }
        assertDiag(hook("activate@1", block).diagnostics, .scriptSizeLimit)
        assertDiag(hook("activate@1", #"{"let":"x","value":9007199254740993}"#).diagnostics, .literalOutOfRange)
    }

    func testRootsAndCallsAreAnalysed() {
        let r = hook("location.list@1", #"{"let":"r","value":{"await":{"call":"fs.root","args":["downloads"]}}},{"return":{"record":{"items":{"list":[]}}}}"#)
        XCTAssertEqual(r.analysis.literalRootIDs, ["downloads"])
        XCTAssertEqual(r.analysis.catalogCalls, ["fs.root"])
        XCTAssertTrue(r.analysis.callsKnown)
    }


    func run(_ compiled: String, handler: String, input: String, bridge: String = "") -> (value: String?, error: String?) {
        let ctx = JSContext()!
        var failure: String?
        ctx.exceptionHandler = { _, e in failure = e?.toString() }
        let prelude = """
        globalThis.__calls = [];
        globalThis.__bf = {
          call: async (name, args, c) => { __calls.push(name); \(bridge.isEmpty ? "return null;" : bridge) },
          checkCancelled: (c) => { if (c.cancelled) throw new Error("cancelled"); },
          loop: (l, max) => { if (!Array.isArray(l)) throw new Error("not a list"); if (l.length > max) throw new Error("loop bound " + max + " exceeded"); },
          index: (l, i) => { if (!Array.isArray(l) || i < 0 || i >= l.length) throw new Error("index out of range"); return l[i]; },
          i: (n) => { if (!Number.isSafeInteger(n)) throw new Error("integer overflow"); return n; },
          div: (a, b) => { if (b === 0) throw new Error("division by zero"); return a / b; },
          mod: (a, b) => { if (b === 0) throw new Error("division by zero"); return a % b; },
          substring: (s, f, n) => s.substring(f, f + n),
          replace: (s, a, b) => s.split(a).join(b),
          unwrap: (v) => { if (v == null) throw new Error("unwrap of null"); return v; },
          fail: (m) => new Error(m),
        };
        """
        ctx.evaluateScript(prelude)
        let script = compiled.replacingOccurrences(of: "export async function", with: "async function").replacingOccurrences(of: "\"use strict\";", with: "")
        ctx.evaluateScript(script)
        ctx.evaluateScript("globalThis.__out = undefined; globalThis.__err = undefined; \(handler)({modId:'t',cancelled:false}, \(input)).then(v => { __out = JSON.stringify(v === undefined ? null : v); }, e => { __err = String(e && e.message || e); });")
        let out = ctx.objectForKeyedSubscript("__out")
        let err = ctx.objectForKeyedSubscript("__err")
        return (out?.isString == true ? out?.toString() : nil, err?.isString == true ? err?.toString() : failure)
    }

    func testExecutionOfPlanExample() throws {
        let js = try XCTUnwrap(BFScript.process(data: Fixture.script(), file: "x").compiledJS)
        let r = run(js, handler: "dimensions", input: #"{"items":[{"handle":"a"}]}"#, bridge: #"return args[0].map(i => ({handle: i.handle, text: "10×20"}));"#)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, #"[{"handle":"a","text":"10×20"}]"#)
    }

    func testExecutionOfRecentDownloadsBuildsEntries() throws {
        let js = try XCTUnwrap(BFScript.process(data: Fixture.script("recent-downloads"), file: "x").compiledJS)
        let bridge = #"if (name === "fs.root") return {handle: "root"}; return {entries: [{handle: "1", name: "a.zip", kind: "file", size: "10", modified: "t"}, {handle: "2", name: "b", kind: "folder"}]};"#
        let r = run(js, handler: "recentDownloads", input: #"{"limit":50}"#, bridge: bridge)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, #"{"items":[{"id":"1","kind":"file","modified":"t","name":"a.zip","size":"10"},{"id":"2","kind":"folder","name":"b"}]}"#)
        let none = run(js, handler: "recentDownloads", input: #"{"limit":50}"#)
        XCTAssertEqual(none.value, #"{"items":[]}"#)
    }

    func testExecutionOfZipSelection() throws {
        let js = try XCTUnwrap(BFScript.process(data: Fixture.script("zip-selection"), file: "x").compiledJS)
        let bridge = #"if (name === "ui.pickDestination") return {handle: "dest"}; return {operationId: "op1"};"#
        let r = run(js, handler: "zipSelection", input: #"{"selection":[{"handle":"a"},{"handle":"b"}]}"#, bridge: bridge)
        XCTAssertEqual(r.value, #"{"message":"Zipping 2 items","operationId":"op1"}"#)
        XCTAssertEqual(run(js, handler: "zipSelection", input: #"{"selection":[]}"#).value, #"{"message":"Select something to zip first"}"#)
        XCTAssertEqual(run(js, handler: "zipSelection", input: #"{"selection":[{"handle":"a"}]}"#).value, "{}")
    }

    func testExecutionOfMarkdownPreviewer() throws {
        let js = try XCTUnwrap(BFScript.process(data: Fixture.script("markdown-previewer"), file: "x").compiledJS)
        let r = run(js, handler: "renderMarkdown", input: #"{"item":{"handle":"h","name":"README.md"},"maxBytes":100}"#, bridge: ##"return "# hi";"##)
        XCTAssertEqual(r.value, ##"{"node":{"text":"# hi","type":"markdown"},"title":"README.md"}"##)
    }

    func testRuntimeEnforcesLoopBoundsAndArithmetic() throws {
        let loop = Fixture.program(Fixture.hookFn("h", "column.values@1", #"{"let":"out","type":{"list":"ColumnValue"},"value":{"list":[]}},{"forEach":"it","in":{"get":["input","items"]},"max":2,"body":[{"checkCancelled":true},{"append":"out","value":{"record":{"handle":{"get":["it","handle"]}}}}]},{"return":{"get":["out"]}}"#))
        let js = try XCTUnwrap(Fixture.check(loop).compiledJS)
        XCTAssertEqual(run(js, handler: "h", input: #"{"items":[{"handle":"a"},{"handle":"b"}]}"#).value, #"[{"handle":"a"},{"handle":"b"}]"#)
        XCTAssertEqual(run(js, handler: "h", input: #"{"items":[{"handle":"a"},{"handle":"b"},{"handle":"c"}]}"#).error, "loop bound 2 exceeded")

        let math = Fixture.program(Fixture.hookFn("h", "command.run@1", #"{"let":"n","value":{"length":{"get":["input","selection"]}}},{"return":{"record":{"message":{"concat":["v=",{"toString":{"mul":[{"get":["n"]},9007199254740991]}}]}}}}"#))
        let mjs = try XCTUnwrap(Fixture.check(math).compiledJS)
        XCTAssertEqual(run(mjs, handler: "h", input: #"{"selection":[1,2]}"#).error, "integer overflow")
        XCTAssertEqual(run(mjs, handler: "h", input: #"{"selection":[]}"#).value, #"{"message":"v=0"}"#)

        let div = Fixture.program(Fixture.hookFn("h", "command.run@1", #"{"let":"n","value":{"length":{"get":["input","selection"]}}},{"return":{"record":{"message":{"toString":{"div":[10,{"get":["n"]}]}}}}}"#))
        let djs = try XCTUnwrap(Fixture.check(div).compiledJS)
        XCTAssertEqual(run(djs, handler: "h", input: #"{"selection":[]}"#).error, "division by zero")
        XCTAssertEqual(run(djs, handler: "h", input: #"{"selection":[1,2,3,4]}"#).value, #"{"message":"2.5"}"#)

        let idx = Fixture.program(Fixture.hookFn("h", "command.run@1", #"{"return":{"record":{"message":{"get":["input","selection",3,"handle"]}}}}"#))
        let ijs = try XCTUnwrap(Fixture.check(idx).compiledJS)
        XCTAssertEqual(run(ijs, handler: "h", input: #"{"selection":[]}"#).error, "index out of range")
    }

    func testCompiledOutputIsEcmaScript2020Only() throws {
        for ex in ModExamples.all {
            guard let data = ex.package.data("scripts/main.bfscript.json"), let js = BFScript.process(data: data, file: "x").compiledJS else { continue }
            for banned in ["?.", "||=", "&&=", "??=", "#", "class ", "eval(", "Function(", "import(", "with ", "require("] {
                XCTAssertFalse(js.contains(banned), "\(ex.id) contains \(banned)")
            }
            XCTAssertFalse(js.contains("require"))
            XCTAssertEqual(js.components(separatedBy: "\n").filter { $0.hasPrefix("export ") }.count, js.components(separatedBy: "export async function ").count - 1)
        }
    }
}
