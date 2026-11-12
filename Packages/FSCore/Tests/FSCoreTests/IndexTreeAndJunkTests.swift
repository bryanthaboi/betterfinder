import XCTest
@testable import FSCore

final class IndexTreeAndJunkTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bf-tree-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SizeIndexLocation.canonical(url)
    }

    private func make(_ url: URL, files: [String: Int] = [:]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, size) in files { try Data(count: size).write(to: url.appendingPathComponent(name)) }
    }

    private func index(_ root: URL, in temp: URL) throws -> SizeIndexTree {
        let database = temp.appendingPathComponent("index.sqlite")
        let writer = try SizeIndexWriter(databaseURL: database)
        try writer.scan(root)
        return try SizeIndexTree(databaseURL: database)
    }

    func testTreeListsChildrenLargestFirstWithPathsAndTotals() throws {
        let temp = try temporary()
        let root = temp.appendingPathComponent("root")
        try make(root.appendingPathComponent("small"), files: ["a": 5_000])
        try make(root.appendingPathComponent("big/inner"), files: ["b": 400_000])
        try make(root.appendingPathComponent("big"), files: ["c": 50_000])
        try make(root.appendingPathComponent("empty"))
        try make(root, files: ["loose": 20_000, "tiny": 10])
        let tree = try index(root, in: temp)

        let top = try XCTUnwrap(tree.folder(at: root))
        XCTAssertEqual(top.name, "root")
        XCTAssertEqual(top.items, 9)
        XCTAssertFalse(top.isCounting)
        let children = tree.children(of: top.id)
        XCTAssertEqual(children.map(\.name), ["big", "small", "empty"])
        XCTAssertEqual(children.last?.allocatedBytes, 0)
        XCTAssertGreaterThan(top.allocatedBytes, children.reduce(0) { $0 + $1.allocatedBytes })

        let big = try XCTUnwrap(children.first)
        let inner = try XCTUnwrap(tree.children(of: big.id).first)
        XCTAssertEqual(tree.path(of: inner.id), root.appendingPathComponent("big/inner").path)
        XCTAssertEqual(tree.path(of: top.id), root.path)
        XCTAssertEqual(tree.folder(id: inner.id), inner)
        XCTAssertNil(tree.folder(at: temp.appendingPathComponent("missing")))

        let stats = tree.statistics()
        XCTAssertEqual(stats.roots, [root.path])
        XCTAssertEqual(stats.folders, 5)
        XCTAssertEqual(stats.items, 9)
        XCTAssertEqual(stats.allocatedBytes, top.allocatedBytes)
        XCTAssertEqual(stats.pendingFolders, 0)
        XCTAssertEqual(stats.unscannedFolders, 0)
        XCTAssertTrue(stats.isComplete)
        XCTAssertGreaterThan(stats.databaseBytes, 0)

        let files = SizeIndexTree.files(in: root)
        XCTAssertEqual(files.map(\.name), ["loose", "tiny"])
        XCTAssertEqual(SizeIndexTree.files(in: root, limit: 1).map(\.name), ["loose"])
    }

    func testJunkScanFindsOnlyWhatTheRulesDescribe() throws {
        let temp = try temporary()
        let home = temp.appendingPathComponent("home")
        try make(home.appendingPathComponent("Library/Caches/BigApp"), files: ["blob": 300_000])
        try make(home.appendingPathComponent("Library/Caches/Quiet"), files: ["x": 10])
        try make(home.appendingPathComponent("Library/Logs/Chatty"), files: ["old.log": 100_000])
        try make(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc"), files: ["o": 200_000])
        try make(home.appendingPathComponent(".npm/_cacache"), files: ["c": 150_000])
        try make(home.appendingPathComponent("code/site/node_modules/dep/node_modules"), files: ["n": 60_000])
        try make(home.appendingPathComponent("code/site/node_modules/dep"), files: ["m": 60_000])
        try make(home.appendingPathComponent("code/rusty/target"), files: ["bin": 90_000])
        try make(home.appendingPathComponent("code/rusty"), files: ["Cargo.toml": 10])
        try make(home.appendingPathComponent("code/plain/target"), files: ["keep": 90_000])
        try make(home.appendingPathComponent("Library/Tool/node_modules"), files: ["t": 90_000])
        try make(home.appendingPathComponent(".hidden/proj/node_modules"), files: ["h": 90_000])
        try make(home.appendingPathComponent("Downloads"), files: ["Setup.DMG": 120_000, "notes.txt": 120_000, "small.pkg": 10])
        try make(home.appendingPathComponent(".Trash"), files: ["gone": 70_000])
        let leftovers = home.appendingPathComponent("Library/Containers/app/Data/tmp")
        for i in 0..<8 { try make(leftovers.appendingPathComponent("left-\(i)")) }
        try make(leftovers.appendingPathComponent("used"), files: ["real": 10])
        for i in 0..<3 { try make(home.appendingPathComponent("code/few/e\(i)")) }

        let tree = try index(home, in: temp)
        var scanner = JunkScanner(home: home)
        scanner.minimumBytes = 40_000
        scanner.emptyClusterMinimum = 5
        let groups = scanner.scan(tree)
        func titles(_ id: String) -> [String] { groups.first { $0.id == id }?.items.map(\.title) ?? [] }

        XCTAssertEqual(groups.map(\.id), ["leftovers", "trash", "caches", "developer", "packages", "projects", "logs", "installers"])
        XCTAssertEqual(titles("caches"), ["BigApp"])
        XCTAssertEqual(titles("logs"), ["Chatty"])
        XCTAssertEqual(titles("developer"), ["App-abc"])
        XCTAssertEqual(titles("packages"), ["npm cache"])
        XCTAssertEqual(titles("projects"), ["node_modules in site", "target in rusty"])
        XCTAssertEqual(titles("installers"), ["Setup.DMG"])
        XCTAssertEqual(titles("trash"), ["Trash"])
        XCTAssertEqual(groups.first { $0.id == "trash" }?.items.first?.action, .emptyTrash)

        let cluster = try XCTUnwrap(groups.first { $0.id == "leftovers" }?.items.first)
        XCTAssertEqual(groups.first { $0.id == "leftovers" }?.items.count, 1)
        XCTAssertEqual(cluster.url.path, leftovers.path)
        XCTAssertEqual(cluster.action, .removeEmptyFolders(8))
        XCTAssertEqual(cluster.bytes, 0)
        let caches = try XCTUnwrap(groups.first { $0.id == "caches" })
        XCTAssertEqual(caches.bytes, caches.items[0].bytes)
        XCTAssertGreaterThanOrEqual(caches.bytes, 300_000)

        try Data(count: 5).write(to: leftovers.appendingPathComponent("left-3/arrived-later"))
        var reported = 0
        let removed = JunkScanner.removeEmptyFolders(in: leftovers, tree: tree) { reported = $0 }
        XCTAssertEqual(removed, 7)
        XCTAssertEqual(reported, 7)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: leftovers.path).sorted(), ["left-3", "used"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftovers.appendingPathComponent("left-3/arrived-later").path))
    }

    func testJunkScanOfAnEmptyHomeFindsNothing() throws {
        let temp = try temporary()
        let home = temp.appendingPathComponent("home")
        try make(home.appendingPathComponent("Documents"), files: ["essay": 900_000])
        let tree = try index(home, in: temp)
        XCTAssertEqual(JunkScanner(home: home).scan(tree), [])
        XCTAssertEqual(JunkScanner.removeEmptyFolders(in: home.appendingPathComponent("Documents"), tree: tree), 0)
    }
}
