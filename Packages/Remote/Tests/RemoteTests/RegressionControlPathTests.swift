import FSCore
import XCTest
@testable import Remote

final class RegressionControlPathTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-cp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func connection(host: String, port: Int, user: String) -> SFTPConnection {
        let toolchain = SSHToolchain(supportDirectory: dir, multiplex: true)
        return SFTPConnection(id: "\(user)-\(host)-\(port)", configuration: SFTPConfiguration(host: host, port: port, username: user), toolchain: toolchain, approver: nil)
    }

    func expandedControlPath(_ c: SFTPConnection, controlDirectory: String) async throws -> String {
        let text = await c.configText(controlDirectory: controlDirectory)
        let conf = dir.appendingPathComponent("\(UUID().uuidString).conf")
        try text.write(to: conf, atomically: true, encoding: .utf8)
        let host = await c.configuration.destinationHost
        let r = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-G", "-F", conf.path, "--", host], stdin: Data(), environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path])
        XCTAssertEqual(r.status, 0, r.stderrString)
        let line = r.stdoutString.split(separator: "\n").first { $0.lowercased().hasPrefix("controlpath ") }
        return try XCTUnwrap(line.map { String($0.dropFirst("controlpath ".count)) })
    }

    func testControlPathKeepsTheConnectionHashToken() async throws {
        let text = await connection(host: "a.example", port: 22, user: "u").configText(controlDirectory: "/tmp/bf-ssh-test")
        XCTAssertTrue(text.contains("  ControlPath \"/tmp/bf-ssh-test/%C\"\n"), text)
        XCTAssertFalse(text.contains("%%C"))
        XCTAssertEqual(SFTPConnection.controlPathValue(directory: "/tmp/a%b"), "\"/tmp/a%%b/%C\"")
    }

    func testDistinctServersExpandToDistinctControlSockets() async throws {
        let base = "/tmp/bf-test-%x"
        let a = try await expandedControlPath(connection(host: "alpha.example", port: 22, user: "deploy"), controlDirectory: base)
        let b = try await expandedControlPath(connection(host: "beta.example", port: 22, user: "deploy"), controlDirectory: base)
        let c = try await expandedControlPath(connection(host: "alpha.example", port: 22, user: "other"), controlDirectory: base)
        let d = try await expandedControlPath(connection(host: "alpha.example", port: 2222, user: "deploy"), controlDirectory: base)
        let again = try await expandedControlPath(connection(host: "alpha.example", port: 22, user: "deploy"), controlDirectory: base)
        XCTAssertEqual(Set([a, b, c, d]).count, 4, [a, b, c, d].joined(separator: "\n"))
        XCTAssertEqual(a, again)
        for p in [a, b, c, d] {
            XCTAssertTrue(p.hasPrefix("/tmp/bf-test-%x/"), p)
            let name = p.dropFirst("/tmp/bf-test-%x/".count)
            XCTAssertEqual(name.count, 40, p)
            XCTAssertTrue(name.allSatisfy(\.isHexDigit), p)
        }
    }

    func testNoMultiplexingDisablesControlPath() async throws {
        let text = await connection(host: "a.example", port: 22, user: "u").configText(controlDirectory: nil)
        XCTAssertTrue(text.contains("  ControlMaster no\n"))
        XCTAssertTrue(text.contains("  ControlPath none\n"))
    }
}
