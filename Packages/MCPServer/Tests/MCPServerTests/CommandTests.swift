import Foundation
import ModKit
import ModValidation
import XCTest
@testable import MCPServer

final class Sink: @unchecked Sendable {
    var out = ""
    var err = ""
    var io: CLIIO { CLIIO(out: { self.out += $0 }, err: { self.err += $0 }) }
}

final class CommandTests: XCTestCase {
    func testHelpAndUsageErrors() async throws {
        let help = Sink()
        let code = try await MCPCommand.run(arguments: ["--help"], io: help.io, validator: .shared, dryRunner: NotRunDryRunner())
        XCTAssertEqual(code, 0)
        XCTAssertTrue(help.out.contains("betterfinder-mod mcp"))
        XCTAssertTrue(help.out.contains("--http"))
        for args in [["--bogus"], ["--port"], ["--port", "99999"], ["--port", "abc"], ["--token-file"], ["--workspaces"], ["--allow-origin"]] {
            let sink = Sink()
            let status = try await MCPCommand.run(arguments: args, io: sink.io, validator: .shared, dryRunner: NotRunDryRunner())
            XCTAssertEqual(status, 2, "\(args)")
            XCTAssertTrue(sink.err.contains("betterfinder-mod mcp:"), sink.err)
            XCTAssertTrue(sink.out.isEmpty, "protocol stdout must stay clean")
        }
    }

    func testParseOptions() throws {
        guard case .success(let o) = MCPCommand.parse(["--http", "--port", "8123", "--token-file", "/tmp/x.json", "--workspaces", "/tmp/ws", "--allow-origin", "http://localhost:6274", "--no-live"]) else { return XCTFail() }
        XCTAssertTrue(o.http)
        XCTAssertEqual(o.port, 8123)
        XCTAssertEqual(o.tokenFile.path, "/tmp/x.json")
        XCTAssertEqual(o.workspaces?.path, "/tmp/ws")
        XCTAssertEqual(o.origins, ["http://localhost:6274"])
        XCTAssertFalse(o.live)
        guard case .success(let d) = MCPCommand.parse([]) else { return XCTFail() }
        XCTAssertFalse(d.http)
        XCTAssertTrue(d.live)
        XCTAssertEqual(d.tokenFile, MCPTokenFile.cliURL)
        XCTAssertNotEqual(MCPTokenFile.cliURL, MCPTokenFile.standardURL)
        XCTAssertEqual(MCPTokenFile.standardURL.lastPathComponent, "mcp.json")
    }

    func testCLIDispatchesToTheMCPExtension() async throws {
        let sink = Sink()
        let status = await ModCLI.run(arguments: ["mcp", "--help"], io: sink.io, extensions: ["mcp": MCPCommand.run])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(sink.out.contains("betterfinder-mod mcp"))
        let plain = Sink()
        let unknown = await ModCLI.run(arguments: ["mcp"], io: plain.io)
        XCTAssertEqual(unknown, 2)
        XCTAssertTrue(ModCLI.usage.contains("mcp [--stdio | --http]"))
    }
}
