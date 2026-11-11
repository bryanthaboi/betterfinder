import Foundation
import Darwin
import FSCore
import Security

final class IndexerService: NSObject, NSXPCListenerDelegate, SizeIndexProtocol {
    let daemon: SizeIndexDaemon
    let identity: String

    init(daemon: SizeIndexDaemon, identity: String) {
        self.daemon = daemon
        self.identity = identity
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        #if !DEBUG
        var ownCode: SecCode?
        var ownStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.bryanthaboi.betterfinder\"")
        #endif
        connection.exportedInterface = NSXPCInterface(with: SizeIndexProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func focus(paths: [String], reply: @escaping (Bool) -> Void) { daemon.focus(paths: paths, reply: reply) }
    func refresh(paths: [String], reply: @escaping (Bool) -> Void) { daemon.refresh(paths: paths, reply: reply) }
    func pause(reply: @escaping (Bool) -> Void) { daemon.pause(reply: reply) }
    func resume(reply: @escaping (Bool) -> Void) { daemon.resume(reply: reply) }
    func rebuild(reply: @escaping (Bool) -> Void) { daemon.rebuild(reply: reply) }
    func status(reply: @escaping (String) -> Void) { daemon.status(reply: reply) }
    func buildIdentity(reply: @escaping (String) -> Void) { reply(identity) }
}

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--scan" {
    do {
        let start = Date()
        let writer = try SizeIndexWriter(databaseURL: URL(fileURLWithPath: CommandLine.arguments[3]), cacheKiB: 49152)
        writer.scanWidth = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        try writer.scan(URL(fileURLWithPath: CommandLine.arguments[2]))
        let seconds = Date().timeIntervalSince(start)
        let dirs = writer.directoryCount
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("SCAN_SECONDS=\(seconds) DIRECTORIES=\(dirs) DIRS_PER_SECOND=\(Int(Double(dirs) / max(seconds, 0.001))) PEAK_RSS_BYTES=\(usage.ru_maxrss)")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}

setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY)

func makeDaemon(_ database: URL) -> SizeIndexDaemon {
    do { return try SizeIndexDaemon(databaseURL: database) } catch { fatalError("Cannot open file index: \(error)") }
}

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--serve" {
    let local = makeDaemon(URL(fileURLWithPath: CommandLine.arguments[3]))
    local.start(roots: [URL(fileURLWithPath: CommandLine.arguments[2])])
    withExtendedLifetime(local) { RunLoop.current.run() }
    exit(0)
}

SizeIndexLocation.removeLegacyDatabase()
let daemon = makeDaemon(SizeIndexLocation.database)
let service = IndexerService(daemon: daemon, identity: SizeIndexService.buildIdentity(
    ofExecutable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BetterFinderIndexer"),
    bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
))
daemon.start(roots: [FileManager.default.homeDirectoryForCurrentUser])
let listener = NSXPCListener(machServiceName: SizeIndexService.machServiceName)
listener.delegate = service
listener.resume()
RunLoop.current.run()
