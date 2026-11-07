import Compression
import Foundation
import ModKit

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

public struct ZipLimits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxTotalBytes: Int
    public var maxEntryBytes: Int
    public var maxArchiveBytes: Int
    public var maxExpansionRatio: Int
    public var ratioFloorBytes: Int

    public init(maxEntries: Int, maxTotalBytes: Int, maxEntryBytes: Int, maxArchiveBytes: Int, maxExpansionRatio: Int = 100, ratioFloorBytes: Int = 1 << 20) {
        self.maxEntries = maxEntries; self.maxTotalBytes = maxTotalBytes; self.maxEntryBytes = maxEntryBytes
        self.maxArchiveBytes = maxArchiveBytes; self.maxExpansionRatio = maxExpansionRatio; self.ratioFloorBytes = ratioFloorBytes
    }

    public init(catalog limits: ModCatalogLimits) {
        self.init(
            maxEntries: limits.maxPackageFiles, maxTotalBytes: limits.maxPackageBytes, maxEntryBytes: limits.maxPackageBytes,
            maxArchiveBytes: limits.maxPackageBytes + (1 << 20)
        )
    }
}

public struct ZipExtraction: Sendable {
    public var files: [String: Data] = [:]
    public var diagnostics: [ModDiagnostic] = []
    public var fatal = false
}

enum ZipFormat {
    static let localSignature: UInt32 = 0x0403_4B50
    static let centralSignature: UInt32 = 0x0201_4B50
    static let endSignature: UInt32 = 0x0605_4B50
}

private struct ZipEntry {
    var name: String
    var displayName: String
    var method: Int
    var flags: Int
    var crc: UInt32
    var compressedSize: Int
    var uncompressedSize: Int
    var dataStart: Int
    var isDirectory: Bool
}

enum ZipReader {
    static func extract(_ data: Data, limits: ZipLimits, archiveName: String? = nil) -> ZipExtraction {
        var out = ZipExtraction()
        let archive = archiveName
        func fail(_ code: ModDiagnosticCode, _ message: String, file: String? = nil, fix: String? = nil) {
            out.diagnostics.append(ModDiagnostic(code, file: file ?? archive, message: message, fix: fix))
        }
        func fatal(_ code: ModDiagnosticCode, _ message: String, fix: String? = nil) {
            fail(code, message, fix: fix)
            out.fatal = true
        }

        if data.count > limits.maxArchiveBytes {
            fatal(.packageTooLarge, "archive is \(data.count) bytes; limit is \(limits.maxArchiveBytes)")
            return out
        }
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }

