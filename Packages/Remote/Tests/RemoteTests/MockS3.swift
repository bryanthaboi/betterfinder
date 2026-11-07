import Foundation
import FSCore
@testable import Remote

final class MockS3Server: @unchecked Sendable {
    struct Object {
        var data: Data
        var etag: String
        var modified: Date
        var meta: [String: String]
        var contentType: String
    }

    struct Upload {
        var key: String
        var parts: [Int: Data] = [:]
        var meta: [String: String]
    }

    struct Logged {
        let method: String
        let host: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let accessKey: String?
    }

    let lock = NSLock()
    var buckets: [String: [String: Object]] = [:]
    var secrets: [String: String] = [:]
    var uploads: [String: Upload] = [:]
    var log: [Logged] = []
    var failNext: [Int] = []
    var redirectTo: String?
    var partDelay: TimeInterval = 0
    var aborted: [String] = []
    var completed: [String] = []
    var verifySignatures = true
    var signatureFailures = 0
    var onRequest: ((_ method: String, _ key: String, _ headers: [String: String], _ buckets: inout [String: [String: Object]]) -> Void)?

    enum ConditionalDelete {
        case enforce
        case ignore
        case reject(Int, String)
    }

    var conditionalDelete: ConditionalDelete = .enforce
    var conditionalDeleteByKey: [String: ConditionalDelete] = [:]
    var beforeDelete: ((_ key: String, _ objects: inout [String: Object]) -> Void)?

    func put(_ bucket: String, _ key: String, _ data: Data, meta: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        buckets[bucket, default: [:]][key] = Object(data: data, etag: FileDigest.md5Hex(data), modified: Date(timeIntervalSince1970: 1_700_000_000), meta: meta, contentType: "application/octet-stream")
    }

    func object(_ bucket: String, _ key: String) -> Object? {
        lock.lock(); defer { lock.unlock() }
        return buckets[bucket]?[key]
    }

    func keys(_ bucket: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (buckets[bucket] ?? [:]).keys.sorted()
    }

    func requests(host: String? = nil) -> [Logged] {
        lock.lock(); defer { lock.unlock() }
        return host.map { h in log.filter { $0.host == h } } ?? log
    }

