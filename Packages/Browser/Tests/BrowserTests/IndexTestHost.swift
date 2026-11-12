import Foundation
import XCTest
import FSCore

final class TemporaryFolderIndex: SizeIndexControl, @unchecked Sendable {
    private let daemon: SizeIndexDaemon
    private let scope: String

    init(daemon: SizeIndexDaemon) {
        self.daemon = daemon
        scope = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    }

    private func scoped(_ paths: [String]) -> [String] {
        paths.filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(scope) }
    }

    func focus(paths: [String]) async -> Bool { await daemon.focus(paths: scoped(paths)) }
    func refresh(paths: [String]) async -> Bool { await daemon.refresh(paths: scoped(paths)) }
    func pause() async -> Bool { await daemon.pause() }
    func resume() async -> Bool { await daemon.resume() }
    func rebuild() async -> Bool { await daemon.rebuild() }
    func status() async -> String { await daemon.status() }
    func stop() { daemon.stop() }
}

@MainActor
enum IndexTestHost {
    static func attach(for test: XCTestCase) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bf-test-index-\(UUID().uuidString)").resolvingSymlinksInPath()
        let database = folder.appendingPathComponent("index.sqlite")
        let index = TemporaryFolderIndex(daemon: try SizeIndexDaemon(databaseURL: database))
        SizeEngine.shared.attach(databaseURL: database, control: index)
        test.addTeardownBlock {
            SizeEngine.shared.attach(databaseURL: SizeIndexLocation.database, control: SizeIndexClient())
            index.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
