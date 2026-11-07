import XCTest
@testable import Theming

final class ThemingTests: XCTestCase {
    static let expectedBuiltIns: Set<String> = [
        "modern", "modern-light", "modern-dark", "platinum", "system7", "aqua", "classic-windows", "luna", "high-contrast",
    ]

    static let legacyModernJSON = """
    {
      "id": "modern",
      "name": "Modern",
      "base": "system",
      "colors": {
        "windowBg": "system:windowBackground",
        "listBg": "system:controlBackground",
        "rowAlt": "system:alternateRow",
        "selection": "system:selection",
        "selectionText": "system:selectionText",
        "text": "system:text",
        "secondaryText": "system:secondaryText",
        "sidebarBg": "system:clear",
        "sidebarText": "system:text",
        "statusBarBg": "system:windowBackground",
        "statusBarText": "system:secondaryText",
        "toolbarBg": "system:windowBackground",
        "accent": "system:accent",
        "border": "system:separator"
      },
      "fonts": {
        "list": { "family": "system", "size": 13 },
        "ui": { "family": "system", "size": 11 }
      },
      "metrics": { "rowHeight": 22, "cornerRadius": 6, "bevel": "none", "borderWidth": 0 },
      "chrome": { "titlebar": "native", "toolbarStyle": "native", "scrollbar": "native", "useNativeChrome": true },
      "icons": { "set": "system" },
      "sounds": {}
    }
    """

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
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bf-theming-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    @MainActor
    func makeManager(dir: URL? = nil, suite: String? = nil) -> ThemeManager {
        let name = suite ?? "bf-theming-\(UUID().uuidString)"
        if !suites.contains(name) { suites.append(name) }
        let m = ThemeManager(userThemesDirectory: dir ?? makeTempDir(), defaults: UserDefaults(suiteName: name)!)
        m.appliesAppAppearance = false
        return m
    }

    func testEveryBuiltInFileDecodesStrictly() throws {
        let dir = try XCTUnwrap(ThemeManager.builtInDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var ids: Set<String> = []
        for f in files {
            let data = try Data(contentsOf: f)
            let theme = try JSONDecoder().decode(Theme.self, from: data)
            XCTAssertEqual(theme.id, f.deletingPathExtension().lastPathComponent, "file name must match id")
            XCTAssertFalse(theme.name.isEmpty)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(raw["colors"], "\(theme.id) missing colors")
            ids.insert(theme.id)
        }
        XCTAssertEqual(ids, Self.expectedBuiltIns)
        XCTAssertEqual(Set(ThemeManager.loadBuiltIns().map(\.id)), Self.expectedBuiltIns)
    }

    func testBuiltInsRoundTripThroughEncoding() throws {
        for t in ThemeManager.loadBuiltIns() {
            let data = try JSONEncoder().encode(t)
            let back = try JSONDecoder().decode(Theme.self, from: data)
            XCTAssertEqual(back, t, t.id)
        }
    }

    func testBuiltInsHaveValidColorsAndFontsLegally() throws {
        for t in ThemeManager.loadBuiltIns() {
            let mirror = Mirror(reflecting: t.colors)
            for child in mirror.children {
                guard let v = child.value as? String, !v.isEmpty, !Theme.isSystemToken(v) else { continue }
                XCTAssertNotNil(NSColor(hex: v), "\(t.id).\(child.label ?? "?") = \(v)")
            }
            for c in t.window.colors + t.window.inactiveColors {
                XCTAssertTrue(Theme.isSystemToken(c) || NSColor(hex: c) != nil, "\(t.id) window color \(c)")
            }
            XCTAssertTrue(t.sounds.isEmpty, "built-ins ship without sounds")
            XCTAssertNil(ThemeManager.builtInDirectory.flatMap { dir -> URL? in
                let folder = dir.appendingPathComponent(t.id)
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent("fonts").path) ? folder : nil
            }, "no bundled fonts")
        }
    }