    static func xml(_ s: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + s).utf8) }
    static func esc(_ s: String) -> String { S3XML.escape(s) }

    static func errorBody(_ code: String, _ message: String) -> Data { xml("<Error><Code>\(code)</Code><Message>\(message)</Message></Error>") }

    func verify(_ req: URLRequest, body: Data, host: String) -> (ok: Bool, accessKey: String?) {
        guard let auth = req.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("AWS4-HMAC-SHA256 ") else { return (false, nil) }
        let fields = auth.dropFirst("AWS4-HMAC-SHA256 ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var dict: [String: String] = [:]
        for f in fields { if let eq = f.firstIndex(of: "=") { dict[String(f[..<eq])] = String(f[f.index(after: eq)...]) } }
        guard let cred = dict["Credential"], let signed = dict["SignedHeaders"], let sig = dict["Signature"] else { return (false, nil) }
        let parts = cred.split(separator: "/").map(String.init)
        guard parts.count == 5 else { return (false, nil) }
        let access = parts[0]
        guard verifySignatures else { return (true, access) }
        guard let secret = secrets[access], let url = req.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (false, access) }
        let signer = SigV4Signer(region: parts[2], service: parts[3])
        var headers: [String: String] = [:]
        let all = req.allHTTPHeaderFields ?? [:]
        for name in signed.split(separator: ";").map(String.init) {
            if name == "host" { headers["host"] = SigV4Signer.hostHeader(for: url); continue }
            guard let v = all.first(where: { $0.key.lowercased() == name })?.value else { return (false, access) }
            headers[name] = v
        }
        let payload = req.value(forHTTPHeaderField: "x-amz-content-sha256") ?? ""
        guard payload == FileDigest.sha256Hex(body) else { return (false, access) }
        let canonical = signer.canonicalRequest(method: req.httpMethod ?? "GET", encodedPath: comps.percentEncodedPath, query: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, headers: headers, payloadHash: payload)
        guard let date = req.value(forHTTPHeaderField: "x-amz-date") else { return (false, access) }
        let sts = signer.stringToSign(canonicalRequest: canonical.request, amzDate: date)
        let expected = signer.signature(stringToSign: sts, secret: secret, dateStamp: parts[1])
        return (expected == sig && canonical.signedHeaders == signed, access)
    }

    func handle(_ req: URLRequest, body: Data) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        guard let url = req.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host else { return (400, [:], Data()) }
        var query: [String: String] = [:]
        for q in comps.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let v = verify(req, body: body, host: host)
        log.append(Logged(method: req.httpMethod ?? "GET", host: host, path: comps.path, query: query, headers: req.allHTTPHeaderFields ?? [:], accessKey: v.accessKey))
        if let redirectTo { return (307, ["Location": redirectTo], Data()) }
        guard v.ok else {
            signatureFailures += 1
            return (403, [:], Self.errorBody("SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided."))
        }
        if !failNext.isEmpty {
            let code = failNext.removeFirst()
            return (code, [:], Self.errorBody(code == 503 ? "SlowDown" : "InternalError", "try again"))
        }
        var segments = comps.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.first == "" { segments.removeFirst() }
        guard let bucket = segments.first, !bucket.isEmpty else { return (400, [:], Data()) }
        let key = segments.dropFirst().joined(separator: "/")
        guard buckets[bucket] != nil else { return (404, [:], Self.errorBody("NoSuchBucket", "The specified bucket does not exist")) }
        let method = req.httpMethod ?? "GET"
        onRequest?(method, key, req.allHTTPHeaderFields ?? [:], &buckets)
        if key.isEmpty && method == "GET" && query["list-type"] == "2" {
            return list(bucket: bucket, query: query)
        }
        if method == "POST" && query["uploads"] != nil {
            let id = UUID().uuidString
            var meta: [String: String] = [:]
            for (k, v) in req.allHTTPHeaderFields ?? [:] where k.lowercased().hasPrefix("x-amz-meta-") { meta[k.lowercased()] = v }
            uploads[id] = Upload(key: key, meta: meta)
            return (200, [:], Self.xml("<InitiateMultipartUploadResult><Bucket>\(bucket)</Bucket><Key>\(Self.esc(key))</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>"))
        }
        if method == "PUT", let id = query["uploadId"], let n = query["partNumber"].flatMap(Int.init) {
            guard uploads[id] != nil else { return (404, [:], Self.errorBody("NoSuchUpload", "")) }
            if let md5 = req.value(forHTTPHeaderField: "Content-MD5"), md5 != FileDigest.md5Base64(body) { return (400, [:], Self.errorBody("BadDigest", "")) }
            uploads[id]!.parts[n] = body
            if partDelay > 0 { lock.unlock(); Thread.sleep(forTimeInterval: partDelay); lock.lock() }
            return (200, ["ETag": "\"\(FileDigest.md5Hex(body))\""], Data())
        }
        if method == "POST", let id = query["uploadId"] {
            guard let up = uploads.removeValue(forKey: id) else { return (404, [:], Self.errorBody("NoSuchUpload", "")) }
            let numbers = up.parts.keys.sorted()
            var data = Data()
            var md5s = Data()
            for n in numbers { data.append(up.parts[n]!); md5s.append(Data(FileDigest.md5Hex(up.parts[n]!).hexBytes)) }
            let etag = FileDigest.md5Hex(md5s) + "-\(numbers.count)"
            buckets[bucket]![up.key] = Object(data: data, etag: etag, modified: Date(), meta: up.meta, contentType: "application/octet-stream")
            completed.append(id)
            return (200, [:], Self.xml("<CompleteMultipartUploadResult><Key>\(Self.esc(up.key))</Key><ETag>&quot;\(etag)&quot;</ETag></CompleteMultipartUploadResult>"))
        }
        if method == "DELETE", let id = query["uploadId"] {
            uploads[id] = nil
            aborted.append(id)
            return (204, [:], Data())
        }
        switch method {
        case "PUT":
            if let src = req.value(forHTTPHeaderField: "x-amz-copy-source") {
                let decoded = src.removingPercentEncoding ?? src
                let trimmed = decoded.drop { $0 == "/" }
                let sb = String(trimmed.prefix { $0 != "/" })
                let sk = String(trimmed.dropFirst(sb.count + 1))
                guard let o = buckets[sb]?[sk] else { return (404, [:], Self.errorBody("NoSuchKey", "")) }
                if let m = req.value(forHTTPHeaderField: "x-amz-copy-source-if-match"), m.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) != o.etag {
                    return (412, [:], Self.errorBody("PreconditionFailed", "At least one of the pre-conditions you specified did not hold"))
                }
                buckets[bucket]![key] = o
                return (200, [:], Self.xml("<CopyObjectResult><ETag>&quot;\(o.etag)&quot;</ETag></CopyObjectResult>"))
            }
            if let md5 = req.value(forHTTPHeaderField: "Content-MD5"), md5 != FileDigest.md5Base64(body) { return (400, [:], Self.errorBody("BadDigest", "")) }
            var meta: [String: String] = [:]
            for (k, v) in req.allHTTPHeaderFields ?? [:] where k.lowercased().hasPrefix("x-amz-meta-") { meta[k.lowercased()] = v }
            let o = Object(data: body, etag: FileDigest.md5Hex(body), modified: Date(), meta: meta, contentType: req.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
            buckets[bucket]![key] = o
            return (200, ["ETag": "\"\(o.etag)\""], Data())
        case "HEAD", "GET":
            guard let o = buckets[bucket]![key] else { return (404, [:], method == "HEAD" ? Data() : Self.errorBody("NoSuchKey", "The specified key does not exist.")) }
            if let m = req.value(forHTTPHeaderField: "If-Match"), m.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) != o.etag { return (412, [:], Self.errorBody("PreconditionFailed", "")) }
            var h: [String: String] = ["ETag": "\"\(o.etag)\"", "Last-Modified": HTTPDate.formatter.string(from: o.modified), "Content-Type": o.contentType]
            for (k, v) in o.meta { h[k] = v }
            if method == "HEAD" {
                h["Content-Length"] = String(o.data.count)
                return (200, h, Data())
            }
            if let r = req.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
                let nums = r.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard nums.count == 2, nums[0] <= nums[1], nums[0] < o.data.count else { return (416, [:], Self.errorBody("InvalidRange", "")) }
                let end = min(nums[1], o.data.count - 1)
                h["Content-Range"] = "bytes \(nums[0])-\(end)/\(o.data.count)"
                return (206, h, o.data.subdata(in: nums[0]..<(end + 1)))
            }
            return (200, h, o.data)
        case "DELETE":
            beforeDelete?(key, &buckets[bucket]!)
            if let m = req.value(forHTTPHeaderField: "If-Match") {
                switch conditionalDeleteByKey[key] ?? conditionalDelete {
                case .enforce:
                    if let o = buckets[bucket]![key], m.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) != o.etag {
                        return (412, [:], Self.errorBody("PreconditionFailed", "At least one of the pre-conditions you specified did not hold"))
                    }
                case .ignore:
                    break
                case .reject(let status, let code):
                    return (status, [:], Self.errorBody(code, "A header you provided implies functionality that is not implemented"))
                }
            }
            buckets[bucket]![key] = nil
            return (204, [:], Data())
        default:
            return (405, [:], Data())
        }
    }

    func list(bucket: String, query: [String: String]) -> (Int, [String: String], Data) {
        let prefix = query["prefix"] ?? ""
        let delimiter = query["delimiter"]
        let maxKeys = Int(query["max-keys"] ?? "1000") ?? 1000
        let start = query["continuation-token"]
        var entries: [(key: String, isPrefix: Bool)] = []
        var seen = Set<String>()
        for k in (buckets[bucket] ?? [:]).keys.sorted() where k.hasPrefix(prefix) {
            if let d = delimiter, let r = k.dropFirst(prefix.count).range(of: d) {
                let cp = prefix + k.dropFirst(prefix.count)[..<r.upperBound]
                if seen.insert(cp).inserted { entries.append((cp, true)) }
            } else {
                entries.append((k, false))
            }
        }
        if let start { entries = entries.filter { $0.key > start } }
        let page = Array(entries.prefix(maxKeys))
        let truncated = entries.count > page.count
        var s = "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>\(bucket)</Name><Prefix>\(Self.esc(prefix))</Prefix><KeyCount>\(page.count)</KeyCount><MaxKeys>\(maxKeys)</MaxKeys><IsTruncated>\(truncated)</IsTruncated>"
        if truncated, let last = page.last { s += "<NextContinuationToken>\(Self.esc(last.key))</NextContinuationToken>" }
        for e in page {
            if e.isPrefix {
                s += "<CommonPrefixes><Prefix>\(Self.esc(e.key))</Prefix></CommonPrefixes>"
            } else if let o = buckets[bucket]?[e.key] {
                s += "<Contents><Key>\(Self.esc(e.key))</Key><LastModified>2023-11-14T22:13:20.000Z</LastModified><ETag>&quot;\(o.etag)&quot;</ETag><Size>\(o.data.count)</Size><StorageClass>STANDARD</StorageClass></Contents>"
            }
        }
        s += "</ListBucketResult>"
        return (200, ["Content-Type": "application/xml"], Self.xml(s))
    }
}

final class MockS3Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var servers: [String: MockS3Server] = [:]
    static let lock = NSLock()

    static func install(_ server: MockS3Server, hosts: [String]) {
        lock.lock(); defer { lock.unlock() }
        for h in hosts { servers[h.lowercased()] = server }
    }

    static func reset() {
        lock.lock(); servers = [:]; lock.unlock()
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockS3Protocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = false

    override func startLoading() {
        let req = request
        var body = req.httpBody ?? Data()
        if body.isEmpty, let stream = req.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let host = req.url?.host?.lowercased() ?? ""
        Self.lock.lock()
        let server = Self.servers[host]
        Self.lock.unlock()
        DispatchQueue.global().async { [self] in
            guard let server else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            let (status, headers, data) = server.handle(req, body: body)
            if cancelled { return }
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            if (300..<400).contains(status), let loc = headers["Location"], let target = URL(string: loc) {
                var next = URLRequest(url: target)
                next.httpMethod = req.httpMethod
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: resp)
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { cancelled = true }
}
