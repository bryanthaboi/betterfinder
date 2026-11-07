import AppKit
@testable import AppBridge
@testable import Browser
import FSCore
import Foundation
@testable import ModHost
import ModKit
import XCTest

private final class FixedCells: ModColumnValuesProviding, @unchecked Sendable {
    let cells: [String: ModCellValue]
    init(_ cells: [String: ModCellValue]) { self.cells = cells }
    func values(for items: [URL], revision: Int) async throws -> [URL: ModCellValue] {
        var out: [URL: ModCellValue] = [:]
        for u in items { if let c = cells[u.lastPathComponent] { out[u] = c } }
        return out
    }
}

private final class FixedPreview: ModPreviewProviding, @unchecked Sendable {
    let node: ModHost.ModUINode
    init(_ node: ModHost.ModUINode) { self.node = node }
    func render(_ item: URL, maxBytes: Int, dark: Bool) async throws -> ModPreviewContent { ModPreviewContent(title: nil, node: node) }
}

@MainActor
final class RegressionModUITests: XCTestCase {
    private func cell(_ n: Double, _ type: ColumnValueType) -> ColumnValue { ModColumnAdapter.value(ModCellValue(number: n), type: type) }

    func testHugeAndInvalidNumbersDoNotTrap() {
        XCTAssertEqual(cell(1e20, .number), .number(1e20))
        XCTAssertEqual(cell(1e20, .number).displayText, (1e20).formatted(.number.precision(.fractionLength(0))))
        XCTAssertEqual(cell(-1e20, .number).displayText, (-1e20).formatted(.number.precision(.fractionLength(0))))
        XCTAssertEqual(cell(.nan, .number), .none)
        XCTAssertEqual(cell(.infinity, .number), .none)
        XCTAssertEqual(cell(-.infinity, .number), .none)
        XCTAssertEqual(cell(1e20, .bytes), .none)
        XCTAssertEqual(cell(-1e20, .bytes), .none)
        XCTAssertEqual(cell(-1, .bytes), .none)
        XCTAssertEqual(cell(.nan, .bytes), .none)
        XCTAssertEqual(cell(.infinity, .bytes), .none)
        XCTAssertEqual(cell(Double(Int64.max), .bytes), .none)
        XCTAssertEqual(cell(9_007_199_254_740_992, .bytes), .bytes(9_007_199_254_740_992))
        XCTAssertEqual(cell(9_223_372_036_854_774_784, .bytes), .bytes(9_223_372_036_854_774_784))
        XCTAssertEqual(cell(1536.7, .bytes), .bytes(1536))
        XCTAssertEqual(cell(1e20, .date), .none)
        XCTAssertEqual(cell(.nan, .date), .none)
        XCTAssertEqual(cell(.infinity, .string), .none)
        XCTAssertEqual(ModColumnAdapter.value(ModCellValue(text: "-5"), type: .bytes), .none)
        XCTAssertEqual(ModColumnAdapter.value(ModCellValue(text: "big", number: .nan), type: .number), .string("big"))
        for v in [cell(1e20, .number), cell(Double(Int64.max), .number), cell(Double(Int64.min), .number), cell(-9_223_372_036_854_777_856, .number)] {
            XCTAssertFalse(v.displayText.isEmpty)
        }
    }

