import Foundation
@testable import ModHost
import ModKit
import Settings
import XCTest

@MainActor
final class RegressionManagementAdapterTests: XCTestCase {
    func testFreshAdapterReportsUpdateOnceIndexIsFetched() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.tool", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": "export async function run(context: unknown, input: unknown) { return {}; }"])
        try await env.install(dir)
        let index = FakeIndex()
        index.listings = [ModListing(id: "bob.tool", title: "Tool", author: "bob", version: "2.0.0")]
        let controller = ModHostManagementController(runtime: env.runtime, index: index, fetcher: index)
        let before = try await controller.listInstalled()
        XCTAssertNil(before.first?.availableUpdate)
        _ = try await controller.fetchIndex()
        let after = try await controller.listInstalled()
        XCTAssertEqual(after.first?.availableUpdate?.version, "2.0.0")
    }

    func testFailedIndexPreflightKeepsDiagnosticReport() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let dir = try env.mod("bob.broken", manifest: commandManifest("go", handler: "run"), files: ["scripts/main.ts": "export async function run(context: unknown, input: unknown) { const n: number = 'x'; return {}; }"])
        let index = FakeIndex()
        let listing = ModListing(id: "bob.broken", title: "Broken", author: "bob", version: "1.0.0")
        index.listings = [listing]
        index.packages["bob.broken@1.0.0"] = dir
        let controller = ModHostManagementController(runtime: env.runtime, index: index, fetcher: index)
        _ = try await controller.fetchIndex()
        XCTAssertNil(controller.preflightRefusal(for: "bob.broken"))
        do {
            _ = try await controller.install(listing, approvedPermissionIDs: [])
            XCTFail("broken mod installed")
        } catch let e as ModManagementError {
            guard case .installRefused(let message) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(message.contains("failed preflight"), message)
        }
        let report = try XCTUnwrap(controller.preflightRefusal(for: "bob.broken"))
        XCTAssertFalse(report.allowsEnable)
        XCTAssertTrue(report.diagnostics.contains { $0.message.hasPrefix("TS2322") })
        XCTAssertTrue(report.checks.contains { $0.name == ModKit.PreflightCheck.types.rawValue && $0.state == .fail })
        XCTAssertNil(env.runtime.status(id: "bob.broken"))
    }
}
