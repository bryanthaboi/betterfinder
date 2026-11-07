import FileOps
import Foundation
@testable import ModHost
import ModHostProtocol
import ModKit
import XCTest

enum Scripts {
    static let probe = """
    import { fs, net, storage } from "betterfinder";

    async function code(p: Promise<unknown>): Promise<string> {
      try { await p; return "ok"; } catch (e) { return String((e as { code?: unknown }).code); }
    }

    export async function probe(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
      const results: string[] = [];
      const root = await fs.root("work");
      if (root === null) return { message: "unbound" };
      const page = await fs.list(root, 50, "name");
      for (const e of page.entries) {
        results.push(e.name + "=" + await code(fs.readText(e, 100)));
      }
      results.push("net=" + await code(net.fetch({ url: "https://127.0.0.1/", method: "GET" })));
      results.push("dns=" + await code(net.fetch({ url: "https://evil.example/", method: "GET" })));
      results.push("storage=" + await code(storage.get("k")));
      return { message: results.join(",") };
    }
    """

    static let spin = """
    export async function spin(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
      const a = input.args as { spin?: boolean } | null | undefined;
      if (a && a.spin === true) { let n = 0; while (true) { n++; } }
      return { message: "fine" };
    }

    export async function ok(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
      return { message: "ok" };
    }
    """

    static func version(_ v: String) -> String {
        """
        export async function run(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
          return { message: "\(v)" };
        }
        """
    }

    static let guardRename = """
    import { log } from "betterfinder";

    export async function guard(context: unknown, input: { items: Array<{ destinationName?: string | null }> }): Promise<{ decision: "allow" | "deny"; reason?: string }> {
      for (const i of input.items) {
        if ((i.destinationName ?? "").includes("protected")) {
          await log.write("info", "blocked " + (i.destinationName ?? ""));
          return { decision: "deny", reason: "protected name" };
        }
      }
      return { decision: "allow" };
    }

    export async function noop(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
      return { message: "noop" };
    }
    """

    static let column = """
    import { media } from "betterfinder";

    export async function dims(context: unknown, input: { items: Array<{ handle: string; name: string }> }): Promise<Array<{ handle: string; text?: string }>> {
      const values = await media.imageDimensions(input.items as never);
      return values.map(v => ({ handle: v.handle, ...(v.text ? { text: "ts:" + v.text } : {}) }));
    }
    """
}

