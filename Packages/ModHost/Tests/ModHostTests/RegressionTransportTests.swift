import Foundation
import ModHostProtocol
import XCTest
@testable import ModHost

final class TransportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ModHostToApp] = []
    private var closes: [ModHostTransportClose] = []
    var messageCount: Int { lock.withLock { messages.count } }
    var closeReasons: [ModHostTransportClose] { lock.withLock { closes } }
    func message(_ m: ModHostToApp) { lock.withLock { messages.append(m) } }
    func close(_ r: ModHostTransportClose) { lock.withLock { closes.append(r) } }
}

final class RegressionTransportTests: XCTestCase {
    static let missing = "com.bryanthaboi.betterfinder.modhost.missing"
    let policies: [XPCModHostTermination] = [.immediate, .graceful(0.05)]

    func pong() throws -> Data {
        try ModHostWire.encode(ModHostToApp.pong(7, ModHostStats(residentBytes: 1, footprintBytes: 1, loadedMods: 0, activeInvocations: 0)))
    }

    func prepared(_ policy: XPCModHostTermination) -> (XPCModHostTransport, TransportRecorder) {
        let t = XPCModHostTransport(serviceName: Self.missing, serviceRequirement: nil, termination: policy, onSpawn: nil)
        let rec = TransportRecorder()
        XCTAssertTrue(t.prepare(connection: nil, onMessage: { rec.message($0) }, onClose: { rec.close($0) }))
        return (t, rec)
    }

    func testLateMessagesAreDroppedAfterInterruption() throws {
        for policy in policies {
            let (t, rec) = prepared(policy)
            t.deliver(try pong())
            XCTAssertEqual(rec.messageCount, 1, "\(policy)")
            t.connectionInterrupted()
            XCTAssertEqual(rec.closeReasons, [.invalidated("service interrupted")], "\(policy)")
            t.deliver(try pong())
            XCTAssertEqual(rec.messageCount, 1, "\(policy)")
            XCTAssertTrue(t.isClosed)
        }
    }

    func testRepeatedCloseReportsOnce() throws {
        for policy in policies {
            let (t, rec) = prepared(policy)
            t.terminate()
            t.terminate()
            t.connectionInterrupted()
            t.connectionInvalidated()
            XCTAssertEqual(rec.closeReasons, [.killed], "\(policy)")
            t.deliver(try pong())
            XCTAssertEqual(rec.messageCount, 0, "\(policy)")
        }
    }

    func testInvalidationThenTerminateStillReportsOnce() throws {
        for policy in policies {
            let (t, rec) = prepared(policy)
            t.connectionInvalidated()
            t.terminate()
            XCTAssertEqual(rec.closeReasons, [.invalidated("connection invalidated")], "\(policy)")
        }
    }

    func testStartAfterCloseDoesNotReopen() throws {
        for policy in policies {
            let (t, rec) = prepared(policy)
            t.terminate()
            let spawn = TransportRecorder()
            XCTAssertFalse(t.prepare(connection: nil, onMessage: { spawn.message($0) }, onClose: { spawn.close($0) }))
            t.deliver(try pong())
            XCTAssertEqual(spawn.messageCount, 0)
            XCTAssertEqual(rec.closeReasons, [.killed])
        }
    }

    func testMissingServiceClosesAndRecordsSpawnUnderBothPolicies() throws {
        for policy in policies {
            let spawns = TransportRecorder()
            let t = XPCModHostTransport(serviceName: Self.missing, serviceRequirement: nil, termination: policy, onSpawn: { spawns.close(.killed) })
            let closed = expectation(description: "closed \(policy)")
            closed.assertForOverFulfill = false
            let rec = TransportRecorder()
            try t.start(onMessage: { rec.message($0) }, onClose: { reason in
                rec.close(reason)
                closed.fulfill()
            })
            wait(for: [closed], timeout: 5)
            XCTAssertEqual(spawns.closeReasons.count, 1)
            t.deliver(try pong())
            t.terminate()
            XCTAssertEqual(rec.messageCount, 0)
            XCTAssertEqual(rec.closeReasons.count, 1)
        }
    }
}
