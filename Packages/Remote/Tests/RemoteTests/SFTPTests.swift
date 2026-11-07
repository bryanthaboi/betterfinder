import FSCore
import XCTest
@testable import Remote

final class StubApprover: HostKeyApproving, @unchecked Sendable {
    let answer: Bool
    private let lock = NSLock()
    private(set) var requests: [HostKeyApprovalRequest] = []
    init(_ answer: Bool) { self.answer = answer }
    func approve(_ request: HostKeyApprovalRequest) async -> Bool {
        lock.lock(); requests.append(request); lock.unlock()
        return answer
    }
}

final class SFTPFixture {
    let dir: URL
    let root: URL
    let support: URL
    let log: URL
    let failures: URL
    var env: [String: String]
    let sftp: URL
    let keyscan: URL
    static let key = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

    init(hostKey: String? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-sftp-\(UUID().uuidString.prefix(8))")
        root = dir.appendingPathComponent("remote")
        support = dir.appendingPathComponent("support")
        log = dir.appendingPathComponent("log.txt")
        failures = dir.appendingPathComponent("failures")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("home/tester"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        sftp = dir.appendingPathComponent("fake-sftp")
        keyscan = dir.appendingPathComponent("fake-ssh-keyscan")
        try fm.copyItem(at: fixtures.appendingPathComponent("fake-sftp"), to: sftp)
        try fm.copyItem(at: fixtures.appendingPathComponent("fake-ssh-keyscan"), to: keyscan)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sftp.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: keyscan.path)
        env = ["FAKE_SFTP_ROOT": root.path, "FAKE_SFTP_LOG": log.path, "FAKE_SFTP_FAILS": failures.path]
        if let hostKey { env["FAKE_SFTP_HOSTKEY"] = hostKey }
    }

    var home: URL { root.appendingPathComponent("home/tester") }

    func toolchain() -> SSHToolchain {
        SSHToolchain(sftp: sftp, ssh: URL(fileURLWithPath: "/usr/bin/true"), keyscan: keyscan, supportDirectory: support, multiplex: false, extraEnvironment: env)
    }

    func provider(path: String = "", approver: HostKeyApproving? = nil, retry: RetryPolicy = RetryPolicy(maxAttempts: 3, initialDelay: 0.01)) -> SFTPProvider {
        let config = SFTPConfiguration(host: "fake.example", port: 2222, username: "tester", path: path)
        let conn = SFTPConnection(id: "test", configuration: config, toolchain: toolchain(), approver: approver, retry: retry)
        return SFTPProvider(providerID: "sftp-test", connection: conn)
    }

    var logLines: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func setFailures(_ n: Int) throws { try String(n).write(to: failures, atomically: true, encoding: .utf8) }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

final class SFTPTests: XCTestCase {
    var fx: SFTPFixture!

    override func setUpWithError() throws {
        fx = try SFTPFixture()
    }

    override func tearDown() {
        fx?.cleanup()
        super.tearDown()
    }

