import Foundation
import ModKit
import ModValidation
import XCTest
@testable import MCPServer

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [CommandInvocation]()
    var handler: @Sendable (CommandInvocation) throws -> CommandResult = { _ in CommandResult(status: 0) }

    var calls: [CommandInvocation] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        lock.withLock { recorded.append(invocation) }
        return try handler(invocation)
    }

    func argv() -> [[String]] { calls.map { [$0.executable] + $0.arguments } }
}

struct ToolOutcome {
    var raw: JSONValue

    var isError: Bool { raw["isError"]?.boolValue ?? false }
    var structured: JSONValue { raw["structuredContent"] ?? .null }
    var ok: Bool { structured["ok"]?.boolValue ?? false }
    var data: JSONValue { structured["data"] ?? .null }
    var errorCode: String? { structured["error"]?["code"]?.stringValue }
    var errorMessage: String { structured["error"]?["message"]?.stringValue ?? "" }
    var content: [JSONValue] { raw["content"]?.arrayValue ?? [] }
    func string(_ key: String) -> String { data[key]?.stringValue ?? "" }
}

final class Harness: @unchecked Sendable {
    let root: URL
    let workspaces: ModWorkspaces
    let runner = FakeRunner()
    let clock = FakeClock()
    let server: MCPServer
    let session: MCPSession
    private var nextID = 100

    init(live: LiveModHosting = UnavailableLiveHosting(), pageSize: Int = 100, dryRunner: DryRunning = NotRunDryRunner()) async {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspaces = ModWorkspaces(root: root.appendingPathComponent("ModWorkspaces", isDirectory: true))
        let clock = self.clock
        let configuration = MCPServerConfiguration(
            dryRunner: dryRunner, workspaces: workspaces, live: live, runner: runner, pageSize: pageSize, clock: { clock.now }
        )
        server = MCPServer(configuration: configuration)
        session = server.makeSession()
        _ = await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": obj([:]), "clientInfo": obj(["name": "tests", "version": "1"])])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func rpc(_ method: String, _ params: JSONValue = obj([:])) async -> JSONValue {
        nextID += 1
        let message = obj(["jsonrpc": "2.0", "id": .int(nextID), "method": method.j, "params": params])
        return await session.handle(message: message) ?? .null
    }

    func call(_ name: String, _ args: JSONValue) async -> ToolOutcome {
        let reply = await rpc("tools/call", obj(["name": name.j, "arguments": args]))
        return ToolOutcome(raw: reply["result"] ?? .null)
    }

    func assertConforms(_ tool: String, _ outcome: ToolOutcome, file: StaticString = #filePath, line: UInt = #line) {
        guard let def = server.toolDefinition(tool) else { return XCTFail("no tool \(tool)", file: file, line: line) }
        let violations = JSONSchema(def.outputSchema).validate(outcome.structured)
        XCTAssertTrue(violations.isEmpty, "\(tool) output violates its outputSchema: \(violations)", file: file, line: line)
    }

    func scaffold(id: String = "alice.demo", template: String = "command", language: String = "bfscript") async -> ToolOutcome {
        await call("mod_scaffold", obj(["request": "a demo".j, "id": id.j, "template": template.j, "language": language.j]))
    }

    func validated(id: String = "alice.demo") async -> (revision: String, receipt: String) {
        let s = await scaffold(id: id)
        XCTAssertTrue(s.ok, s.errorMessage)
        let revision = s.string("revision")
        let v = await call("mod_validate", obj(["workspace": id.j, "revision": revision.j]))
        XCTAssertTrue(v.ok, v.errorMessage)
        return (revision, v.string("receipt"))
    }

    func packaged(id: String = "alice.demo") async -> (revision: String, receipt: String, archive: JSONValue) {
        let (revision, receipt) = await validated(id: id)
        let p = await call("mod_package", obj(["workspace": id.j, "revision": revision.j, "receipt": receipt.j]))
        XCTAssertTrue(p.ok, p.errorMessage)
        return (revision, receipt, p.data["archive"] ?? .null)
    }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

func result(_ text: String, status: Int32 = 0) -> CommandResult { CommandResult(status: status, stdout: text) }

func strs(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }
