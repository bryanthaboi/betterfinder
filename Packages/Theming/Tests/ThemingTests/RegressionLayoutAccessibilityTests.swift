import SwiftUI
import XCTest
@testable import Theming

@MainActor
final class RegressionLayoutAccessibilityTests: XCTestCase {
    override func tearDown() {
        ThemeAccessibility.increaseContrastOverride = nil
        super.tearDown()
    }

    private static let expected: [String: [Density: [CGFloat]]] = [
        "platinum": [.compact: [18, 20, 20, 24, 18], .regular: [22, 24, 20, 24, 18], .comfortable: [26, 28, 20, 24, 18]],
        "system7": [.compact: [18, 20, 20, 24, 18], .regular: [22, 24, 20, 24, 18], .comfortable: [26, 28, 20, 24, 18]],
        "high-contrast": [.compact: [24, 28, 28, 32, 26], .regular: [28, 32, 28, 32, 26], .comfortable: [32, 36, 28, 32, 26]],
        "aqua": [.compact: [19, 22, 22, 24, 17], .regular: [23, 26, 22, 24, 17], .comfortable: [27, 30, 22, 24, 17]],
        "classic-windows": [.compact: [17, 20, 22, 24, 18], .regular: [21, 24, 22, 24, 18], .comfortable: [25, 28, 22, 24, 18]],
        "luna": [.compact: [18, 22, 22, 24, 20], .regular: [22, 26, 22, 24, 20], .comfortable: [26, 30, 22, 24, 20]],
        "modern": [.compact: [24, 28, 28, 32, 0], .regular: [28, 32, 28, 32, 0], .comfortable: [32, 36, 28, 32, 0]],
        "modern-light": [.compact: [24, 28, 28, 32, 0], .regular: [28, 32, 28, 32, 0], .comfortable: [32, 36, 28, 32, 0]],
        "modern-dark": [.compact: [24, 28, 28, 32, 0], .regular: [28, 32, 28, 32, 0], .comfortable: [32, 36, 28, 32, 0]],
    ]

    func testBuiltInLayoutsKeepTheirHeightsAtEveryDensity() {
        XCTAssertEqual(Set(Self.expected.keys), Set(ThemeManager.builtIns.map(\.id)))
        for theme in ThemeManager.builtIns {
            for density in Density.allCases {
                let l = theme.layout(density: density)
                XCTAssertEqual([l.rowHeight, l.sidebarRowHeight, l.statusBarHeight, l.pathBarHeight, l.headerHeight], Self.expected[theme.id]?[density], "\(theme.id) \(density)")
            }
        }
    }

    private func enlarged(_ size: Double) -> Theme {
        var t = ThemeManager.builtIns.first { $0.id == "classic-windows" }!
        let spec = Theme.FontSpec(family: "system", size: size)
        t.fonts.list = spec
        t.fonts.ui = spec
        t.fonts.sidebar = spec
        t.fonts.statusBar = spec
        t.header.font = spec
        t.pathBar.font = spec
        return t
    }

    func testLargeFontsGrowEveryTextSurface() {
        for size in [24.0, 36.0] {
            let t = enlarged(size)
            for density in Density.allCases {
                let l = t.layout(density: density)
                let line = ThemeLayout.lineHeight(NSFont.systemFont(ofSize: CGFloat(size)))
                XCTAssertGreaterThanOrEqual(l.rowHeight, line + ThemeLayout.rowTextPadding)
                XCTAssertGreaterThanOrEqual(l.sidebarRowHeight, line + ThemeLayout.sidebarTextPadding)
                XCTAssertGreaterThanOrEqual(l.statusBarHeight, line + ThemeLayout.statusTextPadding)
                XCTAssertGreaterThanOrEqual(l.pathBarHeight, line + ThemeLayout.pathTextPadding)
                XCTAssertGreaterThanOrEqual(l.headerHeight, line + ThemeLayout.headerTextPadding)
            }
        }
        XCTAssertGreaterThan(enlarged(36).layout(density: .compact).rowHeight, enlarged(24).layout(density: .compact).rowHeight)
    }

    func testRowFitsLargeIcons() {
        var t = ThemeManager.builtIns.first { $0.id == "classic-windows" }!
        t.metrics.listIconSize = 32
        XCTAssertGreaterThanOrEqual(t.layout(density: .compact).rowHeight, 32 + ThemeLayout.rowIconPadding)
    }

