import Foundation
import ModHost
import ModHostProtocol
import XCTest
@testable import AppBridge

final class RegressionGracefulTransportTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var m = 0
        private var c: [ModHostTransportClose] = []
        var messages: Int { lock.withLock { m } }
        var closes: [ModHostTransportClose] { lock.withLock { c } }
        func message() { lock.withLock { m += 1 } }
        func close(_ r: ModHostTransportClose) { lock.withLock { c.append(r) } }
    }

    func testGracefulTransportIsSharedLifecycleConfiguration() {
        let t = GracefulXPCModHostTransport(serviceName: "com.bryanthaboi.betterfinder.modcheck.missing", serviceRequirement: nil, killGrace: 3)
        XCTAssertTrue((t as AnyObject) is XPCModHostTransport)
        XCTAssertEqual(t.termination, .graceful(3))
        XCTAssertEqual(t.killGrace, 3)
        XCTAssertTrue(t.isolatesProcess)
    }

    func testMissingServiceClosesOnceRecordsSpawnAndDropsLateMessages() throws {
        let gate = ModCheckGate()
        XCTAssertEqual(gate.remaining, 0)
        let t = GracefulXPCModHostTransport(serviceName: "com.bryanthaboi.betterfinder.modcheck.missing", serviceRequirement: nil, killGrace: 0.05, gate: gate)
        let rec = Recorder()
        let closed = expectation(description: "closed")
        closed.assertForOverFulfill = false
        try t.start(onMessage: { _ in rec.message() }, onClose: { reason in
            rec.close(reason)
            closed.fulfill()
        })
        XCTAssertGreaterThan(gate.remaining, 0)
        wait(for: [closed], timeout: 5)
        let late = try ModHostWire.encode(ModHostToApp.pong(1, ModHostStats(residentBytes: 0, footprintBytes: 0, loadedMods: 0, activeInvocations: 0)))
        t.deliver(late)
        t.terminate()
        t.terminate()
        XCTAssertEqual(rec.messages, 0)
        XCTAssertEqual(rec.closes.count, 1)
        if case .invalidated = rec.closes.first {} else { XCTFail("\(rec.closes)") }
        XCTAssertTrue(t.isClosed)
    }

    func testFactoryMakesGracefulTransport() throws {
        let made = try GracefulXPCModHostTransportFactory(serviceName: "com.bryanthaboi.betterfinder.modcheck.missing").makeTransport()
        let graceful = try XCTUnwrap(made as? GracefulXPCModHostTransport)
        XCTAssertEqual(graceful.termination, .graceful(2))
    }
}
