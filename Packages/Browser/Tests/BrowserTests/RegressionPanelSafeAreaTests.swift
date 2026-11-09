import AppKit
import XCTest
@testable import Browser

@MainActor
final class RegressionPanelSafeAreaTests: RegistryTestCase {
    func testDockedPanelHeaderRemainsBelowWindowToolbar() throws {
        let registries = BrowserRegistries()
        let controller = makeWindow(try makeTree(), registries: registries)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        registries.panels.register(PanelSpec(id: "notes", title: "Capture Notes", minSize: 340, maxSize: 340, defaultOpen: true, content: .view { NSView() }), owner: "capture-test")
        window.makeKeyAndOrderFront(nil)
        let panel = try XCTUnwrap(controller.panelHost?.instances["capture-test/notes"])
        XCTAssertTrue(spin { panel.vc.view.frame.width >= 330 })
        window.contentView?.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(panel.vc.view.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Capture Notes" })
        let frame = label.convert(label.bounds, to: nil)
        XCTAssertLessThanOrEqual(frame.maxY, window.contentLayoutRect.maxY + 1)
        XCTAssertGreaterThan(frame.height, 0)
    }
}
