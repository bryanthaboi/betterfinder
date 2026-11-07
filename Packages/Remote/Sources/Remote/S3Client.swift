import Foundation
import FSCore

public struct S3Configuration: Codable, Hashable, Sendable {
    public var endpoint: String?
    public var region: String
    public var bucket: String
    public var pathStyle: Bool?
    public var prefix: String
    public var allowInsecureHTTP: Bool

    public init(endpoint: String? = nil, region: String = "us-east-1", bucket: String, pathStyle: Bool? = nil, prefix: String = "", allowInsecureHTTP: Bool = false) {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "us-east-1" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pathStyle = pathStyle
        self.prefix = prefix.split(separator: "/").joined(separator: "/")
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    public var usesPathStyle: Bool { pathStyle ?? (endpoint != nil || bucket.contains(".")) }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]" || h.hasSuffix(".localhost")
    }

    private func endpointComponents() throws -> URLComponents {
        guard let endpoint else {
            var c = URLComponents()
            c.scheme = "https"
            c.host = region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
            return c
        }
        let raw = endpoint.contains("://") ? endpoint : "https://" + endpoint
        guard var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty else {
            throw ResourceError.invalidName(endpoint)
        }
        guard scheme == "https" || scheme == "http" else { throw ResourceError.invalidName(endpoint) }
        if scheme == "http" && !allowInsecureHTTP && !Self.isLoopback(host) {
            throw ResourceError.unsupported("Sending credentials over plain HTTP to \(host)")
        }
        guard c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw ResourceError.invalidName(endpoint) }
        c.path = ""
        return c
    }

    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard (1...255).contains(bucket.count), bucket.unicodeScalars.allSatisfy(allowed.contains), !bucket.hasPrefix("-") else {
            throw ResourceError.invalidName(bucket)
        }
        guard region.unicodeScalars.allSatisfy(allowed.contains) else { throw ResourceError.invalidName(region) }
        _ = try endpointComponents()
    }

    public func baseURL() throws -> URL {
        try validate()
        var c = try endpointComponents()
        if usesPathStyle {
            c.percentEncodedPath = "/" + SigV4Signer.uriEncode(bucket)
        } else {
            c.host = "\(bucket).\(c.host!)"
        }
        guard let url = c.url else { throw ResourceError.invalidName(bucket) }
        return url
    }

    public var host: String {
        guard let url = try? baseURL() else { return "invalid" }
        return SigV4Signer.hostHeader(for: url).lowercased()
    }

    public var credentialScope: CredentialScope { CredentialScope(kind: .s3, host: host, resource: bucket) }

    public var displayName: String { prefix.isEmpty ? bucket : "\(bucket)/\(prefix)" }
}

public struct S3ObjectInfo: Sendable, Hashable {
    public var size: Int64
    public var etag: String?
    public var lastModified: Date?
    public var contentType: String?
    public var sha256: String?
}

