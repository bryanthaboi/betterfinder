import Foundation
import ModHostProtocol
import Network
import Security

struct ModHTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [(name: String, value: String)]
    var body: Data?
}

package struct ModHTTPResponse: Sendable {
    package var status: Int
    package var headers: [(name: String, value: String)]
    package var body: Data

    package func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name.lowercased() == lower }?.value
    }

    package var mergedHeaders: [(name: String, value: String)] {
        var order = [String]()
        var merged = [String: (name: String, value: String)]()
        for h in headers {
            let key = h.name.lowercased()
            if let existing = merged[key] {
                merged[key] = (existing.name, existing.value + ", " + h.value)
            } else {
                merged[key] = h
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }
}

struct ModHTTPTarget: Sendable {
    var host: String
    var port: UInt16
    var tls: Bool
    var addresses: [String]?
}

final class ModHTTPConnection: @unchecked Sendable {
    typealias Dialer = @Sendable (_ host: String, _ port: UInt16) -> (host: String, port: UInt16)

    static let headerLimit = 64 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "betterfinder.modnet.connection")
    private let lock = NSLock()
    private var timedOut = false
    private let dialed: (host: String, port: UInt16)
    private let pinned: Bool

    private init(connection: NWConnection, dialed: (host: String, port: UInt16), pinned: Bool) {
        self.connection = connection
        self.dialed = dialed
        self.pinned = pinned
    }

    static func open(_ target: ModHTTPTarget, deadline: Date, dial: Dialer) async throws -> ModHTTPConnection {
        let candidates = target.addresses ?? [target.host]
        guard !candidates.isEmpty else { throw ModCallError("network", "cannot resolve \(target.host)") }
        var last: Error = ModCallError("network", "could not connect to \(target.host)")
        for address in candidates {
            guard Date() < deadline else { throw ModCallError.timeout("request timed out") }
            let endpoint = dial(address, target.port)
            let c = ModHTTPConnection(connection: NWConnection(to: .hostPort(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port) ?? .http), using: parameters(target)),
                                      dialed: endpoint, pinned: target.addresses != nil)
            do {
                try await c.start(deadline: deadline)
                return c
            } catch let e as ModCallError where e.code == "denied" || e.code == "timeout" {
                c.cancel()
                throw e
            } catch {
                c.cancel()
                last = error
            }
        }
        throw last
    }

    private static func parameters(_ target: ModHTTPTarget) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let params: NWParameters
        if target.tls {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, target.host)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.preferNoProxies = true
        return params
    }

    private func start(deadline: Date) async throws {
        let queue = queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ModOnce()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self, !self.endpointMatches() {
                        once.run { cont.resume(throwing: ModCallError.denied("connection reached an unexpected address")) }
                    } else {
                        once.run { cont.resume() }
                    }
                case .failed(let e):
                    once.run { cont.resume(throwing: ModCallError("network", e.localizedDescription)) }
                case .waiting(let e):
                    once.run { cont.resume(throwing: ModCallError("network", e.localizedDescription)) }
                case .cancelled:
                    once.run { cont.resume(throwing: ModCallError("network", "connection cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
                self?.markTimedOut()
                once.run { cont.resume(throwing: ModCallError.timeout("request timed out")) }
            }
        }
    }

    private func endpointMatches() -> Bool {
        guard let remote = connection.currentPath?.remoteEndpoint else { return !pinned }
        guard case .hostPort(let host, let port) = remote else { return !pinned }
        guard port.rawValue == dialed.port else { return false }
        guard pinned else { return true }
        return Self.sameAddress(host, dialed.host)
    }

    static func sameAddress(_ host: NWEndpoint.Host, _ text: String) -> Bool {
        let bare = text.split(separator: "%").first.map(String.init) ?? text
        switch host {
        case .ipv4(let a): return IPv4Address(bare)?.rawValue == a.rawValue
        case .ipv6(let a):
            if let b = IPv6Address(bare) { return b.rawValue == a.rawValue }
            if let v4 = IPv4Address(bare), let mapped = a.asIPv4 { return v4.rawValue == mapped.rawValue }
            return false
        case .name(let n, _): return n.lowercased() == bare.lowercased()
        @unknown default: return false
        }
    }

    private func markTimedOut() {
        lock.withLock { timedOut = true }
        connection.cancel()
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private var isTimedOut: Bool { lock.withLock { timedOut } }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    cont.resume(throwing: self?.isTimedOut == true ? ModCallError.timeout("request timed out") : ModCallError("network", error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receive() async throws -> (data: Data?, complete: Bool) {
        let chunk: (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                if let error, data?.isEmpty ?? true {
                    cont.resume(throwing: self?.isTimedOut == true ? ModCallError.timeout("request timed out") : ModCallError("network", error.localizedDescription))
                } else {
                    cont.resume(returning: (data, complete))
                }
            }
        }
        if isTimedOut { throw ModCallError.timeout("request timed out") }
        return chunk
    }

    func readResponse(method: String, cap: Int) async throws -> ModHTTPResponse {
        try await ModHTTPResponseReader(source: { [self] in try await self.receive() }).readResponse(method: method, cap: cap)
    }
}

package final class ModHTTPResponseReader: @unchecked Sendable {
    package typealias Source = () async throws -> (data: Data?, complete: Bool)

    package static let headerLimit = ModHTTPConnection.headerLimit
    package static let chunkLineLimit = 1024
    package static let interimLimit = 16

    private let source: Source
    private var bytes: [UInt8] = []
    private var start = 0
    private var eof = false

    package init(source: @escaping Source) {
        self.source = source
    }

    package convenience init(bytes data: Data, segment: Int = 64 * 1024) {
        let parts = ModHTTPSegments(data, segment: segment)
        self.init(source: { parts.next() })
    }

    private var available: Int { bytes.count - start }

    private static func closed() -> ModCallError { ModCallError("network", "connection closed before the response was complete") }
    private static func malformedChunk() -> ModCallError { ModCallError("network", "malformed chunked response") }
    private static func tooLarge(_ cap: Int) -> ModCallError { ModCallError.limit("response exceeds \(cap) bytes") }

    private func fill() async throws {
        guard !eof else { throw Self.closed() }
        if start > 0 {
            bytes.removeSubrange(0..<start)
            start = 0
        }
        let next = try await source()
        if let d = next.data, !d.isEmpty { bytes.append(contentsOf: d) }
        if next.complete { eof = true }
    }

    private func readLine(limit: Int, exceeded: @autoclosure () -> ModCallError) async throws -> ArraySlice<UInt8> {
        var scanned = 0
        while true {
            var i = start + scanned
            while i + 1 < bytes.count {
                if bytes[i] == 13 && bytes[i + 1] == 10 {
                    guard i - start <= limit else { throw exceeded() }
                    let line = bytes[start..<i]
                    start = i + 2
                    return line
                }
                i += 1
            }
            scanned = max(0, available - 1)
            guard scanned <= limit else { throw exceeded() }
            try await fill()
        }
    }

    private func expectCRLF() async throws {
        while available < 2 { try await fill() }
        guard bytes[start] == 13, bytes[start + 1] == 10 else { throw Self.malformedChunk() }
        start += 2
    }

    private func read(_ count: Int, into body: inout Data) async throws {
        var remaining = count
        while remaining > 0 {
            if available == 0 { try await fill(); continue }
            let take = min(remaining, available)
            body.append(contentsOf: bytes[start..<(start + take)])
            start += take
            remaining -= take
        }
    }

    package func readResponse(method: String, cap: Int) async throws -> ModHTTPResponse {
        guard cap >= 0 else { throw Self.tooLarge(cap) }
        var head = try await readHead()
        var interim = 0
        while (100...199).contains(head.status) && head.status != 101 {
            interim += 1
            guard interim <= Self.interimLimit else { throw ModCallError("network", "too many interim responses") }
            head = try await readHead()
        }
        if head.status == 101 { throw ModCallError("network", "protocol upgrades are not supported") }
        if method == "HEAD" || head.status == 204 || head.status == 304 { return ModHTTPResponse(status: head.status, headers: head.headers, body: Data()) }
        let body: Data
        if try Self.isChunked(head.headers) {
            body = try await readChunked(cap: cap)
        } else if let length = try Self.contentLength(head.headers, cap: cap) {
            guard length <= cap else { throw Self.tooLarge(cap) }
            var out = Data()
            try await read(length, into: &out)
            body = out
        } else {
            while !eof {
                guard available <= cap else { throw Self.tooLarge(cap) }
                try await fill()
            }
            guard available <= cap else { throw Self.tooLarge(cap) }
            body = Data(bytes[start...])
            start = bytes.count
        }
        return ModHTTPResponse(status: head.status, headers: head.headers, body: body)
    }

    private func readChunked(cap: Int) async throws -> Data {
        var body = Data()
        while true {
            let line = try await readLine(limit: Self.chunkLineLimit, exceeded: Self.malformedChunk())
            guard let size = try Self.chunkSize(line) else { throw Self.tooLarge(cap) }
            if size == 0 { break }
            guard body.count <= cap, size <= cap - body.count else { throw Self.tooLarge(cap) }
            try await read(size, into: &body)
            try await expectCRLF()
        }
        var trailers = 0
        while true {
            let line = try await readLine(limit: Self.headerLimit - trailers, exceeded: ModCallError.limit("response trailers exceed \(Self.headerLimit) bytes"))
            if line.isEmpty { return body }
            trailers += line.count + 2
            guard trailers <= Self.headerLimit else { throw ModCallError.limit("response trailers exceed \(Self.headerLimit) bytes") }
            guard Self.validFieldLine(line) else { throw Self.malformedChunk() }
        }
    }

    static func chunkSize(_ line: ArraySlice<UInt8>) throws -> Int? {
        let semicolon = line.firstIndex(of: UInt8(ascii: ";")) ?? line.endIndex
        var lo = line.startIndex, hi = semicolon
        while lo < hi, line[lo] == 0x20 || line[lo] == 0x09 { lo += 1 }
        while hi > lo, line[hi - 1] == 0x20 || line[hi - 1] == 0x09 { hi -= 1 }
        guard lo < hi else { throw malformedChunk() }
        for b in line[semicolon...] where (b < 0x20 && b != 0x09) || b == 0x7f { throw malformedChunk() }
        var value = 0
        var overflow = false
        for b in line[lo..<hi] {
            let digit: Int
            switch b {
            case 0x30...0x39: digit = Int(b - 0x30)
            case 0x41...0x46: digit = Int(b - 0x41 + 10)
            case 0x61...0x66: digit = Int(b - 0x61 + 10)
            default: throw malformedChunk()
            }
            guard !overflow else { continue }
            let (shifted, o1) = value.multipliedReportingOverflow(by: 16)
            let (sum, o2) = shifted.addingReportingOverflow(digit)
            if o1 || o2 { overflow = true } else { value = sum }
        }
        return overflow ? nil : value
    }

    static func validFieldLine(_ line: ArraySlice<UInt8>) -> Bool {
        guard let first = line.first, first != 0x20, first != 0x09, let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > line.startIndex else { return false }
        guard line[line.startIndex..<colon].allSatisfy({ $0 < 0x80 && ModHTTPWire.tokenCharacters.contains(Unicode.Scalar($0)) }) else { return false }
        return !line[line.index(after: colon)...].contains { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7f }
    }

    static func isChunked(_ headers: [(name: String, value: String)]) throws -> Bool {
        var codings = [String]()
        for h in headers where h.name.lowercased() == "transfer-encoding" {
            codings += h.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        guard !codings.isEmpty else { return false }
        guard codings == ["chunked"] else { throw ModCallError("network", "unsupported transfer coding \(codings.joined(separator: ", "))") }
        return true
    }

    static func contentLength(_ headers: [(name: String, value: String)], cap: Int) throws -> Int? {
        var length: Int?
        for h in headers where h.name.lowercased() == "content-length" {
            for part in h.value.split(separator: ",", omittingEmptySubsequences: false) {
                let text = part.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { throw ModCallError("network", "malformed content length") }
                guard let n = Int(text) else { throw tooLarge(cap) }
                if let length, length != n { throw ModCallError("network", "conflicting content lengths") }
                length = n
            }
        }
        return length
    }

    private func readHead() async throws -> (status: Int, headers: [(name: String, value: String)]) {
        let exceeded = ModCallError.limit("response headers exceed \(Self.headerLimit) bytes")
        let statusLine = try await readLine(limit: Self.headerLimit, exceeded: exceeded)
        var total = statusLine.count + 2
        guard total <= Self.headerLimit else { throw exceeded }
        guard let status = Self.status(statusLine) else { throw ModCallError("network", "malformed HTTP response") }
        var headers = [(name: String, value: String)]()
        while true {
            let line = try await readLine(limit: Self.headerLimit - total, exceeded: exceeded)
            total += line.count + 2
            guard total <= Self.headerLimit else { throw exceeded }
            if line.isEmpty { return (status, headers) }
            guard Self.validFieldLine(line), let colon = line.firstIndex(of: UInt8(ascii: ":")) else { throw ModCallError("network", "malformed HTTP response header") }
            let name = String(decoding: line[line.startIndex..<colon], as: UTF8.self)
            let value = String(decoding: line[line.index(after: colon)...], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append((name, value))
        }
    }

    static func status(_ line: ArraySlice<UInt8>) -> Int? {
        let text = String(decoding: line, as: UTF8.self)
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].count == 8, parts[0].hasPrefix("HTTP/1."), parts[0].last?.isASCII == true, parts[0].last?.isNumber == true else { return nil }
        let code = parts[1].utf8
        guard code.count == 3, code.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let status = Int(parts[1]), (100...999).contains(status) else { return nil }
        guard !line.contains(where: { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7f }) else { return nil }
        return status
    }
}

final class ModHTTPSegments: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let segment: Int
    private var offset = 0

    init(_ data: Data, segment: Int) {
        self.data = data
        self.segment = max(1, segment)
    }

    func next() -> (data: Data?, complete: Bool) {
        lock.withLock {
            let base = data.startIndex + offset
            let take = min(segment, data.count - offset)
            offset += take
            return (data.subdata(in: base..<(base + take)), offset >= data.count)
        }
    }
}

final class ModOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if first { body() }
    }
}

