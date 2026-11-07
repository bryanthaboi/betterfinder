import Foundation
import ModKit
import XCTest
@testable import MCPServer

final class ProtocolTests: XCTestCase {
    func testInitializeHandshakeNegotiatesVersion() async throws {
        let server = MCPServer(configuration: MCPServerConfiguration(workspaces: ModWorkspaces(root: tempDirectory())))
        let session = server.makeSession()
        let reply = await session.handle(message: obj([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": obj(["protocolVersion": "2025-06-18", "capabilities": obj([:]), "clientInfo": obj(["name": "t", "version": "1"])]),
        ]))
        let result = try XCTUnwrap(reply?["result"])
        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, "betterfinder-mod")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertNotNil(result["capabilities"]?["resources"])
        XCTAssertNotNil(result["capabilities"]?["prompts"])
        XCTAssertNotNil(result["instructions"]?.stringValue)
        XCTAssertTrue(session.isInitialized)
        let note = await session.handle(message: obj(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(note)
        let ping = await session.handle(message: obj(["jsonrpc": "2.0", "id": 2, "method": "ping"]))
        XCTAssertEqual(ping?["result"], obj([:]))
    }

    func testUnknownProtocolVersionFallsBackToLatest() async throws {
        let session = MCPServer(configuration: MCPServerConfiguration(workspaces: ModWorkspaces(root: tempDirectory()))).makeSession()
        let reply = await session.handle(message: obj(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": obj(["protocolVersion": "1999-01-01"])]))
        XCTAssertEqual(reply?["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersions[0])
    }

    func testRequestsBeforeInitializeAreRejected() async throws {
        let session = MCPServer(configuration: MCPServerConfiguration(workspaces: ModWorkspaces(root: tempDirectory()))).makeSession()
        let list = await session.handle(message: obj(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        XCTAssertEqual(list?["error"]?["code"]?.intValue, RPCCode.invalidRequest)
        let ping = await session.handle(message: obj(["jsonrpc": "2.0", "id": 2, "method": "ping"]))
        XCTAssertNotNil(ping?["result"])
    }

    func testMalformedMessages() async throws {
        let h = await Harness()
        let parse = await h.session.handle(Data("{nope".utf8))
        let parsed = try JSONValue.parse(try XCTUnwrap(parse))
        XCTAssertEqual(parsed["error"]?["code"]?.intValue, RPCCode.parseError)
        let batch = await h.session.handle(message: .array([obj(["jsonrpc": "2.0", "id": 1, "method": "ping"])]))
        XCTAssertEqual(batch?["error"]?["code"]?.intValue, RPCCode.invalidRequest)
        let noVersion = await h.session.handle(message: obj(["id": 1, "method": "ping"]))
        XCTAssertEqual(noVersion?["error"]?["code"]?.intValue, RPCCode.invalidRequest)
        let unknown = await h.rpc("nope/method")
        XCTAssertEqual(unknown["error"]?["code"]?.intValue, RPCCode.methodNotFound)
        let unknownTool = await h.rpc("tools/call", obj(["name": "rm_rf", "arguments": obj([:])]))
        XCTAssertEqual(unknownTool["error"]?["code"]?.intValue, RPCCode.invalidParams)
        let huge = await h.session.handle(Data(repeating: 0x20, count: MCPSession.maxMessageBytes + 1))
        XCTAssertNotNil(huge)
    }

    func testShutdownClosesSession() async throws {
        let h = await Harness()
        let reply = await h.rpc("shutdown")
        XCTAssertEqual(reply["result"], obj([:]))
        XCTAssertTrue(h.session.isClosed)
    }

    func testToolsListSchemasAreValidAndComplete() async throws {
        let h = await Harness()
        let reply = await h.rpc("tools/list")
        let tools = try XCTUnwrap(reply["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        let expected = [
            "mod_api", "mod_scaffold", "mod_files_read", "mod_files_write", "mod_validate", "mod_load", "mod_unload", "mod_ui_state", "mod_screenshot",
            "mod_logs", "mod_package", "github_create_repo", "github_publish_release", "mod_index_entry", "mod_index_pr", "mod_files_list",
        ]
        XCTAssertEqual(Set(names), Set(expected))
        for tool in tools {
            let name = tool["name"]?.stringValue ?? "?"
            for key in ["inputSchema", "outputSchema"] {
                let schema = try XCTUnwrap(tool[key], "\(name) \(key)")
                XCTAssertEqual(schema["type"]?.stringValue, "object", "\(name) \(key) root type")
                XCTAssertTrue(schema["properties"]?.objectValue != nil, "\(name) \(key) properties")
                XCTAssertEqual(Self.closedSchemas(schema), [], "\(name) \(key) has an invalid schema node")
            }
            XCTAssertEqual(tool["inputSchema"]?["additionalProperties"], .bool(false), "\(name) input must be closed")
            XCTAssertNotNil(tool["description"]?.stringValue)
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.boolValue)
            let required = tool["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let props = tool["inputSchema"]?["properties"]?.objectValue ?? [:]
            for r in required { XCTAssertNotNil(props[r], "\(name) requires unknown property \(r)") }
            XCTAssertEqual(tool["outputSchema"]?["required"], strs(["ok"]))
        }
        let consent = ["github_create_repo", "github_publish_release", "mod_index_pr"]
        for name in consent {
            let props = tools.first { $0["name"]?.stringValue == name }?["inputSchema"]?["properties"]?.objectValue ?? [:]
            XCTAssertNotNil(props["confirm"], name)
            XCTAssertNotNil(props["confirmationToken"], name)
        }
    }

    static func closedSchemas(_ node: JSONValue, path: String = "") -> [String] {
        var problems = [String]()
        guard case .object(let o) = node else { return problems }
        if let t = o["type"]?.stringValue, !["object", "string", "integer", "number", "boolean", "array", "null"].contains(t) { problems.append("\(path): bad type \(t)") }
        if let t = o["type"]?.arrayValue, t.contains(where: { $0.stringValue == nil }) { problems.append("\(path): bad type list") }
        if o["type"]?.stringValue == "array", o["items"] == nil { problems.append("\(path): array without items") }
        if let p = o["pattern"]?.stringValue, (try? NSRegularExpression(pattern: p)) == nil { problems.append("\(path): bad pattern \(p)") }
        if let r = o["required"]?.arrayValue, let props = o["properties"]?.objectValue {
            for key in r.compactMap(\.stringValue) where props[key] == nil { problems.append("\(path): required \(key) not declared") }
        }
        for (k, v) in o["properties"]?.objectValue ?? [:] { problems += closedSchemas(v, path: path + "/" + k) }
        if let items = o["items"] { problems += closedSchemas(items, path: path + "/items") }
        return problems
    }

    func testToolsListPaginates() async throws {
        let h = await Harness(pageSize: 5)
        var seen = [String]()
        var cursor: String?
        var pages = 0
        repeat {
            let params: JSONValue = cursor.map { obj(["cursor": $0.j]) } ?? obj([:])
            let reply = await h.rpc("tools/list", params)
            seen += (reply["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            cursor = reply["result"]?["nextCursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertEqual(seen.count, 16)
        XCTAssertEqual(Set(seen).count, 16)
        XCTAssertEqual(pages, 4)
        let bad = await h.rpc("tools/list", obj(["cursor": "bogus"]))
        XCTAssertEqual(bad["error"]?["code"]?.intValue, RPCCode.invalidParams)
    }

    func testToolArgumentValidationIsEnforced() async throws {
        let h = await Harness()
        let extra = await h.call("mod_files_list", obj(["workspace": "alice.demo".j, "extra": 1.j]))
        XCTAssertTrue(extra.isError)
        XCTAssertEqual(extra.errorCode, "invalid_arguments")
        let missing = await h.call("mod_validate", obj(["workspace": "alice.demo".j]))
        XCTAssertEqual(missing.errorCode, "invalid_arguments")
        let badHash = await h.call("mod_validate", obj(["workspace": "alice.demo".j, "revision": "nothex".j]))
        XCTAssertEqual(badHash.errorCode, "invalid_arguments")
        let notObject = await h.rpc("tools/call", obj(["name": "mod_api", "arguments": "x"]))
        XCTAssertEqual(notObject["result"]?["structuredContent"]?["error"]?["code"]?.stringValue, "invalid_arguments")
    }

    func testCancellationSuppressesReply() async throws {
        let live = ClosureLiveModHosting(
            status: { LiveHostStatus(available: true, developerMode: true, windows: [LiveWindow(id: "w1", title: "Main")]) },
            load: { _ in LiveLoadResult(generation: 1) },
            unload: { _ in true },
            uiState: { _ in LiveUIState(windows: [], surfaces: [], generation: 0) },
            screenshot: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return pngBytes
            },
            logs: { _ in [] }
        )
        let h = await Harness(live: live)
        let workspace = await h.validated()
        let load = await h.call("mod_load", obj(["workspace": "alice.demo".j, "revision": workspace.revision.j, "receipt": workspace.receipt.j, "window": "w1".j]))
        XCTAssertTrue(load.ok, load.errorMessage)
        let sessionID = load.string("session")
        let message = obj(["jsonrpc": "2.0", "id": 777, "method": "tools/call", "params": obj(["name": "mod_screenshot", "arguments": obj(["session": sessionID.j, "window": "w1".j])])])
        let started = Date()
        async let reply = h.session.handle(message: message)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = await h.session.handle(message: obj(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": obj(["requestId": 777])]))
        let value = await reply
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
