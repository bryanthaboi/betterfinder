import AppKit
import SwiftUI
import XCTest
@testable import Theming

final class RegressionEditorBindingTests: XCTestCase {
    @MainActor
    func testVisibleEditorKeepsLiveBindingEdits() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "editor-binding." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = ThemeManager(userThemesDirectory: directory, defaults: defaults)
        manager.appliesAppAppearance = false
        let model = ThemeEditorModel(manager: manager)
        let host = NSHostingController(rootView: ThemeEditorView(model: model))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        model.binding(\.metrics.rowHeight).wrappedValue = 20
        model.binding(\.metrics.cornerRadius).wrappedValue = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        model.flush()
        XCTAssertEqual(model.draft.metrics.rowHeight, 20)
        XCTAssertEqual(model.draft.metrics.cornerRadius, 0)
        XCTAssertEqual(manager.current.metrics.rowHeight, 20)
        XCTAssertEqual(manager.current.metrics.cornerRadius, 0)
        let restored = ThemeManager(userThemesDirectory: directory, defaults: defaults)
        restored.appliesAppAppearance = false
        XCTAssertEqual(restored.current.metrics.rowHeight, 20)
        XCTAssertEqual(restored.current.metrics.cornerRadius, 0)
    }
}
