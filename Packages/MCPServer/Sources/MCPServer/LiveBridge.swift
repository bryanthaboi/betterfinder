import Foundation
import ModKit

struct LiveBridge: Sendable {
    var live: LiveModHosting
    var workspaces: ModWorkspaces

    struct ModRequest: Codable { var modID: String }

    static func ok(_ data: JSONValue) -> HTTPResponse { .json(200, obj(["ok": true, "data": data])) }

    static func failure(_ code: String, _ message: String, extra: [String: JSONValue] = [:]) -> HTTPResponse {
        var e: [String: JSONValue] = ["code": code.j, "message": message.j]
        for (k, v) in extra { e[k] = v }
        return .json(200, obj(["ok": false, "error": .object(e)]))
    }

    static func failure(_ error: LiveHostError) -> HTTPResponse {
        var extra = [String: JSONValue]()
        switch error {
        case .approvalRequired(let id, let review): extra["id"] = id.j; extra["review"] = review
        case .failed(_, let diagnostics): extra["diagnostics"] = JSONValue.from(diagnostics)
        default: break
        }
        return failure(error.wireCode, error.message, extra: extra)
    }

    func handle(op: String, body: Data) async -> HTTPResponse {
        guard body.count <= 64 << 10 else { return .text(413, "body too large") }
        let json = (try? JSONValue.parse(body)) ?? obj([:])
        do {
            switch op {
            case "status":
                return Self.ok(JSONValue.from(await live.status()))
            case "load":
                guard var request = json.decoded(LiveLoadRequest.self) else { return .text(400, "bad request") }
                guard let dir = containedWorkspace(request.workspacePath, modID: request.modID) else {
                    return Self.failure("rejected", "the workspace path is outside the mod workspaces folder")
                }
                request.workspacePath = dir
                return Self.ok(JSONValue.from(try await live.load(request)))
            case "unload":
                guard let r = json.decoded(ModRequest.self) else { return .text(400, "bad request") }
                return Self.ok(obj(["unloaded": try await live.unload(modID: r.modID).j]))
            case "ui_state":
                guard let r = json.decoded(ModRequest.self) else { return .text(400, "bad request") }
                return Self.ok(JSONValue.from(try await live.uiState(modID: r.modID)))
            case "screenshot":
                guard let r = json.decoded(LiveScreenshotRequest.self) else { return .text(400, "bad request") }
                let png = try await live.screenshot(r)
                return Self.ok(obj(["png": png.base64EncodedString().j]))
            case "logs":
                guard let r = json.decoded(ModRequest.self) else { return .text(400, "bad request") }
                return Self.ok(obj(["entries": JSONValue.from(try await live.logs(modID: r.modID))]))
            default:
                return .text(404, "unknown live operation")
            }
        } catch let e as LiveHostError {
            return Self.failure(e)
        } catch {
            return Self.failure("live_failed", Redactor.clean(error.localizedDescription, limit: 300))
        }
    }

    func containedWorkspace(_ path: String, modID: String) -> String? {
        guard (try? ModWorkspaces.validateID(modID)) != nil else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let expected = workspaces.root.appendingPathComponent(modID, isDirectory: true).standardizedFileURL
        guard url.path == expected.path, let st = ModWorkspaces.lstat(expected.path), ModWorkspaces.isDirectory(st) else { return nil }
        return expected.path
    }
}

public final class RemoteLiveModHosting: LiveModHosting, @unchecked Sendable {
    private let tokenFile: URL
    private let session: URLSession

    public init(tokenFile: URL = MCPTokenFile.standardURL) {
        self.tokenFile = tokenFile
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    static let notRunning = "betterfinder is not running, or MCP is not enabled in Settings > Mods, so live tools (load, screenshot, logs) are unavailable"

    private func call(_ op: String, _ body: JSONValue) async throws -> JSONValue {
        guard let info = MCPTokenFile.read(from: tokenFile), let base = info.baseURL else { throw LiveHostError.unavailable(Self.notRunning) }
        var request = URLRequest(url: base.appendingPathComponent("live").appendingPathComponent(op))
        request.httpMethod = "POST"
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.canonicalData()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw LiveHostError.unavailable(Self.notRunning) }
        guard let http = response as? HTTPURLResponse else { throw LiveHostError.unavailable(Self.notRunning) }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LiveHostError.unavailable("betterfinder refused the pairing token; restart the MCP server or re-pair in Settings > Mods")
        }
        guard http.statusCode == 200, let json = try? JSONValue.parse(data) else {
            throw LiveHostError.unavailable("betterfinder answered with HTTP \(http.statusCode)")
        }
        if json["ok"]?.boolValue == true { return json["data"] ?? .null }
        let e = json["error"] ?? .null
        let code = e["code"]?.stringValue ?? "live_failed"
        let message = e["message"]?.stringValue ?? "the app reported an error"
        switch code {
        case "developer_mode_required": throw LiveHostError.developerModeRequired
        case "approval_required": throw LiveHostError.approvalRequired(id: e["id"]?.stringValue ?? "", review: e["review"] ?? .null)
        case "live_unavailable": throw LiveHostError.unavailable(message)
        case "rejected": throw LiveHostError.rejected(message)
        default: throw LiveHostError.failed(message, e["diagnostics"]?.decoded([ModDiagnostic].self) ?? [])
        }
    }

    public func status() async -> LiveHostStatus {
        do {
            let data = try await call("status", obj([:]))
            return data.decoded(LiveHostStatus.self) ?? .unavailable("unreadable status from betterfinder")
        } catch let e as LiveHostError {
            return .unavailable(e.message)
        } catch {
            return .unavailable(Self.notRunning)
        }
    }

    public func load(_ request: LiveLoadRequest) async throws -> LiveLoadResult {
        guard let r = try await call("load", JSONValue.from(request)).decoded(LiveLoadResult.self) else { throw LiveHostError.failed("unreadable load result", []) }
        return r
    }

    public func unload(modID: String) async throws -> Bool {
        try await call("unload", obj(["modID": modID.j]))["unloaded"]?.boolValue ?? false
    }

    public func uiState(modID: String) async throws -> LiveUIState {
        guard let r = try await call("ui_state", obj(["modID": modID.j])).decoded(LiveUIState.self) else { throw LiveHostError.failed("unreadable UI state", []) }
        return r
    }

    public func screenshot(_ request: LiveScreenshotRequest) async throws -> Data {
        let data = try await call("screenshot", JSONValue.from(request))
        guard let b64 = data["png"]?.stringValue, let png = Data(base64Encoded: b64) else { throw LiveHostError.failed("unreadable screenshot", []) }
        return png
    }

    public func logs(modID: String) async throws -> [LiveLogEntry] {
        try await call("logs", obj(["modID": modID.j]))["entries"]?.decoded([LiveLogEntry].self) ?? []
    }
}