    func testIconItemSizeGrowsWithLabelLines() {
        let l = ThemeManager.builtIns.first { $0.id == "modern" }!.layout(density: .regular)
        let base = l.iconItemSize(iconSize: 64)
        XCTAssertEqual(l.iconItemSize(iconSize: 64, labelFont: .systemFont(ofSize: 12), maxLines: 2), base)
        let big = l.iconItemSize(iconSize: 64, labelFont: .boldSystemFont(ofSize: 14), maxLines: 3)
        XCTAssertGreaterThan(big.height, base.height)
        XCTAssertEqual(big.width, base.width)
    }

    func testPreviewFollowsExplicitDensity() {
        let theme = ThemeManager.builtIns.first { $0.id == "modern" }!
        XCTAssertEqual(ThemePreview(theme: theme, isActive: true, density: .comfortable).resolvedDensity, .comfortable)
        XCTAssertNil(ThemePreview(theme: theme, isActive: true, density: nil).resolvedDensity)
        XCTAssertEqual(ThemePreview(theme: theme).resolvedDensity, ThemeManager.shared.density)
    }

    func testSliderAccessibilityValueIncludesUnits() {
        var v = 12.0
        let binding = Binding(get: { v }, set: { v = $0 })
        XCTAssertEqual(SliderRow(label: "Row height", value: binding, range: 0...40).accessibilityValueText, "12 points")
        v = 1
        XCTAssertEqual(SliderRow(label: "Row height", value: binding, range: 0...40).accessibilityValueText, "1 point")
        v = 0
        XCTAssertEqual(SliderRow(label: "Width", value: binding, range: 0...40, zeroLabel: "Auto").accessibilityValueText, "Auto")
        v = 3
        XCTAssertEqual(SliderRow(label: "Scale", value: binding, range: 1...8, unit: nil).accessibilityValueText, "3")
    }

    func testOptionalFontRowRoleName() {
        var spec: Theme.FontSpec?
        let binding = Binding(get: { spec }, set: { spec = $0 })
        XCTAssertEqual(OptionalFontRow(label: "Custom sidebar font", spec: binding, fallback: Theme.FontSpec()).roleName, "Sidebar")
        XCTAssertEqual(OptionalFontRow(label: "Custom path bar font", spec: binding, fallback: Theme.FontSpec()).roleName, "Path bar")
    }

    func testCaptionButtonsShowFocusRing() {
        for kind in [WindowButtonKind.close, .minimize, .zoom] {
            let b = WindowCaptionButton(kind: kind)
            b.frame = NSRect(x: 0, y: 0, width: 16, height: 14)
            XCTAssertEqual(b.focusRingType, .exterior)
            XCTAssertEqual(b.focusRingMaskBounds, b.bounds)
        }
        for id in ["system7", "classic-windows", "modern"] {
            let t = ThemeManager.builtIns.first { $0.id == id }!
            XCTAssertFalse(WindowButtonRenderer.focusPath(in: NSRect(x: 0, y: 0, width: 16, height: 14), theme: t).isEmpty)
        }
    }

    func testObserverFiresOnDisplayOptionsChange() {
        var fired = 0
        let observer = ThemeObserver(fireImmediately: false) { _ in fired += 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
        XCTAssertEqual(fired, 1)
        observer.invalidate()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
        XCTAssertEqual(fired, 1)
    }

    private func renderSelection(_ theme: Theme, emphasized: Bool) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ListRenderer.drawSelection(in: NSRect(x: 0, y: 0, width: 60, height: 20), theme: theme, emphasized: emphasized)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func testIncreaseContrastOutlinesSelection() {
        let t = ThemeManager.builtIns.first { $0.id == "system7" }!
        ThemeAccessibility.increaseContrastOverride = false
        let plain = renderSelection(t, emphasized: false)
        ThemeAccessibility.increaseContrastOverride = true
        let outlined = renderSelection(t, emphasized: false)
        let edgePlain = plain.colorAt(x: 30, y: 0)?.usingColorSpace(.sRGB)
        let edgeOutlined = outlined.colorAt(x: 30, y: 0)?.usingColorSpace(.sRGB)
        let center = outlined.colorAt(x: 30, y: 10)?.usingColorSpace(.sRGB)
        XCTAssertNotEqual(edgePlain?.hexString, edgeOutlined?.hexString)
        XCTAssertNotEqual(edgeOutlined?.hexString, center?.hexString)
    }
}
