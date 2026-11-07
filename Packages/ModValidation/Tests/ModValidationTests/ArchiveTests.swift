import XCTest
import ModKit
@testable import ModValidation

final class ArchiveTests: XCTestCase {
    var base: [(path: String, data: Data)] {
        let dir = Support.scaffold(.command, .bfscript)
        let pkg = PackageLoader.loadDirectory(dir)
        return pkg.files.map { ($0.key, $0.value) }
    }

    func entries(_ extra: [ZipEntrySpec] = [], dropping: Set<String> = []) -> [ZipEntrySpec] {
        base.filter { !dropping.contains($0.path) }.map { ZipEntrySpec(name: $0.path, data: $0.data) } + extra
    }

    func validate(_ specs: [ZipEntrySpec]) async -> ModValidationResult {
        await Support.run(.archiveData(ZipWriter.build(entries: specs), name: "test.bfmod"))
    }

    func testCleanArchiveValidatesStoredAndDeflated() async {
        for compress in [false, true] {
            let data = ZipWriter.build(base, compress: compress)
            let r = await Support.run(.archiveData(data, name: "ok.bfmod"))
            XCTAssertTrue(r.receipt.staticOK, "compress=\(compress): \(r.receipt.diagnostics)")
            XCTAssertEqual(r.archiveSHA256?.count, 64)
            XCTAssertEqual(r.archiveBytes, data.count)
        }
    }

    func testPathTraversalIsRejected() async {
        for name in ["../evil.json", "scripts/../../evil.json", "/abs/evil.json", "a//b.json", "back\\slash.json", "./x.json"] {
            let r = await validate(entries([ZipEntrySpec(name: name, data: Data("{}".utf8))]))
            XCTAssertTrue(Support.hasCode(r, .archivePathTraversal), "\(name): \(r.receipt.diagnostics)")
            XCTAssertFalse(r.receipt.staticOK, name)
            XCTAssertNil(r.package?.data(name), name)
        }
    }

    func testSymlinkDeviceAndExecutableEntriesAreRejected() async {
        var link = ZipEntrySpec(name: "scripts/link", data: Data("/etc/passwd".utf8))
        link.mode = 0o120755
        var device = ZipEntrySpec(name: "dev", data: Data())
        device.mode = 0o020644
        var exec = ZipEntrySpec(name: "tool.dat", data: Data("x".utf8))
        exec.mode = 0o100755
        for (spec, text, code) in [(link, "symbolic link", ModDiagnosticCode.archiveSymlink), (device, "device", .archiveDeviceEntry), (exec, "executable permission", .archiveExecutableBit)] {
            let r = await validate(entries([spec]))
            XCTAssertTrue(Support.hasCode(r, code, containing: text), "\(spec.name): \(r.receipt.diagnostics)")
            XCTAssertFalse(r.receipt.staticOK)
            XCTAssertNil(r.package?.data(spec.name))
        }
    }

    func testDuplicateAndCaseCollidingNames() async {
        let dup = await validate(entries([ZipEntrySpec(name: "manifest.json", data: Data("{}".utf8))]))
        XCTAssertTrue(Support.hasCode(dup, .archiveDuplicateEntry, containing: "more than once"))
        let collide = await validate(entries([ZipEntrySpec(name: "Manifest.JSON", data: Data("{}".utf8))]))
        XCTAssertTrue(Support.hasCode(collide, .duplicatePath, containing: "collides"))
        XCTAssertFalse(collide.receipt.staticOK)
    }

