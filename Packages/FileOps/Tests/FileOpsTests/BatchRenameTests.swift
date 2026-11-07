import XCTest
@testable import FileOps

@MainActor
final class BatchRenameTests: FileOpsTestCase {
    func names(_ items: [BatchRename.PreviewItem]) -> [String] { items.map(\.newName) }

    func testReplaceTextAndRegex() throws {
        let d = try dir("b")
        let urls = [try file("IMG_001.jpg", in: d), try file("IMG_002.jpg", in: d)]
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.replaceText(find: "IMG_", with: "Photo ", caseSensitive: true)])), ["Photo 001.jpg", "Photo 002.jpg"])
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.replaceText(find: "img_", with: "", caseSensitive: false)])), ["001.jpg", "002.jpg"])
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.regex(pattern: "IMG_0*(\\d+)", template: "shot-$1", caseSensitive: true)])), ["shot-1.jpg", "shot-2.jpg"])
    }

    func testPrefixSuffixKeepExtension() throws {
        let d = try dir("b")
        let urls = [try file("a.txt", in: d), try file("noext", in: d)]
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.addPrefix("x_"), .addSuffix("_y")])), ["x_a_y.txt", "x_noext_y"])
        XCTAssertEqual(names(BatchRename.preview(urls: [urls[0]], rules: [.addSuffix("_y")], options: .init(applyToExtension: true))), ["a.txt_y"])
    }

    func testSequenceNumbers() throws {
        let d = try dir("b")
        let urls = [try file("a.txt", in: d), try file("b.txt", in: d), try file("c.txt", in: d)]
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.sequence(start: 8, step: 1, padding: 3, placement: .suffix, separator: "-")])), ["a-008.txt", "b-009.txt", "c-010.txt"])
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.sequence(start: 1, step: 2, padding: 0, placement: .replaceName, separator: "")])), ["1.txt", "3.txt", "5.txt"])
        XCTAssertEqual(names(BatchRename.preview(urls: [urls[0]], rules: [.sequence(start: 1, step: 1, padding: 2, placement: .prefix, separator: " ")])), ["01 a.txt"])
    }

    func testChangeCase() throws {
        let d = try dir("b")
        let urls = [try file("hello WORLD.txt", in: d)]
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.changeCase(.uppercase)])), ["HELLO WORLD.txt"])
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.changeCase(.lowercase)])), ["hello world.txt"])
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.changeCase(.capitalizedWords)])), ["Hello World.txt"])
        XCTAssertEqual(names(BatchRename.preview(urls: urls, rules: [.changeCase(.sentence)])), ["Hello world.txt"])
    }

    func testDuplicateTargetConflict() throws {
        let d = try dir("b")
        let urls = [try file("a1.txt", in: d), try file("b1.txt", in: d), try file("c.txt", in: d)]
        let preview = BatchRename.preview(urls: urls, rules: [.regex(pattern: "^[ab]1", template: "x", caseSensitive: true)])
        XCTAssertEqual(names(preview), ["x.txt", "x.txt", "c.txt"])
        XCTAssertEqual(preview[0].conflict, .duplicateTarget)
        XCTAssertEqual(preview[1].conflict, .duplicateTarget)
        XCTAssertNil(preview[2].conflict)
        XCTAssertThrowsError(try BatchRename.apply(preview)) { error in
            guard case BatchRename.RenameError.conflicts(let items) = error else { return XCTFail() }
            XCTAssertEqual(items.count, 2)
        }
        XCTAssertTrue(exists(d.appendingPathComponent("a1.txt")))
    }

    func testExistingFileConflictAndEmptyName() throws {
        let d = try dir("b")
        let a = try file("a.txt", in: d)
        try file("b.txt", in: d)
        let p = BatchRename.preview(urls: [a], rules: [.replaceText(find: "a", with: "b", caseSensitive: true)])
        XCTAssertEqual(p[0].conflict, .existsOnDisk)
        let empty = BatchRename.preview(urls: [a], rules: [.replaceText(find: "a.txt", with: "", caseSensitive: true)], options: .init(applyToExtension: true))
        XCTAssertEqual(empty[0].conflict, .emptyName)
        let slash = BatchRename.preview(urls: [a], rules: [.addPrefix("x/")])
        XCTAssertEqual(slash[0].conflict, .invalidName)
        let bad = BatchRename.preview(urls: [a], rules: [.regex(pattern: "(", template: "", caseSensitive: true)])
        XCTAssertEqual(bad[0].conflict, .invalidPattern)
    }

    func testRenameIntoNameVacatedByBatchIsNotAConflict() throws {
        let d = try dir("b")
        let one = try file("1.txt", in: d, "one")
        let two = try file("2.txt", in: d, "two")
        let preview = BatchRename.preview(urls: [two, one], rules: [.sequence(start: 1, step: 1, padding: 0, placement: .replaceName, separator: "")])
        XCTAssertEqual(names(preview), ["1.txt", "2.txt"])
        XCTAssertTrue(preview.allSatisfy { $0.conflict == nil })
        let results = try BatchRename.apply(preview)
        XCTAssertEqual(results.map(\.lastPathComponent), ["1.txt", "2.txt"])
        XCTAssertEqual(read(one), "two")
        XCTAssertEqual(read(two), "one")
    }

    func testApplyIsUndoable() throws {
        let saved = FileOperationQueue.shared.undoManager
        FileOperationQueue.shared.undoManager = undo
        defer { FileOperationQueue.shared.undoManager = saved }
        let d = try dir("b")
        let a = try file("a.txt", in: d, "A")
        let b = try file("b.txt", in: d, "B")
        let results = try BatchRename.apply(urls: [a, b], rules: [.addPrefix("new-")])
        XCTAssertEqual(results.map(\.lastPathComponent), ["new-a.txt", "new-b.txt"])
        XCTAssertFalse(exists(a))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        undo.undo()
        XCTAssertEqual(read(a), "A")
        XCTAssertEqual(read(b), "B")
        XCTAssertFalse(exists(results[0]))
        undo.redo()
        XCTAssertEqual(read(results[0]), "A")
        XCTAssertEqual(read(results[1]), "B")
    }

    func testPerformRenamesRollsBackOnFailure() throws {
        let d = try dir("b")
        let a = try file("a.txt", in: d, "A")
        let missing = d.appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try BatchRename.performRenames([(a, d.appendingPathComponent("a2.txt")), (missing, d.appendingPathComponent("m2.txt"))]))
        XCTAssertEqual(read(a), "A")
        XCTAssertFalse(exists(d.appendingPathComponent("a2.txt")))
    }
}
