import Foundation
@testable import ModHost
import ModHostProtocol
import XCTest

@MainActor
final class SmokeTests: XCTestCase {
    func benchmark(_ runner: URL, iterations: Int) async throws -> Double {
        let env = try TestEnv(transport: ModHostTransports.subprocess(runner))
        defer { Task { await env.cleanup() } }
        var best = Double.infinity
        for _ in 0..<3 {
            let value = try await env.runtime.benchmarkHost(iterations: iterations)
            let ns = try XCTUnwrap(value)
            best = min(best, Double(ns) / 1e6)
        }
        return best
    }

    func testEngineBenchmark() async throws {
        let ms = try await benchmark(Runner.url, iterations: 2_000_000)
        print(String(format: "MODHOST_JIT runner=plain iterations=2000000 best=%.1fms", ms))
    }

    func testSignedSandboxedRunner() async throws {
        guard let path = ProcessInfo.processInfo.environment["MODHOST_SMOKE_RUNNER"] else { throw XCTSkip("set MODHOST_SMOKE_RUNNER to a runner signed with the service entitlements") }
        let runner = URL(fileURLWithPath: path)
        let plain = try await benchmark(Runner.url, iterations: 2_000_000)
        let hardened = try await benchmark(runner, iterations: 2_000_000)
        print(String(format: "MODHOST_JIT plain=%.1fms hardened_sandboxed=%.1fms ratio=%.2f", plain, hardened, hardened / plain))

        let env = try TestEnv(transport: ModHostTransports.subprocess(runner))
        defer { Task { await env.cleanup() } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probe = try await env.runtime.probeHostContainment(
            paths: ["\(home)/Documents", "\(home)/Desktop", "\(home)/Library/Application Support/betterfinder", env.work.path],
            hosts: ["1.1.1.1:443", "127.0.0.1:22"], spawn: "/bin/echo"
        )
        for k in probe.keys.sorted() { print("MODHOST_SANDBOX \(k) => \(probe[k]!)") }
        XCTAssertEqual(probe["sandboxed"], "yes")
        for (k, v) in probe where k.hasPrefix("read:") || k.hasPrefix("write:") || k.hasPrefix("connect:") {
            XCTAssertTrue(v.hasPrefix("denied"), "\(k) => \(v)")
        }

        let dir = try env.mod("bob.smoke", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": Scripts.version("smoke")])
        try await env.install(dir)
        try await env.runtime.enable(id: "bob.smoke")
        var samples = [Double]()
        for _ in 0..<200 {
            let t = DispatchTime.now().uptimeNanoseconds
            let r = try await env.runtime.runCommand(qualifiedID: "bob.smoke/go", selection: [])
            XCTAssertEqual(r.message, "smoke")
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        samples.sort()
        print(String(format: "MODHOST_LATENCY transport=hardened-sandboxed p50=%.3fms p95=%.3fms max=%.3fms", samples[100], samples[190], samples[199]))
        XCTAssertEqual(env.runtime.hostInfo?.sandboxed, true)
    }
}
