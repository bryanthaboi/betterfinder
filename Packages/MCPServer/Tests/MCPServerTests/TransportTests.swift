import Foundation
import ModKit
import XCTest
@testable import MCPServer

final class HTTPHandlerTests: XCTestCase {
    let token = String(repeating: "ab", count: 32)
    let port: UInt16 = 4242

    func makeHandler(live: LiveModHosting = UnavailableLiveHosting(), allowedOrigins: [String] = []) -> (MCPHTTPHandler, MCPTokenStore, ModWorkspaces) {
        let workspaces = ModWorkspaces(root: tempDirectory())
        let server = MCPServer(configuration: MCPServerConfiguration(workspaces: workspaces, live: live))
        let tokens = MCPTokenStore(token: token)
        let box = PortBox()
        box.port = port
        return (MCPHTTPHandler(server: server, tokens: tokens, port: box, allowedOrigins: allowedOrigins), tokens, workspaces)
    }

    func request(_ method: String = "POST", path: String = "/mcp", body: JSONValue? = nil, token: String? = nil, origin: String? = nil, host: String? = "127.0.0.1:4242", session: String? = nil, extra: [String: String] = [:]) -> HTTPRequest {
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let host { headers["Host"] = host }
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let origin { headers["Origin"] = origin }
        if let session { headers["Mcp-Session-Id"] = session }
        for (k, v) in extra { headers[k] = v }
        return HTTPRequest(method: method, path: path, headers: headers, body: body?.canonicalData() ?? Data())
    }

