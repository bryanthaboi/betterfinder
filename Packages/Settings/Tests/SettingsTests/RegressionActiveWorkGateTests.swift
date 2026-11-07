import Combine
import XCTest
@testable import Settings

@MainActor
final class RegressionActiveWorkGateTests: XCTestCase {
    var count = CurrentValueSubject<Int, Never>(0)
    var cancels = 0

    func gate(_ choice: ActiveWorkGate.Choice, keepWaiting: Bool = true, delay: TimeInterval = 20) -> ActiveWorkGate {
        ActiveWorkGate(
            activeCount: { [unowned self] in self.count.value },
            cancelAll: { [unowned self] in self.cancels += 1 },
            counts: count.eraseToAnyPublisher(),
            ask: { _, _ in choice },
            keepWaitingForCancellation: { keepWaiting },
            cancellationPromptDelay: delay
        )
    }

    func testIdleQueueProceedsWithoutAsking() async {
        var asked = false
        let g = ActiveWorkGate(activeCount: { 0 }, cancelAll: {}, counts: Just(0).eraseToAnyPublisher(), ask: { _, _ in asked = true; return .dontProceed })
        XCTAssertEqual(g.terminationDecision(), .proceed)
        let ok = await g.confirm(.update)
        XCTAssertTrue(ok)
        XCTAssertFalse(asked)
    }

    func testDontQuitCancelsTermination() {
        count.value = 2
        XCTAssertEqual(gate(.dontProceed).terminationDecision(), .cancel)
        XCTAssertEqual(cancels, 0)
    }

    func testQuitWhenFinishedFiresOnlyAfterQueueDrains() {
        count.value = 1
        let g = gate(.waitUntilFinished)
        XCTAssertEqual(g.terminationDecision(), .quitWhenIdle)
        var quit = 0
        g.quitWhenIdle { quit += 1 }
        XCTAssertEqual(quit, 0)
        XCTAssertTrue(g.isQuitPending)
        count.value = 0
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(quit, 1)
        count.value = 1
        count.value = 0
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(quit, 1)
        XCTAssertFalse(g.isQuitPending)
    }

    func testCancelledPendingQuitNeverFires() {
        count.value = 1
        let g = gate(.waitUntilFinished)
        var quit = 0
        g.quitWhenIdle { quit += 1 }
        g.cancelPendingQuit()
        count.value = 0
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(quit, 0)
    }

    func testCancelAndQuitCancelsOperationsAndWaitsForCleanup() async {
        count.value = 3
        let g = gate(.cancelWorkAndProceed)
        XCTAssertEqual(g.terminationDecision(), .cancelWorkThenProceed)
        XCTAssertEqual(cancels, 1)
        var finished = false
        let task = Task { @MainActor in
            finished = await g.waitForCancellation()
        }
        await Task.yield()
        XCTAssertFalse(finished)
        count.value = 0
        await task.value
        XCTAssertTrue(finished)
    }

    func testUpdateGateRefusedWhenUserSaysNotNow() async {
        count.value = 1
        let ok = await gate(.dontProceed).confirm(.update)
        XCTAssertFalse(ok)
    }

    func testUpdateGateWaitsForQueueToDrain() async {
        count.value = 1
        let g = gate(.waitUntilFinished)
        let task = Task { @MainActor in await g.confirm(.update) }
        await Task.yield()
        count.value = 0
        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertEqual(cancels, 0)
    }

    func testCancelledUpdateWaitReturnsFalse() async {
        count.value = 1
        let g = gate(.waitUntilFinished)
        let task = Task { @MainActor in await g.confirm(.update) }
        await Task.yield()
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
    }

    func testStuckCancellationAsksBeforeQuittingAnyway() async {
        count.value = 1
        let g = gate(.cancelWorkAndProceed, keepWaiting: false, delay: 0.05)
        let ok = await g.confirm(.quit)
        XCTAssertTrue(ok)
        XCTAssertEqual(cancels, 1)
    }

    func testMessagesNameTheCount() {
        XCTAssertTrue(ActiveWorkGate.message(count: 3, purpose: .quit).title.contains("3 file operations"))
        XCTAssertEqual(ActiveWorkGate.message(count: 1, purpose: .update).wait, "Install When Finished")
    }
}
