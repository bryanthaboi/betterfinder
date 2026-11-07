import AppKit

public enum Spacing {
    public static let hairline: CGFloat = 1
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 20
    public static let xl: CGFloat = 28

    public static let relatedText = xxs
    public static let iconText = xs
    public static let control = xs
    public static let containerPadding = s
    public static let panelPadding = m
    public static let sectionGap = m
    public static let groupGap = m
    public static let dialogMargin = l
    public static let onboardingMargin = xl

    public static let hitTarget: CGFloat = 28
    public static let controlHeight: CGFloat = 32
    public static let crumbHeight: CGFloat = 24
    public static let crumbPaddingH = xs
    public static let crumbPaddingHCompact = xxs
    public static let crumbPaddingV = xxs
    public static let crumbSeparatorWidth = xs
    public static let crumbSeparatorGap = xxs
    public static let listHeaderHeight: CGFloat = 28
    public static let sortIndicatorReserve: CGFloat = 20
    public static let outlineIndent: CGFloat = 16
    public static let columnWidth: CGFloat = 240
    public static let columnChevronWidth: CGFloat = 8
    public static let columnChevronReserve: CGFloat = 24
    public static let sidebarHeadingAbove = s
    public static let sidebarHeadingBelow = xxs
    public static let sidebarTopInset = xs
    public static let infoPanelWidth: CGFloat = 360
    public static let paletteWidth: CGFloat = 520
    public static let paletteRowHeight: CGFloat = 48
    public static let panelHeaderHeight: CGFloat = 44
    public static let operationRowHeight: CGFloat = 80
    public static let iconItemMinWidth: CGFloat = 112
    public static let iconItemHorizontalExtra: CGFloat = 48
    public static let iconItemVerticalExtra: CGFloat = 56
    public static let iconLabelHeight: CGFloat = 32
}

public enum Density: String, CaseIterable, Codable, Hashable, Sendable {
    case compact, regular, comfortable

    nonisolated public static let defaultsKey = "density"

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .comfortable: return "Comfortable"
        }
    }

    var step: Double {
        switch self {
        case .compact: return -1
        case .regular: return 0
        case .comfortable: return 1
        }
    }
}

public struct ThemeLayout: Hashable, Sendable {
    public var density: Density
    public var isAuthenticCompact: Bool
    public var rowHeight: CGFloat
    public var sidebarRowHeight: CGFloat
    public var statusBarHeight: CGFloat
    public var pathBarHeight: CGFloat
    public var headerHeight: CGFloat
    public var listIconSize: CGFloat
    public var cellHorizontalInset: CGFloat
    public var iconTextGap: CGFloat
    public var selectionInset: CGFloat
    public var selectionVerticalInset: CGFloat
    public var cornerRadius: CGFloat
    public var iconGridGapH: CGFloat
    public var iconGridGapV: CGFloat
    public var iconGridInset: CGFloat

    public var listLeadingInset: CGFloat { selectionInset > 0 ? max(cellHorizontalInset, selectionInset + Spacing.xxs) : cellHorizontalInset }

    public func iconItemSize(iconSize s: CGFloat) -> NSSize {
        NSSize(width: max(Spacing.iconItemMinWidth, s + Spacing.iconItemHorizontalExtra), height: s + Spacing.iconItemVerticalExtra)
    }
}

public extension Theme {
    var defaultDensity: Density {
        if let d = metrics.defaultDensity { return d }
        return isRetro && metrics.rowHeight < 24 ? .compact : .regular
    }

    func layout(density chosen: Density?) -> ThemeLayout {
        let m = metrics
        let base = defaultDensity
        let target = chosen ?? base
        let steps = target.step - base.step
        let rowsOnly = base == .compact
        func grow(_ v: Double, by perStep: Double) -> CGFloat { CGFloat(max(0, v + steps * perStep)) }
        func iconGrow(_ v: Double) -> CGFloat {
            guard !rowsOnly else { return CGFloat(v) }
            let up = target == .comfortable && base != .comfortable
            let down = base == .comfortable && target != .comfortable
            return CGFloat(v + (up ? 4 : 0) - (down ? 4 : 0))
        }
        let sidebarBase = m.sidebarRowHeight > 0 ? m.sidebarRowHeight : m.rowHeight + 4
        let grid = rowsOnly ? 0 : 4.0
        let icon = iconGrow(m.listIconSize)
        let fit = ThemeLayout.fittedHeight
        let row = max(fit(max(14, grow(m.rowHeight, by: 4)), listFont, ThemeLayout.rowTextPadding), icon + ThemeLayout.rowIconPadding)
        return ThemeLayout(
            density: target,
            isAuthenticCompact: base == .compact,
            rowHeight: row,
            sidebarRowHeight: fit(max(16, grow(sidebarBase, by: 4)), sidebarFont, ThemeLayout.sidebarTextPadding),
            statusBarHeight: fit(CGFloat(max(16, m.statusBarHeight)), statusBarFont, ThemeLayout.statusTextPadding),
            pathBarHeight: fit(CGFloat(max(18, m.pathBarHeight)), pathBarFont, ThemeLayout.pathTextPadding),
            headerHeight: header.height > 0 ? fit(CGFloat(header.height), headerFont, ThemeLayout.headerTextPadding) : CGFloat(header.height),
            listIconSize: icon,
            cellHorizontalInset: CGFloat(m.cellHorizontalInset),
            iconTextGap: CGFloat(m.iconTextGap),
            selectionInset: CGFloat(m.selectionInset),
            selectionVerticalInset: CGFloat(m.selectionVerticalInset),
            cornerRadius: CGFloat(m.cornerRadius),
            iconGridGapH: grow(m.iconGridGapH, by: grid),
            iconGridGapV: grow(m.iconGridGapV, by: grid),
            iconGridInset: grow(m.iconGridInset, by: grid)
        )
    }
}

@MainActor
public extension Theme {
    var layout: ThemeLayout { layout(density: ThemeManager.shared.density) }
}

public extension ThemeLayout {
    static let rowTextPadding: CGFloat = 1
    static let rowIconPadding: CGFloat = 1
    static let sidebarTextPadding: CGFloat = 2
    static let statusTextPadding: CGFloat = 4
    static let pathTextPadding: CGFloat = 2 * Spacing.crumbPaddingV
    static let headerTextPadding: CGFloat = 2

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func fittedHeight(_ minimum: CGFloat, font: NSFont, verticalPadding: CGFloat) -> CGFloat {
        max(minimum, lineHeight(font) + verticalPadding)
    }

    func iconItemSize(iconSize s: CGFloat, labelFont: NSFont, maxLines: Int) -> NSSize {
        let base = iconItemSize(iconSize: s)
        let label = max(Spacing.iconLabelHeight, Self.lineHeight(labelFont) * CGFloat(max(1, maxLines)))
        return NSSize(width: base.width, height: base.height - Spacing.iconLabelHeight + label)
    }
}
