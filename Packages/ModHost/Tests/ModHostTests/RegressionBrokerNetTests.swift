import Darwin
import Foundation
import ModHostProtocol
import ModKit
import Network
import XCTest
@testable import ModHost

final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var received = 0
    private var requests: [String] = []
    private var clients: [Int32] = []
    private let respond: @Sendable (String) -> Data?

    var connectionCount: Int { lock.withLock { accepted } }
    var byteCount: Int { lock.withLock { received } }
    var requestTexts: [String] { lock.withLock { requests } }

    init(respond: @escaping @Sendable (String) -> Data?) throws {
        self.respond = respond
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(sock, 16) == 0 else { throw NSError(domain: "loopback", code: 1) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            lock.withLock {
                accepted += 1
                clients.append(c)
            }
            Thread { [self] in serve(c) }.start()
        }
    }

    private func serve(_ c: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var expected: Int?
        while true {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
            lock.withLock { received += n }
            if expected == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                expected = r.upperBound + length
            }
            if let e = expected, data.count >= e { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock { requests.append(text) }
        if let reply = respond(text) {
            reply.withUnsafeBytes { _ = send(c, $0.baseAddress, reply.count, 0) }
            Darwin.close(c)
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        let open = lock.withLock { clients }
        for c in open { shutdown(c, SHUT_RDWR) }
    }

    static func ok(_ body: String, extra: String = "") -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
}

final class FlippingResolver: ModHostResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    let answers: [String: [[String]]]
    init(_ answers: [String: [[String]]]) { self.answers = answers }
    var callCount: Int { lock.withLock { calls.values.reduce(0, +) } }
    func addresses(for host: String) -> [String] {
        lock.withLock {
            let n = calls[host, default: 0]
            calls[host] = n + 1
            guard let list = answers[host], !list.isEmpty else { return [] }
            return list[min(n, list.count - 1)]
        }
    }
}

final class RegressionBrokerNetTests: XCTestCase {
    static let publicAddress = "203.0.113.7"

