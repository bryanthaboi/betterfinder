import AppKit
import SwiftUI
import XCTest
@testable import Theming

struct AXControl: CustomStringConvertible {
    let object: NSObject
    let role: String
    let parentRole: String?

    private func attr(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    var label: String? { Self.nonEmpty(attr("accessibilityLabel") as? String) }

    var titleElementText: String? {
        guard let t = attr("accessibilityTitleUIElement") as? NSObject else { return nil }
        let value = t.responds(to: NSSelectorFromString("accessibilityValue")) ? t.value(forKey: "accessibilityValue") as? String : nil
        let label = t.responds(to: NSSelectorFromString("accessibilityLabel")) ? t.value(forKey: "accessibilityLabel") as? String : nil
        return Self.nonEmpty(value) ?? Self.nonEmpty(label)
    }

    var name: String? { label ?? titleElementText }
    var valueDescription: String? { attr("accessibilityValueDescription") as? String }
    var actions: [String] { (attr("accessibilityActionNames") as? [String]) ?? [] }
    var canPress: Bool { actions.contains("AXPress") || object.responds(to: NSSelectorFromString("accessibilityPerformPress")) }

    var description: String { "\(role) \(name ?? "<unnamed>")" }

    static let interactiveRoles: Set<String> = ["AXColorWell", "AXSlider", "AXMenuButton", "AXPopUpButton", "AXIncrementor", "AXTextField", "AXButton", "AXCheckBox", "AXRadioGroup"]
    static let genericNames: Set<String> = ["Font family", "Font family for", "Font family for Font", "Font", "Color", "System color", "System color for", "Slider", "Picker"]

    static func collect(in root: NSObject) -> [AXControl] {
        var out: [AXControl] = []
        func walk(_ node: NSObject, parentRole: String?, depth: Int) {
            guard depth < 60 else { return }
            let role = node.responds(to: NSSelectorFromString("accessibilityRole")) ? node.value(forKey: "accessibilityRole") as? String : nil
            if let role, interactiveRoles.contains(role), !(role == "AXButton" && parentRole == "AXIncrementor") {
                out.append(AXControl(object: node, role: role, parentRole: parentRole))
            }
            let kids = node.responds(to: NSSelectorFromString("accessibilityChildren")) ? node.value(forKey: "accessibilityChildren") as? [Any] : nil
            for case let child as NSObject in kids ?? [] { walk(child, parentRole: role ?? parentRole, depth: depth + 1) }
        }
        walk(root, parentRole: nil, depth: 0)
        return out
    }

    static func problems(_ controls: [AXControl]) -> [String] {
        var out: [String] = []
        var seen: [String: Int] = [:]
        for c in controls {
            guard let name = c.name else {
                out.append("unnamed \(c.role)")
                continue
            }
            if genericNames.contains(name) { out.append("generic \(c.role) \(name)") }
            seen["\(c.role)|\(name)", default: 0] += 1
        }
        for (key, n) in seen where n > 1 { out.append("duplicate \(key) x\(n)") }
        return out.sorted()
    }
}

final class DrawCounter {
    private typealias DrawIMP = @convention(c) (AnyObject, Selector, NSRect) -> Void
    private let method: Method
    private let original: IMP
    var count = 0

    init(_ cls: AnyClass, target: AnyObject) {
        let sel = #selector(NSView.draw(_:))
        method = class_getInstanceMethod(cls, sel)!
        original = method_getImplementation(method)
        let call = unsafeBitCast(original, to: DrawIMP.self)
        let block: @convention(block) (AnyObject, NSRect) -> Void = { [unowned self, weak target] obj, rect in
            if obj === target { self.count += 1 }
            call(obj, sel, rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    func restore() { method_setImplementation(method, original) }
}

@MainActor
final class BehaviorRegressionThemingTests: XCTestCase {
    private var menuRole: String {
        if #available(macOS 26, *) { return "AXMenuButton" }
        return "AXPopUpButton"
    }

    private static func setEnhancedUserInterface(_ on: Bool) {
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: on), with: "AXEnhancedUserInterface")
    }
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for w in windows { w.contentView = nil; w.close() }
        windows.removeAll()
        Self.setEnhancedUserInterface(false)
        ThemeAccessibility.increaseContrastOverride = nil
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        try await super.tearDown()
    }

    private func enableSwiftUIAccessibility() {
        Self.setEnhancedUserInterface(true)
    }

