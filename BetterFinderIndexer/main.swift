import Foundation
import Darwin
import FSCore
import Security
import CoreGraphics

final class Indexer: NSObject, NSXPCListenerDelegate, SizeIndexProtocol {
    let queue = DispatchQueue(label: "betterfinder.indexer", qos: .background)
    let writer: SizeIndexWriter
    var events: SizeIndexEvents!
    var paused = false
    var timer: DispatchSourceTimer!
    var lastReconciliation = Date()

    let reconciliationInterval: TimeInterval = 86400
    private var idling = false

    init(databaseURL: URL = SizeIndexLocation.database, root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        do { writer = try SizeIndexWriter(databaseURL: databaseURL) } catch { fatalError("Cannot open size index: \(error)") }
        super.init()
        events = SizeIndexEvents(writer: writer, queue: queue)
        events.onChange = { [weak self] in self?.wake() }
        queue.async {
            do { try self.events.watch(root); try self.events.restore(); try self.writer.addRoot(root) } catch { NSLog("Indexer: %@", String(describing: error)) }
        }
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.paused else { self.idle(); return }
            do {
                if try self.writer.processBatch(limit: 4096, budget: 0.2) == 0 {
                    if Date().timeIntervalSince(self.lastReconciliation) > self.reconciliationInterval, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) > 60 {
                        try self.writer.rebuild()
                        self.lastReconciliation = Date()
                    } else {
                        self.idle()
                    }
                }
            } catch { NSLog("Indexer: %@", String(describing: error)); self.idle() }
        }
        timer.resume()
    }
    func idle() {
        guard !idling else { return }
        idling = true
        timer.schedule(deadline: .now() + 60, repeating: .seconds(60), leeway: .seconds(10))
    }
    func wake() {
        guard idling else { return }
        idling = false
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(10))
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
    func perform(_ reply: @escaping (Bool) -> Void, _ work: @escaping () throws -> Void) {
        queue.async { do { try work(); self.wake(); reply(true) } catch { reply(false) } }
    }
    func prioritize(path: String, reply: @escaping (Bool) -> Void) {
        perform(reply) { let url = URL(fileURLWithPath: path); try self.events.watch(url); try self.writer.prioritize(url) }
    }
    func addRoot(path: String, reply: @escaping (Bool) -> Void) {
        perform(reply) { let url = URL(fileURLWithPath: path); try self.events.watch(url); try self.writer.addRoot(url, allowNetwork: true) }
    }
    func pause(reply: @escaping (Bool) -> Void) { perform(reply) { self.paused = true } }
    func resume(reply: @escaping (Bool) -> Void) { perform(reply) { self.paused = false } }
    func rebuild(reply: @escaping (Bool) -> Void) { perform(reply) { try self.writer.rebuild() } }
    func status(reply: @escaping (String) -> Void) { queue.async { reply("\(self.paused ? "paused" : "running"): \(self.writer.pendingCount) pending") } }
}

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--scan" {
    do {
        let start = Date()
        let writer = try SizeIndexWriter(databaseURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        try writer.scan(URL(fileURLWithPath: CommandLine.arguments[2]))
        let seconds = Date().timeIntervalSince(start)
        let dirs = writer.directoryCount
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("SCAN_SECONDS=\(seconds) DIRECTORIES=\(dirs) DIRS_PER_SECOND=\(Int(Double(dirs) / max(seconds, 0.001))) PEAK_RSS_BYTES=\(usage.ru_maxrss)")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}

setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE)

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--serve" {
    let local = Indexer(databaseURL: URL(fileURLWithPath: CommandLine.arguments[3]), root: URL(fileURLWithPath: CommandLine.arguments[2]))
    withExtendedLifetime(local) { RunLoop.current.run() }
    exit(0)
}

let indexer = Indexer()
let listener = NSXPCListener(machServiceName: SizeIndexService.machServiceName)
listener.delegate = indexer
listener.resume()
RunLoop.current.run()
