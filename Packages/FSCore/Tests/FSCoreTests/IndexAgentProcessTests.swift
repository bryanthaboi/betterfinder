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

    private func status(of daemon: SizeIndexDaemon, until accept: (SizeIndexStatus) -> Bool) async -> SizeIndexStatus? {
        let end = Date().addingTimeInterval(5)
        var latest: SizeIndexStatus?
        while Date() < end {
            latest = SizeIndexStatus(await daemon.status())
            if let latest, accept(latest) { return latest }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return latest
    }

    private func tree(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tree/a/b"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDaemonReportsParseableStatus() async throws {
        let dir = try tree("status")
        let daemon = try SizeIndexDaemon(databaseURL: dir.appendingPathComponent("index.sqlite"))
        addTeardownBlock { daemon.stop() }
        _ = await daemon.pause()
        _ = await daemon.focus(paths: [dir.appendingPathComponent("tree").path])
        let queued = await status(of: daemon) { $0.isPaused && $0.pendingFolders > 0 }
        XCTAssertEqual(queued?.isPaused, true)
        XCTAssertGreaterThan(queued?.pendingFolders ?? 0, 0)
        _ = await daemon.resume()
        daemon.drain()
        let settled = await status(of: daemon) { !$0.isPaused }
        XCTAssertEqual(settled, SizeIndexStatus(isPaused: false, pendingFolders: 0, folders: 3))
    }

    func testDaemonAnswersWhileItsQueueIsBlocked() async throws {
        let dir = try tree("blocked")
        let daemon = try SizeIndexDaemon(databaseURL: dir.appendingPathComponent("index.sqlite"))
        addTeardownBlock { daemon.stop() }
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal() }
        daemon.occupy { gate.wait() }
        let began = Date()
        let accepted = await daemon.focus(paths: [dir.appendingPathComponent("tree").path])
        let refreshed = await daemon.refresh(paths: [dir.appendingPathComponent("tree/a").path])
        let text = await daemon.status()
        XCTAssertTrue(accepted)
        XCTAssertTrue(refreshed)
        XCTAssertNotNil(SizeIndexStatus(text))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)

        daemon.stallLimit = 0.05
        try await Task.sleep(nanoseconds: 150_000_000)
        let stalled = await daemon.status()
        XCTAssertEqual(stalled, "unavailable")

        daemon.stallLimit = 60
        gate.signal()
        daemon.drain()
        let settled = await status(of: daemon) { $0.folders == 3 }
        XCTAssertEqual(settled, SizeIndexStatus(isPaused: false, pendingFolders: 0, folders: 3))
    }
}