    func testCellAccessibilityLabelSurvivesConversion() async throws {
        let json = try JSONValue.parse(Data(#"{"handle":"h","text":"▁▃▇","number":12000000000,"label":"  Large, 12 GB, 80 percent of folder  "}"#.utf8))
        let cellValue = ModCellValue.from(json)
        XCTAssertEqual(cellValue.accessibilityLabel, "Large, 12 GB, 80 percent of folder")
        let v = ModColumnAdapter.value(cellValue, type: .string)
        XCTAssertEqual(v.displayText, "▁▃▇")
        XCTAssertEqual(v.accessibilityDescription, "Large, 12 GB, 80 percent of folder")
        XCTAssertEqual(v.underlyingValue, .string("▁▃▇"))
        XCTAssertNil(ModColumnAdapter.value(ModCellValue(text: "x", accessibilityLabel: "   "), type: .string).accessibilityDescription)

        let adapter = ModColumnAdapter(provider: FixedCells(["a.bin": cellValue]), valueType: .bytes)
        let url = URL(fileURLWithPath: "/tmp/a.bin")
        let out = try await adapter.values(for: [FileItem(url: url, name: "a.bin", isDirectory: false)], revision: 1)
        XCTAssertEqual(out[url]?.accessibilityDescription, "Large, 12 GB, 80 percent of folder")
        XCTAssertEqual(out[url]?.underlyingValue, .bytes(12_000_000_000))
    }

    func testConversionNormalizesBlankLabelsAndRejectsUnnamedControls() throws {
        let json = try JSONValue.parse(Data("""
        {"type":"vstack","children":[
          {"type":"button","id":"blank","text":"   ","label":"  ","command":"run"},
          {"type":"textField","id":"field"},
          {"type":"list","id":"things","items":[{"id":"1","title":"One"}]},
          {"type":"divider","label":"   "},
          {"type":"progress","value":1e20}
        ]}
        """.utf8))
        let node = try XCTUnwrap(ModHost.ModUINode.from(json, owner: "a.mod"))
        XCTAssertNil(node.children[0].accessibilityLabel)
        let out = ModUIConversion.convert(node, commandResolver: BrowserModSink(registries: BrowserRegistries()).browserCommandID)
        XCTAssertEqual(Set(out.issues.compactMap { $0.split(separator: ":").first.map(String.init) }), ["blank", "field", "things"])
        guard case .stack(_, _, let children) = out.node.kind else { return XCTFail() }
        if case .progress(let value, _) = children[4].kind { XCTAssertEqual(value, 1) } else { XCTFail("progress") }

        let ok = try XCTUnwrap(ModHost.ModUINode.from(try JSONValue.parse(Data("""
        {"type":"vstack","children":[{"type":"textField","id":"f","placeholder":"Search"},{"type":"button","text":"Go","command":"run"},{"type":"divider"}]}
        """.utf8)), owner: "a.mod"))
        XCTAssertTrue(ModUIConversion.convert(ok, commandResolver: { $0.raw }).issues.isEmpty)
    }

    func testAuthorIDsAreStableAcrossInsertionsAndDuplicatesFallBack() throws {
        func convert(_ s: String) throws -> ConvertedModUI {
            let node = try XCTUnwrap(ModHost.ModUINode.from(try JSONValue.parse(Data(s.utf8)), owner: "a.mod"))
            return ModUIConversion.convert(node, commandResolver: { $0.raw })
        }
        let before = try convert(#"{"type":"vstack","children":[{"type":"textField","id":"note","label":"Note","command":"add"}]}"#)
        let after = try convert(#"{"type":"vstack","children":[{"type":"text","text":"Hint"},{"type":"textField","id":"note","label":"Note","command":"add"}]}"#)
        guard case .stack(_, _, let a) = before.node.kind, case .stack(_, _, let b) = after.node.kind else { return XCTFail() }
        XCTAssertEqual(a[0].id, b[1].id)
        XCTAssertEqual(after.fields[b[1].id], "note")
        XCTAssertEqual(after.commands[b[1].id], "add")

        let dup = try convert(#"{"type":"vstack","children":[{"type":"button","id":"x","text":"A","command":"a"},{"type":"button","id":"x","text":"B","command":"b"}]}"#)
        guard case .stack(_, _, let d) = dup.node.kind else { return XCTFail() }
        XCTAssertNotEqual(d[0].id, d[1].id)
        XCTAssertEqual(Set(dup.commands.values), ["a", "b"])
        XCTAssertEqual(dup.duplicateIDs, ["x"])
        XCTAssertFalse(dup.warnings.isEmpty)
        XCTAssertTrue(dup.issues.isEmpty)
    }

    func testPanelKeepsLastValidTreeAndReportsUnlabeledNodeOnce() throws {
        let registries = BrowserRegistries()
        let sink = BrowserModSink(registries: registries)
        var notes: [(String, String, String)] = []
        sink.onNotify = { notes.append(($0, $1, $2)) }
        let pid = ModContributionID(modId: "a.mod", localId: "p")
        _ = try sink.registerPanel(ModPanelContribution(id: pid, title: "Notes", edge: .right, presentation: .docked), owner: "a.mod")
        sink.flush()
        let good = try XCTUnwrap(ModHost.ModUINode.from(try JSONValue.parse(Data(#"{"type":"vstack","children":[{"type":"button","text":"Go","command":"run"}]}"#.utf8)), owner: "a.mod"))
        sink.apply(.panelContent(panel: pid, node: good))
        let shown = try XCTUnwrap(registries.panels.contentOverrides[pid.qualified])
        let bad = try XCTUnwrap(ModHost.ModUINode.from(try JSONValue.parse(Data(#"{"type":"vstack","children":[{"type":"button","id":"mystery","text":" ","command":"run"}]}"#.utf8)), owner: "a.mod"))
        sink.apply(.panelContent(panel: pid, node: bad))
        sink.apply(.panelContent(panel: pid, node: bad))
        XCTAssertEqual(registries.panels.contentOverrides[pid.qualified], shown)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.0, "a.mod")
        XCTAssertEqual(notes.first?.2, "error")
        XCTAssertTrue(notes.first?.1.contains("mystery") == true, notes.first?.1 ?? "")
        XCTAssertTrue(notes.first?.1.contains("Notes") == true)
        sink.apply(.panelContent(panel: pid, node: good))
        sink.apply(.panelContent(panel: pid, node: bad))
        XCTAssertEqual(notes.count, 2)
    }

    func testPreviewWithUnnamedControlFailsInsteadOfRendering() async throws {
        let node = ModHost.ModUINode(kind: .vstack, children: [ModHost.ModUINode(kind: .button, text: "", command: ModCommandReference(raw: "run", owner: "a.mod"))])
        let adapter = ModPreviewAdapter(provider: FixedPreview(node), environment: ModEnvironmentState(), resolve: { $0.raw })
        do {
            _ = try await adapter.render(FileItem(url: URL(fileURLWithPath: "/tmp/x.txt"), name: "x", isDirectory: false))
            XCTFail("expected rejection")
        } catch let e as ModPreviewAccessibilityError {
            XCTAssertTrue(e.issue.contains("button"))
        }
    }

    func testToastDismissesImmediatelyWithReduceMotion() {
        _ = NSApplication.shared
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        p.orderFrontRegardless()
        XCTAssertTrue(p.isVisible)
        ModToast.dismiss(p, reduceMotion: true)
        XCTAssertFalse(p.isVisible)
        XCTAssertEqual(p.alphaValue, 1)
    }
}