    let initialize: JSONValue = obj(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": obj(["protocolVersion": "2025-06-18", "capabilities": obj([:])])])

    func testMissingOrWrongBearerIs401() async throws {
        let (handler, _, _) = makeHandler()
        let missing = await handler.handle(request(body: initialize))
        XCTAssertEqual(missing.status, 401)
        XCTAssertTrue(missing.headers["WWW-Authenticate"]?.contains("Bearer") == true)
        for bad in ["", "wrong", String(repeating: "ab", count: 31), token + "x", token.uppercased()] {
            let r = await handler.handle(request(body: initialize, token: bad))
            XCTAssertEqual(r.status, 401, bad)
        }
        var basic = request(body: initialize)
        basic.headers["authorization"] = "Basic \(token)"
        let basicResponse = await handler.handle(basic)
        XCTAssertEqual(basicResponse.status, 401)
        var raw = request(body: initialize)
        raw.headers["authorization"] = token
        let rawResponse = await handler.handle(raw)
        XCTAssertEqual(rawResponse.status, 401)
        let good = await handler.handle(request(body: initialize, token: token))
        XCTAssertEqual(good.status, 200)
    }

    func testWrongOriginIs403EvenWithValidToken() async throws {
        let (handler, _, _) = makeHandler()
        for origin in ["https://evil.example", "http://127.0.0.1:9999", "http://localhost", "null", "http://127.0.0.1:4242.evil.com", "https://127.0.0.1:4242"] {
            let withToken = await handler.handle(request(body: initialize, token: token, origin: origin))
            XCTAssertEqual(withToken.status, 403, origin)
            let without = await handler.handle(request(body: initialize, origin: origin))
            XCTAssertEqual(without.status, 403, "\(origin) must be refused before auth is even considered")
        }
        for origin in ["http://127.0.0.1:4242", "http://localhost:4242", "http://[::1]:4242", "HTTP://LOCALHOST:4242"] {
            let ok = await handler.handle(request(body: initialize, token: token, origin: origin))
            XCTAssertEqual(ok.status, 200, origin)
        }
        let (custom, _, _) = makeHandler(allowedOrigins: ["http://localhost:6274"])
        let allowed = await custom.handle(request(body: initialize, token: token, origin: "http://localhost:6274"))
        XCTAssertEqual(allowed.status, 200)
    }

    func testHostHeaderIsValidatedAgainstRebinding() async throws {
        let (handler, _, _) = makeHandler()
        for host in ["evil.example", "evil.example:4242", "127.0.0.1", "127.0.0.1:1", "localhost.evil.com:4242", "127.0.0.1:4242.evil.com"] {
            let r = await handler.handle(request(body: initialize, token: token, host: host))
            XCTAssertEqual(r.status, 403, host)
        }
        let missing = await handler.handle(request(body: initialize, token: token, host: nil))
        XCTAssertEqual(missing.status, 400)
        for host in ["127.0.0.1:4242", "localhost:4242", "[::1]:4242", "LOCALHOST:4242"] {
            let r = await handler.handle(request(body: initialize, token: token, host: host))
            XCTAssertEqual(r.status, 200, host)
        }
    }

    func testSessionLifecycleOverHTTP() async throws {
        let (handler, tokens, _) = makeHandler()
        let first = await handler.handle(request(body: initialize, token: token))
        XCTAssertEqual(first.status, 200)
        let sessionID = try XCTUnwrap(first.headers["Mcp-Session-Id"])
        XCTAssertEqual(sessionID.count, 32)
        let reply = try JSONValue.parse(first.body)
        XCTAssertEqual(reply["result"]?["protocolVersion"]?.stringValue, "2025-06-18")

        let list: JSONValue = obj(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let noSession = await handler.handle(request(body: list, token: token))
        XCTAssertEqual(noSession.status, 400)
        let unknown = await handler.handle(request(body: list, token: token, session: String(repeating: "0", count: 32)))
        XCTAssertEqual(unknown.status, 404)
        let noAuth = await handler.handle(request(body: list, session: sessionID))
        XCTAssertEqual(noAuth.status, 401, "a session id is never authentication")
        let ok = await handler.handle(request(body: list, token: token, session: sessionID))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(try JSONValue.parse(ok.body)["result"]?["tools"]?.arrayValue?.count, 16)

        let note = await handler.handle(request(body: obj(["jsonrpc": "2.0", "method": "notifications/initialized"]), token: token, session: sessionID))
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)

        let call: JSONValue = obj(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": obj(["name": "mod_api", "arguments": obj(["kind": "hooks".j])])])
        let called = await handler.handle(request(body: call, token: token, session: sessionID, extra: ["MCP-Protocol-Version": "2025-06-18"]))
        XCTAssertEqual(try JSONValue.parse(called.body)["result"]?["structuredContent"]?["ok"]?.boolValue, true)
        let badVersion = await handler.handle(request(body: call, token: token, session: sessionID, extra: ["MCP-Protocol-Version": "1999-01-01"]))
        XCTAssertEqual(badVersion.status, 400)

        let deleted = await handler.handle(request("DELETE", token: token, session: sessionID))
        XCTAssertEqual(deleted.status, 204)
        let gone = await handler.handle(request(body: list, token: token, session: sessionID))
        XCTAssertEqual(gone.status, 404)

        let second = await handler.handle(request(body: initialize, token: token))
        let secondID = try XCTUnwrap(second.headers["Mcp-Session-Id"])
        _ = tokens.rotate()
        let afterRotate = await handler.handle(request(body: list, token: token, session: secondID))
        XCTAssertEqual(afterRotate.status, 401)
        let fresh = await handler.handle(request(body: list, token: tokens.token, session: secondID))
        XCTAssertEqual(fresh.status, 200)
    }

    func testMalformedHTTPRequests() async throws {
        let (handler, _, _) = makeHandler()
        let get = await handler.handle(request("GET", token: token))
        XCTAssertEqual(get.status, 405)
        let put = await handler.handle(request("PUT", token: token))
        XCTAssertEqual(put.status, 405)
        var wrongType = request(body: initialize, token: token)
        wrongType.headers["content-type"] = "text/plain"
        let typeResponse = await handler.handle(wrongType)
        XCTAssertEqual(typeResponse.status, 415)
        var garbage = request(token: token)
        garbage.body = Data("{nope".utf8)
        let garbageResponse = await handler.handle(garbage)
        XCTAssertEqual(garbageResponse.status, 400)
        var huge = request(token: token)
        huge.body = Data(repeating: 0x20, count: MCPHTTPHandler.maxBodyBytes + 1)
        let hugeResponse = await handler.handle(huge)
        XCTAssertEqual(hugeResponse.status, 413)
        let notFound = await handler.handle(request(path: "/other", body: initialize, token: token))
        XCTAssertEqual(notFound.status, 404)
        let initFail = await handler.handle(request(body: obj(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": obj([:])]), token: token))
        XCTAssertNil(initFail.headers["Mcp-Session-Id"])
    }

    func testLiveBridgeRequiresAuthAndContainsPaths() async throws {
        let recorder = LiveRecorder()
        recorder.approvalRequired = false
        let (handler, _, workspaces) = makeHandler(live: recordingLive(recorder))
        let status: JSONValue = obj([:])
        let noAuth = await handler.handle(request(path: "/live/status", body: status))
        XCTAssertEqual(noAuth.status, 401)
        let badOrigin = await handler.handle(request(path: "/live/status", body: status, token: token, origin: "https://evil.example"))
        XCTAssertEqual(badOrigin.status, 403)
        let get = await handler.handle(request("GET", path: "/live/status", token: token))
        XCTAssertEqual(get.status, 405)
        let ok = await handler.handle(request(path: "/live/status", body: status, token: token))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(try JSONValue.parse(ok.body)["data"]?["available"]?.boolValue, true)

        let dir = workspaces.root.appendingPathComponent("alice.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func load(_ path: String, modID: String = "alice.demo") async throws -> JSONValue {
            let body = JSONValue.from(LiveLoadRequest(modID: modID, workspacePath: path, treeHash: String(repeating: "a", count: 64), windowID: "win-1"))
            return try JSONValue.parse(await handler.handle(request(path: "/live/load", body: body, token: token)).body)
        }
        let good = try await load(dir.path)
        XCTAssertEqual(good["ok"]?.boolValue, true)
        for path in ["/etc", NSHomeDirectory(), workspaces.root.path, dir.path + "/..", dir.deletingLastPathComponent().appendingPathComponent("other").path, "/"] {
            let bad = try await load(path)
            XCTAssertEqual(bad["ok"]?.boolValue, false, path)
            XCTAssertEqual(bad["error"]?["code"]?.stringValue, "rejected", path)
        }
        let wrongMod = try await load(dir.path, modID: "alice.other")
        XCTAssertEqual(wrongMod["ok"]?.boolValue, false)
        XCTAssertEqual(recorder.loads.count, 1)
        let outside = tempDirectory().appendingPathComponent("alice.evil", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspaces.root.appendingPathComponent("alice.evil"), withDestinationURL: outside)
        let viaLink = try await load(workspaces.root.appendingPathComponent("alice.evil").path, modID: "alice.evil")
        XCTAssertEqual(viaLink["ok"]?.boolValue, false)
        let unknownOp = await handler.handle(request(path: "/live/format-disk", body: status, token: token))
        XCTAssertEqual(unknownOp.status, 404)
        let noBridge = MCPHTTPHandler(server: MCPServer(configuration: MCPServerConfiguration(workspaces: workspaces)), tokens: MCPTokenStore(token: token), port: { let b = PortBox(); b.port = port; return b }(), exposeLiveBridge: false)
        let disabled = await noBridge.handle(request(path: "/live/status", body: status, token: token))
        XCTAssertEqual(disabled.status, 404)
    }
}

final class HTTPSocketTests: XCTestCase {
    func post(_ url: URL, body: JSONValue, token: String?, origin: String? = nil, session: String? = nil) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.canonicalData()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        return (response as! HTTPURLResponse, data)
    }

    func testRealListenerEnforcesAuthAndOrigin() async throws {
        let root = tempDirectory()
        let tokenFile = root.appendingPathComponent("support/mcp.json")
        let host = MCPServerHost(MCPServerHostConfiguration(
            server: MCPServerConfiguration(workspaces: ModWorkspaces(root: root.appendingPathComponent("ws"))), tokenFile: tokenFile
        ))
        let info = try await host.start()
        defer { host.stop() }
        let url = try XCTUnwrap(URL(string: info.url))
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertGreaterThan(url.port ?? 0, 1023)
        XCTAssertEqual(info.token.count, 64)

        var st = stat()
        XCTAssertEqual(lstat(tokenFile.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(tokenFile.deletingLastPathComponent().path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(MCPTokenFile.read(from: tokenFile), info)

        let initialize: JSONValue = obj(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": obj(["protocolVersion": "2025-06-18", "capabilities": obj([:])])])
        let (noToken, _) = try await post(url, body: initialize, token: nil)
        XCTAssertEqual(noToken.statusCode, 401)
        let (wrong, _) = try await post(url, body: initialize, token: String(repeating: "0", count: 64))
        XCTAssertEqual(wrong.statusCode, 401)
        let (badOrigin, _) = try await post(url, body: initialize, token: info.token, origin: "https://evil.example")
        XCTAssertEqual(badOrigin.statusCode, 403)
        let (ok, data) = try await post(url, body: initialize, token: info.token, origin: "http://127.0.0.1:\(url.port!)")
        XCTAssertEqual(ok.statusCode, 200)
        XCTAssertEqual(try JSONValue.parse(data)["result"]?["serverInfo"]?["name"]?.stringValue, "betterfinder-mod")
        let sessionID = try XCTUnwrap(ok.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (list, listData) = try await post(url, body: obj(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]), token: info.token, session: sessionID)
        XCTAssertEqual(list.statusCode, 200)
        XCTAssertEqual(try JSONValue.parse(listData)["result"]?["tools"]?.arrayValue?.count, 16)
        let (accepted, body) = try await post(url, body: obj(["jsonrpc": "2.0", "method": "notifications/initialized"]), token: info.token, session: sessionID)
        XCTAssertEqual(accepted.statusCode, 202)
        XCTAssertTrue(body.isEmpty)

        let rotated = try host.rotateToken()
        XCTAssertNotEqual(rotated.token, info.token)
        XCTAssertEqual(MCPTokenFile.read(from: tokenFile)?.token, rotated.token)
        let (old, _) = try await post(url, body: initialize, token: info.token)
        XCTAssertEqual(old.statusCode, 401)
        let (fresh, _) = try await post(url, body: initialize, token: rotated.token)
        XCTAssertEqual(fresh.statusCode, 200)

        host.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path))
        do {
            _ = try await post(url, body: initialize, token: rotated.token)
            XCTFail("listener should be closed")
        } catch {}
    }

    func testRemoteLiveHostingTalksToTheAppEndpoint() async throws {
        let root = tempDirectory()
        let tokenFile = root.appendingPathComponent("mcp.json")
        let recorder = LiveRecorder()
        recorder.logLines = [LiveLogEntry(time: "t", level: "info", message: "hello")]
        let workspaces = ModWorkspaces(root: root.appendingPathComponent("ws"))
        let host = MCPServerHost(MCPServerHostConfiguration(server: MCPServerConfiguration(workspaces: workspaces, live: recordingLive(recorder)), tokenFile: tokenFile))
        _ = try await host.start()
        defer { host.stop() }
        let remote = RemoteLiveModHosting(tokenFile: tokenFile)

        let status = await remote.status()
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.windows, [LiveWindow(id: "win-1", title: "Downloads")])
        XCTAssertEqual(status.appVersion, "9.9")

        let dir = workspaces.root.appendingPathComponent("alice.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let request = LiveLoadRequest(modID: "alice.demo", workspacePath: dir.path, treeHash: String(repeating: "a", count: 64), windowID: "win-1")
        do {
            _ = try await remote.load(request)
            XCTFail("expected approval")
        } catch let e as LiveHostError {
            XCTAssertEqual(e, .approvalRequired(id: "ap-1", review: obj(["wants": "load alice.demo".j])))
        }
        var approved = request
        approved.approval = "ap-1"
        let loaded = try await remote.load(approved)
        XCTAssertEqual(loaded.generation, 1)

        var outside = approved
        outside.workspacePath = "/etc"
        do {
            _ = try await remote.load(outside)
            XCTFail("path outside the workspaces folder must be rejected")
        } catch let e as LiveHostError {
            if case .rejected = e {} else { XCTFail("\(e)") }
        }
        let ui = try await remote.uiState(modID: "alice.demo")
        XCTAssertEqual(ui.surfaces.count, 1)
        let png = try await remote.screenshot(LiveScreenshotRequest(modID: "alice.demo", windowID: "win-1"))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        let logs = try await remote.logs(modID: "alice.demo")
        XCTAssertEqual(logs.map(\.message), ["hello"])
        let unloaded = try await remote.unload(modID: "alice.demo")
        XCTAssertTrue(unloaded)

        recorder.developerMode = false
        let noDev = await remote.status()
        XCTAssertFalse(noDev.developerMode)
    }

    func testRemoteLiveHostingReportsUnavailableWithoutTokenFile() async throws {
        let missing = RemoteLiveModHosting(tokenFile: tempDirectory().appendingPathComponent("mcp.json"))
        let status = await missing.status()
        XCTAssertFalse(status.available)
        XCTAssertTrue(status.reason?.contains("not running") == true)
        do {
            _ = try await missing.logs(modID: "alice.demo")
            XCTFail("expected unavailable")
        } catch let e as LiveHostError {
            if case .unavailable = e {} else { XCTFail("\(e)") }
        }

        let dir = tempDirectory()
        let file = dir.appendingPathComponent("mcp.json")
        try MCPTokenFile.write(MCPEndpointInfo(url: "http://127.0.0.1:1/mcp", token: String(repeating: "f", count: 64), startedAt: "now"), to: file)
        let stale = RemoteLiveModHosting(tokenFile: file)
        let down = await stale.status()
        XCTAssertFalse(down.available)

        chmod(file.path, 0o644)
        XCTAssertNil(MCPTokenFile.read(from: file))
        try MCPTokenFile.write(MCPEndpointInfo(url: "http://evil.example:80/mcp", token: String(repeating: "f", count: 64), startedAt: "now"), to: file)
        XCTAssertNotNil(MCPTokenFile.read(from: file))
        XCTAssertNil(MCPTokenFile.read(from: file)?.baseURL, "the pairing token must never be sent to a non-loopback host")
        let remote = RemoteLiveModHosting(tokenFile: file)
        let external = await remote.status()
        XCTAssertFalse(external.available)
    }

    func testTokenFileIsPrivateAndAtomic() throws {
        let dir = tempDirectory().appendingPathComponent("nested/support")
        let file = dir.appendingPathComponent("mcp.json")
        let a = MCPEndpointInfo(url: "http://127.0.0.1:5000/mcp", token: Hex.random(bytes: 32), startedAt: "now")
        try MCPTokenFile.write(a, to: file)
        let b = MCPEndpointInfo(url: "http://127.0.0.1:5001/mcp", token: Hex.random(bytes: 32), startedAt: "later")
        try MCPTokenFile.write(b, to: file)
        XCTAssertEqual(MCPTokenFile.read(from: file), b)
        var st = stat()
        XCTAssertEqual(lstat(file.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["mcp.json"])
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(MCPTokenFile.read(from: link), "symlinked token files are not trusted")
        XCTAssertTrue(MCPTokenStore(token: "abc").matches("abc"))
        XCTAssertFalse(MCPTokenStore(token: "abc").matches("abd"))
        XCTAssertFalse(MCPTokenStore(token: "abc").matches("abcd"))
    }
}

final class StdioTransportTests: XCTestCase {
    func runTransport(lines: [String], closeInput: Bool = true) async throws -> [JSONValue] {
        let server = MCPServer(configuration: MCPServerConfiguration(workspaces: ModWorkspaces(root: tempDirectory())))
        let input = Pipe()
        let output = Pipe()
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let transport = StdioTransport(server: server, input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let run = Task { await transport.run() }
        let writer = Task.detached {
            for line in lines { try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
            if closeInput { try? input.fileHandleForWriting.close() }
        }
        _ = await writer.value
        await run.value
        try? output.fileHandleForWriting.close()
        let data = await reader.value
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    func testPipelinedHandshakeToolsAndProtocolOnlyStdout() async throws {
        let initialize = obj(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": obj(["protocolVersion": "2025-06-18", "capabilities": obj([:])])]).compactString
        let initialized = obj(["jsonrpc": "2.0", "method": "notifications/initialized"]).compactString
        let list = obj(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]).compactString
        let scaffold = obj(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": obj(["name": "mod_scaffold", "arguments": obj([
            "request": "x".j, "id": "alice.piped".j, "template": "command".j, "language": "bfscript".j])])]).compactString
        let files = obj(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": obj(["name": "mod_files_list", "arguments": obj(["workspace": "alice.piped".j])])]).compactString
        let replies = try await runTransport(lines: [initialize, initialized, list, scaffold, files, "", "not json", "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}"])
        XCTAssertEqual(replies.map { $0["id"] }, [.int(1), .int(2), .int(3), .int(4), .null, .int(9)])
        XCTAssertEqual(replies[0]["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(replies[1]["result"]?["tools"]?.arrayValue?.count, 16)
        XCTAssertEqual(replies[2]["result"]?["structuredContent"]?["ok"]?.boolValue, true)
        XCTAssertEqual(replies[3]["result"]?["structuredContent"]?["data"]?["files"]?.arrayValue?.isEmpty, false)
        XCTAssertEqual(replies[4]["error"]?["code"]?.intValue, RPCCode.parseError)
        XCTAssertEqual(replies[5]["result"], obj([:]))
    }

    func testOversizedLineGetsAnErrorAndStreamContinues() async throws {
        let big = String(repeating: "a", count: MCPSession.maxMessageBytes + 10)
        let replies = try await runTransport(lines: [big, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"])
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0]["error"]?["code"]?.intValue, RPCCode.invalidRequest)
        XCTAssertEqual(replies[1]["result"], obj([:]))
    }

    func testShutdownEndsTheLoopWithoutEOF() async throws {
        let replies = try await runTransport(lines: [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
        ], closeInput: true)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0]["id"], .int(1))
    }
}

final class CommandRunnerTests: XCTestCase {
    func testOnlyGhAndGitAreRunnable() async throws {
        XCTAssertNil(ProcessCommandRunner.locate("rm"))
        XCTAssertNil(ProcessCommandRunner.locate("/bin/sh"))
        XCTAssertNil(ProcessCommandRunner.locate("sh"))
        do {
            _ = try await ProcessCommandRunner().run(CommandInvocation("sh", ["-c", "echo pwned"]))
            XCTFail("sh must not be runnable")
        } catch let e as CommandRunnerError { XCTAssertEqual(e, .notFound("sh")) }
        if ProcessCommandRunner.locate("git") != nil {
            let r = try await ProcessCommandRunner().run(CommandInvocation("git", ["--version"]))
            XCTAssertTrue(r.succeeded)
            XCTAssertTrue(r.stdout.hasPrefix("git version"))
            let failing = try await ProcessCommandRunner().run(CommandInvocation("git", ["definitely-not-a-command"]))
            XCTAssertFalse(failing.succeeded)
        }
    }

    func testRedactorAndCleaner() {
        let dirty = "token=abcdef123456 ghp_0123456789abcdefghijklmnopqrstuvwxyz github_pat_11AAAAAAA0123456789abcdef https://u:pw1234@github.com Bearer abcdefghijklmnop \u{1B}[31mred\u{7}"
        let clean = Redactor.clean(dirty)
        for secret in ["abcdef123456", "ghp_0123", "github_pat_11", "pw1234", "abcdefghijklmnop", "\u{1B}", "\u{7}"] { XCTAssertFalse(clean.contains(secret), secret) }
        XCTAssertEqual(Redactor.clean(String(repeating: "x", count: 50), limit: 10).count, 11)
    }
}
