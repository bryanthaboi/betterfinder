import Foundation
@testable import ModHost
import ModHostProtocol
import ModHostRuntime
import ModKit
import XCTest

@MainActor
final class ContainmentTests: XCTestCase {
    func spinMod(_ env: TestEnv) throws -> URL {
        var m = commandManifest("spin", handler: "spin")
        var c = m["contributes"] as! [String: Any]
        var cmds = c["commands"] as! [[String: Any]]
        cmds.append(["id": "ok", "title": "ok", "handler": "ok"])
        c["commands"] = cmds
        m["contributes"] = c
        m["hooks"] = (m["hooks"] as! [[String: Any]]) + [["name": "command.run", "handler": "ok", "version": 1]]
        return try env.mod("bob.spin", manifest: m, files: ["scripts/main.ts": Scripts.spin])
    }

    func testRunnerBinaryExists() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Runner.url.path), Runner.url.path)
    }

    func testWatchdogKillsHungHandler() async throws {
        let env = try TestEnv(transport: ModHostTransports.subprocess(Runner.url))
        defer { Task { await env.cleanup() } }
        try await env.install(try spinMod(env))
        try await env.runtime.enable(id: "bob.spin")
        let ok = try await env.runtime.runCommand(qualifiedID: "bob.spin/ok", selection: [])
        XCTAssertEqual(ok.message, "ok")
        let pid1 = try XCTUnwrap(env.runtime.hostProcessIdentifier)
        XCTAssertTrue(pid_alive(pid1))
        let start = Date()
        do {
            _ = try await env.runtime.runCommand(qualifiedID: "bob.spin/spin", selection: [], args: .object(["spin": .bool(true)]))
            XCTFail("hung handler returned")
        } catch let e as ModInvocationError {
            XCTAssertEqual(e, .quarantined("spin"))
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "MODHOST_WATCHDOG kill_after=%.0fms", elapsed * 1000))
        XCTAssertLessThan(elapsed, 2.0)
        let died = await eventually { !pid_alive(pid1) }
        XCTAssertTrue(died, "hung host process was not terminated")
        XCTAssertTrue(env.runtime.events.contains { $0.kind == .hung && $0.modId == "bob.spin" })
        let restarted = await eventually { env.runtime.hostProcessIdentifier.map { $0 != pid1 && pid_alive($0) } ?? false }
        XCTAssertTrue(restarted)
        let again = try await env.runtime.runCommand(qualifiedID: "bob.spin/ok", selection: [])
        XCTAssertEqual(again.message, "ok")
        do {
            _ = try await env.runtime.runCommand(qualifiedID: "bob.spin/spin", selection: [], args: .object(["spin": .bool(false)]))
            XCTFail("quarantined handler ran")
        } catch let e as ModInvocationError {
            XCTAssertEqual(e, .quarantined("spin"))
        }
        XCTAssertFalse(env.runtime.isSafeMode)
    }

    func testHostCrashRecoveryAndSafeMode() async throws {
        let env = try TestEnv(transport: ModHostTransports.subprocess(Runner.url)) { $0.safeModeFailures = 2 }
        defer { Task { await env.cleanup() } }
        try await env.install(try spinMod(env))
        try await env.runtime.enable(id: "bob.spin")
        let pid1 = try XCTUnwrap(env.runtime.hostProcessIdentifier)
        kill(pid1, SIGKILL)
        let restarted = await eventually { env.runtime.hostProcessIdentifier.map { $0 != pid1 } ?? false }
        XCTAssertTrue(restarted)
        let recovered = await eventually(timeout: 5) { (try? await env.runtime.runCommand(qualifiedID: "bob.spin/ok", selection: []))?.message == "ok" }
        XCTAssertTrue(recovered)
        XCTAssertTrue(env.runtime.events.contains { $0.kind == .crashed })
        XCTAssertFalse(env.runtime.isSafeMode)
        let pid2 = try XCTUnwrap(env.runtime.hostProcessIdentifier)
        kill(pid2, SIGKILL)
        let safe = await eventually { env.runtime.isSafeMode }
        XCTAssertTrue(safe)
        let cleared = await eventually { env.sink.ids(owner: "bob.spin").isEmpty }
        XCTAssertTrue(cleared)
        do {
            _ = try await env.runtime.runCommand(qualifiedID: "bob.spin/ok", selection: [])
            XCTFail("ran in safe mode")
        } catch {}

        let second = try ModHostController(options: env.runtime.options, dependencies: env.runtime.deps)
        await second.start()
        XCTAssertTrue(second.isSafeMode)
        await second.exitSafeMode()
        XCTAssertFalse(second.isSafeMode)
        XCTAssertEqual(second.status(id: "bob.spin")?.active, true)
        await second.shutdown()
    }

    func testMemoryThresholdRestartsIdleHost() async throws {
        let env = try TestEnv(transport: ModHostTransports.subprocess(Runner.url)) { $0.hostConfig = ModHostConfig(memoryLimitMiB: 1, statsIntervalMs: 250) }
        defer { Task { await env.cleanup() } }
        try await env.install(try spinMod(env))
        try await env.runtime.enable(id: "bob.spin")
        let pid1 = try XCTUnwrap(env.runtime.hostProcessIdentifier)
        let restarted = await eventually { env.runtime.events.contains { $0.kind == .memoryRestart } }
        XCTAssertTrue(restarted)
        XCTAssertFalse(env.runtime.isSafeMode)
        let moved = await eventually { env.runtime.hostProcessIdentifier.map { $0 != pid1 } ?? false }
        XCTAssertTrue(moved)
    }

    func testEngineBlocksDynamicEvaluation() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let js = """
        export const run = async (context, input) => {
          const out = [];
          const probe = (name, f) => { try { f(); out.push(name + "=open"); } catch (e) { out.push(name + "=blocked"); } };
          probe("ctor", () => { const F = (() => {}).constructor; F("return 1")(); });
          probe("asyncCtor", () => { const F = (async () => {}).constructor; F("return 1")(); });
          probe("protoWrite", () => { "use strict"; Object.prototype.polluted = 1; if (({}).polluted !== 1) throw new Error("x"); });
          probe("bridgeWrite", () => { "use strict"; context.modId = "evil"; });
          return { message: out.join(",") };
        };
        """
        var m = commandManifest("go", handler: "run")
        m["runtime"] = "js/1"
        m["entry"] = "scripts/main.js"
        let dir = try env.mod("bob.escape", manifest: m, files: ["scripts/main.js": js])
        let pre = await env.runtime.preflight(directory: dir)
        XCTAssertTrue(pre.receipt.diagnostics.contains { $0.message.contains("constructor") })
        let box = ResultBox()
        let probeEngine = ModHostEngine(exitOnHang: false) { m in box.add(m) }
        probeEngine.start()
        defer { probeEngine.shutdown() }
        let wrapped = "(function(){ const exports = {}; \(js.replacingOccurrences(of: "export const run", with: "exports.run")); return exports; })()"
        probeEngine.handle(.load(ModLoadRequest(modId: "bob.escape", generation: 1, kind: .module, source: wrapped, handlers: ["run"])))
        let loaded = await eventually { box.messages.contains { if case .loaded(_, _, nil) = $0 { return true }; return false } }
        XCTAssertTrue(loaded, "\(box.messages)")
        probeEngine.handle(.invoke(ModInvokeRequest(invocationId: "i1", modId: "bob.escape", generation: 1, handler: "run", context: .object(["modId": .string("bob.escape")]), input: .object([:]), deadlineMs: 1000)))
        let done = await eventually { box.result("i1") != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(box.result("i1")?.value?["message"]?.stringValue, "ctor=blocked,asyncCtor=blocked,protoWrite=blocked,bridgeWrite=blocked")
    }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ModHostToApp] = []
    func add(_ m: ModHostToApp) { lock.withLock { list.append(m) } }
    var messages: [ModHostToApp] { lock.withLock { list } }
    func result(_ id: String) -> ModCallOutcome? {
        for m in messages { if case .result(let i, let o) = m, i == id { return o } }
        return nil
    }
}

