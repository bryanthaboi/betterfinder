import XCTest
@testable import Theming

@MainActor
final class RegressionThemeImportTests: XCTestCase {
    private var dirs: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        dirs = []
        suites = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bf-theme-sol01-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private struct Sandbox {
        let base: URL
        let themes: URL
        let victim: URL
        let sentinel: URL
    }

    private func sandbox() throws -> Sandbox {
        let base = tempDir()
        let themes = base.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let victim = base.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let sentinel = victim.appendingPathComponent("keep.txt")
        try Data("precious".utf8).write(to: sentinel)
        return Sandbox(base: base, themes: themes, victim: victim, sentinel: sentinel)
    }

    private func manager(_ themes: URL) -> ThemeManager {
        let suite = "bf-theme-sol01-\(UUID().uuidString)"
        suites.append(suite)
        let m = ThemeManager(userThemesDirectory: themes, defaults: UserDefaults(suiteName: suite)!)
        m.appliesAppAppearance = false
        return m
    }

    private func hostileTheme(id: String, name: String = "Hostile") -> Theme {
        var t = Theme.modernDefault
        t.id = id
        t.name = name
        return t
    }

    private func assertContained(_ m: ThemeManager, _ theme: Theme, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ThemeManager.isSafeThemeID(theme.id), "id \(theme.id)", file: file, line: line)
        let root = ThemeManager.canonicalPath(of: m.userThemesDirectory)!
        for url in [m.userThemeURL(theme.id), m.userThemeFolder(theme.id)] {
            XCTAssertTrue(ThemeManager.canonicalPath(of: url)!.hasPrefix(root + "/"), url.path, file: file, line: line)
        }
    }

    func testSafeThemeIDRules() {
        for ok in ["modern", "system7", "classic-windows", "café-theme", "a.b_c-1", "My Theme"] {
            XCTAssertTrue(ThemeManager.isSafeThemeID(ok), ok)
        }
        for bad in ["", ".", "..", "../victim", "a/b", "/etc", "a\\b", "a:b", ".hidden", "a\u{0}b", "a\nb", " lead", "~", String(repeating: "x", count: 201)] {
            XCTAssertFalse(ThemeManager.isSafeThemeID(bad), bad.debugDescription)
        }
    }

    func testJSONImportCannotEscapeThemesFolder() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        let src = tempDir().appendingPathComponent("evil.json")
        try ThemeManager.encoder.encode(hostileTheme(id: "../victim")).write(to: src)
        let imported = try m.importTheme(from: src)
        assertContained(m, imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.base.appendingPathComponent("victim.json").path))
        try m.delete(imported.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
    }

    func testDirectoryImportCannotDeleteSiblingDirectory() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        let pkg = tempDir().appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try ThemeManager.encoder.encode(hostileTheme(id: "../victim")).write(to: pkg.appendingPathComponent(ThemeManager.themeFileName))
        let imported = try m.importTheme(from: pkg)
        assertContained(m, imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
        XCTAssertEqual(try String(contentsOf: sb.sentinel, encoding: .utf8), "precious")
    }

    func testArchiveImportWithDeepTraversalID() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        let pkgParent = tempDir()
        let pkg = pkgParent.appendingPathComponent("evil", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try ThemeManager.encoder.encode(hostileTheme(id: "../../../../../../\(sb.victim.path)")).write(to: pkg.appendingPathComponent(ThemeManager.themeFileName))
        let archive = pkgParent.appendingPathComponent("evil.\(ThemeManager.packageExtension)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", pkg.path, archive.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let imported = try m.importTheme(from: archive)
        assertContained(m, imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
    }

    func testSaveRejectsTraversalID() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        XCTAssertThrowsError(try m.save(hostileTheme(id: "../victim"))) { error in
            XCTAssertEqual(error as? ThemeIDError, .unsafe("../victim"))
        }
        XCTAssertThrowsError(try m.resetToOriginal("../victim"))
        XCTAssertThrowsError(try m.delete("../victim"))
        XCTAssertThrowsError(try m.importAsset(from: sb.sentinel, for: "../victim"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.base.appendingPathComponent("victim.json").path))
    }

    func testSymlinkedThemeFolderIsNotFollowed() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        let link = sb.themes.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sb.victim)
        XCTAssertThrowsError(try m.save(hostileTheme(id: "linked")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.victim.appendingPathComponent(ThemeManager.themeFileName).path))
        XCTAssertThrowsError(try m.importAsset(from: sb.sentinel, for: "linked"))
        try m.resetToOriginal("linked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testImportOverSymlinkedDestinationLeavesTargetIntact() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        let link = sb.themes.appendingPathComponent("sunrise", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sb.victim)
        let pkg = tempDir().appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try ThemeManager.encoder.encode(hostileTheme(id: "sunrise", name: "Sunrise")).write(to: pkg.appendingPathComponent(ThemeManager.themeFileName))
        let imported = try m.importTheme(from: pkg)
        assertContained(m, imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.victim.appendingPathComponent(ThemeManager.themeFileName).path))
    }

    func testUserThemeFileWithTraversalIDLoadsUnderItsFileName() throws {
        let sb = try sandbox()
        try ThemeManager.encoder.encode(hostileTheme(id: "../victim", name: "Dropped")).write(to: sb.themes.appendingPathComponent("dropped.json"))
        let m = manager(sb.themes)
        XCTAssertNil(m.theme(withID: "../victim"))
        XCTAssertNotNil(m.theme(withID: "dropped"))
        try m.delete("dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.themes.appendingPathComponent("dropped.json").path))
    }

    func testReimportReplacesStagedWithoutLosingExisting() throws {
        let sb = try sandbox()
        let m = manager(sb.themes)
        let pkg = tempDir().appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([1]).write(to: pkg.appendingPathComponent("assets/a.png"))
        try ThemeManager.encoder.encode(hostileTheme(id: "dusk", name: "Dusk")).write(to: pkg.appendingPathComponent(ThemeManager.themeFileName))
        let first = try m.importTheme(from: pkg)
        XCTAssertEqual(first.id, "dusk")
        let second = try m.importTheme(from: pkg)
        XCTAssertNotEqual(second.id, "dusk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.userThemeFolder("dusk").appendingPathComponent("assets/a.png").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sb.themes.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }
}