    func testForbiddenFileTypesByExtensionAndContent() async {
        for name in ["bin/tool.dylib", "setup.sh", "inner.zip", "x.wasm", "payload.pkg"] {
            let r = await validate(entries([ZipEntrySpec(name: name, data: Data("abcd".utf8))]))
            XCTAssertTrue(Support.hasCode(r, .forbiddenFileType, containing: name), name)
        }
        let macho = Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])
        let r = await validate(entries([ZipEntrySpec(name: "assets/blob.dat", data: macho)]))
        XCTAssertTrue(Support.hasCode(r, .forbiddenFileType, containing: "executable payload"))
        let shebang = await validate(entries([ZipEntrySpec(name: "assets/run.txt", data: Data("#!/bin/sh\necho".utf8))]))
        XCTAssertTrue(Support.hasCode(shebang, .forbiddenFileType, containing: "executable payload"))
    }

    func testDeclaredSizeBombIsRejectedWithoutDecompressing() async {
        var bomb = ZipEntrySpec(name: "assets/zeros.bin", data: Data(), rawData: Data([0x03, 0x00]), methodOverride: 8)
        bomb.declaredUncompressedSize = 4_000_000_000
        bomb.declaredCompressedSize = 2
        let r = await validate(entries([bomb]))
        XCTAssertTrue(Support.hasCode(r, .archiveSizeCap, containing: "expansion bomb"), "\(r.receipt.diagnostics)")
        XCTAssertFalse(r.receipt.staticOK)
        XCTAssertNil(r.package)
    }

    func testStreamLongerThanDeclaredSizeIsRejected() async throws {
        let zeros = Data(count: 3_000_000)
        let z = try XCTUnwrap(Deflate.deflate(zeros))
        var liar = ZipEntrySpec(name: "assets/zeros.bin", data: Data(count: 10), rawData: z, methodOverride: 8)
        liar.declaredCompressedSize = UInt32(z.count)
        liar.declaredUncompressedSize = 10
        let r = await validate(entries([liar]))
        XCTAssertTrue(Support.hasCode(r, .archiveSizeCap, containing: "beyond its declared"), "\(r.receipt.diagnostics)")
        XCTAssertNil(r.package)
    }

    func testHighExpansionRatioIsRejected() async {
        let zeros = Data(count: 8 * 1024 * 1024)
        let r = await validate(entries([ZipEntrySpec(name: "assets/zeros.bin", data: zeros, compress: true)]))
        XCTAssertTrue(Support.hasCode(r, .archiveBombRatio, containing: "expands"), "\(r.receipt.diagnostics)")
        XCTAssertNil(r.package)
    }

    func testTooManyEntriesAndTotalSize() async {
        var many = [ZipEntrySpec]()
        for i in 0..<2100 { many.append(ZipEntrySpec(name: "f/\(i).txt", data: Data("x".utf8))) }
        let r = await validate(entries(many))
        XCTAssertTrue(Support.hasCode(r, .archiveSizeCap, containing: "entries"))
        let limits = ZipLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 100, maxArchiveBytes: 10_000)
        let ex = ZipReader.extract(ZipWriter.build([("a", Data(count: 60)), ("b", Data(count: 60))]), limits: limits)
        XCTAssertTrue(ex.fatal)
    }

    func testOverlappingEntriesAreRejected() async {
        let one = ZipWriter.build([("a.txt", Data("hello world hello world".utf8))])
        var bytes = [UInt8](one)
        let eocd = bytes.count - 22
        let cdOffset = Int(bytes[eocd + 16]) | Int(bytes[eocd + 17]) << 8 | Int(bytes[eocd + 18]) << 16
        var central = Array(bytes[cdOffset..<eocd])
        var second = central
        let nameLen = Int(central[28])
        second[46 + nameLen - 5] = UInt8(ascii: "b")
        central += second
        bytes.replaceSubrange(cdOffset..<eocd, with: central)
        let newEocd = cdOffset + central.count
        bytes[newEocd + 8] = 2
        bytes[newEocd + 10] = 2
        let size = central.count
        bytes[newEocd + 12] = UInt8(size & 0xFF); bytes[newEocd + 13] = UInt8(size >> 8)
        let ex = ZipReader.extract(Data(bytes), limits: ZipLimits(catalog: .v1))
        XCTAssertTrue(ex.fatal || ex.diagnostics.contains { $0.code == .invalidValue }, "\(ex.diagnostics)")
    }

    func testCentralAndLocalNameMismatchIsRejected() async {
        var spec = ZipEntrySpec(name: "good.txt", data: Data("x".utf8))
        spec.localName = "evil.txt"
        let ex = ZipReader.extract(ZipWriter.build(entries: [spec]), limits: ZipLimits(catalog: .v1))
        XCTAssertTrue(ex.fatal)
        XCTAssertTrue(ex.diagnostics.contains { $0.message.contains("local header name") })
    }

    func testEncryptedAndUnsupportedMethodsAndCRC() async {
        var enc = ZipEntrySpec(name: "secret.txt", data: Data("x".utf8))
        enc.flags = 0x0801
        var method = ZipEntrySpec(name: "m.txt", data: Data("x".utf8))
        method.methodOverride = 12
        var crc = ZipEntrySpec(name: "crc.txt", data: Data("x".utf8))
        crc.crcOverride = 1
        let r1 = await validate(entries([enc]))
        XCTAssertTrue(Support.hasCode(r1, .archiveEncrypted, containing: "encrypted"))
        let r2 = await validate(entries([method]))
        XCTAssertTrue(Support.hasCode(r2, .forbiddenFileType, containing: "compression method"))
        let r3 = await validate(entries([crc]))
        XCTAssertTrue(Support.hasCode(r3, .invalidValue, containing: "CRC"))
    }

    func testGarbageAndTruncatedArchives() async {
        let garbage = await Support.run(.archiveData(Data("not a zip at all, definitely not".utf8), name: "x.bfmod"))
        XCTAssertTrue(Support.hasCode(garbage, .invalidValue, containing: "not a zip"))
        XCTAssertFalse(garbage.receipt.ok)
        let full = ZipWriter.build(base)
        let cut = await Support.run(.archiveData(full.prefix(full.count / 2), name: "x.bfmod"))
        XCTAssertFalse(cut.receipt.staticOK)
        let empty = await Support.run(.archiveData(Data(), name: "x.bfmod"))
        XCTAssertFalse(empty.receipt.staticOK)
    }

    func testMacOSMetadataEntriesAreIgnored() async {
        let r = await validate(entries([
            ZipEntrySpec(name: "__MACOSX/._manifest.json", data: Data([0, 5, 22, 7])),
            ZipEntrySpec(name: ".DS_Store", data: Data([0, 0, 0, 1])),
            ZipEntrySpec(name: "scripts/.DS_Store", data: Data([0, 0, 0, 1])),
        ]))
        XCTAssertTrue(r.receipt.staticOK, "\(r.receipt.diagnostics)")
        XCTAssertNil(r.package?.data(".DS_Store"))
    }

    func testWrappedFolderGetsAHelpfulMissingManifest() async {
        let wrapped = base.map { ZipEntrySpec(name: "mymod/\($0.path)", data: $0.data) }
        let r = await validate(wrapped)
        XCTAssertTrue(Support.hasCode(r, .missingManifest))
    }

    func testPackageIsReproducibleAndOrderIndependent() {
        let a = ZipWriter.build(base)
        let b = ZipWriter.build(base.reversed())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, ZipWriter.build(base))
        let dir = Support.scaffold(.command, .bfscript)
        XCTAssertEqual(Support.archive(of: dir), Support.archive(of: dir))
    }

    func testDeflateRoundTripAndCapEnforcement() throws {
        let data = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let z = try XCTUnwrap(Deflate.deflate(data))
        if case .success(let out) = Deflate.inflate(ArraySlice([UInt8](z)), cap: data.count) { XCTAssertEqual(out, data) } else { XCTFail("inflate failed") }
        if case .failure(let f) = Deflate.inflate(ArraySlice([UInt8](z)), cap: 10) { XCTAssertEqual(f, .exceedsCap) } else { XCTFail("cap not enforced") }
        if case .failure(let f) = Deflate.inflate(ArraySlice<UInt8>([1, 2, 3, 4, 5]), cap: 100) { XCTAssertEqual(f, .corrupt) } else { XCTFail("garbage accepted") }
    }

    func testArchiveFileOnDiskAndMissingFile() async throws {
        let dir = Support.tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("x.bfmod")
        try ZipWriter.build(base).write(to: file)
        let r = await Support.run(.archive(file))
        XCTAssertTrue(r.receipt.staticOK, "\(r.receipt.diagnostics)")
        let missing = await Support.run(.archive(dir.appendingPathComponent("nope.bfmod")))
        XCTAssertFalse(missing.receipt.ok)
        XCTAssertTrue(missing.receipt.diagnostics.hasErrors)
    }
}
