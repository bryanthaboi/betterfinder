import Foundation
@testable import ModHost
import ModKit
import XCTest

final class RegressionUISinkTests: XCTestCase {
    func testBlankLabelsNormalizeToNil() throws {
        let json = try JSONValue.parse(Data(#"{"type":"vstack","label":"  \n ","children":[{"type":"button","text":"Go","label":"  Go now  "},{"type":"textField","placeholder":"   "}]}"#.utf8))
        let node = try XCTUnwrap(ModUINode.from(json, owner: "a.mod"))
        XCTAssertNil(node.accessibilityLabel)
        XCTAssertEqual(node.children[0].accessibilityLabel, "Go now")
        XCTAssertNil(node.children[1].placeholder)
    }

    func testNonFiniteNodeValuesAreDropped() {
        let node = ModUINode.from(.object(["type": .string("progress"), "value": .double(.infinity)]), owner: "a.mod")
        XCTAssertNotNil(node)
        XCTAssertNil(node?.value)
        XCTAssertEqual(ModUINode.from(.object(["type": .string("progress"), "value": .double(1e20)]), owner: "a.mod")?.value, 1e20)
    }

    func testCellValueDecodesLabelAndSanitizesNumber() {
        let long = String(repeating: "x", count: 2000)
        let cell = ModCellValue.from(.object(["handle": .string("h"), "text": .string("▁▇"), "number": .double(.nan), "label": .string(" \(long) ")]))
        XCTAssertEqual(cell.text, "▁▇")
        XCTAssertNil(cell.number)
        XCTAssertEqual(cell.accessibilityLabel?.count, ModCellValue.maxAccessibilityLabelLength)
        XCTAssertNil(ModCellValue.from(.object(["label": .string("   ")])).accessibilityLabel)
        XCTAssertEqual(ModCellValue.from(.object(["number": .double(1e20)])).number, 1e20)
        XCTAssertNil(ModCellValue(text: "a").accessibilityLabel)
    }

    func testNumberTypeRequiresFiniteValues() {
        let v = ModValueValidator()
        XCTAssertNil(v.validate(.double(1e20), .number))
        XCTAssertNil(v.validate(.int(Int.max), .number))
        XCTAssertNotNil(v.validate(.double(.nan), .number))
        XCTAssertNotNil(v.validate(.double(.infinity), .number))
        XCTAssertNotNil(v.validate(.double(-.infinity), .number))
    }

    func testColumnValueRecordAcceptsOptionalLabel() throws {
        let v = ModValueValidator()
        let ok = try JSONValue.parse(Data(#"{"handle":"h","text":"▁▇","label":"Large, 12 GB"}"#.utf8))
        XCTAssertNil(v.validate(ok, .ref("ColumnValue")))
        XCTAssertNotNil(v.validate(.object(["handle": .string("h"), "number": .double(.nan)]), .ref("ColumnValue")))
    }
}
