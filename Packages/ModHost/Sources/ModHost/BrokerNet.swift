import Darwin
import Foundation
import ModHostProtocol
import ModKit

public protocol ModHostResolving: Sendable {
    func addresses(for host: String) -> [String]
}

public struct SystemHostResolver: ModHostResolving {
    public init() {}
    public func addresses(for host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out = [String]()
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            cur = ai.pointee.ai_next
        }
        return out
    }
}

public enum ModNetAddress {
    public static func isPrivate(_ address: String) -> Bool {
        let a = address.split(separator: "%").first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, a, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
            case (172, 16...31), (100, 64...127), (198, 18...19): return true
            case (192, 0) where b[2] == 0 || b[2] == 2: return true
            case (224...255, _): return true
            default: return false
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, a, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return true }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            if b[0] & 0xfe == 0xfc { return true }
            if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }
            if b[0] == 0xff { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isPrivate("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
            if b[0] == 0x20, b[1] == 0x02 { return isPrivate("\(b[2]).\(b[3]).\(b[4]).\(b[5])") }
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b { return isPrivate("\(b[12]).\(b[13]).\(b[14]).\(b[15])") }
            return false
        }
        return true
    }
}

final class ModNetBroker: @unchecked Sendable {
    static let hardCap = 768 * 1024
    static let maxRedirects = 16
    let resolver: ModHostResolving
    var dial: ModHTTPConnection.Dialer = { host, port in (host, port) }

    init(resolver: ModHostResolving = SystemHostResolver()) {
        self.resolver = resolver
    }

    struct Match {
        var permission: ModPermission
        var url: URL
        var method: String
    }

    func authorize(_ url: URL, method: String, grants: [ModPermission]) throws -> Match {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(), !host.isEmpty else { throw ModCallError.invalid("invalid URL") }
        guard scheme == "https" || scheme == "http" else { throw ModCallError.denied("scheme \(scheme) is not allowed") }
        guard comps.user == nil, comps.password == nil else { throw ModCallError.denied("credentials in URLs are not allowed") }
        let port = comps.port ?? (scheme == "https" ? 443 : 80)
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        for p in grants where p.kind == .net {
            for ep in p.endpoints ?? [] where ep.scheme.rawValue == scheme && ep.host == bare {
                let epPort = ep.port ?? (ep.scheme == .https ? 443 : 80)
                guard epPort == port, ep.methods.map(\.rawValue).contains(method) else { continue }
                return Match(permission: p, url: url, method: method)
            }
        }
        throw ModCallError.notGranted("\(method) \(scheme)://\(bare):\(port) is not a granted endpoint")
    }

    func checkDestination(_ host: String, allowPrivate: Bool) throws {
        _ = try resolveDestination(host, allowPrivate: allowPrivate)
    }

    func resolveDestination(_ host: String, allowPrivate: Bool) throws -> [String]? {
        guard !allowPrivate else { return nil }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") { throw ModCallError.denied("\(bare) is a local destination") }
        let addrs = isLiteral(bare) ? [bare] : resolver.addresses(for: bare)
        guard !addrs.isEmpty else { throw ModCallError("network", "cannot resolve \(bare)") }
        if let bad = addrs.first(where: ModNetAddress.isPrivate) { throw ModCallError.denied("\(bare) resolves to private address \(bad)") }
        return addrs
    }

    func isLiteral(_ h: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1
    }