@MainActor
final class RuntimeTests: XCTestCase {
    func testTypeScriptColumnMod() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.ts-dims", manifest: [
            "permissions": [["kind": "fs.read", "scope": "selection", "recursive": false, "reason": "Read headers"], ["kind": "ui", "surfaces": ["column"]]],
            "contributes": ["columns": [["id": "dims", "title": "Dims", "valueType": "string", "handler": "dims"]]],
            "hooks": [["name": "column.values", "handler": "dims", "version": 1]],
        ], files: ["scripts/main.ts": Scripts.column])
        let r = try await env.install(dir)
        XCTAssertEqual(r.receipt[.types], .pass)
        XCTAssertEqual(r.receipt[.dryRun], .pass)
        try await env.runtime.enable(id: "bob.ts-dims")
        let provider = try XCTUnwrap(env.sink.entry("bob.ts-dims/dims")?.column)
        let png = try env.png("c.png", width: 10, height: 20)
        let values = try await provider.values(for: [png], revision: 1)
        XCTAssertEqual(values[png]?.text, "ts:10×20")
    }

    func testTypeErrorsBlockInstall() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.broken", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": "export async function run(context: unknown, input: unknown) { const n: number = 'x'; return {}; }"])
        let r = try await env.runtime.install(from: dir, developer: true)
        XCTAssertFalse(r.installed)
        XCTAssertEqual(r.receipt[.types], .fail)
        XCTAssertTrue(r.receipt.diagnostics.contains { $0.message.hasPrefix("TS2322") })
        XCTAssertNil(env.runtime.status(id: "bob.broken"))
    }

    func testGrantDenials() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        env.resolver.table["evil.example"] = ["127.0.0.1"]
        let dir = try env.mod("bob.probe", manifest: commandManifest("probe", handler: "probe", permissions: [
            ["kind": "fs.read", "scope": "root", "rootId": "work", "recursive": false, "reason": "Read the work folder"],
            ["kind": "net", "endpoints": [["scheme": "https", "host": "example.com", "methods": ["GET"]], ["scheme": "https", "host": "evil.example", "methods": ["GET"]]], "reason": "Fetch"],
            ["kind": "storage", "quotaBytes": 1024],
        ]), files: ["scripts/main.ts": Scripts.probe])
        let report = try await env.install(dir)
        let manifest = try XCTUnwrap(report.manifest)
        try await env.runtime.approve(id: "bob.probe", permissionIDs: Set(manifest.permissions.filter { $0.kind != .storage }.map(ModPermissionID.make)))
        try await env.runtime.enable(id: "bob.probe")
        let root = env.work.appendingPathComponent("granted", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
        let secret = try env.file("secret.txt", "outside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: secret)
        try env.runtime.bindRoot(id: "bob.probe", rootId: "work", to: root)
        let out = try await env.runtime.runCommand(qualifiedID: "bob.probe/probe", selection: [])
        XCTAssertEqual(out.message, "escape=notGranted,inside.txt=ok,net=notGranted,dns=denied,storage=notGranted")
    }

    func testNetBrokerRules() throws {
        let resolver = FakeResolver()
        resolver.table["rebind.example"] = ["93.184.216.34", "10.0.0.5"]
        resolver.table["public.example"] = ["93.184.216.34"]
        let net = ModNetBroker(resolver: resolver)
        let grant = ModPermission(kind: .net, reason: "x", endpoints: [NetEndpoint(scheme: .https, host: "public.example", methods: [.GET])])
        XCTAssertNoThrow(try net.authorize(URL(string: "https://public.example/a")!, method: "GET", grants: [grant]))
        XCTAssertThrowsError(try net.authorize(URL(string: "https://public.example/a")!, method: "POST", grants: [grant]))
        XCTAssertThrowsError(try net.authorize(URL(string: "https://public.example:8443/a")!, method: "GET", grants: [grant]))
        XCTAssertThrowsError(try net.authorize(URL(string: "http://public.example/a")!, method: "GET", grants: [grant]))
        XCTAssertNoThrow(try net.checkDestination("public.example", allowPrivate: false))
        XCTAssertThrowsError(try net.checkDestination("rebind.example", allowPrivate: false))
        XCTAssertNoThrow(try net.checkDestination("rebind.example", allowPrivate: true))
        for a in ["127.0.0.1", "10.1.2.3", "192.168.1.1", "172.20.0.1", "169.254.1.1", "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1", "100.64.0.1", "0.0.0.0"] {
            XCTAssertTrue(ModNetAddress.isPrivate(a), a)
        }
        for a in ["93.184.216.34", "2606:2800:220:1::1", "8.8.8.8"] { XCTAssertFalse(ModNetAddress.isPrivate(a), a) }
        XCTAssertThrowsError(try net.checkDestination("localhost", allowPrivate: false))
    }

    func testForgedIdentityAndCrossModHandles() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let a = ModManifest(id: "alice.one", name: "a", author: "alice", version: SemVer(1, 0, 0), api: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), app: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), runtime: .ts, entry: "x.ts", license: "MIT",
                            permissions: [ModPermission(kind: .fsRead, reason: "r", scope: .selection, recursive: false)])
        var b = a
        b.id = "alice.two"
        let file = try env.file("h.txt", "hello")
        let modA = ActiveMod(manifest: a, generation: 1, snapshot: env.work, mode: .live, grants: a.permissions, logs: ModLogBuffer(file: nil), storageURL: env.work.appendingPathComponent("sa.json"), settings: nil)
        let modB = ActiveMod(manifest: b, generation: 2, snapshot: env.work, mode: .live, grants: b.permissions, logs: ModLogBuffer(file: nil), storageURL: env.work.appendingPathComponent("sb.json"), settings: nil)
        let sig = try XCTUnwrap(ModCatalog.v1.hook(named: "command.run", version: 1))
        let invA = ModInvocation(mod: modA, hook: sig, handler: "h", gesture: false, parent: nil)
        let invB = ModInvocation(mod: modB, hook: sig, handler: "h", gesture: false, parent: nil)
        let refs = env.runtime.broker.makeRefs(modA, urls: [file], invocation: invA)
        let ok = await env.runtime.broker.handle(ModCallRequest(callId: "1", invocationId: invA.id, modId: "alice.one", generation: 1, name: "fs.readText", args: [refs[0], .int(10)]), invocation: invA)
        XCTAssertEqual(ok.value, .string("hello"))
        let cross = await env.runtime.broker.handle(ModCallRequest(callId: "2", invocationId: invB.id, modId: "alice.two", generation: 2, name: "fs.readText", args: [refs[0], .int(10)]), invocation: invB)
        XCTAssertEqual(cross.error?.code, "staleHandle")
        let forged = await env.runtime.broker.handle(ModCallRequest(callId: "3", invocationId: invA.id, modId: "alice.two", generation: 2, name: "fs.readText", args: [refs[0], .int(10)]), invocation: invA)
        XCTAssertEqual(forged.error?.code, "denied")
        let unknown = await env.runtime.broker.handle(ModCallRequest(callId: "4", invocationId: invA.id, modId: "alice.one", generation: 1, name: "process.spawn", args: []), invocation: invA)
        XCTAssertEqual(unknown.error?.code, "notFound")
        let noGesture = await env.runtime.broker.handle(ModCallRequest(callId: "5", invocationId: invA.id, modId: "alice.one", generation: 1, name: "process.run", args: [.string("/bin/ls"), .array([])]), invocation: invA)
        XCTAssertEqual(noGesture.error?.code, "notGranted")
        let badArgs = await env.runtime.broker.handle(ModCallRequest(callId: "6", invocationId: invA.id, modId: "alice.one", generation: 1, name: "fs.readText", args: [.string("x")]), invocation: invA)
        XCTAssertEqual(badArgs.error?.code, "invalidArgument")
        try Data("changed".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("h2.txt"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: file.deletingLastPathComponent().appendingPathComponent("h2.txt"), to: file)
        let swapped = await env.runtime.broker.handle(ModCallRequest(callId: "7", invocationId: invA.id, modId: "alice.one", generation: 1, name: "fs.readText", args: [refs[0], .int(10)]), invocation: invA)
        XCTAssertEqual(swapped.error?.code, "staleHandle")
    }

    func testHotReloadKeepsPreviousOnFailure() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let v1 = try env.mod("bob.reload", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": Scripts.version("v1")])
        try await env.install(v1)
        try await env.runtime.enable(id: "bob.reload")
        let g1 = try XCTUnwrap(env.runtime.status(id: "bob.reload")?.generation)
        let r1 = try await env.runtime.runCommand(qualifiedID: "bob.reload/go", selection: [])
        XCTAssertEqual(r1.message, "v1")

        var broken = commandManifest("go", handler: "run")
        broken["version"] = "1.0.1"
        let bad = try env.mod("bob.reload", manifest: broken, files: ["scripts/main.ts": "export async function run(context: unknown, input: unknown) { const n: number = 'x'; return { message: 'v2' }; }"])
        let failed = try await env.runtime.reload(id: "bob.reload", from: bad)
        XCTAssertFalse(failed.installed)
        XCTAssertEqual(env.runtime.status(id: "bob.reload")?.generation, g1)
        XCTAssertEqual(env.runtime.status(id: "bob.reload")?.version, "1.0.0")
        let still = try await env.runtime.runCommand(qualifiedID: "bob.reload/go", selection: [])
        XCTAssertEqual(still.message, "v1")

        var good = commandManifest("go", handler: "run")
        good["version"] = "1.0.2"
        let v2 = try env.mod("bob.reload", manifest: good, files: ["scripts/main.ts": Scripts.version("v2")])
        let swapped = try await env.runtime.reload(id: "bob.reload", from: v2)
        XCTAssertTrue(swapped.installed)
        let g2 = try XCTUnwrap(env.runtime.status(id: "bob.reload")?.generation)
        XCTAssertGreaterThan(g2, g1)
        let r2 = try await env.runtime.runCommand(qualifiedID: "bob.reload/go", selection: [])
        XCTAssertEqual(r2.message, "v2")
        XCTAssertEqual(env.sink.ids(owner: "bob.reload"), ["bob.reload/go"])

        try await env.runtime.rollback(id: "bob.reload")
        let back = try await env.runtime.runCommand(qualifiedID: "bob.reload/go", selection: [])
        XCTAssertEqual(back.message, "v1")
        XCTAssertEqual(env.sink.ids(owner: "bob.reload"), ["bob.reload/go"])
    }

    func testDisableRemovesRegistrationsAndHooks() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.guard", manifest: commandManifest("noop", handler: "noop", permissions: [
            ["kind": "operations.intercept", "operations": ["rename"], "reason": "Protect names"],
        ], extraHooks: [["name": "fileop.before.rename", "handler": "guard", "version": 1]]), files: ["scripts/main.ts": Scripts.guardRename])
        try await env.install(dir)
        try await env.runtime.enable(id: "bob.guard")
        XCTAssertEqual(env.registry.hookCount, 1)
        XCTAssertEqual(env.sink.ids(owner: "bob.guard"), ["bob.guard/noop"])
        let f = try env.file("r/one.txt", "1")
        do {
            _ = try await FileActions.renameAsync(f, to: "protected-one.txt", registry: env.registry)
            XCTFail("rename should be denied")
        } catch let e as HookDeniedError {
            XCTAssertEqual(e.denial.reason, "protected name")
        }
        let renamed = try await FileActions.renameAsync(f, to: "fine.txt", registry: env.registry)
        XCTAssertEqual(renamed.lastPathComponent, "fine.txt")
        XCTAssertTrue(env.runtime.logs(id: "bob.guard").contains { $0.message == "blocked protected-one.txt" })

        try await env.runtime.disable(id: "bob.guard")
        XCTAssertEqual(env.registry.hookCount, 0)
        XCTAssertTrue(env.sink.ids(owner: "bob.guard").isEmpty)
        let after = try await FileActions.renameAsync(renamed, to: "protected-two.txt", registry: env.registry)
        XCTAssertEqual(after.lastPathComponent, "protected-two.txt")
        XCTAssertEqual(env.runtime.status(id: "bob.guard")?.enabled, false)
    }

    func testEnableRequiresPassingReceiptAndUninstallCleansUp() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.clean", manifest: commandManifest("go", handler: "run", permissions: [["kind": "storage"]]), files: ["scripts/main.ts": """
        import { storage } from "betterfinder";
        export async function run(context: unknown, input: { args?: unknown }): Promise<{ message?: string }> {
          await storage.set("n", 41);
          const v = await storage.get("n");
          return { message: String(v) };
        }
        """])
        try await env.install(dir)
        let status = try XCTUnwrap(env.runtime.status(id: "bob.clean"))
        XCTAssertFalse(status.enabled)
        try await env.runtime.enable(id: "bob.clean")
        let out = try await env.runtime.runCommand(qualifiedID: "bob.clean/go", selection: [])
        XCTAssertEqual(out.message, "41")
        let snapshot = status.snapshot
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshot.appendingPathComponent("manifest.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o444)
        try await env.runtime.uninstall(id: "bob.clean", deleteData: true)
        XCTAssertNil(env.runtime.status(id: "bob.clean"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent("ModData/bob.clean").path))
    }

    func testCallbackLatency() async throws {
        for (name, transport) in [("inprocess", ModHostTransports.inProcess()), ("subprocess", ModHostTransports.subprocess(Runner.url))] {
            let env = try TestEnv(transport: transport)
            let dir = try env.mod("bob.lat", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": Scripts.version("x")])
            try await env.install(dir)
            try await env.runtime.enable(id: "bob.lat")
            var samples = [Double]()
            for _ in 0..<200 {
                let t = DispatchTime.now().uptimeNanoseconds
                _ = try await env.runtime.runCommand(qualifiedID: "bob.lat/go", selection: [])
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
            }
            samples.sort()
            print(String(format: "MODHOST_LATENCY transport=%@ p50=%.3fms p95=%.3fms max=%.3fms", name, samples[100], samples[190], samples[199]))
            XCTAssertLessThan(samples[190], 50)
            await env.cleanup()
        }
    }
}