    func testRetroBuiltInsUseCustomChrome() throws {
        let byID = Dictionary(uniqueKeysWithValues: ThemeManager.loadBuiltIns().map { ($0.id, $0) })
        XCTAssertTrue(try XCTUnwrap(byID["modern"]).window.isNative)
        XCTAssertEqual(byID["modern-light"]?.base, .light)
        XCTAssertEqual(byID["modern-dark"]?.base, .dark)
        XCTAssertEqual(byID["modern-dark"]?.appearance?.name, .darkAqua)
        XCTAssertEqual(byID["modern-light"]?.appearance?.name, .aqua)
        XCTAssertNil(byID["modern"]?.appearance)
        XCTAssertEqual(byID["platinum"]?.window.titlebar, .pinstripe)
        XCTAssertEqual(byID["platinum"]?.window.buttons, .classicBoxes)
        XCTAssertEqual(byID["system7"]?.window.titlebar, .lines)
        XCTAssertNotNil(byID["system7"]?.desktopPattern)
        XCTAssertEqual(byID["classic-windows"]?.window.buttons, .winCaption)
        XCTAssertEqual(byID["classic-windows"]?.toolbar.style, .win3d)
        XCTAssertEqual(byID["classic-windows"]?.scrollbar.style, .win3d)
        XCTAssertEqual(byID["luna"]?.window.buttons, .winCaption)
        XCTAssertEqual(byID["aqua"]?.scrollbar.style, .aqua)
        XCTAssertEqual(byID["high-contrast"]?.base, .dark)
    }

    func testLegacyMinimalJSONStillDecodes() throws {
        let t = try JSONDecoder().decode(Theme.self, from: Data(Self.legacyModernJSON.utf8))
        XCTAssertEqual(t.id, "modern")
        XCTAssertEqual(t.metrics.rowHeight, 22)
        XCTAssertEqual(t.metrics.statusBarHeight, 24)
        XCTAssertTrue(t.window.isNative)
        XCTAssertEqual(t.toolbar.style, .native)
        XCTAssertEqual(t.scrollbar.style, .native)
        XCTAssertEqual(t.header.style, .native)
        XCTAssertNil(t.desktopPattern)
        XCTAssertEqual(t.colors.inactiveSelection, "system:inactiveSelection")
        XCTAssertEqual(t.colors.sidebarSelection, t.colors.selection)
        XCTAssertEqual(t.colors.sidebarIcon, t.colors.accent)
        XCTAssertNil(t.fonts.sidebar)
    }

    func testShippedModernMatchesLegacyShape() throws {
        let legacy = try JSONDecoder().decode(Theme.self, from: Data(Self.legacyModernJSON.utf8))
        let shipped = try XCTUnwrap(ThemeManager.loadBuiltIns().first { $0.id == "modern" })
        var expected = legacy
        expected.metrics = shipped.metrics
        XCTAssertEqual(shipped, expected)
        XCTAssertEqual(shipped.metrics.rowHeight, 28)
        XCTAssertEqual(shipped.metrics.sidebarRowHeight, 32)
        XCTAssertEqual(shipped.metrics.statusBarHeight, 28)
        XCTAssertEqual(shipped.metrics.selectionInset, 6)
        XCTAssertEqual(shipped.metrics.selectionVerticalInset, 2)
    }

