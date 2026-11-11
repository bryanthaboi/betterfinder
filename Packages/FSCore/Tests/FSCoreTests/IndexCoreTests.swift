import XCTest
import Darwin
@testable import FSCore

final class IndexCoreTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SizeIndexLocation.canonical(url)
    }

    private func open(_ temp: URL) throws -> (SizeIndexWriter, SizeIndexReader) {
        let database = temp.appendingPathComponent("index.sqlite")
        return (try SizeIndexWriter(databaseURL: database), try SizeIndexReader(databaseURL: database))
    }

    private func make(_ url: URL, files: [String: Int] = [:]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, size) in files { try Data(count: size).write(to: url.appendingPathComponent(name)) }
    }

    private func rescan(_ writer: SizeIndexWriter, _ urls: URL...) throws {
        for url in urls { try writer.enqueue(path: url.path, recursive: false) }
        try writer.drain()
    }

    func testMoveIsAdoptedWithoutRecountingWhenSourceIsSeenFirst() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let a = tree.appendingPathComponent("a"), b = tree.appendingPathComponent("b")
        let sub = a.appendingPathComponent("sub")
        try make(sub.appendingPathComponent("deep"), files: ["f": 700])
        try make(sub, files: ["g": 300])
        try make(b)
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 1000)
        let moved = b.appendingPathComponent("sub")
        try FileManager.default.moveItem(at: sub, to: moved)
        let before = try writer.stamp(moved.appendingPathComponent("deep"))
        try rescan(writer, a)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 0)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 0)
        XCTAssertEqual(reader.size(for: moved)?.logicalBytes, 1000)
        XCTAssertEqual(try writer.collectGarbage(olderThan: 3600), 0)
        try rescan(writer, b)
        XCTAssertEqual(reader.size(for: b)?.logicalBytes, 1000)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 1000)
        XCTAssertEqual(reader.size(for: tree)?.items, 6)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(try writer.stamp(moved.appendingPathComponent("deep")), before)
        XCTAssertEqual(try writer.collectGarbage(olderThan: 0), 0)
        XCTAssertEqual(try writer.count("dirs"), 5)
    }

    func testDeletedSubtreeIsCollected() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let doomed = tree.appendingPathComponent("doomed")
        for i in 0..<30 { try make(doomed.appendingPathComponent("d\(i)/inner"), files: ["f": 10]) }
        try make(tree, files: ["keep": 5])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        XCTAssertEqual(try writer.count("dirs"), 62)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 305)
        try FileManager.default.removeItem(at: doomed)
        try rescan(writer, tree)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 5)
        XCTAssertEqual(reader.size(for: tree)?.items, 1)
        XCTAssertEqual(try writer.count("dirs"), 62)
        XCTAssertEqual(try writer.collectGarbage(olderThan: 0, budget: 20), 20)
        XCTAssertEqual(try writer.count("dirs"), 42)
        while try writer.collectGarbage(olderThan: 0, budget: 20) > 0 {}
        XCTAssertEqual(try writer.count("dirs"), 1)
        XCTAssertEqual(try writer.count("files"), 1)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 5)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
    }

    func testRenamedParentDoesNotLoseOrRecountPendingChildren() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let parent = tree.appendingPathComponent("p")
        let child = parent.appendingPathComponent("mid/c")
        try make(child, files: ["f": 100])
        try make(parent.appendingPathComponent("other"), files: ["o": 40])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        try Data(count: 900).write(to: child.appendingPathComponent("f"))
        try writer.enqueue(path: child.path, recursive: false)
        let renamed = tree.appendingPathComponent("q")
        try FileManager.default.moveItem(at: parent, to: renamed)
        let untouched = try writer.stamp(renamed.appendingPathComponent("other"))
        XCTAssertEqual(reader.size(for: renamed)?.logicalBytes, 140)
        try writer.drain()
        XCTAssertEqual(writer.pendingCount, 0)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 940)
        XCTAssertEqual(reader.size(for: renamed)?.logicalBytes, 940)
        XCTAssertEqual(reader.size(for: renamed.appendingPathComponent("mid/c"))?.logicalBytes, 900)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(try writer.stamp(renamed.appendingPathComponent("other")), untouched)
        XCTAssertEqual(try writer.count("dirs"), 5)
    }

    func testFocusedFolderIsScannedFirst() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        for name in ["a", "b", "c", "d"] {
            for i in 0..<6 { try make(tree.appendingPathComponent("\(name)/n\(i)/deep"), files: ["f": 10]) }
        }
        let (writer, reader) = try open(temp)
        try writer.addRoot(tree)
        let wanted = tree.appendingPathComponent("c")
        try writer.focus(on: [wanted])
        XCTAssertEqual(reader.size(for: wanted)?.isCounting, true)
        var steps = 0
        while reader.size(for: wanted)?.state != .complete {
            XCTAssertTrue(try writer.processNext())
            steps += 1
            XCTAssertLessThan(steps, 20)
        }
        XCTAssertEqual(steps, 13)
        XCTAssertEqual(reader.size(for: wanted)?.logicalBytes, 60)
        XCTAssertEqual(reader.size(for: tree)?.isCounting, true)
        try writer.drain()
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 240)
        XCTAssertEqual(reader.size(for: tree)?.items, 4 + 24 * 3)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
    }

    func testParallelScanMatchesSerialScan() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        var expected: Int64 = 0
        for a in 0..<12 {
            for b in 0..<12 {
                let size = 7 * (a + 1) + b
                try make(tree.appendingPathComponent("a\(a)/b\(b)"), files: ["x": size, "y": 3])
                expected += Int64(size + 3)
            }
        }
        try FileManager.default.linkItem(at: tree.appendingPathComponent("a0/b0/x"), to: tree.appendingPathComponent("a5/b5/linked"))
        let serial = try SizeIndexWriter(databaseURL: temp.appendingPathComponent("serial.sqlite"))
        try serial.scan(tree)
        let parallel = try SizeIndexWriter(databaseURL: temp.appendingPathComponent("parallel.sqlite"))
        parallel.scanWidth = 4
        try parallel.scan(tree)
        let one = try XCTUnwrap(SizeIndexReader(databaseURL: temp.appendingPathComponent("serial.sqlite")).size(for: tree))
        let two = try XCTUnwrap(SizeIndexReader(databaseURL: temp.appendingPathComponent("parallel.sqlite")).size(for: tree))
        XCTAssertEqual(one.logicalBytes, expected)
        XCTAssertEqual(one.items, 12 + 144 + 288 + 1)
        XCTAssertEqual(one.state, .complete)
        XCTAssertEqual(one.logicalBytes, two.logicalBytes)
        XCTAssertEqual(one.allocatedBytes, two.allocatedBytes)
        XCTAssertEqual(one.items, two.items)
        XCTAssertEqual(two.state, .complete)
    }

    func testWiderRootAbsorbsAnExistingRoot() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let outer = temp.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("mid/inner")
        try make(inner.appendingPathComponent("leaf"), files: ["f": 250])
        try make(outer, files: ["top": 50])
        let (writer, reader) = try open(temp)
        try writer.scan(inner)
        let leafStamp = try writer.stamp(inner.appendingPathComponent("leaf"))
        XCTAssertEqual(reader.size(for: inner)?.logicalBytes, 250)
        XCTAssertNil(reader.size(for: outer))
        try writer.addRoot(outer)
        try writer.drain()
        XCTAssertEqual(try writer.count("roots"), 1)
        XCTAssertEqual(reader.size(for: outer)?.logicalBytes, 300)
        XCTAssertEqual(reader.size(for: outer)?.items, 5)
        XCTAssertEqual(reader.size(for: outer)?.state, .complete)
        XCTAssertEqual(reader.size(for: inner)?.logicalBytes, 250)
        XCTAssertEqual(try writer.stamp(inner.appendingPathComponent("leaf")), leafStamp)
        XCTAssertEqual(try writer.count("dirs"), 4)
        XCTAssertEqual(try writer.count("dirs WHERE parent=0"), 1)
    }

    func testFocusOnUndiscoveredFolderReachesItBeforeTheRestOfTheRoot() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        for i in 0..<40 { try make(tree.appendingPathComponent("bulk\(i)/x"), files: ["f": 1]) }
        let wanted = tree.appendingPathComponent("zz/target")
        try make(wanted, files: ["t": 77])
        let (writer, reader) = try open(temp)
        try writer.addRoot(tree)
        try writer.focus(on: [wanted])
        XCTAssertTrue(try writer.processNext())
        XCTAssertEqual(reader.size(for: wanted)?.state, .complete)
        XCTAssertEqual(reader.size(for: wanted)?.logicalBytes, 77)
        try writer.drain()
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 117)
        XCTAssertEqual(reader.size(for: tree)?.items, 40 * 3 + 3)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(try writer.count("roots"), 1)
    }

    func testRenamedFolderKeepsItsSizeBeforeAnyRescan() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let old = tree.appendingPathComponent("old")
        try make(old, files: ["f": 512])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        let new = tree.appendingPathComponent("new")
        try FileManager.default.moveItem(at: old, to: new)
        XCTAssertEqual(reader.size(for: new)?.logicalBytes, 512)
        XCTAssertEqual(reader.sizes(for: [new, old, tree]).map { $0?.logicalBytes }, [512, nil, 512])
    }

    func testReverifyKeepsEverySizeVisible() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let inner = tree.appendingPathComponent("a/b")
        try make(inner, files: ["f": 100])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        try writer.rebuild()
        for url in [tree, tree.appendingPathComponent("a"), inner] {
            XCTAssertEqual(reader.size(for: url)?.logicalBytes, 100)
            XCTAssertEqual(reader.size(for: url)?.isCounting, false)
        }
        XCTAssertEqual(reader.size(for: tree)?.state, .stale)
        XCTAssertTrue(try writer.processNext())
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 100)
        try writer.drain()
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(try writer.flagged(), [])
    }

    func testSymlinksAndSpecialFilesDoNotMakeAFolderPartial() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try make(tree, files: ["f": 10])
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        XCTAssertEqual(mkfifo(tree.appendingPathComponent("pipe").path, 0o600), 0)
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 10)
        XCTAssertEqual(reader.size(for: tree)?.items, 2)
    }

    func testNewFoldersAreScannedBeforeChurnInAlreadyIndexedOnes() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        var busy: [URL] = []
        for i in 0..<25 {
            let url = tree.appendingPathComponent("busy/d\(i)")
            try make(url, files: ["f": 10])
            busy.append(url)
        }
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        let arrival = tree.appendingPathComponent("arrival")
        try make(arrival.appendingPathComponent("inner/leaf"), files: ["n": 500])
        for url in busy { try writer.enqueue(path: url.path, recursive: false) }
        try writer.enqueue(path: tree.path, recursive: false)
        XCTAssertNil(reader.size(for: arrival))
        var steps = 0
        while reader.size(for: arrival)?.state != .complete {
            XCTAssertTrue(try writer.processNext())
            steps += 1
            XCTAssertLessThan(steps, 10)
        }
        XCTAssertEqual(steps, 4)
        XCTAssertEqual(reader.size(for: arrival)?.logicalBytes, 500)
        XCTAssertEqual(try writer.flagged().count, 25)
        XCTAssertEqual(reader.size(for: tree)?.isCounting, false)
        try writer.drain()
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 750)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
    }

    func testRecentlyListedFolderWaitsUnlessSomeoneIsLookingAtIt() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let hot = tree.appendingPathComponent("hot")
        let other = tree.appendingPathComponent("other")
        try make(hot, files: ["f": 100])
        try make(other, files: ["g": 1])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        writer.rescanInterval = 60
        try Data(count: 900).write(to: hot.appendingPathComponent("f"))
        try writer.enqueue(path: hot.path, recursive: false)
        XCTAssertEqual(try writer.processBatch(), 0)
        XCTAssertTrue(writer.isCooling)
        XCTAssertEqual(reader.size(for: hot)?.logicalBytes, 100)
        XCTAssertEqual(reader.size(for: hot)?.isCounting, false)
        let fresh = other.appendingPathComponent("brand-new")
        try make(fresh, files: ["h": 7])
        try writer.prioritize(fresh)
        XCTAssertEqual(try writer.processBatch(), 1)
        XCTAssertEqual(reader.size(for: fresh)?.logicalBytes, 7)
        XCTAssertTrue(writer.isCooling)
        try writer.refresh(hot)
        XCTAssertEqual(try writer.processBatch(), 1)
        XCTAssertEqual(reader.size(for: hot)?.logicalBytes, 900)
        writer.rescanInterval = 0.05
        usleep(80_000)
        try writer.drain()
        XCTAssertFalse(writer.isCooling)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 908)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
    }

    func testFileNamesFollowRenamesAndIgnoreContentOnlyChanges() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        try make(tree, files: ["alpha.txt": 10, "beta.txt": 20])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        func names() throws -> [String] {
            var out: [String] = []
            try writer.db.each("SELECT name FROM files ORDER BY name", args: []) { out.append(IndexDatabase.text($0, 0) ?? "") }
            return out
        }
        XCTAssertEqual(try names(), ["alpha.txt", "beta.txt"])
        try Data(count: 5000).write(to: tree.appendingPathComponent("alpha.txt"))
        try rescan(writer, tree)
        XCTAssertEqual(try names(), ["alpha.txt", "beta.txt"])
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 5020)
        try FileManager.default.moveItem(at: tree.appendingPathComponent("beta.txt"), to: tree.appendingPathComponent("gamma.txt"))
        try rescan(writer, tree)
        XCTAssertEqual(try names(), ["alpha.txt", "gamma.txt"])
        try FileManager.default.removeItem(at: tree.appendingPathComponent("alpha.txt"))
        try Data(count: 1).write(to: tree.appendingPathComponent("delta.txt"))
        try rescan(writer, tree)
        XCTAssertEqual(try names(), ["delta.txt", "gamma.txt"])
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 21)
        XCTAssertEqual(reader.size(for: tree)?.items, 2)
    }

    func testDeniedFolderIsNotRetriedByEventsOnlyWhenLookedAt() throws {
        guard getuid() != 0 else { return }
        let temp = try temporary()
        defer {
            chmod(temp.appendingPathComponent("tree/locked").path, 0o755)
            try? FileManager.default.removeItem(at: temp)
        }
        let tree = temp.appendingPathComponent("tree")
        let locked = tree.appendingPathComponent("locked")
        try make(locked, files: ["secret": 400])
        try make(tree, files: ["open": 5])
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        XCTAssertEqual(reader.size(for: tree)?.state, .partial)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 5)
        XCTAssertEqual(reader.size(for: tree)?.unreadableFolders, 1)
        XCTAssertEqual(try writer.touch(locked.path, recursive: false, retryDenied: false), try writer.touch(locked.path, recursive: false, retryDenied: false))
        XCTAssertEqual(try writer.flagged(), [])
        XCTAssertEqual(chmod(locked.path, 0o755), 0)
        try writer.focus(on: [locked])
        XCTAssertEqual(try writer.flagged(), ["\(locked.path)|0"])
        try writer.drain()
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 405)
        XCTAssertEqual(reader.size(for: tree)?.unreadableFolders, 0)
    }

    func testMoveAndRenameSettleWithoutWaitingOutTheCooldown() throws {
        let temp = try temporary()
        defer { try? FileManager.default.removeItem(at: temp) }
        let tree = temp.appendingPathComponent("tree")
        let a = tree.appendingPathComponent("a"), b = tree.appendingPathComponent("b")
        try make(a.appendingPathComponent("sub/inner"), files: ["f": 640])
        try make(b, files: ["g": 2])
        let (writer, reader) = try open(temp)
        try writer.scan(tree)
        writer.rescanInterval = 120
        func age(_ url: URL) throws {
            var st = stat()
            XCTAssertEqual(lstat(url.path, &st), 0)
            try writer.db.run("UPDATE dirs SET listed_at=0 WHERE inode=?", args: [.int(Int64(bitPattern: UInt64(st.st_ino)))])
        }
        try age(a)
        try FileManager.default.moveItem(at: a.appendingPathComponent("sub"), to: b.appendingPathComponent("sub"))
        let c = tree.appendingPathComponent("c")
        try FileManager.default.moveItem(at: b, to: c)
        try writer.enqueue(path: a.path, recursive: false)
        try writer.enqueue(path: c.path, recursive: false)
        try writer.enqueue(path: tree.path, recursive: false)
        try writer.drain()
        XCTAssertEqual(reader.size(for: c)?.logicalBytes, 642)
        XCTAssertEqual(reader.size(for: c.appendingPathComponent("sub/inner"))?.logicalBytes, 640)
        XCTAssertEqual(reader.size(for: a)?.logicalBytes, 0)
        XCTAssertEqual(reader.size(for: tree)?.logicalBytes, 642)
        XCTAssertEqual(reader.size(for: tree)?.items, 6)
        XCTAssertEqual(reader.size(for: tree)?.state, .complete)
        XCTAssertEqual(try writer.count("dirs WHERE flags&\(IndexFlag.detached | IndexFlag.deferred)!=0"), 0)
        XCTAssertEqual(try writer.count("dirs"), 5)
    }
}
