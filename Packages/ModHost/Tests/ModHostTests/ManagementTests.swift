import CryptoKit
import Foundation
@testable import ModHost
import ModKit
import ModValidation
import Settings
import Theming
import XCTest

final class FakeIndex: ModIndexProviding, ModVerifiedPackageFetching, @unchecked Sendable {
    var listings: [ModListing] = []
    var packages: [String: URL] = [:]
    let key = Curve25519.Signing.PrivateKey()
    var tamper: ((inout ModIndexListing) -> Void)?
    func fetch() async throws -> ModIndexSnapshot { ModIndexSnapshot(listings: listings, fetchedAt: Date()) }
    func fetchPackage(for listing: ModListing) async throws -> URL {
        guard let u = packages["\(listing.id)@\(listing.version)"] else { throw ModManagementError.installRefused("missing") }
        return u
    }
    func fetchRelease(for listing: ModListing) async throws -> ModReleaseArtifact {
        let dir = try await fetchPackage(for: listing)
        let package = PackageLoader.loadDirectory(dir)
        let data = ModPackaging.archive(package: package)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bfmod")
        try data.write(to: url)
        let manifest = try ModManifest.decode(XCTUnwrap(package.data("manifest.json"))).get()
        let keyID = manifest.author.lowercased() + ":test"
        var made = try ModIndexEntry.make(manifest: manifest, archiveSHA256: ModKit.SHA256.hex(data), archiveBytes: data.count, options: IndexEntryOptions(
            repo: "https://github.com/\(manifest.author)/mod", releaseURL: "https://github.com/\(manifest.author)/mod/releases/download/v1/m.bfmod",
            commit: String(repeating: "a", count: 40), keyID: keyID, signingKey: key.rawRepresentation
        )).listing
        tamper?(&made)
        let author = ModAuthorFile(author: manifest.author, keys: [ModAuthorKey(
            keyId: keyID, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), validFrom: Date(timeIntervalSinceNow: -60), validUntil: Date(timeIntervalSinceNow: 3600)
        )])
        return ModReleaseArtifact(archive: url, listing: made, author: author)
    }
}

