import XCTest
@testable import FSCore

final class IndexSearchTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SizeIndexLocation.canonical(url)
    }

    private func make(_ url: URL, _ files: [String] = []) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files { try Data(count: 1).write(to: url.appendingPathComponent(name)) }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ more: [String]) { lock.lock(); paths.append(contentsOf: more); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func search(_ database: URL, _ query: String, under scope: URL, hidden: Bool = false, limit: Int = 5000) -> (paths: Set<String>, pass: SizeIndexSearcher.Pass) {
        let collector = Collector()
        let pass = SizeIndexSearcher(databaseURL: database).pass(query: query, under: scope, includeHidden: hidden, limit: limit, isCancelled: { false }) { collector.add($0) }
        XCTAssertEqual(collector.all.count, Set(collector.all).count)
        return (Set(collector.all), pass)
    }

    private func buildTree(_ tree: URL) throws {
        try make(tree.appendingPathComponent("Docs"), ["Report Q1.pdf", "notes.txt", "résumé final.doc"])
        try make(tree.appendingPathComponent("Docs/Reports Archive"), ["old-REPORT.txt"])
        try make(tree.appendingPathComponent(".hidden"), ["report-secret.txt"])
        try make(tree.appendingPathComponent("Tool.app/Contents"), ["report-inside-bundle"])
        try make(tree.appendingPathComponent("Other"), [".report-dotfile", "unrelated.bin"])
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        func hit(_ query: String, _ name: String) -> Bool {
            let matcher = NameMatcher(query)
            return Array(name.utf8).withUnsafeBufferPointer { matcher.matches($0) }
        }
        XCTAssertTrue(hit("report", "Annual REPORT.pdf"))
        XCTAssertTrue(hit("REPORT", "annual report.pdf"))
        XCTAssertTrue(hit("resume", "résumé final.doc"))
        XCTAssertTrue(hit("résumé", "My Resume.doc"))
        XCTAssertTrue(hit("日本", "東京日本語.txt"))
        XCTAssertTrue(hit(".pdf", "a.PDF"))
        XCTAssertFalse(hit("report", "repor"))
        XCTAssertFalse(hit("report", "re-port.txt"))
        XCTAssertFalse(hit("xyz", "résumé"))
        XCTAssertTrue(NameMatcher("").isEmpty)
    }

    func testSmallScopeFindsFilesAndFoldersButNotHiddenOrPackageContents() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try buildTree(tree)
        let database = temp.appendingPathComponent("index.sqlite")
        try SizeIndexWriter(databaseURL: database).scan(tree)
        let base = tree.path
        let found = search(database, "report", under: tree)
        XCTAssertEqual(found.paths, [base + "/Docs/Report Q1.pdf", base + "/Docs/Reports Archive", base + "/Docs/Reports Archive/old-REPORT.txt"])
        XCTAssertTrue(found.pass.found)
        XCTAssertFalse(found.pass.counting)
        XCTAssertFalse(found.pass.hitLimit)
        let everything = search(database, "report", under: tree, hidden: true)
        XCTAssertEqual(everything.paths, found.paths.union([base + "/.hidden/report-secret.txt", base + "/Other/.report-dotfile"]))
        XCTAssertEqual(search(database, "resume", under: tree).paths, [base + "/Docs/résumé final.doc"])
        XCTAssertEqual(search(database, "tool", under: tree).paths, [base + "/Tool.app"])
        XCTAssertEqual(search(database, "report", under: tree.appendingPathComponent("Docs/Reports Archive")).paths, [base + "/Docs/Reports Archive/old-REPORT.txt"])
        XCTAssertEqual(search(database, "inside", under: tree.appendingPathComponent("Tool.app")).paths, [base + "/Tool.app/Contents/report-inside-bundle"])
    }

    func testSweepOfALargeIndexMatchesTheWalk() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try buildTree(tree)
        for i in 0..<60 { try make(tree.appendingPathComponent("bulk/d\(i)"), ["report-\(i).txt", "x\(i)"]) }
        try make(temp.appendingPathComponent("outside"), ["report-elsewhere.txt"])
        let database = temp.appendingPathComponent("index.sqlite")
        let writer = try SizeIndexWriter(databaseURL: database)
        try writer.scan(tree)
        try writer.scan(temp.appendingPathComponent("outside"))
        let walked = search(database, "report", under: tree)
        try writer.db.run("UPDATE dirs SET items=items+10000000 WHERE parent=0", [])
        let swept = search(database, "report", under: tree)
        XCTAssertEqual(walked.paths.count, 63)
        XCTAssertEqual(swept.paths, walked.paths)
        let sweptHidden = search(database, "report", under: tree, hidden: true)
        XCTAssertEqual(sweptHidden.paths.count, 65)
        XCTAssertFalse(sweptHidden.paths.contains { $0.contains("outside") || $0.contains("inside-bundle") })
    }

    func testLimitStopsAndReportsOverflow() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try make(tree, (0..<50).map { "match-\($0).txt" })
        let database = temp.appendingPathComponent("index.sqlite")
        try SizeIndexWriter(databaseURL: database).scan(tree)
        let limited = search(database, "match", under: tree, limit: 20)
        XCTAssertEqual(limited.paths.count, 20)
        XCTAssertTrue(limited.pass.hitLimit)
        let exact = search(database, "match", under: tree, limit: 50)
        XCTAssertEqual(exact.paths.count, 50)
        XCTAssertFalse(exact.pass.hitLimit)
    }

    func testUnindexedScopeReportsNotFound() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try make(tree, ["a"])
        let database = temp.appendingPathComponent("index.sqlite")
        _ = try SizeIndexWriter(databaseURL: database)
        let result = search(database, "a", under: tree)
        XCTAssertFalse(result.pass.found)
        XCTAssertTrue(result.paths.isEmpty)
    }

    func testEngineSearchIndexesTheScopeThenStreamsResults() async throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try buildTree(tree)
        let database = temp.appendingPathComponent("index.sqlite")
        let daemon = try SizeIndexDaemon(databaseURL: database)
        defer { daemon.stop() }
        let engine = SizeEngine(databaseURL: database, control: daemon)
        var paths = Set<String>()
        var summary: IndexSearchSummary?
        for await event in engine.search("report", under: tree, includeHidden: false, limit: 5000) {
            switch event {
            case .paths(let more): paths.formUnion(more)
            case .finished(let s): summary = s
            }
        }
        XCTAssertEqual(summary, IndexSearchSummary(hitLimit: false, indexed: true))
        XCTAssertEqual(paths.count, 3)
        try Data(count: 1).write(to: tree.appendingPathComponent("Other/late report.txt"))
        _ = await daemon.refresh(paths: [tree.appendingPathComponent("Other").path])
        daemon.drain()
        var again = Set<String>()
        for await event in engine.search("REPORT", under: tree, includeHidden: false, limit: 5000) {
            if case .paths(let more) = event { again.formUnion(more) }
        }
        XCTAssertEqual(again, paths.union([tree.path + "/Other/late report.txt"]))
    }
}
