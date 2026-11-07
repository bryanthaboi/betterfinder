import FileOps
import Foundation
import Integration
import ModHostProtocol
import ModKit
import XCTest
@testable import ModHost

final class BehaviorRegressionHTTPParserTests: XCTestCase {
    static let intMaxChunk = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n"
    static let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"

    var probeURL: URL {
        Bundle(for: BehaviorRegressionHTTPParserTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ModHostHTTPProbe")
    }

    func probe(_ response: String, cap: Int, segment: Int) throws -> (reason: Process.TerminationReason, status: Int32, output: String) {
        let p = Process()
        p.executableURL = probeURL
        p.arguments = [String(cap), String(segment)]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(response.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationReason, p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    func testIntMaxChunkAfterOneByteIsRefusedInSubprocess() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: probeURL.path), probeURL.path)
        let sane = try probe(Self.chunked + "5\r\nhello\r\n0\r\n\r\n", cap: 1024, segment: 3)
        XCTAssertEqual(sane.reason, .exit)
        XCTAssertEqual(sane.output.trimmingCharacters(in: .newlines), "ok 200 5")
        let cases: [(String, Int, Int)] = [
            (Self.intMaxChunk, 1024, 64 * 1024),
            (Self.intMaxChunk, 1024, 1),
            (Self.intMaxChunk, ModNetBroker.hardCap, 7),
            (Self.intMaxChunk, Int.max, 64 * 1024),
            (Self.chunked + "1\r\na\r\n7ffffffffffffffe\r\n", Int.max - 1, 64 * 1024),
            (Self.chunked + "1\r\na\r\nffffffffffffffff\r\n", 1024, 64 * 1024),
            (Self.chunked + "1\r\na\r\n10000000000000000\r\n", 1024, 64 * 1024),
            (Self.chunked + "7fffffffffffffff\r\n", Int.max, 64 * 1024),
            ("HTTP/1.1 200 OK\r\nContent-Length: 9223372036854775807\r\n\r\na", Int.max, 64 * 1024),
            ("HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999999\r\n\r\na", 1024, 64 * 1024),
        ]
        for (response, cap, segment) in cases {
            let r = try probe(response, cap: cap, segment: segment)
            XCTAssertEqual(r.reason, .exit, "probe crashed (signal \(r.status)) on \(response.debugDescription) cap \(cap)")
            XCTAssertEqual(r.status, 0)
            XCTAssertTrue(r.output.hasPrefix("error "), "\(response.debugDescription): \(r.output)")
            if cap < Int.max - 1 { XCTAssertTrue(r.output.hasPrefix("error limitExceeded"), "\(response.debugDescription): \(r.output)") }
        }
    }

    func parse(_ text: String, cap: Int = 1024, segment: Int = 64 * 1024, method: String = "GET") async -> Result<ModHTTPResponse, ModCallError> {
        await parse(Data(text.utf8), cap: cap, segment: segment, method: method)
    }

    func parse(_ data: Data, cap: Int = 1024, segment: Int = 64 * 1024, method: String = "GET") async -> Result<ModHTTPResponse, ModCallError> {
        do {
            return .success(try await ModHTTPResponseReader(bytes: data, segment: segment).readResponse(method: method, cap: cap))
        } catch let e as ModCallError {
            return .failure(e)
        } catch {
            return .failure(ModCallError("other", "\(error)"))
        }
    }

