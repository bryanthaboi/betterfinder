import FSCore
import XCTest
@testable import Remote

final class RegressionSFTPReplaceTests: XCTestCase {
    var fx: SFTPFixture!
    var local: URL!

    override func setUpWithError() throws {
        fx = try SFTPFixture()
        try Data("original contents".utf8).write(to: fx.home.appendingPathComponent("doc.txt"))
        local = fx.dir.appendingPathComponent("replacement.txt")
        try Data("replacement".utf8).write(to: local)
    }

    override func tearDown() {
        fx?.cleanup()
        super.tearDown()
    }

    var remoteText: String? { try? String(contentsOf: fx.home.appendingPathComponent("doc.txt"), encoding: .utf8) }
    var leftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: fx.home.path)) ?? []).filter { $0.hasPrefix(".bfpart-") || $0.hasPrefix(".bfold-") } }

    func replace() async throws -> ResourceItem {
        let p = fx.provider()
        let root = try await p.resolveRoot()
        return try await p.upload(from: local, to: root.appending("doc.txt"), options: .init(overwrite: true), progress: { _ in })
    }

    func testReplaceNeverRemovesTheOriginalBeforeCommitting() async throws {
        let item = try await replace()
        XCTAssertEqual(item.size, 11)
        XCTAssertEqual(remoteText, "replacement")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        XCTAssertFalse(fx.logLines.contains { $0.hasPrefix("CMD rm /home/tester/doc.txt") || $0.hasPrefix("CMD -rm /home/tester/doc.txt") })
    }

    func testLegacyRenameServerReplacesThroughABackup() async throws {
        fx.env["FAKE_SFTP_LEGACY_RENAME"] = "1"
        _ = try await replace()
        XCTAssertEqual(remoteText, "replacement")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        let renames = fx.logLines.filter { $0.hasPrefix("CMD rename") }
        XCTAssertTrue(renames.contains { $0.contains("/home/tester/doc.txt /home/tester/.bfold-") }, "\(renames)")
    }

    func testFailedCommitRestoresTheOriginal() async throws {
        for legacy in ["0", "1"] {
            try Data("original contents".utf8).write(to: fx.home.appendingPathComponent("doc.txt"))
            fx.env["FAKE_SFTP_LEGACY_RENAME"] = legacy
            fx.env["FAKE_SFTP_FAIL_CMD"] = "^rename [^ ]*bfpart"
            do {
                _ = try await replace()
                XCTFail("expected the commit to fail")
            } catch let e as ResourceError {
                if case .remote(let code, _) = e { XCTAssertNotEqual(code, "ReplaceIncomplete") }
            }
            XCTAssertEqual(remoteText, "original contents", "legacy=\(legacy)")
            XCTAssertTrue(leftovers.isEmpty, "legacy=\(legacy) \(leftovers)")
        }
    }

    func testDisconnectWhileCommittingRestoresTheOriginal() async throws {
        fx.env["FAKE_SFTP_DROP_CMD"] = "^rename [^ ]*bfpart"
        do {
            _ = try await replace()
            XCTFail("expected the disconnect to surface")
        } catch ResourceError.connectionFailed {}
        XCTAssertEqual(remoteText, "original contents")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testDisconnectAfterBackupOnLegacyServerRestoresTheOriginal() async throws {
        fx.env["FAKE_SFTP_LEGACY_RENAME"] = "1"
        fx.env["FAKE_SFTP_DROP_CMD"] = "^rename [^ ]*bfpart"
        do {
            _ = try await replace()
            XCTFail("expected the disconnect to surface")
        } catch {}
        XCTAssertEqual(remoteText, "original contents")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testFailedRestoreKeepsTheBackupAndSaysWhere() async throws {
        fx.env["FAKE_SFTP_FAIL_CMD"] = "^rename [^ ]*(bfpart|bfold)"
        do {
            _ = try await replace()
            XCTFail("expected failure")
        } catch ResourceError.remote(let code, let message) {
            XCTAssertEqual(code, "ReplaceIncomplete")
            XCTAssertTrue(message.contains(".bfold-"), message)
        }
        let kept = try XCTUnwrap(leftovers.first { $0.hasPrefix(".bfold-") })
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(kept), encoding: .utf8), "original contents")
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".bfpart-") })
    }

    func testFailedUploadLeavesTheOriginalUntouched() async throws {
        fx.env["FAKE_SFTP_FAIL_CMD"] = "^put "
        do {
            _ = try await replace()
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(remoteText, "original contents")
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        XCTAssertFalse(fx.logLines.contains { $0.hasPrefix("CMD rename") })
    }
}
