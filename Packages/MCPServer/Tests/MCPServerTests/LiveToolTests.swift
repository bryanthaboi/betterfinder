import Foundation
import ModKit
import ModValidation
import XCTest
@testable import MCPServer

final class LiveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    var loads = [LiveLoadRequest]()
    var unloads = [String]()
    var shots = [LiveScreenshotRequest]()
    var generation = 0
    var approvalRequired = true
    var developerMode = true
    var available = true
    var logLines = [LiveLogEntry]()
    func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

func recordingLive(_ r: LiveRecorder) -> LiveModHosting {
    ClosureLiveModHosting(
        status: {
            let (available, dev) = r.withLock { (r.available, r.developerMode) }
            return available ? LiveHostStatus(available: true, developerMode: dev, appVersion: "9.9", windows: [LiveWindow(id: "win-1", title: "Downloads")]) : .unavailable("app is not running")
        },
        load: { req in
            r.withLock { r.loads.append(req) }
            if req.approval == nil, r.withLock({ r.approvalRequired }) { throw LiveHostError.approvalRequired(id: "ap-1", review: obj(["wants": "load \(req.modID)".j])) }
            let g = r.withLock { () -> Int in r.generation += 1; return r.generation }
            return LiveLoadResult(generation: g)
        },
        unload: { id in r.withLock { r.unloads.append(id) }; return true },
        uiState: { _ in LiveUIState(windows: [LiveWindow(id: "win-1", title: "Downloads\u{7}")], surfaces: [obj(["kind": "toolbar", "id": "alice.demo.cmd"])], generation: r.withLock { r.generation }) },
        screenshot: { req in
            r.withLock { r.shots.append(req) }
            return pngBytes + Data(repeating: 7, count: 64)
        },
        logs: { _ in r.withLock { r.logLines } }
    )
}

final class LiveToolTests: XCTestCase {
    func loaded(_ h: Harness, _ r: LiveRecorder) async -> String {
        let (revision, receipt) = await h.validated()
        r.withLock { r.approvalRequired = false }
        let load = await h.call("mod_load", obj(["workspace": "alice.demo".j, "revision": revision.j, "receipt": receipt.j, "window": "win-1".j]))
        XCTAssertTrue(load.ok, load.errorMessage)
        return load.string("session")
    }