final class PeerTests: XCTestCase {
    func testRequirementShapes() {
        let team = ModPeerPolicy.requirement(forPeerIdentifier: "com.bryanthaboi.betterfinder", selfInfo: ModSigningInfo(identifier: "x", teamIdentifier: "ABCDE12345", isAdHoc: false), lenient: true)
        XCTAssertEqual(team, "identifier \"com.bryanthaboi.betterfinder\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertEqual(ModPeerPolicy.requirement(forPeerIdentifier: "com.bryanthaboi.betterfinder", selfInfo: ModSigningInfo(identifier: "x", teamIdentifier: nil, isAdHoc: true), lenient: true), "identifier \"com.bryanthaboi.betterfinder\"")
        XCTAssertEqual(ModPeerPolicy.requirement(forPeerIdentifier: "com.bryanthaboi.betterfinder", selfInfo: ModSigningInfo(identifier: "x", teamIdentifier: nil, isAdHoc: true), lenient: false), "identifier \"com.bryanthaboi.betterfinder\" and anchor apple generic")
        XCTAssertTrue(ModPeerPolicy.isValidRequirement(team))
    }

    func testForeignPeerIsRejected() throws {
        let appRequirement = ModPeerPolicy.requirement(forPeerIdentifier: ModHostWire.appIdentifier, lenient: true)
        XCTAssertFalse(ModPeerPolicy.validate(pid: getpid(), requirement: appRequirement))
        let me = try XCTUnwrap(ModPeerPolicy.signingInfo(pid: getpid()))
        if let id = me.identifier {
            XCTAssertTrue(ModPeerPolicy.validate(pid: getpid(), requirement: "identifier \"\(id)\""))
        }
        let runner = Process()
        runner.executableURL = Runner.url
        let pipe = Pipe()
        runner.standardInput = pipe
        runner.standardOutput = FileHandle.nullDevice
        try runner.run()
        defer { runner.terminate() }
        XCTAssertFalse(ModPeerPolicy.validate(pid: runner.processIdentifier, requirement: appRequirement))
    }

    func testXPCTransportToMissingServiceCloses() throws {
        let t = XPCModHostTransport(serviceName: "com.bryanthaboi.betterfinder.modhost.missing")
        let closed = expectation(description: "closed")
        closed.assertForOverFulfill = false
        try t.start(onMessage: { _ in }, onClose: { reason in
            if case .invalidated = reason { closed.fulfill() }
        })
        wait(for: [closed], timeout: 5)
    }
}
