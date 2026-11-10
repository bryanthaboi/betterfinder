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
            checkNotarization: false,
            checkSignature: false,
            trashPreviousBundle: false
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
        let old = tmp.appendingPathComponent("Apps/betterfinder (previous).app")
        let inst = installer(bundle: bundle, pid: 4242)
        let args = inst.relaunchArguments(removing: old, logURL: tmp.appendingPathComponent("u.log"))
        XCTAssertEqual(args[0], "-c")
        XCTAssertEqual(args[1], UpdateInstaller.relaunchScript)
        XCTAssertEqual(Array(args[3...6]), ["4242", bundle.path, old.path, tmp.appendingPathComponent("u.log").path])
        XCTAssertEqual(inst.relaunchArguments(removing: nil, logURL: tmp.appendingPathComponent("u.log"))[5], "")
    }

    func release(_ version: String = "0.1.2") -> UpdateRelease {
        UpdateRelease(tag: "v\(version)", version: SemanticVersion(version)!, name: version, notes: "", pageURL: nil, publishedAt: nil, zipAsset: nil, dmgAsset: nil)
    }

    func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/app"), encoding: .utf8)
    }

    func installedVersion(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    func makeInstall(newBundleID: String = "com.bryanthaboi.betterfinder", newVersion: String = "0.1.2") throws -> (dest: URL, apps: URL, stage: URL, prepared: PreparedUpdate) {
        let apps = tmp.appendingPathComponent("Apps", isDirectory: true)
        let stage = tmp.appendingPathComponent("caches/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let dest = apps.appendingPathComponent("betterfinder.app")
        let new = stage.appendingPathComponent("0.1.2/unpacked/betterfinder.app")
        try makeFakeApp(at: dest, bundleID: "com.bryanthaboi.betterfinder", version: "0.1.1", marker: "old")
        try makeFakeApp(at: new, bundleID: newBundleID, version: newVersion, marker: "new")
        return (dest, apps, stage, PreparedUpdate(release: release(), appURL: new, stagingDirectory: stage))
    }

    func runScript(pid: Int32, dest: URL, old: URL?, opener: String = "/usr/bin/true") throws -> Int32 {
        let log = tmp.appendingPathComponent("script.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdateInstaller.relaunchScript, "x", String(pid), dest.path, old?.path ?? "", log.path]
        process.environment = ["BF_OPEN": opener, "PATH": "/usr/bin:/bin"]
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

    func makeOpener() throws -> (script: URL, record: URL) {
        let record = tmp.appendingPathComponent("opened.txt")
        let script = tmp.appendingPathComponent("opener.sh")
        try "#!/bin/sh\nprintf '%s' \"$1\" > '\(record.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, record)
    }

    func waitForFile(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return true }
            usleep(50_000)
        }
        return false
    }

    func testReplaceBundleSwapsInNewVersion() throws {
        let (dest, apps, _, prepared) = try makeInstall()
        let inst = installer(bundle: dest, pid: 77)
        let previous = try inst.replaceBundle(with: prepared)

        XCTAssertEqual(marker(dest), "new")
        XCTAssertEqual(installedVersion(dest), "0.1.2")
        XCTAssertEqual(previous, inst.previousBundleURL)
        XCTAssertEqual(marker(previous), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path).sorted(), ["betterfinder (previous).app", "betterfinder.app"])
    }

    func testReplaceBundleReplacesStaleLeftovers() throws {
        let (dest, apps, _, prepared) = try makeInstall()
        let inst = installer(bundle: dest)
        try makeFakeApp(at: inst.previousBundleURL, bundleID: "com.bryanthaboi.betterfinder", version: "0.0.9", marker: "stale")
        try makeFakeApp(at: inst.incomingBundleURL, bundleID: "com.bryanthaboi.betterfinder", version: "0.0.9", marker: "stale")
        let previous = try inst.replaceBundle(with: prepared)
        XCTAssertEqual(marker(dest), "new")
        XCTAssertEqual(marker(previous), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path).sorted(), ["betterfinder (previous).app", "betterfinder.app"])
    }

    func testReplaceBundleKeepsOldAppWhenNewIsMissing() throws {
        let (dest, apps, _, prepared) = try makeInstall()
        try FileManager.default.removeItem(at: prepared.appURL)
        XCTAssertThrowsError(try installer(bundle: dest).replaceBundle(with: prepared)) {
            guard case UpdateError.installFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(marker(dest), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testReplaceBundleRejectsWrongIdentityAndKeepsOldApp() throws {
        let (dest, apps, _, prepared) = try makeInstall(newBundleID: "com.evil.app")
        XCTAssertThrowsError(try installer(bundle: dest).replaceBundle(with: prepared)) {
            guard case UpdateError.verificationFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(marker(dest), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testReplaceBundleRejectsVersionThatIsNotNewer() throws {
        let (dest, apps, _, prepared) = try makeInstall(newVersion: "0.1.1")
        XCTAssertThrowsError(try installer(bundle: dest).replaceBundle(with: prepared)) {
            guard case UpdateError.verificationFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(marker(dest), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testReplaceBundleRejectsUnsignedAppWhenSignatureIsChecked() throws {
        let (dest, apps, _, prepared) = try makeInstall()
        let strict = UpdateInstaller(
            verifier: UpdateVerifier(currentVersion: SemanticVersion("0.1.1")),
            cachesDirectory: tmp.appendingPathComponent("caches/Updates"),
            bundleURL: dest,
            processID: 1,
            checkNotarization: false,
            trashPreviousBundle: false
        )
        XCTAssertThrowsError(try strict.replaceBundle(with: prepared)) {
            guard case UpdateError.verificationFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(marker(dest), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testInstallSwapsBundleBeforeRelaunchingIt() throws {
        let (dest, apps, stage, prepared) = try makeInstall()
        let (opener, record) = try makeOpener()
        setenv("BF_OPEN", opener.path, 1)
        defer { unsetenv("BF_OPEN") }

        try installer(bundle: dest, caches: stage, pid: try deadPID()).install(prepared)
        XCTAssertEqual(marker(dest), "new")
        XCTAssertEqual(installedVersion(dest), "0.1.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))

        XCTAssertTrue(waitForFile(record), (try? String(contentsOf: tmp.appendingPathComponent("caches/update.log"), encoding: .utf8)) ?? "no log")
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), dest.path)
        XCTAssertEqual(marker(dest), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testInstallFailureThrowsAndNeverRelaunches() throws {
        let (dest, apps, stage, prepared) = try makeInstall(newBundleID: "com.evil.app")
        let (opener, record) = try makeOpener()
        setenv("BF_OPEN", opener.path, 1)
        defer { unsetenv("BF_OPEN") }

        XCTAssertThrowsError(try installer(bundle: dest, caches: stage, pid: try deadPID()).install(prepared))
        XCTAssertEqual(marker(dest), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
        usleep(300_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("caches/update.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testRelaunchScriptRemovesPreviousAndOpensInstalledBundle() throws {
        let (dest, apps, _, prepared) = try makeInstall()
        let previous = try installer(bundle: dest).replaceBundle(with: prepared)
        let (opener, record) = try makeOpener()

        let status = try runScript(pid: try deadPID(), dest: dest, old: previous, opener: opener.path)
        XCTAssertEqual(status, 0, (try? String(contentsOf: tmp.appendingPathComponent("script.log"), encoding: .utf8)) ?? "")
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), dest.path)
        XCTAssertEqual(marker(dest), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["betterfinder.app"])
    }

    func testRelaunchScriptWaitsForTheAppToExit() throws {
        let (dest, _, _, _) = try makeInstall()
        let (opener, record) = try makeOpener()
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["30"]
        try app.run()
        defer { if app.isRunning { app.terminate() } }

        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", UpdateInstaller.relaunchScript, "x", String(app.processIdentifier), dest.path, "", tmp.appendingPathComponent("script.log").path]
        script.environment = ["BF_OPEN": opener.path, "PATH": "/usr/bin:/bin"]
        try script.run()
        usleep(700_000)
        XCTAssertTrue(script.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))

        app.terminate()
        app.waitUntilExit()
        script.waitUntilExit()
        XCTAssertEqual(script.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), dest.path)
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