    func fetch(_ mod: ActiveMod, _ request: JSONValue, credentials: ModCredentialStoring?) async throws -> JSONValue {
        guard let urlText = request["url"]?.stringValue, urlText.utf8.count <= 4096, let url = URL(string: urlText) else { throw ModCallError.invalid("invalid URL") }
        let method = request["method"]?.stringValue ?? "GET"
        let match = try authorize(url, method: method, grants: mod.grants)
        let cap = min(match.permission.maxBytes ?? 512 * 1024, Self.hardCap)
        let timeout = Double(min(max(request["timeoutMs"]?.intValue ?? 10_000, 100), 15_000)) / 1000
        let forbidden: Set<String> = ["host", "cookie", "connection", "content-length", "transfer-encoding", "proxy-authorization", "te", "upgrade",
                                      "keep-alive", "proxy-connection", "trailer"]
        let headerList = request["headers"]?.arrayValue ?? []
        guard headerList.count <= 32 else { throw ModCallError.limit("at most 32 headers") }
        var headers = [(name: String, value: String)]()
        for h in headerList {
            guard let name = h["name"]?.stringValue, let value = h["value"]?.stringValue, !forbidden.contains(name.lowercased()), ModHTTPWire.isToken(name),
                  name.utf8.count <= 128, value.utf8.count <= 4096, !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { throw ModCallError.invalid("invalid header") }
            headers.append((name, value))
        }
        var authorization: (destination: String, value: String)?
        if let cred = request["credential"]?.stringValue {
            guard cred.hasPrefix("cred:"), let stored = credentials?.secret(modId: mod.id, name: String(cred.dropFirst(5))) else { throw ModCallError.notGranted("unknown credential") }
            guard stored.destination == url.host?.lowercased() else { throw ModCallError.denied("credential is bound to \(stored.destination)") }
            guard !stored.secret.contains("\r"), !stored.secret.contains("\n") else { throw ModCallError.invalid("invalid credential") }
            authorization = (stored.destination, stored.secret)
        }
        var body: Data?
        if let text = request["body"]?.stringValue {
            guard text.utf8.count <= 256 * 1024 else { throw ModCallError.limit("request body exceeds 256 KiB") }
            body = Data(text.utf8)
        }
        let response = try await perform(ModHTTPRequest(method: method, url: url, headers: headers, body: body), grants: mod.grants, authorization: authorization,
                                         cap: cap, deadline: Date().addingTimeInterval(timeout))
        let respHeaders = response.mergedHeaders.sorted { $0.name < $1.name }.prefix(64).map {
            JSONValue.object(["name": .string($0.name), "value": .string(String($0.value.prefix(4096)))])
        }
        return .object([
            "status": .int(response.status),
            "headers": .array(Array(respHeaders)),
            "body": .string(String(decoding: response.body, as: UTF8.self)),
        ])
    }

    func perform(_ initial: ModHTTPRequest, grants: [ModPermission], authorization: (destination: String, value: String)?, cap: Int, deadline: Date) async throws -> ModHTTPResponse {
        var request = initial
        var redirects = 0
        while true {
            let addresses: [String]?
            do {
                let match = try authorize(request.url, method: request.method, grants: grants)
                addresses = try resolveDestination(request.url.host ?? "", allowPrivate: match.permission.allowPrivate == true)
            } catch let e as ModCallError where redirects > 0 {
                throw ModCallError.denied("redirect refused: \(e.message)")
            }
            guard let comps = URLComponents(url: request.url, resolvingAgainstBaseURL: false), let host = comps.host?.lowercased() else { throw ModCallError.invalid("invalid URL") }
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let tls = comps.scheme?.lowercased() == "https"
            let port = UInt16(clamping: comps.port ?? (tls ? 443 : 80))
            var wire = request
            if let authorization, authorization.destination == bare { wire.headers.append(("Authorization", authorization.value)) }
            let connection = try await ModHTTPConnection.open(ModHTTPTarget(host: bare, port: port, tls: tls, addresses: addresses), deadline: deadline, dial: dial)
            defer { connection.cancel() }
            try await connection.send(ModHTTPWire.encode(wire, host: bare, port: port, tls: tls))
            let response = try await connection.readResponse(method: request.method, cap: cap)
            guard [301, 302, 303, 307, 308].contains(response.status), let location = response.header("location"),
                  let next = URL(string: location, relativeTo: request.url)?.absoluteURL else { return response }
            redirects += 1
            guard redirects <= Self.maxRedirects else { throw ModCallError("network", "too many redirects") }
            var method = request.method
            var body = request.body
            if response.status == 303 && method != "HEAD" || (response.status == 301 || response.status == 302) && method == "POST" {
                method = "GET"
                body = nil
            }
            let dropped: Set<String> = body == nil ? ["content-type"] : []
            request = ModHTTPRequest(method: method, url: next, headers: request.headers.filter { !dropped.contains($0.name.lowercased()) }, body: body)
        }
    }
}
