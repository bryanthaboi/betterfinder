import Foundation
@testable import ModHost
import ModKit
import XCTest

final class RegressionUISinkTests: XCTestCase {
    func testBlankLabelsNormalizeToNil() throws {
        let json = try JSONValue.parse(Data(#"{"type":"vstack","label":"  \n ","children":[{"type":"button","text":"Go","label":"  Go now  "},{"type":"textField","placeholder":"   "}]}"#.utf8))
        let node = try XCTUnwrap(ModUINode.from(json, owner: "a.mod"))
        XCTAssertNil(node.accessibilityLabel)
        XCTAssertEqual(node.children[0].accessibilityLabel, "Go now")
        XCTAssertNil(node.children[1].placeholder)
    }

    func testNonFiniteNodeValuesAreDropped() {
        let node = ModUINode.from(.object(["type": .string("progress"), "value": .double(.infinity)]), owner: "a.mod")
        XCTAssertNotNil(node)
        XCTAssertNil(node?.value)
        XCTAssertEqual(ModUINode.from(.object(["type": .string("progress"), "value": .double(1e20)]), owner: "a.mod")?.value, 1e20)
    }

    func testCellValueDecodesLabelAndSanitizesNumber() {
        let long = String(repeating: "x", count: 2000)
        let cell = ModCellValue.from(.object(["handle": .string("h"), "text": .string("▁▇"), "number": .double(.nan), "label": .string(" \(long) ")]))
        XCTAssertEqual(cell.text, "▁▇")
        XCTAssertNil(cell.number)
        XCTAssertEqual(cell.accessibilityLabel?.count, ModCellValue.maxAccessibilityLabelLength)
        XCTAssertNil(ModCellValue.from(.object(["label": .string("   ")])).accessibilityLabel)
        XCTAssertEqual(ModCellValue.from(.object(["number": .double(1e20)])).number, 1e20)
        XCTAssertNil(ModCellValue(text: "a").accessibilityLabel)
    }

    func testNumberTypeRequiresFiniteValues() {
        let v = ModValueValidator()
        XCTAssertNil(v.validate(.double(1e20), .number))
        XCTAssertNil(v.validate(.int(Int.max), .number))
        XCTAssertNotNil(v.validate(.double(.nan), .number))
        XCTAssertNotNil(v.validate(.double(.infinity), .number))
        XCTAssertNotNil(v.validate(.double(-.infinity), .number))
    }

    func testColumnValueRecordAcceptsOptionalLabel() throws {
        let v = ModValueValidator()
        let ok = try JSONValue.parse(Data(#"{"handle":"h","text":"▁▇","label":"Large, 12 GB"}"#.utf8))
        XCTAssertNil(v.validate(ok, .ref("ColumnValue")))
        XCTAssertNotNil(v.validate(.object(["handle": .string("h"), "number": .double(.nan)]), .ref("ColumnValue")))
    }

    func testDeveloperInstallOverActiveModCanCarryNewApprovals() async throws {
        let env = try await TestEnv()
        defer { Task { await env.cleanup() } }
        func manifest(_ version: String, surfaces: [String], statusBar: Bool) -> [String: Any] {
            var contributes: [String: Any] = ["panels": [["id": "side", "title": "Side", "edge": "right", "presentation": "slideOut"]]]
            if statusBar { contributes["statusBar"] = [["id": "s", "title": "S"]] }
            return [
                "version": version, "permissions": [["kind": "ui", "surfaces": surfaces]], "contributes": contributes,
                "hooks": [["name": "activate", "handler": "activate", "version": 1]],
            ]
        }
        let v1 = try env.mod("bob.grow", manifest: manifest("1.0.0", surfaces: ["panel"], statusBar: false),
                             files: ["scripts/main.ts": "import { ui } from \"betterfinder\";\nexport async function activate(context: unknown, input: unknown) { await ui.setPanel(\"side\", { type: \"text\", text: \"one\" }); }"])
        try await env.install(v1)
        try await env.runtime.enable(id: "bob.grow")
        let v2 = try env.mod("bob.grow", manifest: manifest("1.1.0", surfaces: ["panel", "statusBar"], statusBar: true),
                             files: ["scripts/main.ts": "import { ui } from \"betterfinder\";\nexport async function activate(context: unknown, input: unknown) { await ui.setPanel(\"side\", { type: \"text\", text: \"two\" }); await ui.setStatusText(\"s\", \"hi\"); }"])
        do {
            _ = try await env.runtime.install(from: v2, developer: true)
            XCTFail("expected the swap to fail without the new approval")
        } catch {}
        XCTAssertEqual(env.runtime.status(id: "bob.grow")?.version, "1.0.0")
        let manifestV2 = try ModManifest.decode(Data(contentsOf: v2.appendingPathComponent("manifest.json"))).get()
        let ids = Set(manifestV2.permissions.map { ModPermissionID.make($0) })
        let report = try await env.runtime.install(from: v2, developer: true, approvedPermissionIDs: ids)
        XCTAssertTrue(report.installed)
        XCTAssertEqual(env.runtime.status(id: "bob.grow")?.version, "1.1.0")
    }

    func testShowPanelNeedsAGestureAndADeclaredPanel() async throws {
        let env = try await TestEnv()
        defer { Task { await env.cleanup() } }
        var manifest = commandManifest("open", handler: "run", permissions: [["kind": "ui", "surfaces": ["panel"]]], extraHooks: [["name": "activate", "handler": "activate", "version": 1]],
                                       contributes: ["panels": [["id": "side", "title": "Side", "edge": "right", "presentation": "slideOut"]]])
        manifest["version"] = "1.0.0"
        let script = "import { ui } from \"betterfinder\";\nexport async function activate(context: unknown, input: unknown) { try { await ui.showPanel(\"side\"); } catch (error) { } }\nexport async function run(context: unknown, input: unknown) { await ui.showPanel(\"side\"); return {}; }"
        let dir = try env.mod("bob.show", manifest: manifest, files: ["scripts/main.ts": script])
        try await env.install(dir)
        try await env.runtime.enable(id: "bob.show")
        let before = await MainActor.run { env.sink.updates }
        XCTAssertFalse(before.contains(.showPanel(panel: ModContributionID(modId: "bob.show", localId: "side"))))
        _ = try await env.runtime.runCommand(qualifiedID: "bob.show/open", selection: [])
        let after = await MainActor.run { env.sink.updates }
        XCTAssertTrue(after.contains(.showPanel(panel: ModContributionID(modId: "bob.show", localId: "side"))))
    }

    func testStatusTextSetDuringActivateArrivesAfterRegistration() async throws {
        let env = try await TestEnv()
        defer { Task { await env.cleanup() } }
        let sink = await MainActor.run { () -> OrderingSink in
            let sink = OrderingSink()
            env.runtime.attach(sink: sink, assets: nil)
            return sink
        }
        func manifest(_ version: String) -> [String: Any] {
            [
                "version": version,
                "permissions": [["kind": "ui", "surfaces": ["statusBar"]]],
                "contributes": ["statusBar": [["id": "s", "title": "S"]]],
                "hooks": [["name": "activate", "handler": "activate", "version": 1]],
            ]
        }
        func script(_ text: String) -> String {
            "import { ui } from \"betterfinder\";\nexport async function activate(context: unknown, input: unknown) { await ui.setStatusText(\"s\", \"\(text)\"); }"
        }
        let v1 = try env.mod("bob.status", manifest: manifest("1.0.0"), files: ["scripts/main.ts": script("one")])
        try await env.install(v1)
        try await env.runtime.enable(id: "bob.status")
        let first = await sink.statusUpdates
        XCTAssertEqual(first.map(\.text), ["one"])
        XCTAssertEqual(first.map(\.registered), [true])

        let v2 = try env.mod("bob.status", manifest: manifest("1.0.1"), files: ["scripts/main.ts": script("two")])
        let swapped = try await env.runtime.reload(id: "bob.status", from: v2)
        XCTAssertTrue(swapped.installed)
        let second = await sink.statusUpdates
        XCTAssertEqual(second.map(\.text), ["one", "two"])
        XCTAssertEqual(second.map(\.registered), [true, true])
    }
}

@MainActor
final class OrderingSink: ModUIRegistrySink {
    let inner = ModRecordingSink()
    private(set) var statusUpdates: [(text: String, registered: Bool)] = []

    func registerToolbarItem(_ item: ModToolbarContribution, owner: String) throws -> ModRegistrationToken { try inner.registerToolbarItem(item, owner: owner) }
    func registerSidebarSection(_ section: ModSidebarContribution, owner: String) throws -> ModRegistrationToken { try inner.registerSidebarSection(section, owner: owner) }
    func registerContextMenuItem(_ item: ModContextMenuContribution, owner: String) throws -> ModRegistrationToken { try inner.registerContextMenuItem(item, owner: owner) }
    func registerColumn(_ column: ModColumnContribution, provider: ModColumnValuesProviding, owner: String) throws -> ModRegistrationToken { try inner.registerColumn(column, provider: provider, owner: owner) }
    func registerStatusBarItem(_ item: ModStatusBarContribution, owner: String) throws -> ModRegistrationToken { try inner.registerStatusBarItem(item, owner: owner) }
    func registerPanel(_ panel: ModPanelContribution, owner: String) throws -> ModRegistrationToken { try inner.registerPanel(panel, owner: owner) }
    func registerPreview(_ preview: ModPreviewContribution, provider: ModPreviewProviding, owner: String) throws -> ModRegistrationToken { try inner.registerPreview(preview, provider: provider, owner: owner) }
    func registerView(_ view: ModViewContribution, owner: String) throws -> ModRegistrationToken { try inner.registerView(view, owner: owner) }
    func registerLocation(_ location: ModLocationContribution, provider: ModLocationProviding, owner: String) throws -> ModRegistrationToken { try inner.registerLocation(location, provider: provider, owner: owner) }
    func registerSearchProvider(_ provider: ModSearchProviderContribution, search: ModSearchProviding, owner: String) throws -> ModRegistrationToken { try inner.registerSearchProvider(provider, search: search, owner: owner) }
    func registerCommand(_ command: ModCommandContribution, runner: ModCommandRunning, owner: String) throws -> ModRegistrationToken { try inner.registerCommand(command, runner: runner, owner: owner) }
    func registerKeybinding(_ binding: ModKeybindingContribution, owner: String) throws -> ModRegistrationToken { try inner.registerKeybinding(binding, owner: owner) }
    func apply(_ update: ModUIUpdate) {
        if case .statusText(let item, let text) = update {
            statusUpdates.append((text, inner.ids(kind: .statusBar).contains(item.qualified)))
        }
        inner.apply(update)
    }
}
