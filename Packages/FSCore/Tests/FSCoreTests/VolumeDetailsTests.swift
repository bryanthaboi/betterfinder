@testable import FSCore
import XCTest

final class VolumeDetailsTests: XCTestCase {
    func testRootVolumeHasCapacityAndFormat() throws {
        let details = try XCTUnwrap(VolumeInfo.details(for: URL(fileURLWithPath: "/")))
        XCTAssertEqual(details.mountPoint, "/")
        XCTAssertFalse(details.name.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(details.totalBytes), 0)
        XCTAssertNotNil(details.availableBytes)
        XCTAssertFalse(details.format.isEmpty)
        XCTAssertTrue(details.device.hasPrefix("/dev/"))
        let fraction = try XCTUnwrap(details.usedFraction)
        XCTAssertTrue((0...1).contains(fraction))
    }

    func testTextForKnownAndUnknownSpace() {
        var details = VolumeDetails(name: "Disk", mountPoint: "/Volumes/Disk", format: "APFS", totalBytes: 1000, availableBytes: 250, connection: .external)
        XCTAssertEqual(details.usedBytes, 750)
        XCTAssertEqual(details.usedFraction, 0.75)
        XCTAssertEqual(details.kindText, "External volume (APFS)")
        XCTAssertTrue(details.spaceText.contains("free of"))
        details.availableBytes = 5000
        XCTAssertEqual(details.usedBytes, 0)
        details.totalBytes = nil
        details.availableBytes = nil
        details.format = ""
        details.connection = .network
        XCTAssertNil(details.usedFraction)
        XCTAssertEqual(details.spaceText, "--")
        XCTAssertEqual(details.kindText, "Network volume")
    }
}