    private func makeManager(_ themeID: String = "classic-windows") -> ThemeManager {
        let suite = "bf-r2-theming-\(UUID().uuidString)"
        suites.append(suite)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        dirs.append(dir)
        let m = ThemeManager(userThemesDirectory: dir, defaults: UserDefaults(suiteName: suite)!)
        m.appliesAppAppearance = false
        m.select(themeID)
        return m
    }

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 1000, height: 3000)) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = h
        windows.append(w)
        h.layoutSubtreeIfNeeded()
        spin(0.4)
        return h
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var out: [T] = []
        for v in view.subviews {
            if let t = v as? T { out.append(t) }
            out += descendants(of: v, as: type)
        }
        return out
    }

    private func editorControls(_ tab: ThemeEditorView.Tab, manager: ThemeManager) -> [AXControl] {
        let h = host(ThemeEditorView(manager: manager, initialTab: tab))
        _ = h.accessibilityChildren()
        spin(0.2)
        return AXControl.collect(in: h)
    }

    private func control(_ controls: [AXControl], _ role: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> AXControl? {
        let match = controls.first { $0.role == role && $0.name == name }
        if match == nil { XCTFail("missing \(role) \"\(name)\" in \(controls.map(\.description))", file: file, line: line) }
        return match
    }

    func testEditorControlsHaveDistinctAccessibleIdentities() throws {
        enableSwiftUIAccessibility()
        let manager = makeManager()
        var total = 0
        for tab in ThemeEditorView.Tab.allCases {
            let controls = editorControls(tab, manager: manager)
            XCTAssertGreaterThan(controls.count, 5, tab.rawValue)
            XCTAssertEqual(AXControl.problems(controls), [], tab.rawValue)
            total += controls.count
        }
        XCTAssertGreaterThan(total, 150)
    }

    func testColorRowsNameWellMenuAndAddButtonPerRole() throws {
        enableSwiftUIAccessibility()
        let controls = editorControls(.colors, manager: makeManager())
        for role in ["List background", "Sidebar background", "List selection", "Sidebar selection", "Bevel face", "Accent"] {
            let well = control(controls, "AXColorWell", role)
            XCTAssertEqual(well?.canPress, true, role)
            let menu = control(controls, menuRole, "System color for \(role)")
            XCTAssertEqual(menu?.actions.contains("AXPress"), true, role)
        }
        XCTAssertEqual(control(controls, "AXButton", "Add Alternate row color")?.canPress, true)
        XCTAssertEqual(control(controls, "AXRadioGroup", "Editor section")?.role, "AXRadioGroup")
    }

    func testSliderRowsExposeLabelValueWithUnitsAndAdjustActions() throws {
        enableSwiftUIAccessibility()
        let manager = makeManager()
        let list = editorControls(.list, manager: manager)
        let row = control(list, "AXSlider", "Row height")
        XCTAssertEqual(row?.valueDescription, "17 points")
        XCTAssertEqual(row.map { Set($0.actions).isSuperset(of: ["AXIncrement", "AXDecrement"]) }, true)
        XCTAssertEqual(control(list, "AXSlider", "Column header height")?.valueDescription, "18 points")
        XCTAssertEqual(control(list, "AXSlider", "Grid line width")?.valueDescription, "1 point")
        XCTAssertEqual(control(list, "AXSlider", "Sidebar row height")?.valueDescription, "20 points")
        let window = editorControls(.window, manager: manager)
        XCTAssertEqual(control(window, "AXSlider", "Window button size")?.valueDescription, "Auto")
        XCTAssertEqual(control(window, "AXSlider", "Caption inset")?.valueDescription, "3 points")
        let controls = editorControls(.controls, manager: manager)
        XCTAssertNotNil(control(controls, "AXSlider", "Scroll bar width"))
        XCTAssertNotNil(control(controls, "AXSlider", "Toolbar button corner radius"))
        XCTAssertNotNil(control(controls, "AXPopUpButton", "Scroll bar style"))
        XCTAssertNotNil(control(controls, "AXPopUpButton", "Path bar style"))
        XCTAssertNotNil(control(controls, "AXPopUpButton", "Toolbar button style"))
    }

    func testFontRowsNameFamilySizeAndWeightForEveryRole() throws {
        enableSwiftUIAccessibility()
        let controls = editorControls(.fonts, manager: makeManager())
        for role in ["List", "Interface", "Sidebar", "Status bar", "Window title", "Header"] {
            XCTAssertEqual(control(controls, "AXTextField", "\(role) font family")?.object.value(forKey: "accessibilityValue") as? String, "Tahoma, Verdana, Geneva, system", role)
            XCTAssertEqual(control(controls, menuRole, "Font family for \(role)")?.actions.contains("AXPress"), true, role)
            let size = control(controls, "AXIncrementor", "\(role) font size")
            XCTAssertEqual(size?.valueDescription, "11 points", role)
            XCTAssertEqual(size.map { Set($0.actions).isSuperset(of: ["AXIncrement", "AXDecrement"]) }, true, role)
            XCTAssertEqual(control(controls, "AXPopUpButton", "\(role) font weight")?.actions.contains("AXPress"), true, role)
        }
        XCTAssertNotNil(control(controls, "AXCheckBox", "Custom path bar font"))
    }

    func testColorStopButtonsAndStopsAreNamedForTheirList() throws {
        enableSwiftUIAccessibility()
        let controls = editorControls(.window, manager: makeManager())
        for list in ["Active colors", "Inactive colors"] {
            XCTAssertEqual(control(controls, "AXButton", "Add \(list) color stop")?.canPress, true, list)
            XCTAssertEqual(control(controls, "AXButton", "Remove last \(list) color stop")?.canPress, true, list)
            XCTAssertNotNil(control(controls, "AXColorWell", "\(list) stop 1"), list)
            XCTAssertNotNil(control(controls, menuRole, "System color for \(list) stop 2"), list)
        }
    }

    private struct UnnamedControls: View {
        @State var color = Color.red
        @State var value = 12.0
        @State var weight = "regular"
        @State var list = "#FFFFFF"
        @State var sidebar = "#000000"

        var body: some View {
            VStack {
                ColorPicker("", selection: $color).labelsHidden()
                Slider(value: $value, in: 0...40)
                Menu { Button("system") {} } label: { Image(systemName: "textformat").accessibilityHidden(true) }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Font family")
                Picker("", selection: $weight) { Text("Regular").tag("regular") }.labelsHidden()
                ColorRow(label: "Background", value: $list)
                ColorRow(label: "Background", value: $sidebar)
            }
            .frame(width: 400)
        }
    }

    func testIdentityCheckRejectsUnnamedGenericAndDuplicateControls() throws {
        enableSwiftUIAccessibility()
        let h = host(UnnamedControls(), size: NSSize(width: 420, height: 400))
        _ = h.accessibilityChildren()
        spin(0.2)
        let problems = AXControl.problems(AXControl.collect(in: h))
        XCTAssertTrue(problems.contains("unnamed AXColorWell"), "\(problems)")
        XCTAssertTrue(problems.contains("unnamed AXSlider"), "\(problems)")
        XCTAssertTrue(problems.contains("unnamed AXPopUpButton"), "\(problems)")
        XCTAssertTrue(problems.contains("generic \(menuRole) Font family"), "\(problems)")
        XCTAssertTrue(problems.contains("duplicate AXColorWell|Background x2"), "\(problems)")
        XCTAssertTrue(problems.contains("duplicate \(menuRole)|System color for Background x2"), "\(problems)")
    }

    private func render(_ view: NSView) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func isMagenta(_ c: NSColor?) -> Bool {
        guard let c = c?.usingColorSpace(.sRGB) else { return false }
        return c.redComponent > 0.85 && c.greenComponent < 0.2 && c.blueComponent > 0.85
    }

    private func magentaRuns(_ rep: NSBitmapImageRep, x: Int) -> [Int] {
        var runs: [Int] = []
        var current = 0
        for y in 0..<rep.pixelsHigh {
            if isMagenta(rep.colorAt(x: x, y: y)) {
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    private func previewListColumnX(_ view: ThemePreviewView) -> Int {
        Int(view.bounds.minX + 12 + 156 + 150)
    }

    func testEditorPreviewUpdatesDensityInPlace() throws {
        ThemeAccessibility.increaseContrastOverride = false
        let manager = makeManager()
        var theme = manager.current
        theme.colors.selection = "#FF00FF"
        manager.applyLive(theme)
        manager.density = .compact
        let h = host(ThemeEditorView(manager: manager), size: NSSize(width: 1000, height: 900))
        let preview = try XCTUnwrap(descendants(of: h, as: ThemePreviewView.self).first)
        XCTAssertEqual(preview.density, .compact)
        let compactRow = theme.layout(density: .compact).rowHeight
        let comfortableRow = theme.layout(density: .comfortable).rowHeight
        XCTAssertLessThan(compactRow, comfortableRow)
        let before = magentaRuns(render(preview), x: previewListColumnX(preview))
        XCTAssertEqual(before, [Int(compactRow)])

        let draws = DrawCounter(ThemePreviewView.self, target: preview)
        defer { draws.restore() }
        spin(0.1)
        draws.count = 0
        manager.density = .comfortable
        XCTAssertTrue(spin { preview.density == .comfortable && draws.count > 0 })
        XCTAssertTrue(descendants(of: h, as: ThemePreviewView.self).first === preview)
        XCTAssertEqual(magentaRuns(render(preview), x: previewListColumnX(preview)), [Int(comfortableRow)])

        draws.count = 0
        manager.density = .compact
        XCTAssertTrue(spin { preview.density == .compact && draws.count > 0 })
        XCTAssertTrue(descendants(of: h, as: ThemePreviewView.self).first === preview)
        XCTAssertEqual(magentaRuns(render(preview), x: previewListColumnX(preview)), [Int(compactRow)])
    }

    private func previewHeaderRun(_ theme: Theme, density: Density) -> Int {
        let view = ThemePreviewView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        view.theme = theme
        view.density = density
        return magentaRuns(render(view), x: previewListColumnX(view)).max() ?? 0
    }

    func testEditorPreviewHeaderGrowsForLargeHeaderFonts() throws {
        ThemeAccessibility.increaseContrastOverride = false
        for id in ["modern", "system7"] {
            var base = try XCTUnwrap(ThemeManager.builtIns.first { $0.id == id })
            base.header.background = "#FF00FF"
            base.colors.selection = "#00FF00"
            base.colors.sidebarSelection = "#00FF00"
            let defaultHeight = TableTheming.headerHeight(for: base, fallback: Spacing.listHeaderHeight) ?? 0
            XCTAssertEqual(defaultHeight, base.header.height > 0 ? CGFloat(base.header.height) : Spacing.listHeaderHeight, id)
            for density in Density.allCases {
                let run = previewHeaderRun(base, density: density)
                XCTAssertTrue(run >= Int(defaultHeight) - 2 && run <= Int(defaultHeight), "\(id) default \(density) run \(run)")
            }
            for size in [24.0, 36.0] {
                var big = base
                big.header.font = Theme.FontSpec(family: "system", size: size)
                let expected = ThemeLayout.fittedHeight(defaultHeight, font: .systemFont(ofSize: CGFloat(size)), verticalPadding: ThemeLayout.headerTextPadding)
                XCTAssertGreaterThan(expected, max(defaultHeight, Spacing.listHeaderHeight))
                XCTAssertEqual(TableTheming.headerHeight(for: big, fallback: Spacing.listHeaderHeight), expected, "\(id) \(size)")
                if big.header.height > 0 {
                    XCTAssertEqual(TableTheming.headerHeight(for: big, fallback: nil), big.layout(density: .regular).headerHeight, "\(id) \(size)")
                }
                for density in Density.allCases {
                    let run = previewHeaderRun(big, density: density)
                    XCTAssertTrue(run >= Int(expected) - 2 && run <= Int(expected), "\(id) \(size) \(density) run \(run) expected \(expected)")
                }
            }
        }
    }

    func testTableThemingFitsHeaderToFontForThemedAndNativeHeaders() throws {
        let byID = Dictionary(uniqueKeysWithValues: ThemeManager.builtIns.map { ($0.id, $0) })
        let table = NSTableView()
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Name"
        table.addTableColumn(col)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sv.documentView = table
        for theme in ThemeManager.builtIns {
            TableTheming.apply(theme, to: table, headerHeight: Spacing.listHeaderHeight)
            XCTAssertEqual(table.headerView?.frame.height, theme.header.height > 0 ? CGFloat(theme.header.height) : Spacing.listHeaderHeight, theme.id)
            XCTAssertEqual(col.headerCell.font?.pointSize, TableTheming.headerFont(for: theme).pointSize, theme.id)
        }
        for id in ["classic-windows", "modern"] {
            for size in [24.0, 36.0] {
                var t = try XCTUnwrap(byID[id])
                t.header.font = Theme.FontSpec(family: "system", size: size)
                TableTheming.apply(t, to: table, headerHeight: Spacing.listHeaderHeight)
                let font = NSFont.systemFont(ofSize: CGFloat(size))
                let expected = ThemeLayout.fittedHeight(t.header.height > 0 ? CGFloat(t.header.height) : Spacing.listHeaderHeight, font: font, verticalPadding: ThemeLayout.headerTextPadding)
                XCTAssertEqual(table.headerView?.frame.height, expected, "\(id) \(size)")
                XCTAssertEqual(table.headerView?.superview?.frame.height, expected, "\(id) \(size)")
                XCTAssertEqual(col.headerCell.font?.pointSize, CGFloat(size), "\(id) \(size)")
                XCTAssertGreaterThanOrEqual(expected, ThemeLayout.lineHeight(font) + ThemeLayout.headerTextPadding)
            }
            TableTheming.apply(try XCTUnwrap(byID[id]), to: table, headerHeight: Spacing.listHeaderHeight)
            XCTAssertEqual(table.headerView?.frame.height, byID[id]!.header.height > 0 ? CGFloat(byID[id]!.header.height) : Spacing.listHeaderHeight, id)
            XCTAssertEqual(col.headerCell.font?.pointSize, 11, id)
        }
    }
}