    func testLegacyJSONGetsSpacingDefaults() throws {
        let modern = try JSONDecoder().decode(Theme.self, from: Data(Self.legacyModernJSON.utf8))
        XCTAssertEqual(modern.metrics.pathBarHeight, 32)
        XCTAssertEqual(modern.metrics.cellHorizontalInset, 8)
        XCTAssertEqual(modern.metrics.iconTextGap, 8)
        XCTAssertEqual(modern.metrics.selectionVerticalInset, 0)
        XCTAssertEqual(modern.metrics.iconGridGapH, 12)
        XCTAssertEqual(modern.metrics.iconGridGapV, 16)
        XCTAssertEqual(modern.metrics.iconGridInset, 16)
        XCTAssertNil(modern.metrics.defaultDensity)
        XCTAssertEqual(modern.defaultDensity, .regular)
        let retroJSON = """
        { "id": "old-retro", "metrics": { "rowHeight": 18, "cornerRadius": 0, "bevel": "raised", "borderWidth": 0 },
          "chrome": { "titlebar": "pinstripe", "toolbarStyle": "bevelButtons", "scrollbar": "classic", "useNativeChrome": false } }
        """
        let retro = try JSONDecoder().decode(Theme.self, from: Data(retroJSON.utf8))
        XCTAssertEqual(retro.metrics.pathBarHeight, 24)
        XCTAssertEqual(retro.metrics.cellHorizontalInset, 4)
        XCTAssertEqual(retro.defaultDensity, .compact)
        let roundTrip = try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(retro))
        XCTAssertEqual(roundTrip, retro)
    }

    func testDensityPresetsResolveLayout() throws {
        let byID = Dictionary(uniqueKeysWithValues: ThemeManager.loadBuiltIns().map { ($0.id, $0) })
        let modern = try XCTUnwrap(byID["modern"])
        XCTAssertEqual(modern.layout(density: nil).rowHeight, 28)
        XCTAssertEqual(modern.layout(density: .compact).rowHeight, 24)
        XCTAssertEqual(modern.layout(density: .comfortable).rowHeight, 32)
        XCTAssertEqual(modern.layout(density: .compact).sidebarRowHeight, 28)
        XCTAssertEqual(modern.layout(density: .regular).sidebarRowHeight, 32)
        XCTAssertEqual(modern.layout(density: .comfortable).sidebarRowHeight, 36)
        XCTAssertEqual(modern.layout(density: .compact).listIconSize, 16)
        XCTAssertEqual(modern.layout(density: .comfortable).listIconSize, 20)
        let c = modern.layout(density: .compact), r = modern.layout(density: .regular), f = modern.layout(density: .comfortable)
        XCTAssertEqual([c.iconGridGapH, c.iconGridGapV, c.iconGridInset], [8, 12, 12])
        XCTAssertEqual([r.iconGridGapH, r.iconGridGapV, r.iconGridInset], [12, 16, 16])
        XCTAssertEqual([f.iconGridGapH, f.iconGridGapV, f.iconGridInset], [16, 20, 20])
        XCTAssertEqual(r.iconItemSize(iconSize: 64), NSSize(width: 112, height: 120))
        XCTAssertEqual(r.iconItemSize(iconSize: 128), NSSize(width: 176, height: 184))

        let retro: [String: (CGFloat, CGFloat)] = ["platinum": (18, 20), "system7": (18, 20), "classic-windows": (17, 20), "luna": (18, 22), "aqua": (19, 22)]
        for (id, (row, side)) in retro {
            let t = try XCTUnwrap(byID[id])
            XCTAssertEqual(t.defaultDensity, .compact, id)
            let base = t.layout(density: nil)
            XCTAssertEqual(base.rowHeight, row, id)
            XCTAssertEqual(base.sidebarRowHeight, side, id)
            XCTAssertEqual(base.pathBarHeight, 24, id)
            XCTAssertEqual(base.cellHorizontalInset, 4, id)
            XCTAssertEqual(base.selectionInset, 0, id)
            XCTAssertEqual(base.statusBarHeight, CGFloat(t.metrics.statusBarHeight), id)
            XCTAssertEqual(t.layout(density: .compact), base, id)
            XCTAssertEqual(t.layout(density: .regular).rowHeight, row + 4, id)
            XCTAssertEqual(t.layout(density: .comfortable).rowHeight, row + 8, id)
            XCTAssertEqual(t.layout(density: .comfortable).sidebarRowHeight, side + 8, id)
            XCTAssertEqual(t.layout(density: .comfortable).listIconSize, base.listIconSize, id)
        }

        let hc = try XCTUnwrap(byID["high-contrast"])
        XCTAssertTrue(hc.isRetro)
        XCTAssertEqual(hc.defaultDensity, .comfortable)
        XCTAssertEqual(hc.layout(density: nil).rowHeight, 32)
        XCTAssertEqual(hc.layout(density: nil).sidebarRowHeight, 36)
        XCTAssertEqual(hc.layout(density: nil).listIconSize, 20)
        XCTAssertEqual(hc.layout(density: .regular).rowHeight, 28)
        XCTAssertEqual(hc.layout(density: .regular).listIconSize, 16)
    }

    @MainActor
    func testDensitySettingPersistsAndNotifies() {
        let suite = "bf-density-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = ThemeManager(userThemesDirectory: makeTempDir(), defaults: defaults)
        m.appliesAppAppearance = false
        XCTAssertNil(m.density)
        XCTAssertEqual(m.effectiveDensity, .regular)
        let exp = expectation(forNotification: .themeDidChange, object: nil)
        m.density = .compact
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(defaults.string(forKey: "density"), "compact")
        XCTAssertEqual(m.layout.rowHeight, 24)
        m.density = nil
        XCTAssertNil(defaults.string(forKey: "density"))
    }

    func testLegacyChromeStringsMapToNewSpecs() throws {
        let json = """
        { "id": "old-platinum", "name": "Old",
          "colors": { "windowBg": "#DDDDDD", "selection": "#3333CC", "selectionText": "#FFFFFF" },
          "chrome": { "titlebar": "pinstripe", "toolbarStyle": "bevelButtons", "scrollbar": "classic", "useNativeChrome": false } }
        """
        let t = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        XCTAssertEqual(t.window.titlebar, .pinstripe)
        XCTAssertEqual(t.toolbar.style, .bevel)
        XCTAssertEqual(t.scrollbar.style, .platinum)
        XCTAssertEqual(t.colors.listBg, "system:controlBackground")
        XCTAssertEqual(t.colors.inactiveSelection, "#3333CC")
        XCTAssertEqual(t.fonts.list.size, 13)
        XCTAssertEqual(t.sounds, [:])
    }

    func testUnknownEnumValuesFallBack() throws {
        let json = """
        { "id": "x", "base": "sepia", "window": { "titlebar": "wobbly", "buttons": "WINCAPTION" }, "metrics": { "bevel": "deep" } }
        """
        let t = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        XCTAssertEqual(t.base, .system)
        XCTAssertEqual(t.window.titlebar, .native)
        XCTAssertEqual(t.window.buttons, .winCaption)
        XCTAssertEqual(t.metrics.bevel, Theme.Bevel.none)
        XCTAssertEqual(t.name, "x")
    }

    func testMissingIDFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(Theme.self, from: Data(#"{ "name": "No ID" }"#.utf8)))
    }

    func testHexRoundTrip() throws {
        for hex in ["#3366CC", "#000000", "#FFFFFF", "#C0C0C0", "#00808080", "#FF000080"] {
            let c = try XCTUnwrap(NSColor(hex: hex), hex)
            XCTAssertEqual(c.hexString, hex)
            XCTAssertEqual(NSColor(hex: c.hexString)?.hexString, hex)
        }
        XCTAssertEqual(NSColor(hex: "#ABC")?.hexString, "#AABBCC")
        XCTAssertEqual(NSColor(hex: "3366cc")?.hexString, "#3366CC")
        XCTAssertNil(NSColor(hex: "system:text"))
        XCTAssertNil(NSColor(hex: "#12345"))
        XCTAssertEqual(Theme.color("#3366CC").hexString, "#3366CC")
        XCTAssertEqual(Theme.color("system:clear").alphaComponent, 0)
    }

    func testContrastRatio() {
        XCTAssertEqual(NSColor.contrastRatio(.black, .white), 21, accuracy: 0.1)
        XCTAssertEqual(NSColor.contrastRatio(.white, .white), 1, accuracy: 0.01)
    }

    func testFontFallbackChain() {
        let spec = Theme.FontSpec(family: "DefinitelyNotAFont, Geneva, system", size: 12)
        let f = Theme.resolveFont(spec)
        XCTAssertEqual(f.pointSize, 12)
        if Theme.isFontAvailable("Geneva") {
            XCTAssertEqual(f.familyName, "Geneva")
        }
        let missing = Theme.resolveFont(.init(family: "DefinitelyNotAFont", size: 14))
        XCTAssertEqual(missing.familyName, NSFont.systemFont(ofSize: 14).familyName)
        let bold = Theme.resolveFont(.init(family: "system", size: 13, weight: "bold"))
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testSlug() {
        XCTAssertEqual(ThemeManager.slug("My Cool Theme!"), "my-cool-theme")
        XCTAssertEqual(ThemeManager.slug("  Platinum  Copy "), "platinum-copy")
    }

    @MainActor
    func testForkOnEditAndResetRoundTrip() throws {
        let dir = makeTempDir()
        let suite = "bf-theming-fork-\(UUID().uuidString)"
        let m = makeManager(dir: dir, suite: suite)
        m.select("platinum")
        let original = try XCTUnwrap(m.original("platinum"))
        XCTAssertFalse(m.hasUserOverride("platinum"))
        XCTAssertFalse(m.isModified("platinum"))

        var edited = m.current
        edited.colors.selection = "#AA00AA"
        edited.window.titlebar = .gradient
        try m.save(edited)

        XCTAssertTrue(m.hasUserOverride("platinum"))
        XCTAssertTrue(m.isModified("platinum"))
        XCTAssertTrue(m.isBuiltIn("platinum"))
        XCTAssertEqual(m.current.colors.selection, "#AA00AA")
        XCTAssertEqual(m.current.chrome.titlebar, "gradient")
        XCTAssertEqual(m.available.filter { $0.id == "platinum" }.count, 1)
        XCTAssertEqual(m.original("platinum"), original)

        let reopened = makeManager(dir: dir, suite: suite)
        XCTAssertEqual(reopened.current.id, "platinum")
        XCTAssertEqual(reopened.current.colors.selection, "#AA00AA")

        try m.resetToOriginal("platinum")
        XCTAssertFalse(m.hasUserOverride("platinum"))
        XCTAssertFalse(m.isModified("platinum"))
        XCTAssertEqual(m.current, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    @MainActor
    func testSaveAndLiveApplyPostNotifications() throws {
        let m = makeManager()
        m.select("luna")
        var received: [Theme] = []
        let token = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: nil) { note in
            if let t = note.object as? Theme { received.append(t) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        var t = m.current
        t.metrics.rowHeight = 30
        m.applyLive(t)
        XCTAssertEqual(m.current.metrics.rowHeight, 30)
        XCTAssertFalse(m.hasUserOverride("luna"))
        m.applyLive(t)
        XCTAssertEqual(received.count, 1)
        try m.save(t)
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(m.hasUserOverride("luna"))
    }

    @MainActor
    func testThemeObserverFires() {
        let m = makeManager()
        var seen: [String] = []
        let obs = ThemeObserver(fireImmediately: true, manager: m) { seen.append($0.id) }
        m.select("aqua")
        m.select("system7")
        XCTAssertEqual(seen, [m.available.first { $0.id == "modern" }!.id, "aqua", "system7"])
        obs.invalidate()
        m.select("luna")
        XCTAssertEqual(seen.count, 3)

        final class Owner: NSObject {}
        var owner: Owner? = Owner()
        var bound: [String] = []
        ThemeObserver.bind(owner!, fireImmediately: false) { _, t in bound.append(t.id) }
        m.select("aqua")
        owner = nil
        m.select("platinum")
        XCTAssertEqual(bound, ["aqua"])
    }

    @MainActor
    func testDuplicateAndDelete() throws {
        let m = makeManager()
        let copy = try m.duplicate("classic-windows")
        XCTAssertEqual(copy.name, "Classic Windows Copy")
        XCTAssertEqual(copy.id, "classic-windows-copy")
        XCTAssertFalse(m.isBuiltIn(copy.id))
        XCTAssertTrue(m.hasUserOverride(copy.id))
        XCTAssertEqual(copy.colors, m.original("classic-windows")?.colors)
        let second = try m.duplicate("classic-windows")
        XCTAssertEqual(second.id, "classic-windows-copy-2")
        m.select(copy.id)
        try m.delete(copy.id)
        XCTAssertNil(m.theme(withID: copy.id))
        XCTAssertEqual(m.current.id, "modern")
    }

    @MainActor
    func testExportImportRoundTrip() throws {
        let m = makeManager()
        var t = try XCTUnwrap(m.theme(withID: "system7"))
        t.colors.accent = "#123456"
        try m.save(t)
        let archive = makeTempDir().appendingPathComponent("System 7.bftheme")
        try m.exportTheme("system7", to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let other = makeManager()
        let imported = try other.importTheme(from: archive)
        XCTAssertEqual(imported.id, "system-7-2")
        XCTAssertEqual(imported.colors.accent, "#123456")
        XCTAssertEqual(imported.window, t.window)
        XCTAssertNotNil(other.theme(withID: imported.id))
        XCTAssertTrue(other.hasUserOverride(imported.id))

        let fresh = ThemeManager(userThemesDirectory: other.userThemesDirectory, defaults: UserDefaults(suiteName: suites.last!)!)
        XCTAssertEqual(fresh.theme(withID: imported.id)?.colors.accent, "#123456")
    }

    @MainActor
    func testImportUniqueThemeKeepsID() throws {
        let src = makeTempDir()
        var t = Theme.modernDefault
        t.id = "sunset"
        t.name = "Sunset"
        t.colors.accent = "#FF6600"
        let file = src.appendingPathComponent("sunset.json")
        try JSONEncoder().encode(t).write(to: file)
        let m = makeManager()
        let imported = try m.importTheme(from: file)
        XCTAssertEqual(imported.id, "sunset")
        XCTAssertEqual(m.theme(withID: "sunset")?.colors.accent, "#FF6600")
    }

    @MainActor
    func testImportAssetMovesThemeIntoFolder() throws {
        let m = makeManager()
        var t = try XCTUnwrap(m.theme(withID: "aqua"))
        t.name = "Aqua Mine"
        try m.save(t)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.userThemeURL("aqua").path))
        let src = makeTempDir().appendingPathComponent("click.aiff")
        try Data([0, 1, 2]).write(to: src)
        let rel = try m.importAsset(from: src, for: "aqua", subdirectory: "sounds")
        XCTAssertEqual(rel, "sounds/click.aiff")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.userThemeURL("aqua").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.userThemeFolderFile("aqua").path))
        XCTAssertNotNil(m.assetURL(rel, for: "aqua"))
        m.reload()
        XCTAssertEqual(m.theme(withID: "aqua")?.name, "Aqua Mine")
        try m.resetToOriginal("aqua")
        XCTAssertNil(m.assetURL(rel, for: "aqua"))
        XCTAssertEqual(m.theme(withID: "aqua")?.name, "Aqua")
    }

    @MainActor
    func testSoundsResolveOnlyWhenConfigured() {
        let m = makeManager()
        XCTAssertNil(ThemeSounds.sound(for: .trash, theme: m.current, manager: m))
        var t = m.current
        t.sounds[ThemeSoundEvent.trash.rawValue] = "missing/file.aiff"
        XCTAssertNil(ThemeSounds.sound(for: .trash, theme: t, manager: m))
        XCTAssertFalse(ThemeSounds.play(.trash, theme: t, manager: m))
    }

    @MainActor
    func testRenderersDrawEveryBuiltIn() throws {
        for t in ThemeManager.loadBuiltIns() {
            let v = ThemePreviewView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            v.theme = t
            for active in [true, false] {
                v.isActive = active
                let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
                v.cacheDisplay(in: v.bounds, to: rep)
                XCTAssertEqual(rep.pixelsWide > 0, true, t.id)
            }
            let scroller = ThemedScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 200))
            scroller.theme = t
            scroller.knobProportion = 0.3
            scroller.doubleValue = 0.5
            let layout = scroller.currentLayout
            if t.scrollbar.style != .native {
                let knob = try XCTUnwrap(layout.knob, t.id)
                XCTAssertTrue(layout.track.contains(NSPoint(x: knob.midX, y: knob.midY)), t.id)
            }
        }
    }

    @MainActor
    func testWindowChromeInstallsAndReverts() throws {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.toolbar = NSToolbar(identifier: "t")
        w.toolbarStyle = .unified
        let byID = Dictionary(uniqueKeysWithValues: ThemeManager.loadBuiltIns().map { ($0.id, $0) })
        let chrome = ThemedWindowChrome.install(on: w, theme: byID["classic-windows"]!)
        chrome.followsCurrentTheme = false
        XCTAssertTrue(chrome.isDrawingCustomChrome)
        XCTAssertEqual(w.titleVisibility, .hidden)
        XCTAssertTrue(w.titlebarAppearsTransparent)
        XCTAssertEqual(w.toolbarStyle, .expanded)
        XCTAssertEqual(w.standardWindowButton(.closeButton)?.isHidden, true)
        let tv = try XCTUnwrap(chrome.titlebarView)
        XCTAssertEqual(tv.subviews.compactMap { $0 as? WindowCaptionButton }.count, 3)
        XCTAssertTrue(ThemedWindowChrome.install(on: w) === chrome)

        chrome.apply(byID["aqua"]!)
        XCTAssertEqual(tv.subviews.compactMap { $0 as? WindowCaptionButton }.count, 0)
        XCTAssertEqual(w.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertTrue(chrome.isDrawingCustomChrome)

        chrome.apply(byID["system7"]!)
        XCTAssertEqual(tv.subviews.compactMap { $0 as? WindowCaptionButton }.map(\.kind), [.close, .zoom])

        chrome.apply(byID["modern"]!)
        XCTAssertFalse(chrome.isDrawingCustomChrome)
        XCTAssertEqual(w.titleVisibility, .visible)
        XCTAssertFalse(w.titlebarAppearsTransparent)
        XCTAssertEqual(w.toolbarStyle, .unified)
        XCTAssertEqual(w.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertTrue(tv.subviews.allSatisfy { !($0 is WindowCaptionButton) && !($0 is TitlebarBackgroundView) })
        ThemedWindowChrome.uninstall(from: w)
        XCTAssertNil(ThemedWindowChrome.chrome(for: w))
    }

    @MainActor
    func testTableThemingSwapsHeaderBothWays() {
        let table = NSTableView()
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Name"
        table.addTableColumn(col)
        let sv = NSScrollView()
        sv.documentView = table
        let byID = Dictionary(uniqueKeysWithValues: ThemeManager.loadBuiltIns().map { ($0.id, $0) })
        TableTheming.apply(byID["classic-windows"]!, to: table)
        XCTAssertTrue(table.headerView is ThemedHeaderView)
        XCTAssertTrue(col.headerCell is ThemedHeaderCell)
        XCTAssertEqual(col.headerCell.stringValue, "Name")
        XCTAssertEqual(table.headerView?.frame.height, 18)
        TableTheming.apply(byID["high-contrast"]!, to: table)
        XCTAssertTrue(table.gridStyleMask.contains(.solidHorizontalGridLineMask))
        TableTheming.apply(byID["modern"]!, to: table)
        XCTAssertFalse(table.headerView is ThemedHeaderView)
        XCTAssertFalse(col.headerCell is ThemedHeaderCell)
        XCTAssertEqual(col.headerCell.stringValue, "Name")
        XCTAssertEqual(table.gridStyleMask, [])
    }
}
