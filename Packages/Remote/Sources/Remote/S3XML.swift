import Foundation

final class XMLNode {
    let name: String
    var text = ""
    var children: [XMLNode] = []

    init(name: String) { self.name = name }

    func child(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XMLNode] { children.filter { $0.name == n } }
    func string(_ n: String) -> String? { child(n)?.text }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private(set) var root: XMLNode?

    static func parse(_ data: Data) -> XMLNode? {
        let p = XMLParser(data: data)
        let b = XMLTreeBuilder()
        p.delegate = b
        p.shouldProcessNamespaces = true
        guard p.parse() else { return nil }
        return b.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let n = XMLNode(name: elementName)
        stack.last?.children.append(n)
        if stack.isEmpty { root = n }
        stack.append(n)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

public struct S3Object: Sendable, Hashable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    public var etag: String?
}

public struct S3ListPage: Sendable, Hashable {
    public var objects: [S3Object]
    public var commonPrefixes: [String]
    public var isTruncated: Bool
    public var nextContinuationToken: String?
    public var keyCount: Int
}

public struct S3ErrorBody: Sendable, Hashable {
    public var code: String
    public var message: String
}

enum S3XML {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    static func unquote(_ etag: String?) -> String? {
        guard var e = etag?.trimmingCharacters(in: .whitespaces) else { return nil }
        if e.hasPrefix("W/") { e.removeFirst(2) }
        if e.hasPrefix("\""), e.hasSuffix("\""), e.count >= 2 { e = String(e.dropFirst().dropLast()) }
        if e.hasPrefix("&quot;") { e = e.replacingOccurrences(of: "&quot;", with: "") }
        return e
    }

    static func listPage(_ data: Data) -> S3ListPage? {
        guard let root = XMLTreeBuilder.parse(data), root.name == "ListBucketResult" else { return nil }
        let objects = root.all("Contents").compactMap { c -> S3Object? in
            guard let key = c.string("Key") else { return nil }
            return S3Object(key: key, size: Int64(c.string("Size") ?? "") ?? 0, lastModified: date(c.string("LastModified")), etag: unquote(c.string("ETag")))
        }
        let prefixes = root.all("CommonPrefixes").compactMap { $0.string("Prefix") }
        let truncated = root.string("IsTruncated")?.lowercased() == "true"
        let token = root.string("NextContinuationToken").flatMap { $0.isEmpty ? nil : $0 }
        let count = Int(root.string("KeyCount") ?? "") ?? (objects.count + prefixes.count)
        return S3ListPage(objects: objects, commonPrefixes: prefixes, isTruncated: truncated, nextContinuationToken: token, keyCount: count)
    }

    static func error(_ data: Data) -> S3ErrorBody? {
        guard let root = XMLTreeBuilder.parse(data), root.name == "Error" else { return nil }
        return S3ErrorBody(code: root.string("Code") ?? "Unknown", message: root.string("Message") ?? "")
    }

    static func uploadID(_ data: Data) -> String? {
        guard let root = XMLTreeBuilder.parse(data), root.name == "InitiateMultipartUploadResult" else { return nil }
        return root.string("UploadId")
    }

    static func completeETag(_ data: Data) -> String? {
        guard let root = XMLTreeBuilder.parse(data), root.name == "CompleteMultipartUploadResult" else { return nil }
        return unquote(root.string("ETag"))
    }

    static func copyETag(_ data: Data) -> String? {
        guard let root = XMLTreeBuilder.parse(data), root.name == "CopyObjectResult" else { return nil }
        return unquote(root.string("ETag"))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func completeBody(_ parts: [(Int, String)]) -> Data {
        var s = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for (n, etag) in parts { s += "<Part><PartNumber>\(n)</PartNumber><ETag>\"\(escape(etag))\"</ETag></Part>" }
        s += "</CompleteMultipartUpload>"
        return Data(s.utf8)
    }
}
