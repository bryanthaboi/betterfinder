import Foundation
@testable import ModHost
import ModHostProtocol
import ModKit
import XCTest

@MainActor
final class PlatformTests: XCTestCase {
    let hello = """
    export async function run(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
      return { message: "hello" };
    }
    """

    func test(_ expect: String) -> String {
        #"{"name":"t","hook":"command.run","input":{"commandId":"go","selection":[]},"expect":\#(expect)}"#
    }

    func testDryRunRunsAuthorTestsAndKeepsTheCheckHostWarm() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let good = try env.mod("bob.tested", manifest: commandManifest("go", handler: "run"), files: [
            "scripts/main.ts": hello, "tests/greets.bftest.json": test(#"{"contains":{"message":"hell"}}"#),
        ])
        let ok = await env.runtime.preflight(directory: good)
        XCTAssertTrue(ok.receipt.ok, "\(ok.receipt.diagnostics.map(\.message))")
        XCTAssertEqual(ok.receipt[.dryRun], .pass)
        XCTAssertTrue(env.runtime.checkHostIsWarm)
        let bad = try env.mod("bob.tested", manifest: commandManifest("go", handler: "run"), files: [
            "scripts/main.ts": hello, "tests/greets.bftest.json": test(#"{"equals":{"message":"bye"}}"#),
        ])
        let failed = await env.runtime.preflight(directory: bad)
        XCTAssertEqual(failed.receipt[.dryRun], .fail)
        let d = failed.receipt.diagnostics.first { $0.code == .dryRunFailure }
        XCTAssertEqual(d?.file, "tests/greets.bftest.json", "\(failed.receipt.diagnostics.map(\.message))")
        XCTAssertTrue(env.runtime.checkHostIsWarm)
        env.runtime.stopCheckHost()
        XCTAssertFalse(env.runtime.checkHostIsWarm)
    }

    func testDryRunCodesForTimeoutsAndCrashes() {
        XCTAssertEqual(ModHostController.dryRunCode("timeout"), .dryRunTimeout)
        XCTAssertEqual(ModHostController.dryRunCode("hostRestarted"), .dryRunCrash)
        XCTAssertEqual(ModHostController.dryRunCode("scriptError"), .dryRunFailure)
    }

    func testLocationsCurrentFolderFollowsGrants() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let folder = env.work.appendingPathComponent("here", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        env.services.folder = folder
        let sig = try XCTUnwrap(ModCatalog.v1.hook(named: "command.run", version: 1))
        func mod(_ permissions: [ModPermission], generation: Int) throws -> ActiveMod {
            let m = ModManifest(id: "alice.here", name: "here", author: "alice", version: SemVer(1, 0, 0), api: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")),
                                app: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), runtime: .ts, entry: "x.ts", license: "MIT", permissions: permissions)
            return ActiveMod(manifest: m, generation: generation, snapshot: env.work, mode: .live, grants: permissions, logs: ModLogBuffer(file: nil),
                             storageURL: env.work.appendingPathComponent("s\(generation).json"), settings: nil)
        }
        func current(_ m: ActiveMod, gesture: Bool) async -> (JSONValue?, ModInvocation) {
            let inv = ModInvocation(mod: m, hook: sig, handler: "h", gesture: gesture, parent: nil)
            let r = await env.runtime.broker.handle(ModCallRequest(callId: "1", invocationId: inv.id, modId: m.id, generation: m.generation, name: "locations.current", args: []), invocation: inv)
            return (r.value, inv)
        }
        let writer = try mod([ModPermission(kind: .fsWrite, reason: "drop", scope: .destination)], generation: 1)
        let (w, winv) = await current(writer, gesture: true)
        XCTAssertEqual(w?["title"]?.stringValue, "here")
        let ref = try XCTUnwrap(w?["folder"])
        XCTAssertEqual(ref["kind"]?.stringValue, "folder")
        XCTAssertNoThrow(try env.runtime.broker.resolve(writer, ref, need: .write))
        _ = winv
        let (passive, _) = await current(writer, gesture: false)
        let passiveRef = try XCTUnwrap(passive?["folder"])
        XCTAssertThrowsError(try env.runtime.broker.resolve(writer, passiveRef, need: .write))
        let reader = try mod([ModPermission(kind: .fsRead, reason: "list", scope: .selection, recursive: true)], generation: 2)
        let (r, _) = await current(reader, gesture: false)
        let readRef = try XCTUnwrap(r?["folder"])
        XCTAssertNoThrow(try env.runtime.broker.resolve(reader, readRef, need: .list))
        XCTAssertThrowsError(try env.runtime.broker.resolve(reader, readRef, need: .write))
        env.services.folder = nil
        let (none, _) = await current(reader, gesture: true)
        XCTAssertNil(none?["folder"])
    }

    func testLogsOfInactiveModsComeFromTheLogFile() throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let file = env.runtime.options.paths.dataDirectory("alice.quiet").appendingPathComponent("mod.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("2026-11-06T10:00:00Z [info] started up\nnot a log line\n2026-11-06T10:00:01Z [error] it broke [badly]\n".utf8).write(to: file)
        let logs = env.runtime.logs(id: "alice.quiet")
        XCTAssertEqual(logs.map(\.level), ["info", "error"])
        XCTAssertEqual(logs.last?.message, "it broke [badly]")
    }

    func testDeveloperReloadsPruneOldSnapshots() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.pruned", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": hello])
        try await env.install(dir)
        for i in 0..<3 {
            try Data((hello + "\nexport const v\(i) = \(i);\n").utf8).write(to: dir.appendingPathComponent("scripts/main.ts"))
            let r = try await env.runtime.reload(id: "bob.pruned", from: dir)
            XCTAssertTrue(r.installed, "\(r.receipt.diagnostics.map(\.message))")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: env.runtime.options.paths.modDirectory("bob.pruned").path).filter { !$0.hasPrefix(".") && $0 != "state.json" }
        XCTAssertEqual(names.count, 2, "\(names)")
        let s = try XCTUnwrap(env.runtime.store.state("bob.pruned"))
        XCTAssertEqual(Set(names), Set([s.active.folder, s.previous?.folder].compactMap { $0 }))
    }
}
