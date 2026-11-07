import XCTest
@testable import Browser

@MainActor
final class RegressionMutationTrackerTests: XCTestCase {
    func testTracksActiveRemoteMutationsUntilTheyFinish() async {
        let tracker = RemoteMutationTracker()
        var counts: [Int] = []
        let sub = tracker.$activeCount.sink { counts.append($0) }
        let gate = AsyncStream<Void>.makeStream()
        let task = tracker.run {
            for await _ in gate.stream { break }
        }
        XCTAssertEqual(tracker.activeCount, 1)
        gate.continuation.yield()
        await task.value
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertEqual(counts, [0, 1, 0])
        sub.cancel()
    }

    func testCancelAllCancelsInFlightMutations() async {
        let tracker = RemoteMutationTracker()
        var sawCancellation = false
        let task = tracker.run {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { sawCancellation = true }
        }
        XCTAssertEqual(tracker.activeCount, 1)
        tracker.cancelAll()
        await task.value
        XCTAssertTrue(sawCancellation)
        XCTAssertEqual(tracker.activeCount, 0)
    }
}
