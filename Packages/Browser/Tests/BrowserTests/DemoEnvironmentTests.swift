import XCTest
import FSCore
@testable import Browser

final class DemoEnvironmentTests: XCTestCase {
    @MainActor
    func testDemoIdentityVolumesAndScopes() throws {
        let keys = ["BETTERFINDER_DEMO", "BETTERFINDER_DEMO_COMPUTER", "BETTERFINDER_DEMO_USER", "BETTERFINDER_DEMO_VOLUMES", "CFFIXED_USER_HOME"]
        let saved = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("Users/alex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("BETTERFINDER_DEMO", "1", 1)
        setenv("CFFIXED_USER_HOME", home.path, 1)
        setenv("BETTERFINDER_DEMO_VOLUMES", root.path + ":/Volumes/Demo", 1)
        unsetenv("BETTERFINDER_DEMO_COMPUTER")
        unsetenv("BETTERFINDER_DEMO_USER")
        XCTAssertEqual(BrowserLocation.computer.displayName, "Studio Mac")
        XCTAssertEqual(DemoEnvironment.userName, "alex")
        setenv("BETTERFINDER_DEMO_COMPUTER", "Creative Mac", 1)
        setenv("BETTERFINDER_DEMO_USER", "sam", 1)
        XCTAssertEqual(BrowserLocation.computer.displayName, "Creative Mac")
        XCTAssertEqual(DemoEnvironment.userName, "sam")
        XCTAssertEqual(Set(DirectoryStream.listVolumes().map { $0.url.path }), [root.path])
        XCTAssertFalse(SidebarStore.defaultFavorites.contains("/Applications"))
        XCTAssertTrue(SidebarStore.defaultFavorites.dropFirst().allSatisfy { $0.hasPrefix(home.path) })
        XCTAssertEqual(BrowserLocation.folder(URL(fileURLWithPath: "/")).normalized.url?.path, home.path)
        XCTAssertEqual(BrowserLocation.search(scope: root, query: "report").normalized.scopeURL?.path, home.path)
        let search = MetadataSearch(kind: .name("report", scope: root))
        if case .name(_, let scope) = search.kind { XCTAssertEqual(scope.path, home.path) } else { XCTFail() }
        XCTAssertTrue(SizeIndexLocation.database.path.hasPrefix(home.path + "/"))
        XCTAssertEqual(SizeIndexService.status, .notRegistered)
        XCTAssertEqual(VolumeInfo.availableCapacity(for: home), try home.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertFalse(DemoEnvironment.contains(home.appendingPathComponent("escape/file"), in: home))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("root-link"), withDestinationURL: URL(fileURLWithPath: "/"))
        setenv("BETTERFINDER_DEMO_VOLUMES", "/:relative:" + root.appendingPathComponent("root-link").path, 1)
        XCTAssertTrue(DemoEnvironment.volumes.isEmpty)
        unsetenv("BETTERFINDER_DEMO")
        XCTAssertFalse(DemoEnvironment.isEnabled)
        XCTAssertEqual(DemoEnvironment.userName, NSUserName())
        XCTAssertEqual(BrowserLocation.folder(root).normalized.url?.path, root.path)
    }
}
