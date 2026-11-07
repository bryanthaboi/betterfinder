import CryptoKit
import Foundation

public struct FileDigest: Sendable, Hashable {
    public let size: Int64
    public let sha256: String
    public let md5: String

    public static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    public static func md5Hex(_ data: Data) -> String { hex(Insecure.MD5.hash(data: data)) }
    public static func md5Base64(_ data: Data) -> String { Data(Insecure.MD5.hash(data: data)).base64EncodedString() }

    public static func compute(_ url: URL, chunkSize: Int = 4 << 20, cancellation: (() throws -> Void)? = nil) throws -> FileDigest {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var size: Int64 = 0
        while true {
            try cancellation?()
            let chunk = try autoreleasepool { try h.read(upToCount: chunkSize) ?? Data() }
            if chunk.isEmpty { break }
            sha.update(data: chunk)
            md5.update(data: chunk)
            size += Int64(chunk.count)
        }
        return FileDigest(size: size, sha256: hex(sha.finalize()), md5: hex(md5.finalize()))
    }

    public static func computeAsync(_ url: URL) async throws -> FileDigest {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<FileDigest, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do { c.resume(returning: try compute(url)) } catch { c.resume(throwing: error) }
            }
        }
    }
}
