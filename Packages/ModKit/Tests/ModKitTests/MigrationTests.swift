import XCTest
@testable import ModKit

final class MigrationTests: XCTestCase {
    func testNewCodesExistWithStableValues() {
        let expected: [(ModDiagnosticCode, String)] = [
            (.tsTypeError, "BF8001"), (.tsSyntaxError, "BF8002"), (.scriptPolicyViolation, "BF8003"), (.dynamicCatalogAccess, "BF8004"),
            (.dryRunFailure, "BF8005"), (.dryRunTimeout, "BF8006"), (.dryRunCrash, "BF8007"),
            (.archivePathTraversal, "BF5030"), (.archiveSymlink, "BF5031"), (.archiveDeviceEntry, "BF5032"), (.archiveExecutableBit, "BF5033"),
            (.archiveBombRatio, "BF5034"), (.archiveSizeCap, "BF5035"), (.archiveDuplicateEntry, "BF5036"), (.archiveEncrypted, "BF5037"),
            (.archiveZip64Unsupported, "BF5038"), (.archiveNameMismatch, "BF5039"),
        ]
        for (code, raw) in expected {
            XCTAssertEqual(code.rawValue, raw)
            XCTAssertEqual(ModDiagnosticCode(rawValue: raw), code)
            XCTAssertEqual(code.defaultSeverity, .error)
            XCTAssertFalse(code.title.isEmpty)
        }
        XCTAssertEqual(ModDiagnosticCode(rawValue: "BF5001"), .forbiddenFileType)
        XCTAssertEqual(ModDiagnosticCode(rawValue: "BF9002"), .checkNotRun)
    }

    func testArchiveMapping() {
        func m(_ c: ModDiagnosticCode, _ msg: String) -> ModDiagnosticCode { .legacyMapping(c, context: .archive, message: msg) }
        XCTAssertEqual(m(.pathNotContained, "archive entry '../x' is not a contained relative path"), .archivePathTraversal)
        XCTAssertEqual(m(.pathNotContained, "an archive entry name is not valid UTF-8"), .archivePathTraversal)
        XCTAssertEqual(m(.duplicatePath, "archive contains 'a' more than once"), .archiveDuplicateEntry)
        XCTAssertEqual(m(.forbiddenFileType, "'a' is a symbolic link"), .archiveSymlink)
        XCTAssertEqual(m(.forbiddenFileType, "'a' has an executable permission bit"), .archiveExecutableBit)
        XCTAssertEqual(m(.forbiddenFileType, "'a' is a device, socket or FIFO"), .archiveDeviceEntry)
        XCTAssertEqual(m(.forbiddenFileType, "'a' is encrypted"), .archiveEncrypted)
        XCTAssertEqual(m(.forbiddenFileType, "'a' uses unsupported compression method 9"), .forbiddenFileType)
        XCTAssertEqual(m(.invalidValue, "zip64 archives are not supported"), .archiveZip64Unsupported)
        XCTAssertEqual(m(.invalidValue, "zip64 entries are not supported (a)"), .archiveZip64Unsupported)
        XCTAssertEqual(m(.invalidValue, "'a' local header name differs from the central directory"), .archiveNameMismatch)
        XCTAssertEqual(m(.packageTooLarge, "'a' expands 500:1; limit is 100:1 (expansion bomb?)"), .archiveBombRatio)
        XCTAssertEqual(m(.packageTooLarge, "archive entries 'a' and 'b' overlap (zip quine / bomb)"), .archiveBombRatio)
        XCTAssertEqual(m(.packageTooLarge, "archive is 99 bytes; limit is 10"), .archiveSizeCap)
        XCTAssertEqual(m(.packageTooLarge, "archive expands to more than 5 bytes (expansion bomb?)"), .archiveSizeCap)
        XCTAssertEqual(m(.invalidValue, "zip central directory is corrupt"), .invalidValue)
    }