enum ModHTTPWire {
    static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy(tokenCharacters.contains)
    }

    static func hostHeader(host: String, port: UInt16, tls: Bool) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        let defaultPort: UInt16 = tls ? 443 : 80
        return port == defaultPort ? h : "\(h):\(port)"
    }

    static func target(of url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "/" }
        var path = comps.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let q = comps.percentEncodedQuery { path += "?" + q }
        return path
    }

    static func encode(_ r: ModHTTPRequest, host: String, port: UInt16, tls: Bool) -> Data {
        var lines = ["\(r.method) \(target(of: r.url)) HTTP/1.1", "Host: \(hostHeader(host: host, port: port, tls: tls))"]
        var hasUserAgent = false
        var hasAccept = false
        for h in r.headers {
            let lower = h.name.lowercased()
            if lower == "accept-encoding" { continue }
            if lower == "user-agent" { hasUserAgent = true }
            if lower == "accept" { hasAccept = true }
            lines.append("\(h.name): \(h.value)")
        }
        if !hasUserAgent { lines.append("User-Agent: betterfinder-mod") }
        if !hasAccept { lines.append("Accept: */*") }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        if let body = r.body {
            lines.append("Content-Length: \(body.count)")
        } else if ["POST", "PUT", "PATCH"].contains(r.method) {
            lines.append("Content-Length: 0")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body = r.body { data.append(body) }
        return data
    }
}