final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class S3Client: @unchecked Sendable {
    public let configuration: S3Configuration
    let credentials: BoundCredentials
    let session: URLSession
    let signer: SigV4Signer
    let retry: RetryPolicy
    let clock: @Sendable () -> Date
    public var multipartThreshold: Int64 = 16 << 20
    public var partSize: Int64 = 16 << 20
    public var downloadChunkSize: Int64 = 8 << 20
    public var maxSinglePartCopy: Int64 = 5 << 30
    private let stateLock = NSLock()
    private var conditionalDeleteEnforced: Bool?

    public init(configuration: S3Configuration, credentialStore: CredentialStore, sessionConfiguration: URLSessionConfiguration? = nil, retry: RetryPolicy = RetryPolicy(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.credentials = BoundCredentials(scope: configuration.credentialScope, store: credentialStore)
        let cfg = sessionConfiguration ?? .ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg, delegate: RedirectBlocker(), delegateQueue: nil)
        self.signer = SigV4Signer(region: configuration.region, service: "s3")
        self.retry = retry
        self.clock = clock
    }

    deinit { session.invalidateAndCancel() }

    func url(key: String?, query: [(String, String?)]) throws -> URL {
        let base = try configuration.baseURL()
        var s = base.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        s += "/"
        if let key, !key.isEmpty { s += SigV4Signer.uriEncode(key, encodeSlash: false) }
        if !query.isEmpty {
            s += "?" + query.map { k, v in v.map { "\(SigV4Signer.uriEncode(k))=\(SigV4Signer.uriEncode($0))" } ?? SigV4Signer.uriEncode(k) }.joined(separator: "&")
        }
        guard let u = URL(string: s) else { throw ResourceError.invalidName(key ?? configuration.bucket) }
        return u
    }

    struct Response {
        let data: Data
        let http: HTTPURLResponse
        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
    }

    func perform(_ method: String, key: String?, query: [(String, String?)] = [], headers: [String: String] = [:], body: Data? = nil, retryable: Bool = true) async throws -> Response {
        let policy = retryable ? retry : .none
        return try await policy.run { _ in
            let url = try self.url(key: key, query: query)
            let creds = try self.credentials.awsCredentials(forRequestHost: SigV4Signer.hostHeader(for: url))
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 120
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let body { req.httpBody = body }
            let hash = body.map(FileDigest.sha256Hex) ?? SigV4Signer.emptyPayloadHash
            self.signer.sign(&req, credentials: creds, payloadHash: hash, date: self.clock())
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await self.session.data(for: req)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse else { throw ResourceError.connectionFailed("No HTTP response") }
            if (200..<300).contains(http.statusCode) {
                if method == "POST" || (method == "PUT" && headers["x-amz-copy-source"] != nil), let err = S3XML.error(data) {
                    throw ResourceError.remote(code: err.code, message: err.message)
                }
                return Response(data: data, http: http)
            }
            throw self.mapError(http, data: data, key: key)
        }
    }

    func mapError(_ http: HTTPURLResponse, data: Data, key: String?) -> ResourceError {
        let body = S3XML.error(data)
        let code = body?.code ?? "HTTP\(http.statusCode)"
        let message = body?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        let name = key ?? configuration.bucket
        switch (http.statusCode, code) {
        case (404, _): return .notFound(name)
        case (301, _), (302, _), (307, _), (_, "PermanentRedirect"), (_, "TemporaryRedirect"):
            return .remote(code: code == "HTTP\(http.statusCode)" ? "PermanentRedirect" : code, message: "The bucket is served from a different endpoint or region. Check the region setting.")
        case (_, "SignatureDoesNotMatch"), (_, "InvalidAccessKeyId"), (_, "InvalidToken"), (_, "ExpiredToken"), (_, "AuthorizationHeaderMalformed"):
            return .authenticationFailed(message)
        case (403, _): return .permissionDenied(message)
        case (412, _): return .remote(code: "PreconditionFailed", message: "The object changed while it was being read.")
        default: return .remote(code: code, message: message)
        }
    }

    public func list(prefix: String, delimiter: String? = "/", continuationToken: String? = nil, maxKeys: Int = 1000) async throws -> S3ListPage {
        var q: [(String, String?)] = [("list-type", "2"), ("max-keys", String(max(1, min(1000, maxKeys)))), ("prefix", prefix)]
        if let delimiter { q.append(("delimiter", delimiter)) }
        if let continuationToken { q.append(("continuation-token", continuationToken)) }
        let r = try await perform("GET", key: nil, query: q)
        guard let page = S3XML.listPage(r.data) else { throw ResourceError.remote(code: "MalformedXML", message: "The server returned an unreadable listing.") }
        return page
    }

    func info(_ r: Response) -> S3ObjectInfo {
        let length = r.header("Content-Range").flatMap { $0.split(separator: "/").last.flatMap { Int64($0) } } ?? r.header("Content-Length").flatMap { Int64($0) } ?? 0
        let modified = r.header("Last-Modified").flatMap { HTTPDate.parse($0) }
        return S3ObjectInfo(size: length, etag: S3XML.unquote(r.header("ETag")), lastModified: modified, contentType: r.header("Content-Type"), sha256: r.header("x-amz-meta-sha256"))
    }

    public func head(key: String) async throws -> S3ObjectInfo {
        info(try await perform("HEAD", key: key))
    }

    public func get(key: String, range: Range<Int64>? = nil, ifMatch: String? = nil) async throws -> (Data, S3ObjectInfo, Bool) {
        var h: [String: String] = [:]
        if let range {
            guard range.upperBound > range.lowerBound else { return (Data(), try await head(key: key), true) }
            h["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
        }
        if let ifMatch { h["If-Match"] = "\"\(ifMatch)\"" }
        let r = try await perform("GET", key: key, headers: h)
        return (r.data, info(r), r.http.statusCode == 206)
    }

    public func download(key: String, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> S3ObjectInfo {
        let head = try await self.head(key: key)
        let fm = FileManager.default
        try? fm.removeItem(at: file)
        guard fm.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        do {
            while offset < head.size {
                try Task.checkCancellation()
                let end = min(head.size, offset + max(1, downloadChunkSize))
                let (data, _, partial) = try await get(key: key, range: offset..<end, ifMatch: head.etag)
                if !partial {
                    guard offset == 0 else { throw ResourceError.remote(code: "RangeIgnored", message: "The server ignored a ranged read.") }
                    try handle.write(contentsOf: data)
                    offset = Int64(data.count)
                    progress(offset)
                    break
                }
                guard Int64(data.count) == end - offset else { throw ResourceError.verificationFailed("short read of \(key)") }
                try handle.write(contentsOf: data)
                offset = end
                progress(offset)
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: file)
            throw error
        }
        guard offset == head.size else { throw ResourceError.verificationFailed("\(key): expected \(head.size) bytes, got \(offset)") }
        return head
    }

    public func put(key: String, data: Data, contentType: String? = nil, sha256: String? = nil) async throws -> String? {
        var h: [String: String] = ["Content-MD5": FileDigest.md5Base64(data)]
        h["Content-Type"] = contentType ?? "application/octet-stream"
        h["x-amz-meta-sha256"] = sha256 ?? FileDigest.sha256Hex(data)
        let r = try await perform("PUT", key: key, headers: h, body: data)
        let etag = S3XML.unquote(r.header("ETag"))
        if let etag, Self.isMD5(etag), r.header("x-amz-server-side-encryption") != "aws:kms", etag.lowercased() != FileDigest.md5Hex(data) {
            throw ResourceError.verificationFailed("\(key): ETag \(etag) doesn’t match the uploaded content")
        }
        return etag
    }

    static func isMD5(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit }
    }

    public func createMultipart(key: String, contentType: String?, sha256: String?) async throws -> String {
        var h: [String: String] = ["Content-Type": contentType ?? "application/octet-stream"]
        if let sha256 { h["x-amz-meta-sha256"] = sha256 }
        let r = try await perform("POST", key: key, query: [("uploads", nil)], headers: h)
        guard let id = S3XML.uploadID(r.data) else { throw ResourceError.remote(code: "MalformedXML", message: "No upload ID was returned.") }
        return id
    }

    public func uploadPart(key: String, uploadID: String, number: Int, data: Data) async throws -> String {
        let r = try await perform("PUT", key: key, query: [("partNumber", String(number)), ("uploadId", uploadID)], headers: ["Content-MD5": FileDigest.md5Base64(data)], body: data)
        guard let etag = S3XML.unquote(r.header("ETag")) else { throw ResourceError.remote(code: "MissingETag", message: "Part \(number) returned no ETag.") }
        if Self.isMD5(etag), r.header("x-amz-server-side-encryption") != "aws:kms", etag.lowercased() != FileDigest.md5Hex(data) {
            throw ResourceError.verificationFailed("part \(number) of \(key) didn’t match")
        }
        return etag
    }

    public func completeMultipart(key: String, uploadID: String, parts: [(Int, String)]) async throws -> String? {
        let r = try await perform("POST", key: key, query: [("uploadId", uploadID)], headers: ["Content-Type": "application/xml"], body: S3XML.completeBody(parts))
        return S3XML.completeETag(r.data) ?? S3XML.unquote(r.header("ETag"))
    }

    public func abortMultipart(key: String, uploadID: String) async {
        _ = try? await perform("DELETE", key: key, query: [("uploadId", uploadID)], retryable: false)
    }

    public func upload(file: URL, key: String, contentType: String?, sha256 knownSHA: String? = nil, progress: @escaping @Sendable (Int64) -> Void) async throws -> String? {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
        if size <= multipartThreshold {
            let data = try Data(contentsOf: file)
            let etag = try await put(key: key, data: data, contentType: contentType, sha256: knownSHA)
            progress(Int64(data.count))
            return etag
        }
        let digest: String
        if let knownSHA { digest = knownSHA } else { digest = try await FileDigest.computeAsync(file).sha256 }
        let part = max(partSize, (size + 9_999) / 10_000)
        let uploadID = try await createMultipart(key: key, contentType: contentType, sha256: digest)
        var parts: [(Int, String)] = []
        var partMD5 = Data()
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var sent: Int64 = 0
            var number = 1
            while sent < size {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Int(min(part, size - sent))) ?? Data()
                guard !chunk.isEmpty else { throw ResourceError.verificationFailed("\(file.lastPathComponent) changed while uploading") }
                let etag = try await uploadPart(key: key, uploadID: uploadID, number: number, data: chunk)
                parts.append((number, etag))
                partMD5.append(Data(FileDigest.md5Hex(chunk).hexBytes))
                sent += Int64(chunk.count)
                progress(sent)
                number += 1
            }
            try Task.checkCancellation()
            let final = try await completeMultipart(key: key, uploadID: uploadID, parts: parts)
            let expected = FileDigest.md5Hex(partMD5) + "-\(parts.count)"
            if let final, final.contains("-"), final.lowercased() != expected {
                throw ResourceError.verificationFailed("\(key): multipart ETag \(final) doesn’t match \(expected)")
            }
            return final
        } catch {
            await Task.detached { await self.abortMultipart(key: key, uploadID: uploadID) }.value
            throw error
        }
    }

    public func delete(key: String) async throws {
        _ = try await perform("DELETE", key: key)
    }

    enum ConditionalDeleteResult: Sendable, Equatable {
        case deleted
        case changed
        case refused(String)
    }

    static let conditionFailedCodes: Set<String> = ["PreconditionFailed", "ConditionalRequestConflict"]
    static let conditionRefusedCodes: Set<String> = ["NotImplemented", "InvalidArgument", "InvalidRequest", "InvalidHeader", "MethodNotAllowed", "HTTP400", "HTTP405", "HTTP501"]

    func delete(key: String, ifMatch etag: String) async throws -> ConditionalDeleteResult {
        do {
            _ = try await perform("DELETE", key: key, headers: ["If-Match": "\"\(etag)\""])
            return .deleted
        } catch ResourceError.notFound {
            return .deleted
        } catch ResourceError.remote(let code, _) where Self.conditionFailedCodes.contains(code) {
            return .changed
        } catch ResourceError.remote(let code, let message) where Self.conditionRefusedCodes.contains(code) {
            return .refused(message.isEmpty ? code : message)
        }
    }

    var knownConditionalDeleteSupport: Bool? { stateLock.withLock { conditionalDeleteEnforced } }

    func noteConditionalDeleteRefused() {
        stateLock.withLock { conditionalDeleteEnforced = false }
    }

    func enforcesConditionalDelete(probeKey: String) async throws -> Bool {
        if let known = knownConditionalDeleteSupport { return known }
        let body = Data("betterfinder\n".utf8)
        let enforced: Bool
        do {
            let etag = try await put(key: probeKey, data: body, contentType: "text/plain") ?? FileDigest.md5Hex(body)
            let wrong = etag.lowercased() == String(repeating: "0", count: 32) ? String(repeating: "f", count: 32) : String(repeating: "0", count: 32)
            switch try await delete(key: probeKey, ifMatch: wrong) {
            case .changed:
                do {
                    _ = try await head(key: probeKey)
                    enforced = true
                } catch ResourceError.notFound {
                    enforced = false
                }
            case .deleted, .refused:
                enforced = false
            }
        } catch {
            await discardProbe(probeKey)
            throw error
        }
        await discardProbe(probeKey)
        stateLock.withLock { conditionalDeleteEnforced = enforced }
        return enforced
    }

    private func discardProbe(_ key: String) async {
        await Task.detached { [self] in _ = try? await self.perform("DELETE", key: key) }.value
    }

    public func copy(from source: String, to destination: String) async throws -> String? {
        try await copy(from: source, to: destination, ifMatch: nil)
    }

    public func copy(from source: String, to destination: String, ifMatch: String?) async throws -> String? {
        let src = "/" + SigV4Signer.uriEncode(configuration.bucket) + "/" + SigV4Signer.uriEncode(source, encodeSlash: false)
        var h = ["x-amz-copy-source": src, "x-amz-metadata-directive": "COPY"]
        if let ifMatch, !ifMatch.isEmpty { h["x-amz-copy-source-if-match"] = "\"\(ifMatch)\"" }
        let r = try await perform("PUT", key: destination, headers: h)
        return S3XML.copyETag(r.data)
    }
}

extension String {
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        var it = makeIterator()
        while let a = it.next(), let b = it.next() {
            if let v = UInt8(String([a, b]), radix: 16) { out.append(v) }
        }
        return out
    }
}

enum HTTPDate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parse(_ s: String) -> Date? { formatter.date(from: s) }
}
