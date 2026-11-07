import XCTest
@testable import Updates

final class InstallerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws { tmp = try makeTempDirectory() }

    override func tearDown() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path) }
        }
        try? fm.removeItem(at: tmp)
    }

    func installer(bundle: URL, caches: URL? = nil, pid: Int32 = 1) -> UpdateInstaller {
        UpdateInstaller(
            verifier: UpdateVerifier(currentVersion: SemanticVersion("0.1.1")),
            cachesDirectory: caches ?? tmp.appendingPathComponent("caches/Updates"),
            bundleURL: bundle,
            processID: pid,
            checkNotarization: false
        )
    }

    func testLocationRejectsNonApp() {
        XCTAssertThrowsError(try InstallLocation.validate(bundleURL: URL(fileURLWithPath: "/usr/bin/tool"))) {
            guard case UpdateError.notInstallable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testLocationRejectsTranslocation() {
        let url = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/betterfinder.app")
        XCTAssertThrowsError(try InstallLocation.validate(bundleURL: url)) {
            XCTAssertTrue(($0 as? UpdateError)?.errorDescription?.contains("Applications") ?? false)
        }
    }

    func testLocationRejectsReadOnlyParent() throws {
        let dir = tmp.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "x", version: "1")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try InstallLocation.validate(bundleURL: app)) {
            XCTAssertTrue(($0 as? UpdateError)?.errorDescription?.contains("isn't writable") ?? false)
        }
    }

    func testLocationAcceptsWritableParent() throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "x", version: "1")
        XCTAssertNoThrow(try InstallLocation.validate(bundleURL: app))
    }

    func testUnpackFindsSingleApp() throws {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeFakeApp(at: src.appendingPathComponent("betterfinder.app"), bundleID: "com.bryanthaboi.betterfinder", version: "0.1.2")
        let zip = tmp.appendingPathComponent("a.zip")
        let result = UpdateVerifier.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.appendingPathComponent("betterfinder.app").path, zip.path])
        XCTAssertEqual(result.status, 0, result.output)
        let app = try installer(bundle: tmp.appendingPathComponent("betterfinder.app")).unpack(zip: zip, into: tmp.appendingPathComponent("out"))
        XCTAssertEqual(app.lastPathComponent, "betterfinder.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    }

    func testUnpackRejectsBadArchive() throws {
        let zip = tmp.appendingPathComponent("bad.zip")
        try Data("nope".utf8).write(to: zip)
        XCTAssertThrowsError(try installer(bundle: tmp.appendingPathComponent("betterfinder.app")).unpack(zip: zip, into: tmp.appendingPathComponent("out")))
    }

    func testDownloadRequestUsesAPIURLWithToken() throws {
        let release = try UpdateRelease.parse(fixtureData("release"))
        let asset = release.zipAsset!
        let plain = installer(bundle: tmp).downloadRequest(for: asset)
        XCTAssertEqual(plain.url, asset.downloadURL)
        XCTAssertNil(plain.value(forHTTPHeaderField: "Authorization"))

        let authed = UpdateInstaller(
            verifier: UpdateVerifier(currentVersion: nil),
            tokenProvider: { "tok" },
            cachesDirectory: tmp,
            bundleURL: tmp.appendingPathComponent("betterfinder.app")
        ).downloadRequest(for: asset)
        XCTAssertEqual(authed.url, asset.apiURL)
        XCTAssertEqual(authed.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(authed.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testRelaunchArguments() throws {
        let bundle = tmp.appendingPathComponent("Apps/betterfinder.app")
        let prepared = PreparedUpdate(
            release: try UpdateRelease.parse(fixtureData("release")),
            appURL: tmp.appendingPathComponent("stage/betterfinder.app"),
            stagingDirectory: tmp.appendingPathComponent("stage")
        )
        let args = installer(bundle: bundle, pid: 4242).relaunchArguments(for: prepared, logURL: tmp.appendingPathComponent("u.log"))
        XCTAssertEqual(args[0], "-c")
        XCTAssertEqual(args[1], UpdateInstaller.relaunchScript)
        XCTAssertEqual(Array(args[3...7]), ["4242", prepared.appURL.path, bundle.path, prepared.stagingDirectory.path, tmp.appendingPathComponent("u.log").path])
    }

    func runScript(pid: Int32, new: URL, dest: URL, stage: URL, home: URL) throws -> Int32 {
        let log = tmp.appendingPathComponent("script.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdateInstaller.relaunchScript, "x", String(pid), new.path, dest.path, stage.path, log.path]
        process.environment = ["HOME": home.path, "BF_OPEN": "/usr/bin/true", "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func deadPID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    func testRelaunchScriptSwapsBundleAndTrashesOld() throws {
        let apps = tmp.appendingPathComponent("Apps", isDirectory: true)
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let stage = tmp.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dest = apps.appendingPathComponent("betterfinder.app")
        let new = stage.appendingPathComponent("unpacked/betterfinder.app")
        try makeFakeApp(at: dest, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.1", marker: "old")
        try makeFakeApp(at: new, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.2", marker: "new")

        let status = try runScript(pid: try deadPID(), new: new, dest: dest, stage: stage, home: home)
        XCTAssertEqual(status, 0, (try? String(contentsOf: tmp.appendingPathComponent("script.log"), encoding: .utf8)) ?? "")

        let marker = try String(contentsOf: dest.appendingPathComponent("Contents/MacOS/app"), encoding: .utf8)
        XCTAssertEqual(marker, "new")
        let trash = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".Trash").path)
        XCTAssertEqual(trash.count, 1)
        XCTAssertTrue(trash[0].hasPrefix("betterfinder "))
        let trashed = try String(contentsOf: home.appendingPathComponent(".Trash/\(trash[0])/Contents/MacOS/app"), encoding: .utf8)
        XCTAssertEqual(trashed, "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        XCTAssertEqual(leftovers, ["betterfinder.app"])
    }

    func testRelaunchScriptKeepsOldAppWhenNewIsMissing() throws {
        let apps = tmp.appendingPathComponent("Apps", isDirectory: true)
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dest = apps.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: dest, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.1", marker: "old")

        let status = try runScript(pid: try deadPID(), new: tmp.appendingPathComponent("nope.app"), dest: dest, stage: tmp.appendingPathComponent("stage"), home: home)
        XCTAssertNotEqual(status, 0)
        let marker = try String(contentsOf: dest.appendingPathComponent("Contents/MacOS/app"), encoding: .utf8)
        XCTAssertEqual(marker, "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testPrepareFailsEarlyWhenNotInstallable() async throws {
        let release = try UpdateRelease.parse(fixtureData("release"))
        let inst = installer(bundle: URL(fileURLWithPath: "/usr/bin/tool"))
        do {
            _ = try await inst.prepare(release) { _ in }
            XCTFail("expected throw")
        } catch {
            guard case UpdateError.notInstallable = error else { return XCTFail("\(error)") }
        }
    }

    func testPrepareFailsWithoutZipAsset() async throws {
        let app = tmp.appendingPathComponent("betterfinder.app")
        try makeFakeApp(at: app, bundleID: "x", version: "1")
        let release = try UpdateRelease.parse(Data(#"{"tag_name":"v9.9.9"}"#.utf8))
        do {
            _ = try await installer(bundle: app).prepare(release) { _ in }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? UpdateError, .noZipAsset)
        }
    }
}