    func write(_ rel: String, _ text: String) throws {
        let u = fx.root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    func testConfigurationParsingAndValidation() throws {
        let c = try XCTUnwrap(SFTPConfiguration.parse("deploy@files.example.com:2200/srv/www"))
        XCTAssertEqual(c.username, "deploy")
        XCTAssertEqual(c.host, "files.example.com")
        XCTAssertEqual(c.port, 2200)
        XCTAssertEqual(c.path, "/srv/www")
        let v6 = try XCTUnwrap(SFTPConfiguration.parse("sftp://me@[::1]:22"))
        XCTAssertEqual(v6.host, "::1")
        XCTAssertEqual(v6.destinationHost, "[::1]")
        XCTAssertEqual(SFTPConfiguration.parse("me@host")?.path, "")
        XCTAssertNil(SFTPConfiguration.parse("nohost"))
        XCTAssertThrowsError(try SFTPConfiguration(host: "-oProxyCommand=evil", username: "u").validate())
        XCTAssertThrowsError(try SFTPConfiguration(host: "h", username: "-l").validate())
        XCTAssertThrowsError(try SFTPConfiguration(host: "h;rm -rf", username: "u").validate())
        XCTAssertThrowsError(try SFTPConfiguration(host: "h", username: "u", path: "/a\nb").validate())
        XCTAssertThrowsError(try SFTPConfiguration(host: "h", username: "u", identityFile: "relative/key").validate())
        XCTAssertNoThrow(try SFTPConfiguration(host: "h.example", port: 22, username: "u_1", path: "~/x", identityFile: "~/.ssh/id_ed25519").validate())
    }

    func testQuotingEscapesQuotesAndGlobsAndRejectsControlCharacters() throws {
        XCTAssertEqual(try SFTPCommand.quote("/a b/c\"d"), "/a\\ b/c\\\"d")
        XCTAssertEqual(try SFTPCommand.quote("/x*?[y] #'z"), "/x\\*\\?\\[y]\\ \\#\\'z")
        XCTAssertThrowsError(try SFTPCommand.quote("/a\nput /etc/passwd"))
        XCTAssertThrowsError(try SFTPCommand.quote("/a\\b"))
        XCTAssertThrowsError(try SFTPCommand.quote(""))
        XCTAssertEqual(try SFTPCommand.lenient(.remove("/a b")).render(), "-rm /a\\ b")
        XCTAssertEqual(try SFTPCommand.batch([.pwd, .list("/")]), "pwd\nls -lan /\n")
    }

    func testControlledConfigurationPinsHostKeysAndDisablesInteractiveAuth() async throws {
        let p = fx.provider()
        _ = try await p.resolveRoot()
        let conf = try String(contentsOf: fx.support.appendingPathComponent("ssh/test.conf"), encoding: .utf8)
        for line in ["BatchMode yes", "StrictHostKeyChecking yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no", "ProxyCommand none", "PermitLocalCommand no", "ForwardAgent no", "User tester", "Port 2222"] {
            XCTAssertTrue(conf.contains(line), line)
        }
        XCTAssertTrue(conf.contains("UserKnownHostsFile \"\(fx.support.appendingPathComponent("known_hosts").path)\""))
        let perms = try FileManager.default.attributesOfItem(atPath: fx.support.appendingPathComponent("ssh/test.conf").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        let args = fx.logLines.first { $0.hasPrefix("ARGS") }
        XCTAssertEqual(args, "ARGS -F \(fx.support.appendingPathComponent("ssh/test.conf").path) -b - -- fake.example")
    }

    func testListingResolvesHomeAndParsesEntries() async throws {
        try write("home/tester/notes.txt", "hello")
        try write("home/tester/My Docs/a.md", "a")
        try write("home/tester/.profile", "x")
        let p = fx.provider()
        let root = try await p.resolveRoot()
        XCTAssertEqual(root.path, "/home/tester")
        XCTAssertEqual(p.root, root)
        let items = try await p.listAll(root, options: ResourceListOptions(showHidden: false))
        XCTAssertEqual(items.map(\.name).sorted(), ["My Docs", "notes.txt"])
        let notes = try XCTUnwrap(items.first { $0.name == "notes.txt" })
        XCTAssertEqual(notes.size, 5)
        XCTAssertFalse(notes.isDirectory)
        XCTAssertEqual(notes.id.path, "/home/tester/notes.txt")
        XCTAssertNotNil(notes.modified)
        XCTAssertEqual(items.first { $0.name == "My Docs" }?.isDirectory, true)
        let all = try await p.listAll(root, options: ResourceListOptions(showHidden: true))
        XCTAssertTrue(all.contains { $0.name == ".profile" })
        let stat = try await p.stat(root.appending("My Docs"))
        XCTAssertTrue(stat.isDirectory)
        XCTAssertEqual(p.parent(of: root)?.path, "/home")
    }

    func testGetPutRenameRemoveAndMkdir() async throws {
        try write("home/tester/src.bin", String(repeating: "z", count: 5000))
        let p = fx.provider()
        let root = try await p.resolveRoot()
        let local = fx.dir.appendingPathComponent("staged.bin")
        let progress = ProgressLog()
        let meta = try await p.download(root.appending("src.bin"), to: local, progress: progress.add)
        XCTAssertEqual(meta.size, 5000)
        XCTAssertEqual(try Data(contentsOf: local).count, 5000)
        XCTAssertEqual(progress.values.last, 5000)
        let up = try await p.upload(from: local, to: root.appending("weird \"name\" [1] #'x'.bin"), options: .init(), progress: { _ in })
        XCTAssertEqual(up.size, 5000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("weird \"name\" [1] #'x'.bin").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fx.home.path).filter { $0.hasPrefix(".bfpart-") }
        XCTAssertTrue(leftovers.isEmpty)
        do {
            _ = try await p.upload(from: local, to: root.appending("src.bin"), options: .init(overwrite: false), progress: { _ in })
            XCTFail("expected conflict")
        } catch ResourceError.alreadyExists {}
        try Data("new".utf8).write(to: local)
        let replaced = try await p.upload(from: local, to: root.appending("src.bin"), options: .init(overwrite: true), progress: { _ in })
        XCTAssertEqual(replaced.size, 3)
        _ = try await p.makeDirectory(root.appending("made"))
        _ = try await p.move(root.appending("src.bin"), to: root.appending("made/moved.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("made/moved.bin").path))
        try write("home/tester/made/deep/x.txt", "x")
        try await p.delete(root.appending("made"), recursive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("made").path))
        do {
            _ = try await p.stat(root.appending("missing"))
            XCTFail("expected notFound")
        } catch ResourceError.notFound {}
        XCTAssertFalse(p.capabilities.canTrash)
        XCTAssertFalse(p.capabilities.contains(.serverSideCopy))
    }

    func testUnknownHostKeyPromptsOnceThenPinsKey() async throws {
        fx = try SFTPFixture(hostKey: SFTPFixture.key)
        let approver = StubApprover(true)
        let p = fx.provider(approver: approver)
        _ = try await p.resolveRoot()
        XCTAssertEqual(approver.requests.count, 1)
        let req = try XCTUnwrap(approver.requests.first)
        XCTAssertEqual(req.host, "fake.example")
        XCTAssertEqual(req.port, 2222)
        XCTAssertEqual(req.keys.first?.fingerprint, SSHHostKey(host: "x", type: "ssh-ed25519", base64: SFTPFixture.key).fingerprint)
        XCTAssertTrue(req.keys.first!.fingerprint.hasPrefix("SHA256:"))
        let known = try String(contentsOf: fx.support.appendingPathComponent("known_hosts"), encoding: .utf8)
        XCTAssertTrue(known.contains("[fake.example]:2222 ssh-ed25519 \(SFTPFixture.key)"))
        _ = try await p.listAll(p.root)
        XCTAssertEqual(approver.requests.count, 1)
    }

    func testRejectedHostKeyIsNotPinned() async throws {
        fx = try SFTPFixture(hostKey: SFTPFixture.key)
        let p = fx.provider(approver: StubApprover(false))
        do {
            _ = try await p.resolveRoot()
            XCTFail("expected rejection")
        } catch ResourceError.hostKeyRejected {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.support.appendingPathComponent("known_hosts").path))
        XCTAssertEqual(fx.logLines.filter { $0.hasPrefix("CMD") }.count, 0)
    }

    func testChangedHostKeyFailsWithoutPrompting() async throws {
        fx = try SFTPFixture(hostKey: SFTPFixture.key)
        fx.env["FAKE_SFTP_KEY_CHANGED"] = "1"
        let approver = StubApprover(true)
        let p = fx.provider(approver: approver)
        do {
            _ = try await p.resolveRoot()
            XCTFail("expected changed key")
        } catch ResourceError.hostKeyChanged {}
        XCTAssertTrue(approver.requests.isEmpty)
        let state = await p.connection.state
        if case .failed = state {} else { XCTFail("state \(state)") }
    }

    func testNoApproverReportsFingerprintsHonestly() async throws {
        fx = try SFTPFixture(hostKey: SFTPFixture.key)
        let p = fx.provider(approver: nil)
        do {
            _ = try await p.resolveRoot()
            XCTFail("expected unknown host")
        } catch ResourceError.hostKeyUnknown(_, let prints) {
            XCTAssertEqual(prints.count, 1)
        }
    }

    func testReconnectsAfterDroppedConnections() async throws {
        try write("home/tester/a.txt", "a")
        try fx.setFailures(2)
        let p = fx.provider()
        let root = try await p.resolveRoot()
        XCTAssertEqual(fx.logLines.filter { $0 == "DROP" }.count, 2)
        let items = try await p.listAll(root)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
        let state = await p.connection.state
        XCTAssertEqual(state, .connected)
        try fx.setFailures(5)
        do {
            _ = try await p.listAll(root)
            XCTFail("expected failure after retries")
        } catch ResourceError.connectionFailed {}
        let failed = await p.connection.state
        if case .failed = failed {} else { XCTFail("state \(failed)") }
    }

    func testNonIdempotentCommandsAreNotReplayedAfterPartialExecution() async throws {
        XCTAssertFalse(SFTPCommand.rename("/a", "/b").isIdempotent)
        XCTAssertTrue(SFTPCommand.list("/a").isIdempotent)
        XCTAssertTrue(SFTPCommand.lenient(.get(remote: "/a", local: "/b")).isIdempotent)
        let e = SFTPConnection.classify(stderr: "Connection closed", status: 255, host: "h", executed: 1)
        XCTAssertTrue(e.isTransient)
        XCTAssertEqual(SFTPConnection.classify(stderr: "u@h: Permission denied (publickey).", status: 255, host: "h", executed: 0), .authenticationFailed("u@h: Permission denied (publickey)."))
        if case .notFound = SFTPConnection.classify(stderr: "File \"/x\" not found.", status: 1, host: "h", executed: 1) {} else { XCTFail() }
    }

    func testCancellationTerminatesTheTransfer() async throws {
        try write("home/tester/a.txt", "a")
        fx.env["FAKE_SFTP_DELAY"] = "5"
        let p = fx.provider()
        let started = Date()
        let task = Task { try await p.listAll(ResourceID(providerID: p.providerID, path: "/home/tester")) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}

final class SFTPListingParserTests: XCTestCase {
    func testParsesOpenSSHNumericLongFormat() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        let text = """
        drwxr-xr-x    5 1000     1000         4096 Nov 06 10:00 /home/u/.
        drwxr-xr-x    3 0        0            4096 Jan 02  2024 /home/u/..
        -rw-r--r--    ? alice    staff  1234567890 Dec 31 23:59 /home/u/big  file.iso
        lrwxrwxrwx    1 1000     1000            7 Mar  4 09:15 /home/u/link
        -rw-------    1 1000     1000            0 Feb 29  2024 /home/u/émoji 🚀.txt
        garbage line
        """
        let entries = SFTPListingParser.parse(text, now: now, calendar: cal)
        XCTAssertEqual(entries.map(\.name), [".", "..", "big  file.iso", "link", "émoji 🚀.txt"])
        XCTAssertEqual(entries[2].size, 1_234_567_890)
        XCTAssertNil(entries[2].links)
        XCTAssertEqual(entries[2].owner, "alice")
        XCTAssertEqual(cal.component(.year, from: entries[2].modified!), 2025)
        XCTAssertEqual(cal.component(.year, from: entries[0].modified!), 2026)
        XCTAssertTrue(entries[3].isSymlink)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(cal.component(.year, from: entries[4].modified!), 2024)
    }

    func testParsesServerLongnameWithSymlinkTarget() {
        let e = SFTPListingParser.parseLine("lrwxrwxrwx    1 alice    staff          11 Jun  1 12:00 current -> releases/42")
        XCTAssertEqual(e?.name, "current")
        XCTAssertEqual(e?.linkTarget, "releases/42")
    }

    func testHostKeyFingerprintAndKeyscanParsing() {
        let keys = SSHHostKey.parse(keyscanOutput: "# comment\n[h]:2222 ssh-ed25519 \(SFTPFixture.key)\nbad line\nh ssh-rsa !!!\n")
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].displayType, "ED25519")
        XCTAssertEqual(keys[0].fingerprint.count, "SHA256:".count + 43)
    }
}
