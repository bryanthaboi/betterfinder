import XCTest
import ModKit
@testable import ModValidation

final class RegressionValidatorIdleTests: XCTestCase {
    func mod(_ id: String) -> URL {
        Support.scaffold(.command, .ts, id: id)
    }

    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func testCompilerUnloadsAfterIdleAndReloadsForNextCheck() async {
        let v = ModValidator()
        v.idleUnloadInterval = 0.2
        let a = await v.run(.directory(mod("alice.idle-one")))
        XCTAssertEqual(a.receipt[.compile], .pass, "\(a.receipt.diagnostics)")
        XCTAssertTrue(waitUntil(5) { !v.isCompilerLoaded })
        let b = await v.run(.directory(mod("alice.idle-two")))
        XCTAssertEqual(b.receipt[.compile], .pass, "\(b.receipt.diagnostics)")
        XCTAssertTrue(waitUntil(5) { !v.isCompilerLoaded })
    }

    func testConcurrentChecksShareCompilerAndReleaseAfterBoth() async {
        let v = ModValidator()
        v.idleUnloadInterval = 0.2
        let dirs = [mod("alice.par-one"), mod("alice.par-two"), mod("alice.par-three")]
        let results = await withTaskGroup(of: ModValidationResult.self) { group in
            for d in dirs { group.addTask { await v.run(.directory(d)) } }
            var out = [ModValidationResult]()
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.count, 3)
        for r in results { XCTAssertEqual(r.receipt[.compile], .pass, "\(r.receipt.diagnostics)") }
        XCTAssertTrue(waitUntil(5) { !v.isCompilerLoaded })
    }

    func testManualReleaseWhenIdle() async {
        let v = ModValidator()
        v.idleUnloadInterval = .infinity
        let r = await v.run(.directory(mod("alice.manual")))
        XCTAssertEqual(r.receipt[.compile], .pass, "\(r.receipt.diagnostics)")
        XCTAssertTrue(v.isCompilerLoaded)
        XCTAssertTrue(v.releaseCompilerIfIdle())
        XCTAssertFalse(v.isCompilerLoaded)
        XCTAssertFalse(v.releaseCompilerIfIdle())
    }
}
