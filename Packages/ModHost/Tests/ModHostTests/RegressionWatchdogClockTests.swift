import XCTest
@testable import ModHostRuntime

final class RegressionWatchdogClockTests: XCTestCase {
    func testTurnStartingAfterTheTickReadIsNotAHang() throws {
        let dog = ModWatchdog()
        let hangs = HangBox()
        dog.onHang = { turn, ms in hangs.add(turn.handler ?? "", ms) }
        dog.configure(budgetMs: 10_000, loadBudgetMs: 10_000, graceMs: 10_000)
        dog.start()
        defer { dog.stop() }
        let key = dog.begin(ModWatchdog.Turn(modId: "bob.lat", generation: 1, invocationId: "i1", handler: "run", isLoad: false))
        let start = try XCTUnwrap(dog.start(of: key))
        dog.tick(at: start - 1_000)
        XCTAssertTrue(hangs.all.isEmpty, "\(hangs.all)")
        dog.tick(at: start + 10_001_000_000)
        XCTAssertEqual(hangs.all.map(\.0), ["run"])
        XCTAssertEqual(hangs.all.first?.1, 10_001)
        dog.end(key)
    }
}

private final class HangBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, Int)] = []
    func add(_ h: String, _ ms: Int) { lock.lock(); items.append((h, ms)); lock.unlock() }
    var all: [(String, Int)] { lock.lock(); defer { lock.unlock() }; return items }
}
