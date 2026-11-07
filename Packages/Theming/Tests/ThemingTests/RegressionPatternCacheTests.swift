import XCTest
@testable import Theming

@MainActor
final class RegressionPatternCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ThemePatterns.purgeCache()
    }

    func testLongColorEditSequenceStaysBounded() {
        for i in 0..<512 {
            let c = NSColor(srgbRed: CGFloat(i % 256) / 255, green: CGFloat(i / 256) / 2, blue: 0.5, alpha: 1)
            _ = ThemePatterns.brushedMetalImage(base: c)
            _ = ThemePatterns.checkerboard(c, .white, cell: 4)
            XCTAssertLessThanOrEqual(ThemePatterns.cachedCount, ThemePatterns.countLimit)
            XCTAssertLessThanOrEqual(ThemePatterns.cachedCost, ThemePatterns.costLimit)
        }
        XCTAssertGreaterThan(ThemePatterns.cachedCount, 0)
    }

    func testRepeatedRequestReusesCachedImage() {
        let c = NSColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1)
        let a = ThemePatterns.brushedMetalImage(base: c)
        let b = ThemePatterns.brushedMetalImage(base: c)
        XCTAssertTrue(a === b)
    }

    func testPurgeEmptiesCache() {
        _ = ThemePatterns.brushedMetalImage(base: .gray)
        XCTAssertGreaterThan(ThemePatterns.cachedCount, 0)
        ThemePatterns.purgeCache()
        XCTAssertEqual(ThemePatterns.cachedCount, 0)
        XCTAssertEqual(ThemePatterns.cachedCost, 0)
    }
}