        guard b.count >= 22 else {
            fatal(.invalidValue, "not a zip archive: file is shorter than an end-of-central-directory record")
            return out
        }
        var eocd = -1
        var pos = b.count - 22
        let lowest = max(0, b.count - 22 - 65535)
        while pos >= lowest {
            if u32(pos) == ZipFormat.endSignature, pos + 22 + u16(pos + 20) <= b.count { eocd = pos; break }
            pos -= 1
        }
        guard eocd >= 0 else {
            fatal(.invalidValue, "not a zip archive: no end-of-central-directory record")
            return out
        }
        let diskNumber = u16(eocd + 4), cdDisk = u16(eocd + 6)
        let entriesOnDisk = u16(eocd + 8), entryCount = u16(eocd + 10)
        let cdSize = Int(u32(eocd + 12)), cdOffset = Int(u32(eocd + 16))
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            fatal(.invalidValue, "zip64 archives are not supported", fix: "Create the archive with `betterfinder-mod package`")
            return out
        }
        guard diskNumber == 0, cdDisk == 0, entriesOnDisk == entryCount else {
            fatal(.invalidValue, "multi-disk zip archives are not supported")
            return out
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= eocd else {
            fatal(.invalidValue, "zip central directory lies outside the archive")
            return out
        }
        if entryCount > limits.maxEntries {
            fatal(.packageTooLarge, "archive lists \(entryCount) entries; limit is \(limits.maxEntries)")
            return out
        }

        var entries = [ZipEntry]()
        var cursor = cdOffset
        var declaredTotal = 0
        var seenNames = Set<String>()
        var spans = [(Int, Int, String)]()
        for _ in 0..<entryCount {
            guard cursor + 46 <= cdOffset + cdSize, u32(cursor) == ZipFormat.centralSignature else {
                fatal(.invalidValue, "zip central directory is corrupt")
                return out
            }
            let madeBy = u16(cursor + 4)
            let flags = u16(cursor + 8)
            let method = u16(cursor + 10)
            let crc = u32(cursor + 16)
            let csize = Int(u32(cursor + 20)), usize = Int(u32(cursor + 24))
            let nameLen = u16(cursor + 28), extraLen = u16(cursor + 30), commentLen = u16(cursor + 32)
            let externalAttrs = u32(cursor + 38)
            let localOffset = Int(u32(cursor + 42))
            let next = cursor + 46 + nameLen + extraLen + commentLen
            guard next <= cdOffset + cdSize else {
                fatal(.invalidValue, "zip central directory entry overruns the directory")
                return out
            }
            let nameBytes = Array(b[(cursor + 46)..<(cursor + 46 + nameLen)])
            cursor = next
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                fail(.pathNotContained, "an archive entry name is not valid UTF-8")
                continue
            }
            let shown = display(name)
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                fatal(.invalidValue, "zip64 entries are not supported (\(shown))")
                return out
            }
            if name.hasSuffix("/") { continue }
            if isIgnored(name) { continue }
            if !ModPatterns.matches(name, ModPatterns.relativePath) {
                fail(.pathNotContained, "archive entry '\(shown)' is not a contained relative path", file: shown, fix: "Archive entries must be relative paths without '..', absolute roots or backslashes")
                continue
            }
            if !seenNames.insert(name).inserted {
                fail(.duplicatePath, "archive contains '\(shown)' more than once", file: shown)
                continue
            }
            if madeBy >> 8 == 3 {
                let mode = Int(externalAttrs >> 16)
                switch mode & 0o170000 {
                case 0o120000:
                    fail(.forbiddenFileType, "'\(shown)' is a symbolic link", file: shown, fix: "Replace the link with a regular file")
                    continue
                case 0, 0o100000:
                    if mode & 0o111 != 0 {
                        fail(.forbiddenFileType, "'\(shown)' has an executable permission bit", file: shown, fix: "chmod a-x the file before packaging")
                        continue
                    }
                case 0o040000:
                    continue
                default:
                    fail(.forbiddenFileType, "'\(shown)' is a device, socket or FIFO", file: shown)
                    continue
                }
            }
            if let forbidden = PackageInventory.forbiddenDiagnostic(path: name) {
                out.diagnostics.append(forbidden)
                continue
            }
            if flags & 0x1 != 0 || flags & 0x40 != 0 {
                fail(.forbiddenFileType, "'\(shown)' is encrypted", file: shown)
                continue
            }
            guard method == 0 || method == 8 else {
                fail(.forbiddenFileType, "'\(shown)' uses unsupported compression method \(method)", file: shown, fix: "Use stored or deflate")
                continue
            }
            if method == 0, csize != usize {
                fail(.invalidValue, "'\(shown)' is stored but its compressed and uncompressed sizes differ", file: shown)
                continue
            }
            if usize > limits.maxEntryBytes {
                fatal(.packageTooLarge, "'\(shown)' declares \(usize) bytes; limit is \(limits.maxEntryBytes) (expansion bomb?)")
                return out
            }
            declaredTotal += usize
            if declaredTotal > limits.maxTotalBytes {
                fatal(.packageTooLarge, "archive expands to more than \(limits.maxTotalBytes) bytes (expansion bomb?)")
                return out
            }
            if usize > limits.ratioFloorBytes, usize / max(csize, 1) > limits.maxExpansionRatio {
                fatal(.packageTooLarge, "'\(shown)' expands \(usize / max(csize, 1)):1; limit is \(limits.maxExpansionRatio):1 (expansion bomb?)")
                return out
            }
            guard localOffset >= 0, localOffset + 30 <= cdOffset, u32(localOffset) == ZipFormat.localSignature else {
                fatal(.invalidValue, "'\(shown)' has an invalid local header")
                return out
            }
            let localNameLen = u16(localOffset + 26), localExtraLen = u16(localOffset + 28)
            let localName = Array(b[(localOffset + 30)..<min(b.count, localOffset + 30 + localNameLen)])
            guard localNameLen == nameLen, localName == nameBytes else {
                fatal(.invalidValue, "'\(shown)' local header name differs from the central directory")
                return out
            }
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart >= 0, dataStart + csize <= cdOffset else {
                fatal(.invalidValue, "'\(shown)' data lies outside the archive")
                return out
            }
            spans.append((localOffset, dataStart + csize, shown))
            entries.append(ZipEntry(name: name, displayName: shown, method: method, flags: flags, crc: crc, compressedSize: csize, uncompressedSize: usize, dataStart: dataStart, isDirectory: false))
        }

        spans.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        for i in spans.indices.dropFirst() where spans[i].0 < spans[i - 1].1 {
            fatal(.packageTooLarge, "archive entries '\(spans[i - 1].2)' and '\(spans[i].2)' overlap (zip quine / bomb)")
            return out
        }

        for e in entries {
            let slice = b[e.dataStart..<(e.dataStart + e.compressedSize)]
            var content: Data
            if e.method == 0 {
                content = Data(slice)
            } else {
                switch Deflate.inflate(slice, cap: e.uncompressedSize) {
                case .success(let d): content = d
                case .failure(let err):
                    switch err {
                    case .exceedsCap:
                        fatal(.packageTooLarge, "'\(e.displayName)' expands beyond its declared \(e.uncompressedSize) bytes (expansion bomb)")
                        return out
                    case .corrupt:
                        fail(.invalidValue, "'\(e.displayName)' has a corrupt deflate stream", file: e.displayName)
                        continue
                    }
                }
            }
            guard content.count == e.uncompressedSize else {
                fail(.invalidValue, "'\(e.displayName)' is \(content.count) bytes but declares \(e.uncompressedSize)", file: e.displayName)
                continue
            }
            guard CRC32.checksum(content) == e.crc else {
                fail(.invalidValue, "'\(e.displayName)' fails its CRC-32 check", file: e.displayName)
                continue
            }
            out.files[e.name] = content
        }
        return out
    }

    static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix("__MACOSX/") || name == ".DS_Store" || name.hasSuffix("/.DS_Store")
    }

    static func display(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "?" : Character($0) })
        return cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
    }
}

