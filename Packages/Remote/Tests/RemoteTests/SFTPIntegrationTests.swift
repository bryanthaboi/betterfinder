import FSCore
import XCTest
@testable import Remote

final class SFTPIntegrationTests: XCTestCase {
    var dir: URL!
    var sshd: Process?

    override func tearDown() {
        sshd?.terminate()
        sshd?.waitUntilExit()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func sh(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw XCTSkip("\(path) failed") }
    }

    func testRealSSHDRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["BF_SFTP_INTEGRATION"] == "1" else { throw XCTSkip("set BF_SFTP_INTEGRATION=1 to run against a temporary localhost sshd") }
        dir = URL(fileURLWithPath: "/tmp/bf-sshd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostKey = dir.appendingPathComponent("host_ed25519")
        let clientKey = dir.appendingPathComponent("client_ed25519")
        try sh("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        try sh("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", clientKey.path])
        try FileManager.default.copyItem(at: clientKey.appendingPathExtension("pub"), to: dir.appendingPathComponent("authorized_keys"))
        let port = Int.random(in: 40000...49000)
        let conf = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        PidFile \(dir.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(dir.appendingPathComponent("authorized_keys").path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        Subsystem sftp /usr/libexec/sftp-server
        """
        let confURL = dir.appendingPathComponent("sshd_config")
        try conf.write(to: confURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-e", "-f", confURL.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        sshd = p
        try await Task.sleep(nanoseconds: 700_000_000)
        guard p.isRunning else { throw XCTSkip("sshd could not start unprivileged here") }

        let work = dir.appendingPathComponent("remote work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: work.appendingPathComponent("a file [1] *.txt"))
        try Data().write(to: work.appendingPathComponent("ünïcødé.txt"))
        let support = dir.appendingPathComponent("support")
        let approver = StubApprover(true)
        let config = SFTPConfiguration(host: "127.0.0.1", port: port, username: NSUserName(), path: work.path, identityFile: clientKey.path)
        for multiplex in [false, true] {
            try? FileManager.default.removeItem(at: support)
            let toolchain = SSHToolchain(supportDirectory: support, multiplex: multiplex)
            let provider = SFTPProvider(providerID: "real", connection: SFTPConnection(id: "real\(multiplex)", configuration: config, toolchain: toolchain, approver: approver))
            let root = try await provider.resolveRoot()
            XCTAssertEqual(root.path, ResourceID.normalize(work.path))
            let items = try await provider.listAll(root)
            XCTAssertEqual(Set(items.map(\.name)), ["a file [1] *.txt", "ünïcødé.txt"])
            XCTAssertEqual(items.first { $0.name.hasPrefix("a file") }?.size, 11)
            let local = dir.appendingPathComponent("dl-\(multiplex)")
            _ = try await provider.download(root.appending("a file [1] *.txt"), to: local, progress: { _ in })
            XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "hello world")
            _ = try await provider.upload(from: local, to: root.appending("up \"quoted\" ?.txt"), options: .init(), progress: { _ in })
            XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("up \"quoted\" ?.txt"), encoding: .utf8), "hello world")
            _ = try await provider.upload(from: local, to: root.appending("up \"quoted\" ?.txt"), options: .init(overwrite: true), progress: { _ in })
            _ = try await provider.makeDirectory(root.appending("new dir"))
            _ = try await provider.move(root.appending("up \"quoted\" ?.txt"), to: root.appending("new dir/moved.txt"))
            try await provider.delete(root.appending("new dir"), recursive: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("new dir").path))
            await provider.connection.disconnect()
        }
        XCTAssertEqual(approver.requests.count, 2)
    }
}
