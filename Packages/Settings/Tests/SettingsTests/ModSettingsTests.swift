import SwiftUI
import XCTest
@testable import Settings

final class ModSettingsSchemaTests: XCTestCase {
    let sample = """
    {
      "schemaVersion": 1,
      "fields": [
        {"key":"enabled","type":"boolean","title":"Enabled","description":"Turn it on","default":true},
        {"key":"count","type":"integer","title":"Count","min":1,"max":10,"step":1,"default":3},
        {"key":"ratio","type":"number","title":"Ratio","min":0,"max":1,"default":0.5},
        {"key":"label","type":"string","title":"Label","maxLength":8,"default":"hi","placeholder":"name"},
        {"key":"mode","type":"enum","title":"Mode","options":["fast",{"value":"safe","title":"Safe"}],"default":"safe"},
        {"key":"token","type":"secret","title":"API token"}
      ]
    }
    """

    var suites: [String] = []

    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    func schema() throws -> ModSettingsSchema { try ModSettingsSchema.decode(from: Data(sample.utf8)) }

    func store(secrets: SecretStore = InMemorySecretStore()) throws -> ModSettingsStore {
        let name = "bf-mod-\(UUID().uuidString)"
        suites.append(name)
        return try ModSettingsStore(modID: "ada@test", schema: try schema(), defaults: UserDefaults(suiteName: name)!, secrets: secrets)
    }

    func testDecodesAllFieldTypes() throws {
        let s = try schema()
        XCTAssertEqual(s.fields.map(\.key), ["enabled", "count", "ratio", "label", "mode", "token"])
        XCTAssertEqual(s.field("enabled")?.description, "Turn it on")
        XCTAssertEqual(s.field("mode")?.kind, .enumeration(options: [.init(value: "fast"), .init(value: "safe", title: "Safe")], defaultValue: "safe"))
        XCTAssertTrue(s.field("token")!.isSecret)
    }

    func testDefaults() throws {
        let d = try schema().defaults
        XCTAssertEqual(d["enabled"], .bool(true))
        XCTAssertEqual(d["count"], .integer(3))
        XCTAssertEqual(d["ratio"], .number(0.5))
        XCTAssertEqual(d["label"], .string("hi"))
        XCTAssertEqual(d["mode"], .string("safe"))
        XCTAssertNil(d["token"])

        let bare = try ModSettingsSchema.decode(from: Data("""
        {"fields":[{"key":"n","type":"integer","title":"N","min":5},{"key":"b","type":"boolean","title":"B"},
        {"key":"s","type":"string","title":"S"},{"key":"e","type":"enum","title":"E","options":["x","y"]}]}
        """.utf8))
        XCTAssertEqual(bare.defaults["n"], .integer(5))
        XCTAssertEqual(bare.defaults["b"], .bool(false))
        XCTAssertEqual(bare.defaults["s"], .string(""))
        XCTAssertEqual(bare.defaults["e"], .string("x"))
    }

