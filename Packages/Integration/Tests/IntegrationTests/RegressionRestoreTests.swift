import UniformTypeIdentifiers
import XCTest
@testable import Integration

final class RegressionRestoreTests: XCTestCase {
    let ours = "com.test.betterfinder"
    let mount = UTType("com.apple.mount-point")

    func freshDefaults() -> UserDefaults {
        let name = "RegressionRestoreTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func makeController(_ handlers: FakeHandlers, _ defaults: UserDefaults) -> DefaultFileManagerController {
        DefaultFileManagerController(bundleID: ours, appURL: URL(fileURLWithPath: "/Applications/BetterFinder.app"), preferences: InMemoryPreferencesWriter(), handlers: handlers, defaults: defaults)
    }

    func testRestoreResetsOptionalTypesThatHadNoPreviousHandler() async throws {
        let handlers = FakeHandlers()
        let c = makeController(handlers, freshDefaults())
        try await c.makeDefault()
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], ours)
        if let mount { XCTAssertEqual(handlers.handlers[mount.identifier], ours) }

        let report = try await c.restoreFinder()
        XCTAssertEqual(handlers.handlers[UTType.folder.identifier], "com.apple.finder")
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], "com.apple.finder")
        if let mount { XCTAssertEqual(handlers.handlers[mount.identifier], "com.apple.finder") }
        XCTAssertFalse(handlers.handlers.values.contains(ours))
        XCTAssertTrue(report.warnings.contains { $0.contains("public.directory") })
        XCTAssertFalse(c.status().hasRestorePoint)
    }

    func testFailedOptionalRestoreKeepsRestorePointAndWarns() async throws {
        let handlers = FakeHandlers()
        let c = makeController(handlers, freshDefaults())
        try await c.makeDefault()
        handlers.failing = [UTType.directory.identifier]
        let report = try await c.restoreFinder()
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], ours)
        XCTAssertTrue(report.warnings.contains { $0.contains("public.directory") && $0.contains("Try Restore again") })
        XCTAssertTrue(c.status().hasRestorePoint)

        handlers.failing = []
        _ = try await c.restoreFinder()
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], "com.apple.finder")
        XCTAssertFalse(c.status().hasRestorePoint)
    }

    func testRestoreLeavesOptionalTypeChangedToAnotherAppAlone() async throws {
        let handlers = FakeHandlers()
        let c = makeController(handlers, freshDefaults())
        try await c.makeDefault()
        handlers.handlers[UTType.directory.identifier] = "com.other.manager"
        _ = try await c.restoreFinder()
        XCTAssertEqual(handlers.handlers[UTType.directory.identifier], "com.other.manager")
    }
}