enum Deflate {
    enum Failure: Error { case exceedsCap, corrupt }

    private static let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

    private static func makeStream() -> UnsafeMutablePointer<compression_stream> {
        let state = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        state.initialize(to: compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: UnsafePointer(placeholder), src_size: 0, state: nil))
        return state
    }

    static func inflate(_ input: ArraySlice<UInt8>, cap: Int) -> Result<Data, Failure> {
        let state = makeStream()
        defer { state.deallocate() }
        guard compression_stream_init(state, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { return .failure(.corrupt) }
        defer { compression_stream_destroy(state) }

        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var result = Data()
        var failure: Failure?
        input.withUnsafeBufferPointer { buffer in
            var fallback = UInt8(0)
            withUnsafePointer(to: &fallback) { dummy in
                state.pointee.src_ptr = buffer.baseAddress ?? dummy
                state.pointee.src_size = buffer.count
                while true {
                    state.pointee.dst_ptr = dst
                    state.pointee.dst_size = chunk
                    let before = state.pointee.src_size
                    let status = compression_stream_process(state, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = chunk - state.pointee.dst_size
                    if produced > 0 {
                        if result.count + produced > cap { failure = .exceedsCap; return }
                        result.append(dst, count: produced)
                    }
                    if status == COMPRESSION_STATUS_END { return }
                    if status == COMPRESSION_STATUS_ERROR { failure = .corrupt; return }
                    if produced == 0, state.pointee.src_size == before { failure = .corrupt; return }
                }
            }
        }
        if let failure { return .failure(failure) }
        return .success(result)
    }

    static func deflate(_ input: Data) -> Data? {
        let state = makeStream()
        defer { state.deallocate() }
        guard compression_stream_init(state, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(state) }
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var result = Data()
        var ok = true
        let bytes = [UInt8](input)
        bytes.withUnsafeBufferPointer { buffer in
            var fallback = UInt8(0)
            withUnsafePointer(to: &fallback) { dummy in
                state.pointee.src_ptr = buffer.baseAddress ?? dummy
                state.pointee.src_size = buffer.count
                while true {
                    state.pointee.dst_ptr = dst
                    state.pointee.dst_size = chunk
                    let status = compression_stream_process(state, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = chunk - state.pointee.dst_size
                    if produced > 0 { result.append(dst, count: produced) }
                    if status == COMPRESSION_STATUS_END { return }
                    if status == COMPRESSION_STATUS_ERROR { ok = false; return }
                }
            }
        }
        return ok ? result : nil
    }
}

struct ZipEntrySpec {
    var name: String
    var data: Data
    var compress = false
    var mode: UInt32 = 0o100644
    var madeByUnix = true
    var declaredUncompressedSize: UInt32?
    var declaredCompressedSize: UInt32?
    var rawData: Data?
    var localName: String?
    var flags: UInt16 = 0x0800
    var methodOverride: UInt16?
    var crcOverride: UInt32?
}

enum ZipWriter {
    static func build(_ files: [(path: String, data: Data)], compress: Bool = false) -> Data {
        let sorted = files.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        return build(entries: sorted.map { ZipEntrySpec(name: $0.path, data: $0.data, compress: compress) })
    }

    static func build(entries: [ZipEntrySpec], trailingComment: Data = Data()) -> Data {
        var out = Data()
        var central = Data()
        func put16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        func put32(_ d: inout Data, _ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for e in entries {
            let nameBytes = Data(e.name.utf8)
            let localNameBytes = Data((e.localName ?? e.name).utf8)
            let payload: Data
            var method: UInt16 = 0
            if let raw = e.rawData {
                payload = raw
                method = e.methodOverride ?? 0
            } else if e.compress, let z = Deflate.deflate(e.data) {
                payload = z
                method = 8
            } else {
                payload = e.data
                method = e.methodOverride ?? 0
            }
            let crc = e.crcOverride ?? CRC32.checksum(e.data)
            let csize = e.declaredCompressedSize ?? UInt32(payload.count)
            let usize = e.declaredUncompressedSize ?? UInt32(e.data.count)
            let offset = UInt32(out.count)
            put32(&out, ZipFormat.localSignature)
            put16(&out, 20); put16(&out, e.flags); put16(&out, method); put16(&out, 0); put16(&out, 0x0021)
            put32(&out, crc); put32(&out, csize); put32(&out, usize)
            put16(&out, UInt16(localNameBytes.count)); put16(&out, 0)
            out.append(localNameBytes)
            out.append(payload)
            put32(&central, ZipFormat.centralSignature)
            put16(&central, e.madeByUnix ? (3 << 8) | 20 : 20); put16(&central, 20); put16(&central, e.flags); put16(&central, method)
            put16(&central, 0); put16(&central, 0x0021)
            put32(&central, crc); put32(&central, csize); put32(&central, usize)
            put16(&central, UInt16(nameBytes.count)); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
            put32(&central, e.madeByUnix ? e.mode << 16 : 0)
            put32(&central, offset)
            central.append(nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        put32(&out, ZipFormat.endSignature)
        put16(&out, 0); put16(&out, 0)
        put16(&out, UInt16(entries.count)); put16(&out, UInt16(entries.count))
        put32(&out, UInt32(central.count)); put32(&out, cdOffset)
        put16(&out, UInt16(trailingComment.count))
        out.append(trailingComment)
        return out
    }
}