    func testLoadScreenshotLogsUnloadHappyPath() async throws {
        let r = LiveRecorder()
        r.logLines = (0..<5).map { LiveLogEntry(time: "2026-11-06T10:0\($0):00Z", level: "INFO", message: "line \($0) token=abcdef123456789 ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        let h = await Harness(live: recordingLive(r))
        let (revision, receipt) = await h.validated()
        let args: JSONValue = obj(["workspace": "alice.demo".j, "revision": revision.j, "receipt": receipt.j, "window": "win-1".j])

        let pending = await h.call("mod_load", args)
        XCTAssertTrue(pending.ok, pending.errorMessage)
        h.assertConforms("mod_load", pending)
        XCTAssertEqual(pending.string("pending"), "ap-1")
        XCTAssertEqual(pending.data["review"]?["wants"]?.stringValue, "load alice.demo")
        XCTAssertNil(pending.data["session"])

        let load = await h.call("mod_load", merged(args, ["approval": "ap-1".j]))
        XCTAssertTrue(load.ok, load.errorMessage)
        h.assertConforms("mod_load", load)
        let session = load.string("session")
        XCTAssertTrue(session.hasPrefix("sess-"))
        XCTAssertEqual(load.data["generation"]?.intValue, 1)
        let request = try XCTUnwrap(r.loads.last)
        XCTAssertEqual(request.modID, "alice.demo")
        XCTAssertEqual(request.treeHash, revision)
        XCTAssertEqual(request.workspacePath, h.workspaces.root.appendingPathComponent("alice.demo").path)
        XCTAssertEqual(request.windowID, "win-1")

        let reload = await h.call("mod_load", merged(args, ["approval": "ap-1".j]))
        XCTAssertEqual(reload.string("session"), session)
        XCTAssertEqual(reload.data["generation"]?.intValue, 2)

        let ui = await h.call("mod_ui_state", obj(["session": session.j]))
        XCTAssertTrue(ui.ok, ui.errorMessage)
        h.assertConforms("mod_ui_state", ui)
        XCTAssertEqual(ui.data["windows"]?[0]?["id"]?.stringValue, "win-1")
        XCTAssertFalse(ui.data["windows"]?[0]?["title"]?.stringValue?.contains("\u{7}") ?? true)
        XCTAssertEqual(ui.data["generation"]?.intValue, 2)

        let shot = await h.call("mod_screenshot", obj(["session": session.j, "window": "win-1".j]))
        XCTAssertTrue(shot.ok, shot.errorMessage)
        h.assertConforms("mod_screenshot", shot)
        let path = try XCTUnwrap(shot.data["path"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(path.hasPrefix(h.workspaces.root.appendingPathComponent("alice.demo").path + "/"), "screenshots must live outside the package tree")
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(shot.data["sha256"]?.stringValue, Hex.sha256(try Data(contentsOf: URL(fileURLWithPath: path))))
        let image = try XCTUnwrap(shot.content.first { $0["type"]?.stringValue == "image" })
        XCTAssertEqual(image["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(Data(base64Encoded: image["data"]?.stringValue ?? "")?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))

        let validateAfter = await h.call("mod_validate", obj(["workspace": "alice.demo".j, "revision": revision.j]))
        XCTAssertEqual(validateAfter.string("treeHash"), revision)
        let package = await h.call("mod_package", obj(["workspace": "alice.demo".j, "revision": revision.j, "receipt": validateAfter.string("receipt").j]))
        let archive = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(package.data["archive"]?["path"]?.stringValue)))
        XCTAssertFalse(archive.range(of: pngBytes.prefix(8)) != nil, "screenshots never enter the package")

        let logs = await h.call("mod_logs", obj(["session": session.j, "limit": 2.j]))
        XCTAssertTrue(logs.ok, logs.errorMessage)
        h.assertConforms("mod_logs", logs)
        XCTAssertEqual(logs.data["entries"]?.arrayValue?.count, 2)
        XCTAssertEqual(logs.data["entries"]?[0]?["level"]?.stringValue, "info")
        let text = logs.data["entries"]?.arrayValue?.compactMap { $0["message"]?.stringValue }.joined() ?? ""
        XCTAssertFalse(text.contains("abcdef123456789"), text)
        XCTAssertFalse(text.contains("ghp_"), text)
        let cursor = try XCTUnwrap(logs.data["next"]?.stringValue)
        let more = await h.call("mod_logs", obj(["session": session.j, "limit": 10.j, "cursor": cursor.j]))
        XCTAssertEqual(more.data["entries"]?.arrayValue?.count, 3)
        XCTAssertNil(more.data["next"])
        let badCursor = await h.call("mod_logs", obj(["session": session.j, "limit": 10.j, "cursor": "o999".j]))
        XCTAssertEqual(badCursor.errorCode, "invalid_cursor")

        let unload = await h.call("mod_unload", obj(["session": session.j]))
        XCTAssertEqual(unload.data["unloaded"]?.boolValue, true)
        XCTAssertEqual(r.unloads, ["alice.demo"])
        let again = await h.call("mod_ui_state", obj(["session": session.j]))
        XCTAssertEqual(again.errorCode, "unknown_session")
    }

    func testLoadRequiresReceiptWindowAndDeveloperMode() async throws {
        let r = LiveRecorder()
        let h = await Harness(live: recordingLive(r))
        let (revision, receipt) = await h.validated()
        r.withLock { r.approvalRequired = false }
        let base: JSONValue = obj(["workspace": "alice.demo".j, "revision": revision.j, "receipt": receipt.j, "window": "win-1".j])

        let forged = await h.call("mod_load", merged(base, ["receipt": "rcpt-forged".j]))
        XCTAssertEqual(forged.errorCode, "receipt_invalid")
        let badWindow = await h.call("mod_load", merged(base, ["window": "win-404".j]))
        XCTAssertEqual(badWindow.errorCode, "invalid_window")
        XCTAssertNotNil(badWindow.structured["error"]?["details"]?["windows"])
        r.withLock { r.developerMode = false }
        let noDev = await h.call("mod_load", base)
        XCTAssertEqual(noDev.errorCode, "developer_mode_required")
        r.withLock { r.developerMode = true; r.available = false }
        let down = await h.call("mod_load", base)
        XCTAssertEqual(down.errorCode, "live_unavailable")
        XCTAssertEqual(down.errorMessage, "app is not running")
        XCTAssertTrue(r.loads.isEmpty)

        let edit = await h.call("mod_files_write", obj(["workspace": "alice.demo".j, "expected": revision.j, "changes": [obj(["path": "N.md", "text": "x".j])].j]))
        r.withLock { r.available = true }
        let stale = await h.call("mod_load", base)
        XCTAssertEqual(stale.errorCode, "stale_revision")
        _ = edit
    }

    func testCliOnlyModeReportsLiveToolsUnavailable() async throws {
        let h = await Harness()
        let (revision, receipt) = await h.validated()
        let load = await h.call("mod_load", obj(["workspace": "alice.demo".j, "revision": revision.j, "receipt": receipt.j, "window": "w".j]))
        XCTAssertTrue(load.isError)
        XCTAssertEqual(load.errorCode, "live_unavailable")
        let shot = await h.call("mod_screenshot", obj(["session": "sess-x".j, "window": "w".j]))
        XCTAssertEqual(shot.errorCode, "unknown_session")
    }

    func testSessionsAreOwnedByTheServerNotTheCaller() async throws {
        let r = LiveRecorder()
        let h = await Harness(live: recordingLive(r))
        _ = await loaded(h, r)
        for tool in ["mod_unload", "mod_ui_state", "mod_logs", "mod_screenshot"] {
            var args: [String: JSONValue] = ["session": "alice.demo".j]
            if tool == "mod_logs" { args["limit"] = 5.j }
            if tool == "mod_screenshot" { args["window"] = "win-1".j }
            let result = await h.call(tool, .object(args))
            XCTAssertEqual(result.errorCode, "unknown_session", tool)
        }
        XCTAssertTrue(r.unloads.isEmpty)
        XCTAssertTrue(r.shots.isEmpty)
    }

    func testInvalidScreenshotFromAppIsRejected() async throws {
        let r = LiveRecorder()
        let live = ClosureLiveModHosting(
            status: { LiveHostStatus(available: true, developerMode: true, windows: [LiveWindow(id: "win-1", title: "x")]) },
            load: { _ in LiveLoadResult(generation: 1) },
            unload: { _ in true },
            uiState: { _ in LiveUIState(windows: [], surfaces: [], generation: 1) },
            screenshot: { _ in Data("<html>not a png</html>".utf8) },
            logs: { _ in [] }
        )
        let h = await Harness(live: live)
        let session = await loaded(h, r)
        let shot = await h.call("mod_screenshot", obj(["session": session.j, "window": "win-1".j]))
        XCTAssertEqual(shot.errorCode, "screenshot_invalid")
    }

    func testLiveFailureCarriesDiagnostics() async throws {
        let diagnostic = ModDiagnostic(.invalidValue, message: "activation failed")
        let live = ClosureLiveModHosting(
            status: { LiveHostStatus(available: true, developerMode: true, windows: [LiveWindow(id: "win-1", title: "x")]) },
            load: { _ in throw LiveHostError.failed("reload failed; kept the previous version", [diagnostic]) },
            unload: { _ in true },
            uiState: { _ in LiveUIState(windows: [], surfaces: [], generation: 1) },
            screenshot: { _ in pngBytes },
            logs: { _ in [] }
        )
        let h = await Harness(live: live)
        let (revision, receipt) = await h.validated()
        let load = await h.call("mod_load", obj(["workspace": "alice.demo".j, "revision": revision.j, "receipt": receipt.j, "window": "win-1".j]))
        XCTAssertEqual(load.errorCode, "live_failed")
        XCTAssertEqual(load.structured["error"]?["diagnostics"]?[0]?["message"]?.stringValue, "activation failed")
    }

    func testDryRunnerIsUsedByValidate() async throws {
        struct Failing: DryRunning {
            func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] { [] }
        }
        let h = await Harness(dryRunner: Failing())
        let s = await h.scaffold()
        let v = await h.call("mod_validate", obj(["workspace": "alice.demo".j, "revision": s.string("revision").j]))
        XCTAssertEqual(v.data["checks"]?["dryRun"]?.stringValue, "pass")
        XCTAssertEqual(v.data["ok"]?.boolValue, true)
    }
}
