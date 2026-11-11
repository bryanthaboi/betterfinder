import XCTest
import Darwin
@testable import FSCore

final class SizeIndexTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testBulkKindsAndStreaming() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".hidden", "hello é.txt"] { try Data([1,2]).write(to: root.appendingPathComponent(name)) }
        for name in ["Folder", "Demo.app"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.appendingPathComponent("Folder").path)
        let items = try DirectoryLister.list(root, options: .init(showHidden: true, fetchTags: false))
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.first { $0.name == "link" }!.isSymlink)
        XCTAssertTrue(items.first { $0.name == "Demo.app" }!.isPackage)
        XCTAssertEqual(items.first { $0.name == "hello é.txt" }?.logicalSize, 2)
        XCTAssertEqual(try DirectoryLister.list(root).count, 4)
        var count = 0
        for try await batch in DirectoryLister.stream(root, batchSize: 2, options: .init(showHidden: true, fetchTags: false)) { XCTAssertLessThanOrEqual(batch.count, 2); count += batch.count }
        XCTAssertEqual(count, 5)
    }
    func testHardLinksDeltasWALAndSymlink() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let a = tree.appendingPathComponent("a")
        let b = tree.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = a.appendingPathComponent("f")
        try Data(count: 12345).write(to: file)
        try FileManager.default.linkItem(at: file, to: b.appendingPathComponent("hard"))
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 90000).write(to: outside.appendingPathComponent("skip"))
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("symbolic"), withDestinationURL: outside)
        let database = temp.appendingPathComponent("db.sqlite")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 12345)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 12345)
        XCTAssertEqual(reader.size(for: b)?.logicalBytes, 12345)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        try Data(count: 15000).write(to: file, options: [])
        try writer.enqueue(path: a.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 15000)
        XCTAssertEqual(reader.size(for: b)?.logicalBytes, 15000)
        try Data(count: 12345).write(to: file, options: [])
        try writer.enqueue(path: a.path, recursive: false)
        while try writer.processNext() {}
        try Data(count: 7).write(to: a.appendingPathComponent("new"))
        try writer.enqueue(path: a.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 12352)
        try FileManager.default.moveItem(at: a.appendingPathComponent("new"), to: b.appendingPathComponent("moved"))
        try writer.enqueue(path: a.path, recursive: false)
        try writer.enqueue(path: b.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 12352)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 12345)
        try FileManager.default.removeItem(at: b.appendingPathComponent("hard"))
        try FileManager.default.removeItem(at: file)
        try writer.enqueue(path: a.path, recursive: false)
        try writer.enqueue(path: b.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 7)
    }
    func testDeviceEventsReconcile() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let database = temp.appendingPathComponent("index.sqlite")
        let writer = try SizeIndexWriter(databaseURL: database)
        let reader = try SizeIndexReader(databaseURL: database)
        let queue = DispatchQueue(label: "size-index-event-test")
        let events = SizeIndexEvents(writer: writer, queue: queue)
        try queue.sync {
            try writer.addRoot(tree)
            try events.watch(tree)
            while try writer.processNext() {}
        }
        defer { queue.sync { events.stop() } }
        let updated = expectation(description: "FSEvents reconciles new file")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var fulfilled = false
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100))
        timer.setEventHandler {
            do {
                while try writer.processNext() {}
                if !fulfilled && reader.size(for: tree)?.logicalBytes == 321 {
                    fulfilled = true
                    updated.fulfill()
                }
            } catch { }
        }
        timer.resume()
        defer { timer.cancel() }
        try Data(count: 321).write(to: tree.appendingPathComponent("event-file"))
        wait(for: [updated], timeout: 10)
    }

    func testDirectoryMoveAndRemoval() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let a = tree.appendingPathComponent("a")
        let b = tree.appendingPathComponent("b")
        let sub = a.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(count: 42).write(to: sub.appendingPathComponent("file"))
        let db = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: db)
        let reader = try SizeIndexReader(databaseURL: db)
        try writer.scan(tree)
        try FileManager.default.moveItem(at: sub, to: b.appendingPathComponent("sub"))
        try writer.enqueue(path: b.path, recursive: false)
        try writer.enqueue(path: a.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 0)
        XCTAssertEqual(reader.size(for: b)?.logicalBytes, 42)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 42)
        XCTAssertEqual(reader.size(for: tree)?.items, 4)
        try FileManager.default.removeItem(at: b.appendingPathComponent("sub"))
        try writer.enqueue(path: b.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 0)
        XCTAssertEqual(reader.size(for: tree)?.items, 2)
    }

    func testTwentyThousandBenchmarkAndRSS() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for i in 0..<20000 {
            let fd = open(tree.appendingPathComponent("file-\(i).txt").path, O_CREAT | O_WRONLY, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            close(fd)
        }
        _ = try DirectoryLister.list(tree, options: .init(fetchTags: false))
        let start = Date()
        let items = try DirectoryLister.list(tree, options: .init(fetchTags: false))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(items.count, 20000)
        print("BULK_20K_SECONDS=\(elapsed)")
        #if !DEBUG
        XCTAssertLessThan(elapsed, 0.2)
        #endif
        let taggedStart = Date()
        XCTAssertEqual(try DirectoryLister.list(tree).count, 20000)
        let taggedElapsed = Date().timeIntervalSince(taggedStart)
        print("BULK_20K_DEFAULT_SECONDS=\(taggedElapsed)")
        #if !DEBUG
        XCTAssertLessThan(taggedElapsed, 0.2)
        #endif
        let writer = try SizeIndexWriter(databaseURL: temp.appendingPathComponent("index.sqlite"))
        try writer.scan(tree)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("WALKER_TEST_PROCESS_PEAK_RSS_BYTES=\(usage.ru_maxrss)")
        let reader = try SizeIndexReader(databaseURL: temp.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(reader.size(for: tree)?.items, 20000)
    }

    func testDeepTreeInitialScanSpeedAndTotals() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        var dirs = 0
        var files = 0
        var logical: Int64 = 0
        func make(_ url: URL, _ depth: Int) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            dirs += 1
            for i in 0..<4 {
                let size = 100 * (i + 1)
                try Data(count: size).write(to: url.appendingPathComponent("f\(i)"))
                files += 1
                logical += Int64(size)
            }
            if depth < 4 { for b in 0..<6 { try make(url.appendingPathComponent("d\(b)"), depth + 1) } }
        }
        try make(tree, 0)
        let link = tree.appendingPathComponent("d0/d1/linked")
        try FileManager.default.linkItem(at: tree.appendingPathComponent("d0/f3"), to: link)
        let database = temp.appendingPathComponent("db.sqlite")
        let writer = try SizeIndexWriter(databaseURL: database)
        let start = Date()
        try writer.scan(tree)
        let elapsed = Date().timeIntervalSince(start)
        print("DEEP_SCAN_DIRS=\(dirs) FILES=\(files) SECONDS=\(elapsed) DIRS_PER_SECOND=\(Double(dirs) / elapsed)")
        let reader = try SizeIndexReader(databaseURL: database)
        let size = try XCTUnwrap(reader.size(for: tree))
        XCTAssertEqual(size.logicalBytes, logical)
        XCTAssertEqual(size.items, dirs - 1 + files + 1)
        XCTAssertEqual(size.state, .complete)
        XCTAssertEqual(reader.size(for: tree.appendingPathComponent("d0"))?.logicalBytes, (logical - 1000) / 6)
        XCTAssertEqual(reader.size(for: tree.appendingPathComponent("d0/d1"))?.logicalBytes, ((logical - 1000) / 6 - 1000) / 6 + 400)
        XCTAssertEqual(writer.pendingCount, 0)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("d2"))
        try writer.enqueue(path: tree.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, logical - (logical - 1000) / 6)
        try writer.rebuild()
        XCTAssertEqual(reader.size(for: tree)?.state, .stale)
        while try writer.processBatch() > 0 {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, logical - (logical - 1000) / 6)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        #if !DEBUG
        XCTAssertGreaterThan(Double(dirs) / elapsed, 1000)
        #endif
    }

    func testForeignSchemaIsReplaced() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data(count: 64).write(to: tree.appendingPathComponent("a"))
        let database = temp.appendingPathComponent("old.sqlite")
        do {
            let db = try IndexDatabase(database)
            try db.exec("""
            CREATE TABLE roots(path TEXT PRIMARY KEY);
            CREATE TABLE directories(volume_uuid TEXT NOT NULL,inode TEXT NOT NULL,path TEXT UNIQUE,PRIMARY KEY(volume_uuid,inode));
            CREATE TABLE entries(volume_uuid TEXT,parent TEXT,name TEXT,PRIMARY KEY(volume_uuid,parent,name));
            CREATE TRIGGER count_add AFTER INSERT ON entries BEGIN SELECT 1; END;
            PRAGMA user_version=2;
            """)
        }
        let writer = try SizeIndexWriter(databaseURL: database)
        XCTAssertEqual(try writer.count("sqlite_master WHERE name IN ('directories','entries','count_add')"), 0)
        try writer.scan(tree)
        XCTAssertEqual(try SizeIndexReader(databaseURL: database).size(for: tree)?.logicalBytes, 64)
    }

    func testDirectoryRenameKeepsTotals() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let inner = tree.appendingPathComponent("x/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(count: 500).write(to: inner.appendingPathComponent("file"))
        try Data(count: 20).write(to: tree.appendingPathComponent("top"))
        let db = temp.appendingPathComponent("db")
        let writer = try SizeIndexWriter(databaseURL: db)
        let reader = try SizeIndexReader(databaseURL: db)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 520)
        try FileManager.default.moveItem(at: tree.appendingPathComponent("x"), to: tree.appendingPathComponent("y"))
        try writer.enqueue(path: tree.path, recursive: false)
        while try writer.processNext() {}
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 520)
        XCTAssertEqual(reader.size(for: tree)?.items, 4)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree.appendingPathComponent("y"))?.logicalBytes, 500)
        XCTAssertEqual(reader.size(for: tree.appendingPathComponent("y/inner"))?.logicalBytes, 500)
    }
}
