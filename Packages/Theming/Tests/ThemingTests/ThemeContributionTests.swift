import AppKit
import XCTest
@testable import Theming

@MainActor
final class ThemeContributionTests: XCTestCase {
    var tempDirs: [URL] = []
    var suites: [String] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        tempDirs.removeAll()
        suites.removeAll()
        super.tearDown()
    }

    func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bf-contrib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func makeManager() -> ThemeManager {
        let name = "bf-contrib-\(UUID().uuidString)"
        suites.append(name)
        let m = ThemeManager(userThemesDirectory: makeTempDir(), defaults: UserDefaults(suiteName: name)!)
        m.appliesAppAppearance = false
        return m
    }

    func source(_ id: String, name: String? = nil, assetRoot: URL? = nil, sounds: [String: String] = [:]) throws -> ThemeSource {
        var t = Theme.modernDefault
        t.id = id
        t.name = name ?? id
        t.sounds = sounds
        return ThemeSource(json: try ThemeManager.encoder.encode(t), assetRoot: assetRoot)
    }

    func testRegisterRemoveToken() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        let token = try registry.register([try source("mod-a"), try source("mod-b")], owner: "com.example.pack")
        XCTAssertNotNil(manager.theme(withID: "mod-a"))
        XCTAssertNotNil(manager.theme(withID: "mod-b"))
        XCTAssertTrue(manager.isContributed("mod-a"))
        XCTAssertEqual(manager.contributionOwner(of: "mod-b"), "com.example.pack")
        XCTAssertEqual(registry.owner(ofTheme: "mod-a"), "com.example.pack")
        XCTAssertFalse(manager.isBuiltIn("mod-a"))
        XCTAssertEqual(registry.registrations(owner: "com.example.pack").first?.themeIDs, ["mod-a", "mod-b"])

        XCTAssertTrue(registry.remove(token))
        XCTAssertNil(manager.theme(withID: "mod-a"))
        XCTAssertNil(manager.theme(withID: "mod-b"))
        XCTAssertFalse(registry.remove(token))
        XCTAssertTrue(registry.registrations().isEmpty)
    }

    func testRegistrationIsTransactional() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        let before = manager.available.map(\.id)
        XCTAssertThrowsError(try registry.register([try source("fresh"), try source("modern")], owner: "o")) { error in
            XCTAssertEqual(error as? ThemeContributionError, .idCollision("modern"))
        }
        XCTAssertEqual(manager.available.map(\.id), before)
        XCTAssertTrue(registry.registrations().isEmpty)

        XCTAssertThrowsError(try registry.register([try source("dup"), try source("dup")], owner: "o")) { error in
            XCTAssertEqual(error as? ThemeContributionError, .duplicateID("dup"))
        }
        XCTAssertThrowsError(try registry.register([ThemeSource(json: Data("{ not json".utf8))], owner: "o"))
        XCTAssertThrowsError(try registry.register([try source("x")], owner: ""))
        XCTAssertEqual(manager.available.map(\.id), before)

        try registry.register([try source("taken")], owner: "a")
        XCTAssertThrowsError(try registry.register([try source("taken")], owner: "b"))
        XCTAssertEqual(registry.registrations().count, 1)
    }

    func testRemovingSelectedContributedThemeFallsBackToModern() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        let token = try registry.register([try source("mod-a")], owner: "o")
        manager.select("mod-a")
        XCTAssertEqual(manager.current.id, "mod-a")

        var notified = 0
        let obs = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(obs) }
        registry.remove(token)
        XCTAssertEqual(manager.current.id, "modern")
        XCTAssertGreaterThan(notified, 0)

        try registry.register([try source("mod-a")], owner: "o")
        XCTAssertEqual(manager.current.id, "mod-a")
    }

    func testRemovingUnselectedThemeKeepsCurrent() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        let token = try registry.register([try source("mod-a")], owner: "o")
        manager.select("platinum")
        registry.remove(token)
        XCTAssertEqual(manager.current.id, "platinum")
    }

    func testRemoveAllForOwner() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        try registry.register([try source("a1")], owner: "alpha")
        try registry.register([try source("a2")], owner: "alpha")
        try registry.register([try source("b1")], owner: "beta")
        XCTAssertEqual(registry.removeAll(owner: "alpha"), 2)
        XCTAssertNil(manager.theme(withID: "a1"))
        XCTAssertNil(manager.theme(withID: "a2"))
        XCTAssertNotNil(manager.theme(withID: "b1"))
    }

    func testContributedThemeIsReadOnlyAndForks() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        try registry.register([try source("mod-a", name: "Mod A")], owner: "o")
        var edited = try XCTUnwrap(manager.theme(withID: "mod-a"))
        edited.name = "Edited"
        XCTAssertThrowsError(try manager.save(edited))

        manager.select("mod-a")
        let model = ThemeEditorModel(manager: manager)
        XCTAssertTrue(model.isContributed)
        XCTAssertEqual(model.contributionOwner, "o")
        model.draft.name = "Renamed By User"
        XCTAssertFalse(model.isContributed)
        XCTAssertNotEqual(manager.current.id, "mod-a")
        XCTAssertEqual(manager.current.name, "Renamed By User")
        XCTAssertEqual(manager.theme(withID: "mod-a")?.name, "Mod A")
        let forkID = manager.current.id
        XCTAssertFalse(manager.isContributed(forkID))

        registry.removeAll(owner: "o")
        XCTAssertNil(manager.theme(withID: "mod-a"))
        XCTAssertNotNil(manager.theme(withID: forkID))
        XCTAssertEqual(manager.current.id, forkID)
    }

    func testDuplicateContributedThemeCopiesAssets() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        let root = makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("assets/pic.png"))
        try registry.register([try source("mod-a", assetRoot: root)], owner: "o")
        let copy = try manager.duplicate("mod-a")
        XCTAssertFalse(manager.isContributed(copy.id))
        XCTAssertNotNil(manager.assetURL("assets/pic.png", for: copy.id))
        XCTAssertTrue(manager.hasUserOverride(copy.id))
    }

    func testContributedAssetsAreContained() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        let parent = makeTempDir()
        let root = parent.appendingPathComponent("pack", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("assets/pic.png"))
        try Data("secret".utf8).write(to: parent.appendingPathComponent("secret.txt"))
        try registry.register([try source("mod-a", assetRoot: root)], owner: "o")
        XCTAssertNotNil(manager.assetURL("assets/pic.png", for: "mod-a"))
        XCTAssertNil(manager.assetURL("../secret.txt", for: "mod-a"))
        XCTAssertNil(manager.assetURL(parent.appendingPathComponent("secret.txt").path, for: "mod-a"))
        XCTAssertNil(manager.assetURL("assets/missing.png", for: "mod-a"))
    }

    func testBFThemeImportStillWorksAlongsideContributions() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        try registry.register([try source("mod-a", name: "Mod A")], owner: "o")

        var imported = Theme.modernDefault
        imported.id = "mod-a"
        imported.name = "Mod A"
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("theme.json")
        try ThemeManager.encoder.encode(imported).write(to: file)
        let result = try manager.importTheme(from: file)
        XCTAssertNotEqual(result.id, "mod-a")
        XCTAssertFalse(manager.isContributed(result.id))
        XCTAssertNotNil(manager.theme(withID: "mod-a"))

        let archive = dir.appendingPathComponent("pack.\(ThemeManager.packageExtension)")
        try manager.exportTheme(result.id, to: archive)
        try manager.delete(result.id)
        let again = try manager.importTheme(from: archive)
        XCTAssertFalse(manager.isContributed(again.id))
        XCTAssertTrue(manager.available.contains { $0.id == again.id })
    }

    func testContributedThemesSortAfterBuiltIns() throws {
        let manager = makeManager()
        let registry = ThemeContributionRegistry(manager: manager)
        try registry.register([try source("zzz-theme", name: "Zzz")], owner: "o")
        let ids = manager.available.map(\.id)
        XCTAssertEqual(ids.last, "zzz-theme")
    }

    func testIconResolverPrecedence() throws {
        let registry = IconSetRegistry()
        func image(_ side: CGFloat) -> NSImage { NSImage(size: NSSize(width: side, height: side)) }
        let special = image(11), type = image(22), kind = image(33), folder = image(44)
        let provider = StaticIconSetProvider(
            setID: "pack",
            specialFolders: [.downloads: special],
            contentTypes: ["public.image": type],
            kinds: [.folder: folder, .file: kind]
        )
        registry.register(provider, owner: "o")
        registry.setActiveSetID("pack")

        let downloads = IconRequest(contentTypeIdentifier: "public.folder", kind: .folder, specialFolder: .downloads)
        XCTAssertTrue(IconResolver.icon(for: downloads, size: 0, registry: registry) === special)

        let png = IconRequest(contentTypeIdentifier: "public.png", kind: .file)
        XCTAssertTrue(IconResolver.icon(for: png, size: 0, registry: registry) === type)

        let plainFolder = IconRequest(contentTypeIdentifier: "public.folder", kind: .folder)
        XCTAssertTrue(IconResolver.icon(for: plainFolder, size: 0, registry: registry) === folder)

        let text = IconRequest(contentTypeIdentifier: "public.plain-text", kind: .file)
        XCTAssertTrue(IconResolver.icon(for: text, size: 0, registry: registry) === kind)

        let app = IconRequest(kind: .application)
        XCTAssertNil(IconResolver.icon(for: app, size: 0, registry: registry))
    }

    func testIconResolverMostSpecificTypeAndSizing() throws {
        let registry = IconSetRegistry()
        let generic = NSImage(size: NSSize(width: 1, height: 1))
        let specific = NSImage(size: NSSize(width: 2, height: 2))
        registry.register(StaticIconSetProvider(setID: "pack", contentTypes: ["public.image": generic, "public.png": specific]), owner: "o")
        registry.setActiveSetID("pack")
        let png = IconRequest(contentTypeIdentifier: "public.png", kind: .file)
        XCTAssertTrue(IconResolver.icon(for: png, size: 0, registry: registry) === specific)
        let jpeg = IconRequest(contentTypeIdentifier: "public.jpeg", kind: .file)
        XCTAssertTrue(IconResolver.icon(for: jpeg, size: 0, registry: registry) === generic)
        let resized = try XCTUnwrap(IconResolver.icon(for: jpeg, size: 64, registry: registry))
        XCTAssertEqual(resized.size, NSSize(width: 64, height: 64))
        XCTAssertEqual(generic.size, NSSize(width: 1, height: 1))
    }

    func testIconResolverOnlyConsultsActiveSetAndLatestWins() throws {
        let registry = IconSetRegistry()
        let first = NSImage(size: NSSize(width: 1, height: 1))
        let second = NSImage(size: NSSize(width: 2, height: 2))
        let other = NSImage(size: NSSize(width: 3, height: 3))
        registry.register(StaticIconSetProvider(setID: "pack", kinds: [.file: first]), owner: "a")
        let token = registry.register(StaticIconSetProvider(setID: "pack", kinds: [.file: second]), owner: "b")
        registry.register(StaticIconSetProvider(setID: "elsewhere", kinds: [.file: other]), owner: "c")
        let request = IconRequest(kind: .file)

        XCTAssertNil(IconResolver.icon(for: request, size: 0, registry: registry))
        registry.setActiveSetID("pack")
        XCTAssertTrue(IconResolver.icon(for: request, size: 0, registry: registry) === second)
        registry.remove(token)
        XCTAssertTrue(IconResolver.icon(for: request, size: 0, registry: registry) === first)
        registry.setActiveSetID("elsewhere")
        XCTAssertTrue(IconResolver.icon(for: request, size: 0, registry: registry) === other)
        XCTAssertEqual(registry.removeAll(owner: "a"), 1)
        XCTAssertEqual(registry.registeredSetIDs, ["elsewhere"])
    }

    func testIconSetChangesPostNotification() throws {
        let registry = IconSetRegistry()
        var count = 0
        let obs = NotificationCenter.default.addObserver(forName: .iconSetDidChange, object: registry, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(obs) }

        let token = registry.register(StaticIconSetProvider(setID: "pack"), owner: "o")
        XCTAssertEqual(count, 1)
        registry.setActiveSetID("pack")
        XCTAssertEqual(count, 2)
        registry.setActiveSetID("pack")
        XCTAssertEqual(count, 2)
        registry.remove(token)
        XCTAssertEqual(count, 3)
        registry.remove(token)
        XCTAssertEqual(count, 3)
    }

    func testThemeSelectionDrivesActiveIconSetForSharedOnly() throws {
        let manager = makeManager()
        let before = IconSetRegistry.shared.activeSetID
        var t = Theme.modernDefault
        t.icons.set = "something-else"
        manager.applyLive(t)
        XCTAssertEqual(IconSetRegistry.shared.activeSetID, before)
    }

    func testSpecialFolderDetection() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(SpecialFolder.detect(url: URL(fileURLWithPath: "/Users/tester/Downloads"), home: home), .downloads)
        XCTAssertEqual(SpecialFolder.detect(url: URL(fileURLWithPath: "/Users/tester"), home: home), .home)
        XCTAssertEqual(SpecialFolder.detect(url: URL(fileURLWithPath: "/Applications"), home: home), .applications)
        XCTAssertNil(SpecialFolder.detect(url: URL(fileURLWithPath: "/Users/tester/Other"), home: home))
        let r = IconRequest(url: URL(fileURLWithPath: "/Applications/Foo.app"), isDirectory: true, isPackage: true, contentTypeIdentifier: "com.apple.application-bundle")
        XCTAssertEqual(r.kind, .application)
    }

    func testSoundSetProviderIntegration() throws {
        let pop = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pop.path))
        let manager = makeManager()
        let registry = SoundSetRegistry()
        let theme = try {
            var t = Theme.modernDefault
            t.id = "snd"
            t.sounds = ["trash": "set:pack", "error": "set:missing"]
            return t
        }()
        ThemeSounds.clearCache()
        XCTAssertNil(ThemeSounds.sound(for: .trash, theme: theme, manager: manager, registry: registry))

        let token = registry.register(StaticSoundSetProvider(setID: "pack", urls: [.trash: pop]), owner: "o")
        XCTAssertNotNil(ThemeSounds.sound(for: .trash, theme: theme, manager: manager, registry: registry))
        XCTAssertNil(ThemeSounds.sound(for: .error, theme: theme, manager: manager, registry: registry))
        XCTAssertNil(ThemeSounds.sound(for: .drop, theme: theme, manager: manager, registry: registry))
        XCTAssertEqual(registry.registeredSetIDs, ["pack"])

        registry.remove(token)
        XCTAssertNil(ThemeSounds.sound(for: .trash, theme: theme, manager: manager, registry: registry))
    }

    func testSoundSetChangesPostNotification() {
        let registry = SoundSetRegistry()
        var count = 0
        let obs = NotificationCenter.default.addObserver(forName: .soundSetDidChange, object: registry, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(obs) }
        let token = registry.register(StaticSoundSetProvider(setID: "pack", urls: [:]), owner: "o")
        registry.remove(token)
        XCTAssertEqual(count, 2)
    }
}