    func testTypeScriptMapping() {
        func m(_ c: ModDiagnosticCode, _ ts: Int) -> ModDiagnosticCode { .legacyMapping(c, context: .typeScript(code: ts)) }
        XCTAssertEqual(m(.unknownConstruct, 90002), .scriptPolicyViolation)
        XCTAssertEqual(m(.unknownReference, 90003), .scriptPolicyViolation)
        XCTAssertEqual(m(.missingHandlerFunction, 90004), .missingHandlerFunction)
        XCTAssertEqual(m(.entryInvalid, 90001), .entryInvalid)
        XCTAssertEqual(m(.malformedProgram, 1005), .tsSyntaxError)
        XCTAssertEqual(m(.typeMismatch, 2322), .tsTypeError)
        XCTAssertEqual(m(.unknownVariable, 2304), .unknownVariable)
    }

    func testCatalogAndDryRunMapping() {
        XCTAssertEqual(ModDiagnosticCode.legacyMapping(.unknownConstruct, context: .catalogAnalysis), .dynamicCatalogAccess)
        XCTAssertEqual(ModDiagnosticCode.legacyMapping(.typeMismatch, context: .catalogAnalysis), .typeMismatch)
        func d(_ msg: String) -> ModDiagnosticCode { .legacyMapping(.checkNotRun, context: .dryRun, message: msg) }
        XCTAssertEqual(d("dry run: run (command.run) failed: deadline: took too long"), .dryRunTimeout)
        XCTAssertEqual(d("dry run: check host did not start"), .dryRunCrash)
        XCTAssertEqual(d("dry run: check host failed to start: boom"), .dryRunCrash)
        XCTAssertEqual(d("dry run: run returned an invalid result"), .dryRunFailure)
        XCTAssertEqual(ModDiagnosticCode.legacyMapping(.typeMismatch, context: .dryRun), .typeMismatch)
    }

    func testDiagnosticMigratedKeepsOtherFields() {
        let old = ModDiagnostic(.checkNotRun, severity: .error, file: "a.js", message: "dry run: failed")
        let new = old.migrated(.dryRun)
        XCTAssertEqual(new.code, .dryRunFailure)
        XCTAssertEqual(new.severity, .error)
        XCTAssertEqual(new.file, "a.js")
        let info = ModDiagnostic(.checkNotRun, message: "dry run: timed out").migrated(.dryRun)
        XCTAssertEqual(info.code, .dryRunTimeout)
        XCTAssertEqual(info.severity, .error)
    }

    func testReceiptArchiveHashIsAdditive() throws {
        let r = PreflightReceipt(treeHash: String(repeating: "a", count: 64), checks: [:], diagnostics: [])
        XCTAssertNil(r.archiveSHA256)
        XCTAssertFalse(String(decoding: r.modKitJSON(), as: UTF8.self).contains("archiveSHA256"))
        var withHash = PreflightReceipt(treeHash: r.treeHash, checks: [:], diagnostics: [], archiveSHA256: String(repeating: "b", count: 64))
        XCTAssertEqual(try JSONDecoder().decode(PreflightReceipt.self, from: withHash.modKitJSON()), withHash)
        XCTAssertEqual(withHash.merging(check: .schema, status: .pass, diagnostics: []).archiveSHA256, withHash.archiveSHA256)
        XCTAssertEqual(try JSONDecoder().decode(PreflightReceipt.self, from: r.modKitJSON()), r)
        withHash.archiveSHA256 = nil
        XCTAssertEqual(withHash, r)
    }

    func testIndexListingMemberwiseInit() throws {
        let data = try XCTUnwrap(ModExamples.indexListingExample)
        guard case .success(let decoded) = ModIndexListing.decode(data) else { return XCTFail() }
        let built = ModIndexListing(
            id: decoded.id, title: decoded.title, author: decoded.author, version: decoded.version, api: decoded.api, app: decoded.app,
            categories: decoded.categories, repo: decoded.repo, release: decoded.release, permissions: decoded.permissions,
            summary: decoded.summary, tags: decoded.tags, thumbnail: decoded.thumbnail
        )
        XCTAssertEqual(built, decoded)
        XCTAssertEqual(built.signedPayload, decoded.signedPayload)
    }
}
