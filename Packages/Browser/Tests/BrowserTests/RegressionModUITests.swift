import AppKit
import FSCore
import XCTest
@testable import Browser

private struct DescribedColumnProvider: ColumnProvider {
    func values(for items: [FileItem], context: ColumnContext) async throws -> [URL: ColumnValue] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.url, ColumnValue.described(.bytes(2048), accessibility: "Small, 2 KB")) })
    }
}

final class RegressionModUITests: RegistryTestCase {
    func testNumberDisplayNeverTraps() {
        XCTAssertEqual(ColumnValue.number(42).displayText, Int64(42).formatted())
        XCTAssertEqual(ColumnValue.number(1e20).displayText, (1e20).formatted(.number.precision(.fractionLength(0))))
        XCTAssertEqual(ColumnValue.number(-1e20).displayText, (-1e20).formatted(.number.precision(.fractionLength(0))))
        XCTAssertEqual(ColumnValue.number(Double(Int64.max)).displayText, Double(Int64.max).formatted(.number.precision(.fractionLength(0))))
        XCTAssertEqual(ColumnValue.number(Double(Int64.min)).displayText, Int64.min.formatted())
        XCTAssertEqual(ColumnValue.number(9_223_372_036_854_774_784).displayText, Int64(9_223_372_036_854_774_784).formatted())
        XCTAssertEqual(ColumnValue.number(.nan).displayText, "--")
        XCTAssertEqual(ColumnValue.number(.infinity).displayText, "--")
        XCTAssertEqual(ColumnValue.number(-.infinity).displayText, "--")
        XCTAssertEqual(ColumnValue.number(1.25).displayText, (1.25).formatted(.number.precision(.fractionLength(0...3))))
        XCTAssertEqual(ColumnValue.date(Date(timeIntervalSince1970: .nan)).displayText, "--")
    }

    func testDescribedValueKeepsDisplayAndSortValue() throws {
        let v = ColumnValue.described(.number(3), accessibility: "Three stars")
        XCTAssertEqual(v.displayText, ColumnValue.number(3).displayText)
        XCTAssertEqual(v.accessibilityDescription, "Three stars")
        XCTAssertEqual(v.underlyingValue, .number(3))
        XCTAssertNil(ColumnValue.number(3).accessibilityDescription)

        let store = ColumnValueStore()
        let dir = try makeTree(files: ["a.txt"])
        let item = FileItem(url: dir.appendingPathComponent("a.txt"), name: "a.txt", isDirectory: false)
        store.request(.init(qualifiedID: "o/c", provider: DescribedColumnProvider(), specRevision: "1", timeout: 5), items: [item])
        XCTAssertTrue(spin { store.cachedValue(column: "o/c", for: item) != nil })
        XCTAssertEqual(store.cachedValue(column: "o/c", for: item)?.accessibilityDescription, "Small, 2 KB")
        XCTAssertEqual(store.snapshot(column: "o/c")[item.url.pathKey], .bytes(2048))
    }

    func testAccessibilityIssuesTreatWhitespaceTitlesAsMissing() {
        let node = ModUINode.stack(id: "r", [.button(id: "b", title: "  "), .toggle(id: "t", title: "\n", isOn: true), .button(id: "ok", title: "Go")])
        XCTAssertEqual(node.accessibilityIssues().count, 2)
    }

    func testProgressWithOutOfRangeValueRendersWithoutTrapping() {
        let renderer = ModUIRenderer()
        renderer.render(.stack(id: "r", [.progress(id: "p", value: 1e20, accessibilityLabel: "Load"), .progress(id: "q", value: .nan, accessibilityLabel: "Other")]))
        XCTAssertEqual(renderer.control(withID: "p")?.accessibilityValue() as? String, "100 percent")
        XCTAssertEqual(renderer.control(withID: "q")?.accessibilityValue() as? String, "In progress")
    }

    private func hostedRenderer() -> (ModUIRenderer, NSWindow) {
        let renderer = ModUIRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(renderer.rootView)
        NSLayoutConstraint.activate([
            renderer.rootView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            renderer.rootView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            renderer.rootView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        return (renderer, window)
    }

    private func focusedID(_ renderer: ModUIRenderer, _ window: NSWindow) -> String? {
        let responder = window.firstResponder
        let view = (responder as? NSTextView)?.isFieldEditor == true ? (responder as? NSTextView)?.delegate as? NSView : responder as? NSView
        return ["id:note", "id:go", "id:other", "n.0", "n.1"].first { renderer.control(withID: $0) === view }
    }

    func testInsertionBeforeFocusedFieldKeepsFocusAndCaret() throws {
        let (renderer, window) = hostedRenderer()
        renderer.render(.stack(id: "n", [.textField(id: "id:note", value: "hello", accessibilityLabel: "Note")]))
        let field = try XCTUnwrap(renderer.control(withID: "id:note") as? NSTextField)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 2, length: 1)
        renderer.render(.stack(id: "n", [.label(id: "n.0", "Hint"), .textField(id: "id:note", value: "hello", accessibilityLabel: "Note")]))
        XCTAssertEqual(focusedID(renderer, window), "id:note")
        XCTAssertEqual((renderer.control(withID: "id:note") as? NSTextField)?.currentEditor()?.selectedRange, NSRange(location: 2, length: 1))
    }

    func testRemovingFocusedControlMovesFocusToNeighbour() throws {
        let (renderer, window) = hostedRenderer()
        renderer.render(.stack(id: "n", [.button(id: "id:go", title: "Go"), .textField(id: "id:note", value: "", accessibilityLabel: "Note"), .button(id: "id:other", title: "Other")]))
        window.makeFirstResponder(renderer.control(withID: "id:note"))
        var events: [ModUIEvent] = []
        renderer.onEvent = { events.append($0) }
        renderer.render(.stack(id: "n", [.button(id: "id:go", title: "Go"), .button(id: "id:other", title: "Other")]))
        XCTAssertEqual(focusedID(renderer, window), "id:other")
        XCTAssertTrue(events.isEmpty, "\(events)")
        renderer.render(.stack(id: "n", [.button(id: "id:go", title: "Go")]))
        XCTAssertEqual(focusedID(renderer, window), "id:go")
    }

    func testFallbackFocusOrder() {
        XCTAssertEqual(ModUIRenderer.fallbackFocus(removed: "b", previousOrder: ["a", "b", "c"], newOrder: ["a", "c"]), "c")
        XCTAssertEqual(ModUIRenderer.fallbackFocus(removed: "c", previousOrder: ["a", "b", "c"], newOrder: ["a", "b"]), "b")
        XCTAssertEqual(ModUIRenderer.fallbackFocus(removed: "x", previousOrder: [], newOrder: ["z"]), "z")
        XCTAssertNil(ModUIRenderer.fallbackFocus(removed: "a", previousOrder: ["a"], newOrder: []))
    }
}