@MainActor
final class ManagementTests: XCTestCase {
    func testSettingsAdapterLifecycle() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let example = try XCTUnwrap(ModExamples.example("image-dimensions"))
        let manifest = try XCTUnwrap(try? ModManifest.decode(Data(contentsOf: example.directory.appendingPathComponent("manifest.json"))).get())
        let perms = manifest.permissions.map(ModHostManagementController.summary)
        let index = FakeIndex()
        index.listings = [ModListing(id: manifest.id, title: manifest.name, author: manifest.author, version: "1.0.0", permissions: perms)]
        index.packages["\(manifest.id)@1.0.0"] = example.directory
        let controller = ModHostManagementController(runtime: env.runtime, index: index, fetcher: index)
        let snapshot = try await controller.fetchIndex()
        XCTAssertEqual(snapshot.listings.count, 1)
        let installed = try await controller.install(snapshot.listings[0], approvedPermissionIDs: Set(perms.map(\.id)))
        XCTAssertEqual(installed.id, manifest.id)
        XCTAssertFalse(installed.isEnabled)
        XCTAssertEqual(Set(installed.permissions.map(\.id)), Set(perms.map(\.id)))
        XCTAssertEqual(installed.lastPreflight?.allowsEnable, true)
        let enabled = try await controller.enable(id: manifest.id)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(env.sink.ids(owner: manifest.id).count, 1)
        let pre = try await controller.preflight(id: manifest.id)
        XCTAssertTrue(pre.allowsEnable)
        let list = try await controller.listInstalled()
        XCTAssertEqual(list.map(\.id), [manifest.id])
        let disabled = try await controller.disable(id: manifest.id)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertTrue(env.sink.ids(owner: manifest.id).isEmpty)
        do {
            _ = try await controller.install(snapshot.listings[0], approvedPermissionIDs: [])
            XCTFail("double install")
        } catch let e as ModManagementError {
            XCTAssertEqual(e, .alreadyInstalled(manifest.id))
        }
        try await controller.uninstall(id: manifest.id, deleteData: true)
        let after = try await controller.listInstalled()
        XCTAssertTrue(after.isEmpty)
        index.tamper = { $0.release.signature = String(repeating: "A", count: 86) + "==" }
        do {
            _ = try await controller.install(snapshot.listings[0], approvedPermissionIDs: Set(perms.map(\.id)))
            XCTFail("unsigned release installed")
        } catch let e as ModManagementError {
            guard case .installRefused(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("BF7011"), m)
        }
        index.tamper = { $0.release.sha256 = String(repeating: "0", count: 64) }
        do {
            _ = try await controller.install(snapshot.listings[0], approvedPermissionIDs: [])
            XCTFail("mismatched release installed")
        } catch let e as ModManagementError {
            guard case .installRefused = e else { return XCTFail("\(e)") }
        }
        let none = try await controller.listInstalled()
        XCTAssertTrue(none.isEmpty)
    }

    func testPartialApprovalDeniesAtRuntime() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let example = try XCTUnwrap(ModExamples.example("markdown-previewer"))
        let r = try await env.install(example.directory, approve: false)
        let m = try XCTUnwrap(r.manifest)
        let uiOnly = Set(m.permissions.filter { $0.kind == .ui }.map(ModPermissionID.make))
        try await env.runtime.approve(id: m.id, permissionIDs: uiOnly)
        try await env.runtime.enable(id: m.id)
        let provider = try XCTUnwrap(env.sink.entry("\(m.id)/markdown")?.preview)
        let md = try env.file("x.md", "# hi")
        do {
            _ = try await provider.render(md, maxBytes: 100, dark: false)
            XCTFail("read should be denied without the fs.read grant")
        } catch let e as ModInvocationError {
            guard case .script(let code, _) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(code, "notGranted")
        }
        try await env.runtime.approveAll(id: m.id)
        let ok = try await provider.render(md, maxBytes: 100, dark: false)
        XCTAssertEqual(ok.node.text, "# hi")
    }

    func testAssetRegistrarRegistersAndRemoves() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let icons = IconSetRegistry()
        let sounds = SoundSetRegistry()
        let panes = SettingsPaneRegistry()
        env.runtime.attach(sink: env.sink, assets: ModSystemAssetRegistrar(themes: nil, icons: icons, sounds: sounds, settingsPanes: panes))
        let dir = try env.mod("cleo.pack", manifest: [
            "runtime": "data/1",
            "contributes": [
                "iconSets": [["id": "neon", "title": "Neon", "path": "icons"]],
                "sounds": [["id": "neon", "title": "Neon", "path": "sounds"]],
                "settingsPanes": [["id": "main", "title": "Neon", "settings": ["glow"]]],
            ],
            "settings": [["key": "glow", "type": "boolean", "label": "Glow", "default": true]],
        ], files: [:])
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! [String: Any]
        m.removeValue(forKey: "entry")
        try JSONSerialization.data(withJSONObject: m).write(to: dir.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try env.png("folder.png", width: 16, height: 16), to: dir.appendingPathComponent("icons/kind.folder.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: dir.appendingPathComponent("sounds/trash.aiff"))
        try await env.install(dir)
        try await env.runtime.enable(id: "cleo.pack")
        XCTAssertEqual(icons.registeredSetIDs, ["cleo.pack/neon"])
        XCTAssertEqual(sounds.registeredSetIDs, ["cleo.pack/neon"])
        XCTAssertEqual(panes.panes.map(\.id), ["mod.cleo.pack.main"])
        try await env.runtime.disable(id: "cleo.pack")
        let removed = await eventually { icons.registeredSetIDs.isEmpty && sounds.registeredSetIDs.isEmpty && panes.panes.isEmpty }
        XCTAssertTrue(removed)
    }

    func testKeyChordParsing() {
        XCTAssertEqual(ModKeyChord.hotKeyCombo("cmd+opt+d")?.keyCode, 2)
        XCTAssertNil(ModKeyChord.hotKeyCombo("hyper+d"))
        XCTAssertNotNil(ModKeyChord.hotKeyCombo("ctrl+shift+f12"))
    }
}
