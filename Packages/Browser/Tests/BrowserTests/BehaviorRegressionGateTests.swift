import AppKit
import Combine
import FileOps
import XCTest
@testable import Browser

@MainActor
final class BehaviorRegressionGateTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-r2-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private final class Recorder {
        var seen: [Int] = []
        var sub: AnyCancellable?
        init(_ queue: FileOperationQueue) {
            sub = queue.$backgroundMutationCount.dropFirst().sink { [unowned self] in self.seen.append($0) }
        }
    }

    func testInlineRenameCountsExactlyOnceUntilFinished() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("a".utf8))
        let queue = FileOperationQueue.shared
        let before = queue.backgroundMutationCount
        let recorder = Recorder(queue)
        let session = RenameSession(url: file, field: NSTextField())
        var result: URL?
        session.onFinish = { result = $0 }
        session.commit("b.txt")
        XCTAssertTrue(spin { result != nil && queue.backgroundMutationCount == before })
        XCTAssertEqual(recorder.seen.max(), before + 1)
        XCTAssertEqual(recorder.seen.last, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }

    func testGetInfoRenameAndTagsCountExactlyOnceUntilFinished() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("info.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("i".utf8))
        let queue = FileOperationQueue.shared
        let before = queue.backgroundMutationCount

        let tags = Recorder(queue)
        let tagModel = InfoModel(url: file)
        tagModel.setTags(["TestGate"])
        XCTAssertTrue(spin { tagModel.tags == ["TestGate"] && queue.backgroundMutationCount == before })
        XCTAssertEqual(tags.seen.max(), before + 1)
        XCTAssertEqual(tags.seen.last, before)

        let renames = Recorder(queue)
        let renameModel = InfoModel(url: file)
        renameModel.rename(to: "renamed.txt")
        XCTAssertTrue(spin { FileManager.default.fileExists(atPath: dir.appendingPathComponent("renamed.txt").path) && queue.backgroundMutationCount == before })
        XCTAssertEqual(renames.seen.max(), before + 1)
        XCTAssertEqual(renames.seen.last, before)
    }
}
