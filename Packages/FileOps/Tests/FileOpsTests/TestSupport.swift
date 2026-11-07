import XCTest
@testable import FileOps

final class ScriptedResolver: ConflictResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [ConflictDecision]
    private(set) var asked: [FileConflict] = []

    init(_ decisions: [ConflictDecision]) { self.decisions = decisions }

    func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        lock.lock(); defer { lock.unlock() }
        asked.append(conflict)
        return decisions.isEmpty ? ConflictDecision(.stop) : decisions.removeFirst()
    }
}

@MainActor
class FileOpsTestCase: XCTestCase {
    var root: URL!
    var trashDir: URL!
    var journal: TrashJournal!
    var service: TrashService!
    var queue: FileOperationQueue!
    var undo: UndoManager!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trashDir = root.appendingPathComponent("FakeTrash")
        journal = try TrashJournal(databasePath: ":memory:")
        service = TrashService(journal: journal, provider: DirectoryTrashProvider(directory: trashDir))
        queue = FileOperationQueue(trashService: service)
        undo = UndoManager()
        queue.undoManager = undo
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ name: String, in dir: URL, _ text: String = "data") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func waitIdle(timeout: TimeInterval = 30) async {
        let end = Date().addingTimeInterval(timeout)
        while queue.operations.contains(where: \.isActive), Date() < end {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @discardableResult
    func run(_ kind: FileOperationKind, resolver: ConflictResolver? = nil) async -> FileOperation {
        let op = queue.enqueue(kind, resolver: resolver)
        await waitIdle()
        try? await Task.sleep(nanoseconds: 20_000_000)
        return op
    }
}