    func mod(_ grants: [ModPermission]) throws -> ActiveMod {
        let m = ModManifest(id: "alice.net", name: "n", author: "alice", version: SemVer(1, 0, 0), api: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), app: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), runtime: .ts, entry: "x.ts", license: "MIT", permissions: grants)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return ActiveMod(manifest: m, generation: 1, snapshot: dir, mode: .live, grants: grants, logs: ModLogBuffer(file: nil), storageURL: dir.appendingPathComponent("net-\(UUID().uuidString).json"), settings: nil)
    }

    func grant(_ host: String, port: UInt16, methods: [HTTPMethod] = [.GET], allowPrivate: Bool? = nil, maxBytes: Int? = nil) -> ModPermission {
        ModPermission(kind: .net, reason: "x", endpoints: [NetEndpoint(scheme: .http, host: host, port: Int(port), methods: methods)], allowPrivate: allowPrivate, maxBytes: maxBytes)
    }

    func broker(_ resolver: ModHostResolving, publicPort: UInt16) -> ModNetBroker {
        let net = ModNetBroker(resolver: resolver)
        net.dial = { host, port in host == Self.publicAddress ? ("127.0.0.1", publicPort) : (host, port) }
        return net
    }

    func fetch(_ net: ModNetBroker, _ mod: ActiveMod, _ url: String, method: String = "GET", body: String? = nil, headers: [(String, String)] = [], timeoutMs: Int = 3000) async -> Result<JSONValue, ModCallError> {
        var o: [String: JSONValue] = ["url": .string(url), "method": .string(method), "timeoutMs": .int(timeoutMs)]
        if let body { o["body"] = .string(body) }
        if !headers.isEmpty { o["headers"] = .array(headers.map { .object(["name": .string($0.0), "value": .string($0.1)]) }) }
        do { return .success(try await net.fetch(mod, .object(o), credentials: nil)) } catch let e as ModCallError { return .failure(e) } catch { return .failure(ModCallError("other", "\(error)")) }
    }

    func testRebindBetweenAuthorizationAndConnectionNeverReachesPrivateEndpoint() async throws {
        let privateServer = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok("private") }
        let publicServer = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok("public") }
        defer { privateServer.stop(); publicServer.stop() }
        let resolver = FlippingResolver(["rebind.test": [[Self.publicAddress], ["127.0.0.1"]]])
        let net = broker(resolver, publicPort: publicServer.port)
        let m = try mod([grant("rebind.test", port: privateServer.port)])
        let r = await fetch(net, m, "http://rebind.test:\(privateServer.port)/x")
        let value = try r.get()
        XCTAssertEqual(value["status"]?.intValue, 200)
        XCTAssertEqual(value["body"]?.stringValue, "public")
        XCTAssertEqual(resolver.callCount, 1)
        XCTAssertEqual(publicServer.connectionCount, 1)
        XCTAssertEqual(privateServer.connectionCount, 0)
        XCTAssertEqual(privateServer.byteCount, 0)
        XCTAssertTrue(publicServer.requestTexts.first?.contains("Host: rebind.test:\(privateServer.port)\r\n") == true)
    }

    func testPrivateResolutionIsRefusedBeforeAnyConnection() async throws {
        let privateServer = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok("private") }
        defer { privateServer.stop() }
        let resolver = FlippingResolver(["inner.test": [["127.0.0.1"]]])
        let net = ModNetBroker(resolver: resolver)
        let m = try mod([grant("inner.test", port: privateServer.port, methods: [.POST]), grant("127.0.0.1", port: privateServer.port)])
        let a = await fetch(net, m, "http://inner.test:\(privateServer.port)/", method: "POST", body: "secret")
        XCTAssertEqual(a.failureCode, "denied")
        let b = await fetch(net, m, "http://127.0.0.1:\(privateServer.port)/")
        XCTAssertEqual(b.failureCode, "denied")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(privateServer.connectionCount, 0)
        XCTAssertEqual(privateServer.byteCount, 0)
    }

    func testRedirectToPrivateDestinationIsRefusedWithoutContactingIt() async throws {
        let privateServer = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok("private") }
        let p = privateServer.port
        let publicServer = try LoopbackHTTPServer { req in
            if req.hasPrefix("GET /literal ") { return Data("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(p)/x\r\nContent-Length: 0\r\n\r\n".utf8) }
            return Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://inner.test:\(p)/x\r\nContent-Length: 0\r\n\r\n".utf8)
        }
        defer { privateServer.stop(); publicServer.stop() }
        let resolver = FlippingResolver(["front.test": [[Self.publicAddress]], "inner.test": [["10.0.0.5"]]])
        let net = broker(resolver, publicPort: publicServer.port)
        let m = try mod([grant("front.test", port: p), grant("127.0.0.1", port: p), grant("inner.test", port: p)])
        let a = await fetch(net, m, "http://front.test:\(p)/literal")
        XCTAssertEqual(a.failureCode, "denied")
        XCTAssertTrue(a.failureMessage.contains("redirect refused"), a.failureMessage)
        let b = await fetch(net, m, "http://front.test:\(p)/name")
        XCTAssertEqual(b.failureCode, "denied")
        XCTAssertEqual(publicServer.connectionCount, 2)
        XCTAssertEqual(privateServer.connectionCount, 0)
        XCTAssertEqual(privateServer.byteCount, 0)
    }

    func testRedirectToUngrantedEndpointIsRefused() async throws {
        let publicServer = try LoopbackHTTPServer { _ in Data("HTTP/1.1 301 Moved\r\nLocation: http://elsewhere.test/\r\nContent-Length: 0\r\n\r\n".utf8) }
        defer { publicServer.stop() }
        let resolver = FlippingResolver(["front.test": [[Self.publicAddress]], "elsewhere.test": [[Self.publicAddress]]])
        let net = broker(resolver, publicPort: publicServer.port)
        let m = try mod([grant("front.test", port: 80)])
        let r = await fetch(net, m, "http://front.test/")
        XCTAssertEqual(r.failureCode, "denied")
        XCTAssertEqual(publicServer.connectionCount, 1)
    }

    func testAllowedPrivateEndpointRoundTrip() async throws {
        let server = try LoopbackHTTPServer { req in
            if req.hasPrefix("POST ") {
                let body = req.components(separatedBy: "\r\n\r\n").last ?? ""
                return Data("HTTP/1.1 201 Created\r\nX-Echo: a\r\nX-Echo: b\r\nTransfer-Encoding: chunked\r\n\r\n4\r\necho\r\n\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n".utf8)
            }
            if req.hasPrefix("GET /redirect ") { return Data("HTTP/1.1 303 See Other\r\nLocation: /done\r\nContent-Length: 0\r\n\r\n".utf8) }
            return LoopbackHTTPServer.ok("done")
        }
        defer { server.stop() }
        let net = ModNetBroker(resolver: FlippingResolver([:]))
        let m = try mod([grant("127.0.0.1", port: server.port, methods: [.GET, .POST], allowPrivate: true)])
        let post = try await fetch(net, m, "http://127.0.0.1:\(server.port)/submit?q=1", method: "POST", body: "payload", headers: [("X-Mod", "yes")]).get()
        XCTAssertEqual(post["status"]?.intValue, 201)
        XCTAssertEqual(post["body"]?.stringValue, "echopayload")
        let headers = post["headers"]?.arrayValue ?? []
        XCTAssertTrue(headers.contains { $0["name"]?.stringValue == "X-Echo" && $0["value"]?.stringValue == "a, b" })
        let sent = server.requestTexts.first ?? ""
        XCTAssertTrue(sent.hasPrefix("POST /submit?q=1 HTTP/1.1\r\n"), sent)
        XCTAssertTrue(sent.contains("Host: 127.0.0.1:\(server.port)\r\n"))
        XCTAssertTrue(sent.contains("X-Mod: yes\r\n"))
        XCTAssertTrue(sent.contains("Content-Length: 7\r\n"))
        let redirected = try await fetch(net, m, "http://127.0.0.1:\(server.port)/redirect").get()
        XCTAssertEqual(redirected["status"]?.intValue, 200)
        XCTAssertEqual(redirected["body"]?.stringValue, "done")
    }

    func testResponseLimitsAndTimeouts() async throws {
        let big = String(repeating: "x", count: 4096)
        let server = try LoopbackHTTPServer { req in
            if req.hasPrefix("GET /declared ") { return LoopbackHTTPServer.ok(big) }
            if req.hasPrefix("GET /stream ") { return Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n\(big)".utf8) }
            if req.hasPrefix("GET /chunked ") { return Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1000\r\n\(big)\r\n0\r\n\r\n".utf8) }
            return nil
        }
        defer { server.stop() }
        let net = ModNetBroker(resolver: FlippingResolver([:]))
        let m = try mod([grant("127.0.0.1", port: server.port, allowPrivate: true, maxBytes: 1024)])
        for path in ["declared", "stream", "chunked"] {
            let r = await fetch(net, m, "http://127.0.0.1:\(server.port)/\(path)")
            XCTAssertEqual(r.failureCode, "limitExceeded", path)
        }
        let start = Date()
        let hang = await fetch(net, m, "http://127.0.0.1:\(server.port)/hang", timeoutMs: 400)
        XCTAssertEqual(hang.failureCode, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testHeaderNamesMustBeTokens() async throws {
        let server = try LoopbackHTTPServer { _ in LoopbackHTTPServer.ok("x") }
        defer { server.stop() }
        let net = ModNetBroker(resolver: FlippingResolver([:]))
        let m = try mod([grant("127.0.0.1", port: server.port, allowPrivate: true)])
        for name in ["X-A\r\nEvil", "Bad Name", "X:Y", "Keep-Alive", "Host"] {
            let r = await fetch(net, m, "http://127.0.0.1:\(server.port)/", headers: [(name, "v")])
            XCTAssertEqual(r.failureCode, "invalidArgument", name)
        }
        XCTAssertEqual(server.connectionCount, 0)
    }

    func testLiveHTTPSValidatesHostnameWhenEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BF_LIVE_NET"] == "1")
        let net = ModNetBroker()
        let m = try mod([ModPermission(kind: .net, reason: "x", endpoints: [NetEndpoint(scheme: .https, host: "example.com", methods: [.GET])])])
        let ok = try await fetch(net, m, "https://example.com/", timeoutMs: 10_000).get()
        XCTAssertEqual(ok["status"]?.intValue, 200)
        XCTAssertTrue(ok["body"]?.stringValue?.contains("Example Domain") == true)
        let ips = SystemHostResolver().addresses(for: "example.com")
        let wrong = ModNetBroker(resolver: FlippingResolver(["mismatch.test": [ips]]))
        let bad = try mod([ModPermission(kind: .net, reason: "x", endpoints: [NetEndpoint(scheme: .https, host: "mismatch.test", methods: [.GET])])])
        let refused = await fetch(wrong, bad, "https://mismatch.test/", timeoutMs: 10_000)
        XCTAssertNotNil(refused.failureCode)
    }

    func testPinnedEndpointComparison() {
        XCTAssertTrue(ModHTTPConnection.sameAddress(.ipv4(IPv4Address("93.184.216.34")!), "93.184.216.34"))
        XCTAssertFalse(ModHTTPConnection.sameAddress(.ipv4(IPv4Address("127.0.0.1")!), "93.184.216.34"))
        XCTAssertTrue(ModHTTPConnection.sameAddress(.ipv6(IPv6Address("2606:2800:220:1::1")!), "2606:2800:220:1:0:0:0:1"))
        XCTAssertTrue(ModHTTPConnection.sameAddress(.ipv6(IPv6Address("::ffff:93.184.216.34")!), "93.184.216.34"))
        XCTAssertEqual(ModHTTPWire.hostHeader(host: "2606:2800::1", port: 443, tls: true), "[2606:2800::1]")
        XCTAssertEqual(ModHTTPWire.hostHeader(host: "example.com", port: 8080, tls: false), "example.com:8080")
    }
}

private extension Result where Failure == ModCallError {
    var failureCode: String? { if case .failure(let e) = self { return e.code }; return nil }
    var failureMessage: String { if case .failure(let e) = self { return e.message }; return "" }
}
