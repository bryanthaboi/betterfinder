import XCTest
@testable import Theming

@MainActor
final class RegressionContrastTests: XCTestCase {
    func testContrastCompositesTranslucentForeground() {
        let halfBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
        let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let ratio = NSColor.contrastRatio(halfBlack, .white)
        XCTAssertLessThan(ratio, 4.5)
        XCTAssertEqual(ratio, NSColor.contrastRatio(gray, .white), accuracy: 0.001)
    }

    func testContrastCompositesWhiteOverDarkGray() {
        let dark = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        let translucentWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)
        let v = 0.55 + 0.2 * 0.45
        let opaque = NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        let ratio = NSColor.contrastRatio(translucentWhite, dark)
        XCTAssertEqual(ratio, NSColor.contrastRatio(opaque, dark), accuracy: 0.001)
        XCTAssertLessThan(ratio, NSColor.contrastRatio(.white, dark))
    }

    func testOpaqueContrastUnchanged() {
        XCTAssertEqual(NSColor.contrastRatio(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(NSColor.contrastRatio(.white, .white), 1, accuracy: 0.0001)
    }

    func testPressedToolbarTextUsesTextThreshold() {
        var t = try! XCTUnwrap(ThemeManager.builtIns.first { $0.id == "aqua" })
        t.toolbar.text = "#FFFFFF"
        t.toolbar.pressed = "#767676"
        let glyph = ToolbarButtonRenderer.contentColor(t, state: .pressed, isText: false)
        let text = ToolbarButtonRenderer.contentColor(t, state: .pressed, isText: true)
        XCTAssertEqual(glyph.usingColorSpace(.sRGB)?.hexString, "#FFFFFF")
        XCTAssertGreaterThanOrEqual(NSColor.contrastRatio(text, Theme.color(t.toolbar.pressed)), 4.5)
    }

    private struct Pair {
        let name: String
        let fg: String
        let bg: String
    }

    private func pairs(_ t: Theme) -> [Pair] {
        let c = t.colors
        let rowAlt = c.rowAlt.isEmpty ? c.listBg : c.rowAlt
        let sidebarBg = Theme.color(c.sidebarBg).alphaComponent == 0 ? c.windowBg : c.sidebarBg
        var out: [Pair] = []
        for (fgName, fg) in [("text", c.text), ("secondaryText", c.secondaryText)] {
            for (bgName, bg) in [("windowBg", c.windowBg), ("listBg", c.listBg), ("rowAlt", rowAlt), ("sidebarBg", sidebarBg), ("statusBarBg", c.statusBarBg), ("toolbarBg", c.toolbarBg)] {
                out.append(Pair(name: "\(fgName)/\(bgName)", fg: fg, bg: bg))
            }
        }
        out.append(Pair(name: "sidebarText/sidebarBg", fg: c.sidebarText, bg: sidebarBg))
        out.append(Pair(name: "statusBarText/statusBarBg", fg: c.statusBarText, bg: c.statusBarBg))
        out.append(Pair(name: "toolbarText/toolbarBg", fg: c.toolbarText, bg: c.toolbarBg))
        out.append(Pair(name: "selectionText/selection", fg: c.selectionText, bg: c.selection))
        out.append(Pair(name: "inactiveSelectionText/inactiveSelection", fg: c.inactiveSelectionText, bg: c.inactiveSelection))
        out.append(Pair(name: "sidebarSelectionText/sidebarSelection", fg: c.sidebarSelectionText, bg: c.sidebarSelection))
        out.append(Pair(name: "header", fg: t.header.text, bg: t.header.background))
        out.append(Pair(name: "pathBar.text", fg: t.pathBar.text, bg: t.pathBar.background))
        out.append(Pair(name: "pathBar.highlight", fg: t.pathBar.highlight, bg: t.pathBar.background))
        out.append(Pair(name: "iconLabels.selection", fg: t.iconLabels.selectionText, bg: t.iconLabels.selectionBackground))
        return out
    }

    private func isSystemOwned(_ p: Pair) -> Bool {
        let accentDependent = ["system:selection", "system:selectiontext", "system:accent", "system:inactiveselection"]
        return accentDependent.contains(p.fg.lowercased()) || accentDependent.contains(p.bg.lowercased())
            || p.fg.isEmpty || p.bg.isEmpty
    }

    func testBuiltInThemeTextPairsMeetMinimumUnrounded() {
        var failures: [String] = []
        for theme in ThemeManager.builtIns {
            let appearances: [NSAppearance.Name]
            switch theme.base {
            case .light: appearances = [.aqua]
            case .dark: appearances = [.darkAqua]
            case .system: appearances = [.aqua, .darkAqua]
            }
            for name in appearances {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    for p in pairs(theme) where !isSystemOwned(p) {
                        let bg = Theme.color(p.bg)
                        guard bg.alphaComponent > 0 else { continue }
                        let ratio = NSColor.contrastRatio(Theme.color(p.fg), bg, over: Theme.color(theme.colors.windowBg))
                        if ratio < 4.5 { failures.append("\(theme.id) \(name.rawValue) \(p.name) \(ratio)") }
                    }
                }
            }
        }
        XCTAssertEqual(failures, [])
    }

    func testAquaSelectionPairsPass() {
        let t = ThemeManager.builtIns.first { $0.id == "aqua" }!
        XCTAssertGreaterThanOrEqual(NSColor.contrastRatio(Theme.color(t.colors.selectionText), Theme.color(t.colors.selection)), 4.5)
        XCTAssertGreaterThanOrEqual(NSColor.contrastRatio(Theme.color(t.colors.sidebarSelectionText), Theme.color(t.colors.sidebarSelection)), 4.5)
        XCTAssertEqual(t.colors.selection, t.colors.sidebarSelection)
        XCTAssertEqual(t.iconLabels.selectionBackground, t.colors.selection)
    }

    func testSecondaryTextTokenStaysLegibleInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let fg = Theme.color("system:secondaryText")
                let backgrounds = [NSColor.windowBackgroundColor, .controlBackgroundColor] + NSColor.alternatingContentBackgroundColors
                for bg in backgrounds {
                    XCTAssertGreaterThanOrEqual(NSColor.contrastRatio(fg, bg, over: .windowBackgroundColor), 4.5, "\(name.rawValue) \(bg)")
                }
            }
        }
    }

    func testSidebarHeadingColorMeetsMinimumForEveryBuiltIn() {
        for theme in ThemeManager.builtIns {
            let name: NSAppearance.Name = theme.base == .dark ? .darkAqua : .aqua
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let window = Theme.color(theme.colors.windowBg)
                let sidebar = Theme.color(theme.colors.sidebarBg)
                let ratio = NSColor.contrastRatio(ListRenderer.sidebarHeadingColor(theme), sidebar.alphaComponent > 0 ? sidebar : window, over: window)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, theme.id)
            }
        }
        let luna = ThemeManager.builtIns.first { $0.id == "luna" }!
        XCTAssertEqual(ListRenderer.sidebarHeadingColor(luna).alphaComponent, Theme.color(luna.colors.sidebarText).alphaComponent)
    }

    func testIconLabelHelpersMatchThemeShape() {
        let aqua = ThemeManager.builtIns.first { $0.id == "aqua" }!
        let box = NSRect(x: 0, y: 0, width: 80, height: 16)
        XCTAssertNotNil(ListRenderer.iconLabelPath(in: box, theme: aqua, selected: true))
        XCTAssertEqual(ListRenderer.iconLabelBackgroundColor(aqua, selected: true)?.usingColorSpace(.sRGB)?.hexString, "#356FCC")
        XCTAssertNil(ListRenderer.iconLabelBackgroundColor(aqua, selected: false))
    }
}
