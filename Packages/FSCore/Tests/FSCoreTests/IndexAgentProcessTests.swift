import XCTest
@testable import FSCore

final class IndexAgentProcessTests: XCTestCase {
    private func sleeper() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        addTeardownBlock { if child.isRunning { child.terminate() } }
        return child
    }

    func testFindsProcessesByNameAndParent() throws {
        let child = try sleeper()
        let pid = child.processIdentifier
        XCTAssertTrue(SizeIndexService.processes(named: "sleep", parent: getpid()).contains(pid))
        XCTAssertFalse(SizeIndexService.processes(named: "sleep", parent: 1).contains(pid))
        XCTAssertFalse(SizeIndexService.processes(named: "slee", parent: getpid()).contains(pid))
        XCTAssertFalse(SizeIndexService.processes(named: "sleep", parent: getpid()).contains(getpid()))
    }

    func testTerminateStopsAProcessWithoutAskingIt() async throws {
        let child = try sleeper()
        let found = SizeIndexService.processes(named: "sleep", parent: getpid()).filter { $0 == child.processIdentifier }
        XCTAssertEqual(found, [child.processIdentifier])
        let stopped = await SizeIndexService.terminate(found)
        XCTAssertTrue(stopped)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    func testTerminateReportsWhenNothingWasRunning() async {
        let stopped = await SizeIndexService.terminate([])
        XCTAssertFalse(stopped)
    }

    func testStatusTextRoundTrips() {
        let running = SizeIndexStatus(isPaused: false, pendingFolders: 12, folders: 1_790_412)
        XCTAssertEqual(running.text, "running: 12 pending, 1790412 folders")
        XCTAssertEqual(SizeIndexStatus(running.text), running)
        let paused = SizeIndexStatus(isPaused: true, pendingFolders: 0, folders: 3)
        XCTAssertEqual(SizeIndexStatus(paused.text), paused)
        XCTAssertNil(SizeIndexStatus("unavailable"))
        XCTAssertNil(SizeIndexStatus("running: 5 pending"))
        XCTAssertNil(SizeIndexStatus("stopped: 1 pending, 2 folders"))
    }

    func testDaemonReportsParseableStatus() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-status-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tree/a/b"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let daemon = try SizeIndexDaemon(databaseURL: dir.appendingPathComponent("index.sqlite"))
        addTeardownBlock { daemon.stop() }
        _ = await daemon.pause()
        _ = await daemon.focus(paths: [dir.appendingPathComponent("tree").path])
        let queuedText = await daemon.status()
        let queued = try XCTUnwrap(SizeIndexStatus(queuedText))
        XCTAssertTrue(queued.isPaused)
        XCTAssertGreaterThan(queued.pendingFolders, 0)
        _ = await daemon.resume()
        daemon.drain()
        let settledText = await daemon.status()
        let settled = try XCTUnwrap(SizeIndexStatus(settledText))
        XCTAssertFalse(settled.isPaused)
        XCTAssertEqual(settled.pendingFolders, 0)
        XCTAssertEqual(settled.folders, 3)
    }
}
