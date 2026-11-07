import XCTest
@testable import ModKit

final class ExamplesTests: XCTestCase {
    func testExamplesPresent() {
        XCTAssertEqual(ModExamples.ids, ["image-dimensions", "markdown-previewer", "pinned-folders", "recent-downloads", "zip-selection"])
    }

    func testEveryExamplePassesStaticPreflightWithoutWarnings() {
        for ex in ModExamples.all {
            let out = ModStaticPreflight.run(package: ex.package)
            XCTAssertTrue(out.receipt.staticOK, "\(ex.id): \(out.receipt.diagnostics)")
            XCTAssertEqual(out.receipt.diagnostics, [], "\(ex.id)")
            XCTAssertEqual(out.receipt[.dryRun], .notRun)
            XCTAssertFalse(out.receipt.ok)
        }
    }
}
