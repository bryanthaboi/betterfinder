import CryptoKit
import Foundation
import FSCore

public struct SigV4Signer: Sendable {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public var region: String
    public var service: String
    public var doubleEncodePath: Bool
    public var addsContentSHA256Header: Bool

    public init(region: String, service: String = "s3", doubleEncodePath: Bool? = nil, addsContentSHA256Header: Bool? = nil) {
        self.region = region
        self.service = service
        self.doubleEncodePath = doubleEncodePath ?? (service != "s3")
        self.addsContentSHA256Header = addsContentSHA256Header ?? (service == "s3")
    }

    private static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

    public static func uriEncode(_ s: String, encodeSlash: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if unreserved.contains(b) || (!encodeSlash && b == UInt8(ascii: "/")) {
                out.unicodeScalars.append(UnicodeScalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    public static func amzDate(_ d: Date) -> String { amzDateFormatter.string(from: d) }

    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(String, String)] = items.map { (uriEncode($0.0), uriEncode($0.1)) }
        let sorted = encoded.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func normalizeHeaderValue(_ v: String) -> String {
        v.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    public func canonicalRequest(method: String, encodedPath: String, query: [(String, String)], headers: [String: String], payloadHash: String) -> (request: String, signedHeaders: String) {
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let canonicalPath = doubleEncodePath ? Self.uriEncode(path, encodeSlash: false) : path
        var lowered: [String: String] = [:]
        for (k, v) in headers {
            let key = k.lowercased()
            let value = Self.normalizeHeaderValue(v)
            if let existing = lowered[key] { lowered[key] = existing + "," + value } else { lowered[key] = value }
        }
        let names = lowered.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lowered[$0]!)\n" }.joined()
        let signed = names.joined(separator: ";")
        let request = [method.uppercased(), canonicalPath, Self.canonicalQuery(query), canonicalHeaders, signed, payloadHash].joined(separator: "\n")
        return (request, signed)
    }

    public func scope(dateStamp: String) -> String { "\(dateStamp)/\(region)/\(service)/aws4_request" }

    public func stringToSign(canonicalRequest: String, amzDate: String) -> String {
        let dateStamp = String(amzDate.prefix(8))
        return ["AWS4-HMAC-SHA256", amzDate, scope(dateStamp: dateStamp), FileDigest.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
    }

    public func signingKey(secret: String, dateStamp: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ s: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)))
        }
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secret)".utf8)), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    public func signature(stringToSign: String, secret: String, dateStamp: String) -> String {
        let key = signingKey(secret: secret, dateStamp: dateStamp)
        return FileDigest.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
    }

    public static func hostHeader(for url: URL) -> String {
        let host = url.host ?? ""
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            return "\(host):\(port)"
        }
        return host
    }

    public func sign(_ request: inout URLRequest, credentials: AWSCredentials, payloadHash: String, date: Date = Date()) {
        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let amzDate = Self.amzDate(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if addsContentSHA256Header { request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256") }
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "x-amz-security-token") }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["host"] = Self.hostHeader(for: url)
        let query = (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        let canonical = canonicalRequest(method: request.httpMethod ?? "GET", encodedPath: comps.percentEncodedPath, query: query, headers: headers, payloadHash: payloadHash)
        let sts = stringToSign(canonicalRequest: canonical.request, amzDate: amzDate)
        let dateStamp = String(amzDate.prefix(8))
        let sig = signature(stringToSign: sts, secret: credentials.secretAccessKey, dateStamp: dateStamp)
        let auth = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope(dateStamp: dateStamp)), SignedHeaders=\(canonical.signedHeaders), Signature=\(sig)"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
    }
}