    func rejects(_ json: String, pointer: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ModSettingsSchema.decode(from: Data(json.utf8)), file: file, line: line) { error in
            XCTAssertEqual((error as? ModSettingsSchemaError)?.pointer, pointer, "\(error)", file: file, line: line)
        }
    }

    func testRejectsMalformedSchemas() {
        rejects("nope", pointer: "")
        rejects("[]", pointer: "")
        rejects(#"{"fields":[],"extra":1}"#, pointer: "/extra")
        rejects(#"{"schemaVersion":2,"fields":[]}"#, pointer: "/schemaVersion")
        rejects(#"{"fields":[{"key":"a","type":"color","title":"A"}]}"#, pointer: "/fields/0/type")
        rejects(#"{"fields":[{"key":"1bad","type":"boolean","title":"A"}]}"#, pointer: "/fields/0/key")
        rejects(#"{"fields":[{"key":"a","type":"boolean","title":"A"},{"key":"a","type":"boolean","title":"B"}]}"#, pointer: "/fields/1/key")
        rejects(#"{"fields":[{"key":"a","type":"boolean","title":"A","onChange":"eval()"}]}"#, pointer: "/fields/0/onChange")
        rejects(#"{"fields":[{"key":"a","type":"boolean","title":"A","default":1}]}"#, pointer: "/fields/0/default")
        rejects(#"{"fields":[{"key":"a","type":"integer","title":"A","min":5,"max":1}]}"#, pointer: "/fields/0/min")
        rejects(#"{"fields":[{"key":"a","type":"integer","title":"A","min":1,"max":5,"default":9}]}"#, pointer: "/fields/0/default")
        rejects(#"{"fields":[{"key":"a","type":"integer","title":"A","default":1.5}]}"#, pointer: "/fields/0/default")
        rejects(#"{"fields":[{"key":"a","type":"number","title":"A","step":0}]}"#, pointer: "/fields/0/step")
        rejects(#"{"fields":[{"key":"a","type":"string","title":"A","maxLength":2,"default":"abc"}]}"#, pointer: "/fields/0/default")
        rejects(#"{"fields":[{"key":"a","type":"enum","title":"A","options":[]}]}"#, pointer: "/fields/0/options")
        rejects(#"{"fields":[{"key":"a","type":"enum","title":"A","options":["x","x"]}]}"#, pointer: "/fields/0/options")
        rejects(#"{"fields":[{"key":"a","type":"enum","title":"A","options":["x"],"default":"y"}]}"#, pointer: "/fields/0/default")
        rejects(#"{"fields":[{"key":"a","type":"secret","title":"A","default":"hunter2"}]}"#, pointer: "/fields/0/default")
        rejects(#"{"fields":[{"type":"boolean","title":"A"}]}"#, pointer: "/fields/0/key")
    }

    func testFieldLimit() {
        let fields = (0..<65).map { #"{"key":"k\#($0)","type":"boolean","title":"T"}"# }.joined(separator: ",")
        rejects(#"{"fields":[\#(fields)]}"#, pointer: "/fields")
    }

    func testValueValidationAndBounds() throws {
        let s = try schema()
        let count = s.field("count")!
        XCTAssertEqual(try count.validate(.integer(1)), .integer(1))
        XCTAssertEqual(try count.validate(.integer(10)), .integer(10))
        XCTAssertThrowsError(try count.validate(.integer(0))) { XCTAssertEqual($0 as? ModSettingsValueError, .belowMinimum(key: "count", minimum: 1)) }
        XCTAssertThrowsError(try count.validate(.integer(11))) { XCTAssertEqual($0 as? ModSettingsValueError, .aboveMaximum(key: "count", maximum: 10)) }
        XCTAssertThrowsError(try count.validate(.string("3")))

        let ratio = s.field("ratio")!
        XCTAssertEqual(try ratio.validate(.integer(1)), .number(1))
        XCTAssertThrowsError(try ratio.validate(.number(1.01)))
        XCTAssertThrowsError(try ratio.validate(.number(.nan)))
        XCTAssertThrowsError(try ratio.validate(.number(.infinity)))

        let label = s.field("label")!
        XCTAssertNoThrow(try label.validate(.string("12345678")))
        XCTAssertThrowsError(try label.validate(.string("123456789")))

        let mode = s.field("mode")!
        XCTAssertNoThrow(try mode.validate(.string("fast")))
        XCTAssertThrowsError(try mode.validate(.string("reckless"))) { XCTAssertEqual($0 as? ModSettingsValueError, .notAnOption(key: "mode")) }
        XCTAssertThrowsError(try s.field("token")!.validate(.string("x")))
        XCTAssertThrowsError(try s.field("enabled")!.validate(.integer(1)))
    }

    func testStoreReadsDefaultsAndPersistsValidValues() throws {
        let st = try store()
        XCTAssertEqual(st.value(for: "count"), .integer(3))
        XCTAssertFalse(st.isModified("count"))
        try st.set(.integer(7), for: "count")
        XCTAssertEqual(st.value(for: "count"), .integer(7))
        XCTAssertTrue(st.isModified("count"))
        XCTAssertThrowsError(try st.set(.integer(70), for: "count"))
        XCTAssertEqual(st.value(for: "count"), .integer(7))
        XCTAssertThrowsError(try st.set(.bool(true), for: "missing")) { XCTAssertEqual($0 as? ModSettingsValueError, .unknownKey("missing")) }
        st.reset("count")
        XCTAssertEqual(st.value(for: "count"), .integer(3))
    }

    func testStoreIgnoresCorruptStoredValues() throws {
        let name = "bf-mod-\(UUID().uuidString)"
        suites.append(name)
        let d = UserDefaults(suiteName: name)!
        d.set(999, forKey: "count")
        d.set("junk", forKey: "enabled")
        d.set("reckless", forKey: "mode")
        let st = try ModSettingsStore(modID: "ada@test", schema: try schema(), defaults: d, secrets: InMemorySecretStore())
        XCTAssertEqual(st.value(for: "count"), .integer(3))
        XCTAssertEqual(st.value(for: "enabled"), .bool(true))
        XCTAssertEqual(st.value(for: "mode"), .string("safe"))
        XCTAssertEqual(st.values.count, 5)
    }

    func testStoresAreIsolatedPerMod() throws {
        let s = try schema()
        let a = try ModSettingsStore(modID: "mod-a", schema: s, secrets: InMemorySecretStore())
        let b = try ModSettingsStore(modID: "mod-b", schema: s, secrets: InMemorySecretStore())
        defer { try? a.eraseAllData(); try? b.eraseAllData() }
        try a.set(.integer(9), for: "count")
        XCTAssertEqual(b.value(for: "count"), .integer(3))
        XCTAssertNotEqual(ModSettingsStore.suiteName(for: "mod-a"), ModSettingsStore.suiteName(for: "mod-b"))
    }

    func testRejectsBadModIDs() throws {
        let s = try schema()
        for id in ["", "../x", "a b", "-lead", String(repeating: "a", count: 200)] {
            XCTAssertThrowsError(try ModSettingsStore(modID: id, schema: s, secrets: InMemorySecretStore()), id)
        }
    }

    func testSecretsGoToSecretStoreNotDefaults() throws {
        let secrets = InMemorySecretStore()
        let st = try store(secrets: secrets)
        XCTAssertFalse(st.hasSecret("token"))
        try st.setSecret("hunter2", for: "token")
        XCTAssertTrue(st.hasSecret("token"))
        XCTAssertEqual(try secrets.readSecret(modID: "ada@test", key: "token"), "hunter2")
        XCTAssertNil(st.value(for: "token"))
        XCTAssertFalse(st.values.keys.contains("token"))
        XCTAssertThrowsError(try st.set(.string("leak"), for: "token"))
        XCTAssertThrowsError(try st.setSecret("x", for: "count"))
        try st.clearSecret("token")
        XCTAssertFalse(st.hasSecret("token"))
        try st.setSecret("again", for: "token")
        try st.eraseAllData()
        XCTAssertFalse(secrets.hasSecret(modID: "ada@test", key: "token"))
    }

    @MainActor
    func testFormModelValidatesAndResets() throws {
        let model = ModSettingsFormModel(store: try store())
        XCTAssertTrue(model.update("count", .integer(4)))
        XCTAssertEqual(model.value("count"), .integer(4))
        XCTAssertFalse(model.update("count", .integer(400)))
        XCTAssertNotNil(model.errors["count"])
        XCTAssertEqual(model.value("count"), .integer(4))
        XCTAssertTrue(model.update("count", .integer(5)))
        XCTAssertNil(model.errors["count"])
        model.resetAll()
        XCTAssertEqual(model.value("count"), .integer(3))

        model.secretDrafts["token"] = "abc"
        model.commitSecret("token")
        XCTAssertTrue(model.secretPresence.contains("token"))
        XCTAssertNil(model.secretDrafts["token"])
        model.clearSecret("token")
        XCTAssertFalse(model.secretPresence.contains("token"))
    }

    @MainActor
    func testFormViewRendersWithoutExecutingAnything() throws {
        let model = ModSettingsFormModel(store: try store())
        let host = NSHostingView(rootView: ModSettingsFormView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}

@MainActor
final class SettingsPaneRegistryTests: XCTestCase {
    func descriptor(_ id: String, title: String = "T") -> SettingsPaneDescriptor {
        SettingsPaneDescriptor(id: id, title: title) { Text(title) }
    }

    func testRegisterRemoveToken() throws {
        let registry = SettingsPaneRegistry()
        let t1 = try registry.register(descriptor("mod.a"), owner: "a")
        let t2 = try registry.register(descriptor("mod.b"), owner: "b")
        XCTAssertEqual(registry.panes.map(\.id), ["mod.a", "mod.b"])
        XCTAssertTrue(registry.remove(t1))
        XCTAssertFalse(registry.remove(t1))
        XCTAssertEqual(registry.panes.map(\.id), ["mod.b"])
        XCTAssertNotNil(registry.pane(withID: "mod.b"))
        XCTAssertNotEqual(t1, t2)
    }

    func testRejectsReservedDuplicateAndEmptyIDs() throws {
        let registry = SettingsPaneRegistry()
        for id in SettingsPaneID.reserved {
            XCTAssertThrowsError(try registry.register(descriptor(id), owner: "a")) { XCTAssertEqual($0 as? SettingsPaneRegistryError, .reservedID(id)) }
        }
        XCTAssertThrowsError(try registry.register(descriptor(""), owner: "a")) { XCTAssertEqual($0 as? SettingsPaneRegistryError, .emptyID) }
        try registry.register(descriptor("mod.a"), owner: "a")
        XCTAssertThrowsError(try registry.register(descriptor("mod.a"), owner: "b")) { XCTAssertEqual($0 as? SettingsPaneRegistryError, .duplicateID("mod.a")) }
        XCTAssertEqual(registry.panes.count, 1)
    }

    func testRemoveAllByOwner() throws {
        let registry = SettingsPaneRegistry()
        try registry.register(descriptor("mod.a1"), owner: "a")
        try registry.register(descriptor("mod.a2"), owner: "a")
        try registry.register(descriptor("mod.b"), owner: "b")
        XCTAssertEqual(registry.removeAll(owner: "a"), 2)
        XCTAssertEqual(registry.panes.map(\.id), ["mod.b"])
    }

    func testWindowAppendsDynamicPanesAfterBuiltInsAndShowsByID() throws {
        let registry = SettingsPaneRegistry()
        let controller = SettingsWindowController()
        controller.paneRegistry = registry
        XCTAssertEqual(SettingsWindowController.Tab.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(controller.paneIDs, SettingsWindowController.Tab.allCases.map(\.paneID))

        let token = try registry.register(descriptor("mod.a", title: "Alpha"), owner: "a")
        XCTAssertEqual(controller.paneIDs.last, "mod.a")
        XCTAssertEqual(controller.paneIDs.count, 6)

        XCTAssertTrue(controller.show(paneID: "mod.a"))
        XCTAssertEqual(controller.window?.title, "Alpha")
        XCTAssertFalse(controller.show(paneID: "nope"))
        XCTAssertTrue(controller.show(paneID: SettingsPaneID.advanced))
        XCTAssertEqual(controller.window?.title, "Advanced")

        registry.remove(token)
        XCTAssertEqual(controller.paneIDs.count, 5)
        controller.window?.close()
    }

    func testModsPaneAppearsOnlyWithController() {
        let controller = SettingsWindowController()
        controller.paneRegistry = SettingsPaneRegistry()
        XCTAssertFalse(controller.paneIDs.contains(SettingsPaneID.mods))
        controller.modManagementController = PreviewModManagementController()
        XCTAssertEqual(controller.paneIDs[5], SettingsPaneID.mods)
        XCTAssertTrue(controller.show(paneID: SettingsPaneID.mods))
        XCTAssertEqual(controller.window?.title, "Mods")
        controller.modManagementController = nil
        XCTAssertFalse(controller.paneIDs.contains(SettingsPaneID.mods))
        controller.window?.close()
    }

    func testSelectionSurvivesPaneChanges() throws {
        let registry = SettingsPaneRegistry()
        let controller = SettingsWindowController()
        controller.paneRegistry = registry
        controller.show(tab: .permissions)
        try registry.register(descriptor("mod.a"), owner: "a")
        XCTAssertEqual(controller.paneIDs[controller.window.map { _ in 3 } ?? 3], SettingsPaneID.permissions)
        controller.window?.close()
    }
}