    func expect(_ text: String, body: String, cap: Int = 1024, segments: [Int] = [1, 2, 3, 5, 64 * 1024], file: StaticString = #filePath, line: UInt = #line) async {
        for segment in segments {
            switch await parse(text, cap: cap, segment: segment) {
            case .success(let r): XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body, "segment \(segment): \(text.debugDescription)", file: file, line: line)
            case .failure(let e): XCTFail("segment \(segment): \(e.code) \(e.message) for \(text.debugDescription)", file: file, line: line)
            }
        }
    }

    func expect(_ text: String, code: String, cap: Int = 1024, segments: [Int] = [1, 64 * 1024], file: StaticString = #filePath, line: UInt = #line) async {
        for segment in segments {
            switch await parse(text, cap: cap, segment: segment) {
            case .success(let r): XCTFail("segment \(segment): accepted \(text.debugDescription) as \(r.status) \(r.body.count) bytes", file: file, line: line)
            case .failure(let e): XCTAssertEqual(e.code, code, "segment \(segment): \(e.message) for \(text.debugDescription)", file: file, line: line)
            }
        }
    }

    func testIntMaxChunkSizesAreRefusedAtTheParserBoundary() async {
        await expect(Self.intMaxChunk, code: "limitExceeded", segments: [1, 2, 7, 64 * 1024])
        await expect(Self.intMaxChunk, code: "limitExceeded", cap: ModNetBroker.hardCap)
        await expect(Self.intMaxChunk, code: "limitExceeded", cap: Int.max)
        await expect(Self.chunked + "7fffffffffffffff\r\n", code: "network", cap: Int.max)
        await expect(Self.chunked + "1\r\na\r\nffffffffffffffff\r\n", code: "limitExceeded")
        await expect(Self.chunked + "1\r\na\r\n8000000000000000\r\n", code: "limitExceeded")
        await expect(Self.chunked + "1\r\na\r\n10000000000000000\r\n", code: "limitExceeded")
        await expect(Self.chunked + "1\r\na\r\n" + String(repeating: "f", count: 1000) + "\r\n", code: "limitExceeded")
        await expect(Self.chunked + "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n", body: "helloworld", cap: 10)
        await expect(Self.chunked + "5\r\nhello\r\n6\r\nworld!\r\n0\r\n\r\n", code: "limitExceeded", cap: 10)
        await expect(Self.chunked + "0\r\n\r\n", body: "", cap: 0)
    }

    func testChunkFramingIsValidated() async {
        await expect(Self.chunked + "5\r\nhello\r\n0\r\n\r\n", body: "hello")
        await expect(Self.chunked + "5;ext=1;q=\"x y\"\r\nhello\r\n0;last\r\n\r\n", body: "hello")
        await expect(Self.chunked + "5 \t;ext\r\nhello\r\n0\r\n\r\n", body: "hello")
        await expect(Self.chunked + "000000000000000000005\r\nhello\r\n0\r\n\r\n", body: "hello")
        await expect(Self.chunked + "A\r\n0123456789\r\na\r\nabcdefghij\r\n0\r\n\r\n", body: "0123456789abcdefghij")
        for bad in ["-0\r\n\r\n", "+5\r\nhello\r\n0\r\n\r\n", "0x5\r\nhello\r\n0\r\n\r\n", "\r\nhello\r\n0\r\n\r\n", ";ext\r\nhello\r\n0\r\n\r\n",
                    "5g\r\nhello\r\n0\r\n\r\n", "5 5\r\nhello\r\n0\r\n\r\n", "5\u{0}\r\nhello\r\n0\r\n\r\n", "5;a\u{7f}\r\nhello\r\n0\r\n\r\n", "5;a\u{1}b\r\nhello\r\n0\r\n\r\n",
                    "5\r\nhelloXY0\r\n\r\n", "5\r\nhello\n0\r\n\r\n", "5\r\nhello\r0\r\n\r\n", "5\nhello\r\n0\r\n\r\n",
                    String(repeating: "0", count: 1100) + "5\r\nhello\r\n0\r\n\r\n", "5;" + String(repeating: "x", count: 2000) + "\r\nhello\r\n0\r\n\r\n"] {
            await expect(Self.chunked + bad, code: "network")
        }
        for truncated in ["5\r\nhel", "5\r\nhello", "5\r\nhello\r", "5\r\nhello\r\n", "5\r\nhello\r\n0\r\n", "5\r\nhello\r\n0\r\nX-T: 1\r\n", "5"] {
            await expect(Self.chunked + truncated, code: "network")
        }
    }

    func testTrailersAreParsedAndBounded() async {
        await expect(Self.chunked + "3\r\nabc\r\n0\r\nX-Sum: 1\r\nX-Other: two\r\n\r\n", body: "abc")
        let many = String(repeating: "X-T: " + String(repeating: "a", count: 40) + "\r\n", count: 2000)
        await expect(Self.chunked + "0\r\n" + many + "\r\n", code: "limitExceeded")
        await expect(Self.chunked + "0\r\nX: " + String(repeating: "a", count: 70_000) + "\r\n\r\n", code: "limitExceeded")
        await expect(Self.chunked + "0\r\nbad trailer\r\n\r\n", code: "network")
        await expect(Self.chunked + "0\r\n folded\r\n\r\n", code: "network")
    }

    func testContentLengthIsValidated() async {
        func cl(_ v: String, _ body: String = "hello") -> String { "HTTP/1.1 200 OK\r\nContent-Length: \(v)\r\n\r\n\(body)" }
        await expect(cl("5"), body: "hello")
        await expect(cl("5, 5"), body: "hello")
        await expect("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello", body: "hello")
        await expect(cl("0", ""), body: "")
        for bad in ["5, 6", "+5", "-1", "5x", "", " ", "0x5", "5,", "1e3"] {
            await expect(cl(bad), code: "network")
        }
        await expect("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!", code: "network")
        await expect(cl("99999999999999999999999"), code: "limitExceeded")
        await expect(cl("9223372036854775807"), code: "limitExceeded")
        await expect(cl("9223372036854775807"), code: "network", cap: Int.max)
        await expect(cl("2000"), code: "limitExceeded")
        await expect(cl("10"), code: "network")
    }

    func testTransferCodingsOtherThanChunkedAreRefused() async {
        await expect("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n", body: "ok")
        await expect("HTTP/1.1 200 OK\r\nContent-Length: 50\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n", body: "ok")
        for te in ["gzip, chunked", "chunked, gzip", "identity", "gzip", "chunked\r\nTransfer-Encoding: chunked"] {
            await expect("HTTP/1.1 200 OK\r\nTransfer-Encoding: \(te)\r\n\r\n2\r\nok\r\n0\r\n\r\n", code: "network")
        }
    }

    func testHeadFramingIsBounded() async {
        await expect("HTTP/1.1 200\r\nContent-Length: 2\r\n\r\nok", body: "ok")
        await expect("HTTP/1.0 200 Fine Thanks\r\nX-Empty:\r\nContent-Length: 2\r\n\r\nok", body: "ok")
        await expect("HTTP/1.1 200 OK\r\nX-Big: " + String(repeating: "a", count: 70_000) + "\r\n\r\n", code: "limitExceeded")
        await expect("HTTP/1.1 200 OK\r\n" + String(repeating: "X-H: " + String(repeating: "b", count: 40) + "\r\n", count: 2000) + "\r\n", code: "limitExceeded")
        await expect("HTTP/1.1 200 " + String(repeating: "r", count: 70_000) + "\r\n\r\n", code: "limitExceeded")
        for bad in ["HTTP/1.1 200 OK\r\n folded: x\r\n\r\n", "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n", "HTTP/1.1 200 OK\r\nNoColon\r\n\r\n",
                    "HTTP/1.1 200 OK\r\n: empty\r\n\r\n", "HTTP/1.1 200 OK\r\nX-Nul: a\u{0}b\r\n\r\n", "HTTP/1.1 200 OK\r\nX-Cr: a\rb\r\n\r\n",
                    "HTTP/1.1 2000 OK\r\n\r\n", "HTTP/1.1 +20 OK\r\n\r\n", "HTTP/2 200 OK\r\n\r\n", "HTTP/1.1 OK\r\n\r\n", "HTTP/1.1 099 Low\r\n\r\n",
                    "ICY 200 OK\r\n\r\n", "\r\n\r\n", "HTTP/1.x 200 OK\r\n\r\n", "HTTP/1.1 200 O\u{1}K\r\n\r\n", "HTTP/1.1 101 Switching\r\n\r\n"] {
            await expect(bad, code: "network")
        }
        await expect("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n", code: "network")
        let interim = "HTTP/1.1 100 Continue\r\n\r\n"
        await expect(interim + interim + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", body: "ok")
        await expect(String(repeating: interim, count: 17) + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", code: "network")
        if case .success(let head) = await parse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", method: "HEAD") { XCTAssertEqual(head.body.count, 0) } else { XCTFail("HEAD") }
        if case .success(let empty) = await parse("HTTP/1.1 204 No Content\r\nContent-Length: 7\r\n\r\n") { XCTAssertEqual(empty.status, 204) } else { XCTFail("204") }
    }

    func testUnframedBodyRespectsCap() async {
        let head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"
        await expect(head + String(repeating: "z", count: 1024), body: String(repeating: "z", count: 1024), segments: [1, 100, 64 * 1024])
        await expect(head + String(repeating: "z", count: 1025), code: "limitExceeded", segments: [1, 100, 64 * 1024])
        await expect(head, body: "")
    }

    func testManySmallChunksStayLinear() async {
        let body = String(repeating: "1\r\nq\r\n", count: 200_000) + "0\r\n\r\n"
        let start = Date()
        switch await parse(Self.chunked + body, cap: 200_000) {
        case .success(let r): XCTAssertEqual(r.body.count, 200_000)
        case .failure(let e): XCTFail("\(e.code) \(e.message)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func broker() -> ModNetBroker { ModNetBroker(resolver: FlippingResolver([:])) }

    func loopbackMod(port: UInt16) throws -> ActiveMod {
        let grants = [ModPermission(kind: .net, reason: "x", endpoints: [NetEndpoint(scheme: .http, host: "127.0.0.1", port: Int(port), methods: [.GET])], allowPrivate: true, maxBytes: 1024)]
        let m = ModManifest(id: "alice.http", name: "n", author: "alice", version: SemVer(1, 0, 0), api: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), app: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), runtime: .ts, entry: "x.ts", license: "MIT", permissions: grants)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return ActiveMod(manifest: m, generation: 1, snapshot: dir, mode: .live, grants: grants, logs: ModLogBuffer(file: nil), storageURL: dir.appendingPathComponent("http-\(UUID().uuidString).json"), settings: nil)
    }

    func testMalformedFramingThroughBrokerFetchIsRefused() async throws {
        let replies: [String: String] = [
            "intmax": Self.intMaxChunk,
            "minuszero": Self.chunked + "-0\r\n\r\n",
            "nocrlf": Self.chunked + "5\r\nhelloXY0\r\n\r\n",
            "plus": Self.chunked + "+5\r\nhello\r\n0\r\n\r\n",
            "gzip": "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
            "conflict": "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nok!",
            "fold": "HTTP/1.1 200 OK\r\n Transfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\nok",
            "ok": Self.chunked + "2\r\nok\r\n0\r\n\r\n",
        ]
        let server = try LoopbackHTTPServer { req in
            let path = req.split(separator: " ").dropFirst().first.map { String($0.dropFirst()) } ?? ""
            return replies[path].map { Data($0.utf8) }
        }
        defer { server.stop() }
        let net = broker()
        let m = try loopbackMod(port: server.port)
        let expected: [String: String] = ["intmax": "limitExceeded", "minuszero": "network", "nocrlf": "network", "plus": "network", "gzip": "network", "conflict": "network", "fold": "network"]
        for (path, code) in expected.sorted(by: { $0.key < $1.key }) {
            do {
                let v = try await net.fetch(m, .object(["url": .string("http://127.0.0.1:\(server.port)/\(path)"), "timeoutMs": .int(3000)]), credentials: nil)
                XCTFail("\(path) accepted: \(v)")
            } catch let e as ModCallError {
                XCTAssertEqual(e.code, code, "\(path): \(e.message)")
            }
        }
        let ok = try await net.fetch(m, .object(["url": .string("http://127.0.0.1:\(server.port)/ok"), "timeoutMs": .int(3000)]), credentials: nil)
        XCTAssertEqual(ok["body"]?.stringValue, "ok")
    }
}

class FakeFileOperations: ModFileOperationsPerforming, @unchecked Sendable {
    let lock = NSLock()
    var states: [String: ModOperationProgress] = [:]
    var started = 0
    var failNext = false

    var startedCount: Int { lock.withLock { started } }

    func start() throws -> String {
        try lock.withLock {
            if failNext { failNext = false; throw ModCallError("denied", "refused") }
            started += 1
            let id = "op_\(started)"
            states[id] = ModOperationProgress(state: .running, completed: 0, total: 1)
            return id
        }
    }

    func state(_ id: String) -> ModOperationState? { lock.withLock { states[id]?.state } }

    func finish(_ id: String, _ state: ModOperationState) {
        let p = ModOperationProgress(state: state, completed: state == .done ? 1 : 0, total: 1)
        lock.withLock { states[id] = p }
        finished(id, p)
    }

    func finished(_ id: String, _ progress: ModOperationProgress) {}

    func copy(_ items: [URL], to destination: URL, conflict: ModConflictPolicy, modId: String) async throws -> String { try start() }
    func move(_ items: [URL], to destination: URL, conflict: ModConflictPolicy, modId: String) async throws -> String { try start() }
    func trash(_ items: [URL], modId: String) async throws -> String { try start() }
    func rename(_ item: URL, to newName: String, modId: String) async throws -> String { try start() }
    func status(_ operationId: String) async -> ModOperationProgress? { lock.withLock { states[operationId] } }

    func cancel(_ operationId: String) async -> Bool {
        let ok: Bool = lock.withLock {
            guard let s = states[operationId], !ModOperationLedger.isTerminal(s.state) else { return false }
            states[operationId] = ModOperationProgress(state: .cancelled, completed: 0, total: 1)
            return true
        }
        if ok { finished(operationId, ModOperationProgress(state: .cancelled, completed: 0, total: 1)) }
        return ok
    }
}

final class ObservingFakeFileOperations: FakeFileOperations, ModFileOperationsObserving, @unchecked Sendable {
    var observers: [String: [@Sendable (ModOperationProgress) -> Void]] = [:]

    func observeCompletion(_ operationId: String, _ handler: @escaping @Sendable (ModOperationProgress) -> Void) async {
        let done: ModOperationProgress? = lock.withLock {
            if let s = states[operationId], ModOperationLedger.isTerminal(s.state) { return s }
            observers[operationId, default: []].append(handler)
            return nil
        }
        if let done { handler(done) }
    }

    override func finished(_ id: String, _ progress: ModOperationProgress) {
        let handlers = lock.withLock { observers.removeValue(forKey: id) ?? [] }
        for h in handlers { h(progress) }
    }
}

final class StallingHook: FileOperationHook, @unchecked Sendable {
    let id = "test.stall"
    let priority = 0
    var timeout: TimeInterval? { 0.05 }
    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return .allow
    }
}

final class BehaviorRegressionOperationLedgerTests: XCTestCase {
    static let running = ModOperationProgress(state: .running, completed: 0, total: 1)

    func activeMod(_ id: String = "alice.ops") throws -> ActiveMod {
        let m = ModManifest(id: id, name: "o", author: "alice", version: SemVer(1, 0, 0), api: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), app: try XCTUnwrap(SemVerRange.parse(">=1.0.0 <2.0.0")), runtime: .ts, entry: "x.ts", license: "MIT", permissions: [])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return ActiveMod(manifest: m, generation: 1, snapshot: dir, mode: .live, grants: [], logs: ModLogBuffer(file: nil), storageURL: dir.appendingPathComponent("ops-\(UUID().uuidString).json"), settings: nil)
    }

    func broker(_ ops: ModFileOperationsPerforming, _ ledger: ModOperationLedger) -> ModBroker {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("modhost-r2-\(UUID().uuidString)", isDirectory: true)
        let access = ScopedAccessAuthorizer(defaults: UserDefaults(suiteName: "modhost.r2.\(UUID().uuidString)")!, coder: PlainBookmarkCoder())
        return ModBroker(deps: ModBrokerDependencies(catalog: .v1, grants: ModGrantStore(paths: ModHostPaths(root: root), scopedAccess: access), services: TestServices(),
                                                     fileOperations: ops, fileSearch: nil, credentials: nil, net: ModNetBroker(resolver: FakeResolver()), ledger: ledger))
    }

    func start(_ b: ModBroker, _ mod: ActiveMod, _ ops: ModFileOperationsPerforming) async -> Result<String, ModCallError> {
        do {
            let v = try await b.trackExternal(mod, ops) { try await ops.copy([], to: URL(fileURLWithPath: "/tmp"), conflict: .fail, modId: mod.id) }
            return .success(v["operationId"]?.stringValue ?? "")
        } catch let e as ModCallError {
            return .failure(e)
        } catch {
            return .failure(ModCallError("other", "\(error)"))
        }
    }

    func testRunningExternalEntriesSurviveTrimmingAndStayCancellable() async throws {
        let ops = FakeFileOperations()
        let ledger = ModOperationLedger(terminalLimit: 1, totalLimit: 2, expiredLimit: 16)
        var ids = [String]()
        for _ in 0..<3 {
            let id = try ops.start()
            ledger.register(id, owner: "m", external: true, progress: Self.running)
            ids.append(id)
        }
        XCTAssertEqual(ledger.count, 3)
        for id in ids {
            let lookup = await ledger.lookup(id, owner: "m", external: ops)
            XCTAssertEqual(lookup, .progress(Self.running), id)
        }
        let cancelled = await ledger.cancel(ids[0], owner: "m", external: ops)
        XCTAssertEqual(cancelled, true)
        XCTAssertEqual(ops.state(ids[0]), .cancelled)
        let after = await ledger.lookup(ids[0], owner: "m", external: nil)
        XCTAssertEqual(after, .expired)
        for i in 0..<20 {
            ledger.register("done\(i)", owner: "m", external: false, progress: ModOperationProgress(state: .done, completed: 1, total: 1))
        }
        for id in ids.dropFirst() {
            let lookup = await ledger.lookup(id, owner: "m", external: ops)
            XCTAssertEqual(lookup, .progress(Self.running), id)
            let ok = await ledger.cancel(id, owner: "m", external: ops)
            XCTAssertEqual(ok, true, id)
        }
    }

    func testFinishedExternalsAreEvictedOnceCompletionIsReported() async throws {
        let ops = ObservingFakeFileOperations()
        let ledger = ModOperationLedger(terminalLimit: 2, totalLimit: 4, expiredLimit: 64, activeLimit: 8, ownerActiveLimit: 8)
        let b = broker(ops, ledger)
        let mod = try activeMod()
        var ids = [String]()
        for _ in 0..<6 { ids.append(try await start(b, mod, ops).get()) }
        XCTAssertEqual(ledger.count, 6)
        XCTAssertEqual(ledger.activeCount, 6)
        for id in ids.prefix(4) { ops.finish(id, .done) }
        XCTAssertEqual(ledger.activeCount, 2)
        XCTAssertEqual(ledger.count, 4)
        for id in ids.prefix(2) {
            let lookup = await ledger.lookup(id, owner: mod.id, external: nil)
            XCTAssertEqual(lookup, .expired, id)
        }
        for id in ids[2..<4] {
            let s = await ledger.status(id, owner: mod.id, external: nil)
            XCTAssertEqual(s?.state, .done, id)
        }
        for id in ids.suffix(2) {
            let s = await ledger.status(id, owner: mod.id, external: ops)
            XCTAssertEqual(s?.state, .running, id)
        }
        let late = try await start(b, mod, ops).get()
        ops.finish(late, .failed)
        let s = await ledger.status(late, owner: mod.id, external: nil)
        XCTAssertEqual(s?.state, .failed)
    }

    func testRegistrationBeyondTheActiveLimitIsRejectedBeforeStarting() async throws {
        let ops = FakeFileOperations()
        let ledger = ModOperationLedger(terminalLimit: 4, totalLimit: 8, expiredLimit: 64, activeLimit: 3, ownerActiveLimit: 2)
        let b = broker(ops, ledger)
        let alice = try activeMod("alice.ops"), bob = try activeMod("bob.ops")
        let a1 = try await start(b, alice, ops).get()
        _ = try await start(b, alice, ops).get()
        let a3 = await start(b, alice, ops)
        XCTAssertEqual(a3.failure?.code, "limitExceeded")
        XCTAssertEqual(ops.startedCount, 2)
        _ = try await start(b, bob, ops).get()
        let b2 = await start(b, bob, ops)
        XCTAssertEqual(b2.failure?.code, "limitExceeded")
        XCTAssertEqual(ops.startedCount, 3)
        XCTAssertEqual(ledger.activeCount, 3)
        ops.finish(a1, .done)
        let a4 = try await start(b, alice, ops).get()
        XCTAssertEqual(ops.startedCount, 4)
        let s = await ledger.status(a4, owner: alice.id, external: nil)
        XCTAssertEqual(s?.state, .queued)
        let first = await ledger.status(a1, owner: alice.id, external: nil)
        XCTAssertEqual(first?.state, .done)
        ops.failNext = true
        let failed = await start(b, bob, ops)
        XCTAssertEqual(failed.failure?.code, "limitExceeded")
        let handle = ModProcessHandle()
        XCTAssertThrowsError(try ledger.registerActive("arc_x", owner: bob.id, external: false, progress: Self.running, handle: handle)) {
            XCTAssertEqual(($0 as? ModCallError)?.code, "limitExceeded")
        }
        XCTAssertEqual(ledger.count, 4)
    }

    func testFailedStartReleasesItsReservation() async throws {
        let ops = FakeFileOperations()
        let ledger = ModOperationLedger(terminalLimit: 4, totalLimit: 8, expiredLimit: 64, activeLimit: 1, ownerActiveLimit: 1)
        let b = broker(ops, ledger)
        let mod = try activeMod()
        for _ in 0..<5 {
            ops.failNext = true
            let r = await start(b, mod, ops)
            XCTAssertEqual(r.failure?.code, "denied")
        }
        XCTAssertEqual(ledger.count, 0)
        let id = try await start(b, mod, ops).get()
        XCTAssertFalse(id.isEmpty)
        ledger.cancelAll(owner: mod.id)
        let again = try await start(b, mod, ops).get()
        XCTAssertFalse(again.isEmpty)
    }

    @MainActor
    func testGenuinelyRunningFileOperationsSurviveTrimmingAndCancelThroughTheLedger() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("modhost-r2-ops-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let src = base.appendingPathComponent("src", isDirectory: true), dest = base.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = try (0..<4).map { i -> URL in
            let u = src.appendingPathComponent("f\(i).txt")
            try Data("file \(i)".utf8).write(to: u)
            return u
        }
        let queue = FileOperationQueue()
        queue.announcesStateChanges = false
        queue.undoManager = nil
        let hooks = FileOperationHookRegistry()
        hooks.register(StallingHook(), owner: "test", timeout: 0.05)
        queue.hooks = hooks
        let adapter = FileOperationQueueAdapter(queue: queue)
        let ledger = ModOperationLedger(terminalLimit: 1, totalLimit: 2, expiredLimit: 16, activeLimit: 3, ownerActiveLimit: 3)
        let b = broker(adapter, ledger)
        let mod = try activeMod()
        var ids = [String]()
        for f in files.prefix(3) {
            let v = try await b.trackExternal(mod, adapter) { try await adapter.copy([f], to: dest, conflict: .fail, modId: mod.id) }
            ids.append(try XCTUnwrap(v["operationId"]?.stringValue))
        }
        XCTAssertEqual(ledger.count, 3)
        let fourth = await start(b, mod, adapter)
        XCTAssertEqual(fourth.failure?.code, "limitExceeded")
        XCTAssertEqual(queue.operations.count, 3)
        let waiting = await eventually {
            if case .awaitingDecision = queue.operations.first?.state { return true }
            return false
        }
        XCTAssertTrue(waiting)
        for id in ids {
            let lookup = await ledger.lookup(id, owner: mod.id, external: adapter)
            switch lookup {
            case .progress(let p): XCTAssertTrue(p.state == .running || p.state == .queued, "\(id) \(p.state)")
            default: XCTFail("\(id) \(lookup)")
            }
        }
        let cancelled = await ledger.cancel(ids[0], owner: mod.id, external: adapter)
        XCTAssertEqual(cancelled, true)
        let pushed = await eventually { ledger.activeCount == 2 }
        XCTAssertTrue(pushed)
        let gone = await ledger.lookup(ids[0], owner: mod.id, external: nil)
        XCTAssertEqual(gone, .expired)
        for id in ids.dropFirst() {
            let ok = await ledger.cancel(id, owner: mod.id, external: adapter)
            XCTAssertEqual(ok, true, id)
        }
        let settled = await eventually { ledger.activeCount == 0 }
        XCTAssertTrue(settled)
        XCTAssertEqual(ledger.count, 1)
        for id in ids.prefix(2) {
            let lookup = await ledger.lookup(id, owner: mod.id, external: adapter)
            XCTAssertEqual(lookup, .expired, id)
        }
        let last = await ledger.status(ids[2], owner: mod.id, external: nil)
        XCTAssertEqual(last?.state, .cancelled)
        let status = await adapter.status(ids[2])
        XCTAssertEqual(status?.state, .cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [])
        let next = try await b.trackExternal(mod, adapter) { try await adapter.copy([files[3]], to: dest, conflict: .fail, modId: mod.id) }
        XCTAssertNotNil(next["operationId"]?.stringValue)
        queue.cancelAll()
    }
}

private extension Result where Failure == ModCallError {
    var failure: ModCallError? { if case .failure(let e) = self { return e }; return nil }
}
