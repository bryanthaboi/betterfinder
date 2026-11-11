import Foundation
import FSCore

enum IndexTestHost {
    private static let daemon: SizeIndexDaemon = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bf-test-index-\(UUID().uuidString)").resolvingSymlinksInPath()
        let database = folder.appendingPathComponent("index.sqlite")
        let daemon = try! SizeIndexDaemon(databaseURL: database)
        SizeEngine.shared.attach(databaseURL: database, control: daemon)
        return daemon
    }()

    static func install() { _ = daemon }
}
