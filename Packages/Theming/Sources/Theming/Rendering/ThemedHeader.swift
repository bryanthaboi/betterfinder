import AppKit

@MainActor
public enum HeaderRenderer {
    public static func drawBar(in rect: NSRect, theme: Theme) {
        let h = theme.header
        let bg = Theme.color(h.background)
        let p = theme.bevelPalette
        switch h.style {
        case .native:
            BevelDrawing.fill(rect, bg)
        case .flat, .etched:
            BevelDrawing.fill(rect, bg)
            SurfaceRenderer.line(.maxY, of: rect, Theme.color(h.separator))
        case .raised:
            BevelDrawing.verticalGradient([p.highlight, bg], in: rect)
            SurfaceRenderer.line(.maxY, of: rect, p.darkShadow)
        case .win3d:
            BevelDrawing.fill(rect, bg)
        case .sunken:
            BevelDrawing.fill(rect, bg)
            BevelDrawing.draw(.thinSunken, in: rect, palette: p, fillFace: false)
        }
    }

    public static func drawCell(in rect: NSRect, theme: Theme, pressed: Bool, sorted: Bool) {
        let h = theme.header
        let bg = Theme.color(h.background)
        let sep = Theme.color(h.separator)
        let p = theme.bevelPalette
        switch h.style {
        case .native, .flat:
            BevelDrawing.fill(rect, pressed ? (bg.blended(withFraction: 0.1, of: .black) ?? bg) : bg)
            SurfaceRenderer.line(.maxY, of: rect, sep)
            let inset = floor(rect.height * 0.2)
            BevelDrawing.fill(NSRect(x: rect.maxX - 1, y: rect.minY + inset, width: 1, height: rect.height - inset * 2), sep)
        case .raised:
            let face = sorted ? (bg.blended(withFraction: 0.12, of: .black) ?? bg) : bg
            BevelDrawing.verticalGradient([pressed ? p.shadow : p.highlight, pressed ? face.blended(withFraction: 0.2, of: .black) ?? face : face], in: rect)
            BevelDrawing.ring(rect.integral, topLeft: pressed ? p.shadow : p.highlight, bottomRight: p.shadow)
            SurfaceRenderer.line(.maxY, of: rect, p.darkShadow)
        case .win3d:
            BevelDrawing.draw(pressed ? .thinSunken : .raised, in: rect, palette: p.withFace(bg))
        case .sunken:
            BevelDrawing.fill(rect, bg)
            BevelDrawing.draw(.thinSunken, in: rect, palette: p, fillFace: false)
        case .etched:
            BevelDrawing.fill(rect, bg)
            SurfaceRenderer.line(.maxY, of: rect, sep)
            let inset = floor(rect.height * 0.2)
            BevelDrawing.etchedVerticalLine(x: rect.maxX - 2, from: rect.minY + inset, to: rect.maxY - inset, palette: p)
        }
    }

    public static func drawTitle(_ title: String, in rect: NSRect, theme: Theme, alignment: NSTextAlignment, sortAscending: Bool?, pressed: Bool) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: TableTheming.headerFont(for: theme), .foregroundColor: Theme.color(theme.header.text), .paragraphStyle: para]
        let off: CGFloat = pressed && theme.header.style == .win3d ? 1 : 0
        let pad = CGFloat(theme.metrics.cellHorizontalInset)
        var textRect = rect.insetBy(dx: pad, dy: 0).offsetBy(dx: off, dy: off)
        if sortAscending != nil { textRect.size.width -= 12 }
        let str = NSAttributedString(string: title, attributes: attrs)
        let h = ceil(str.size().height)
        str.draw(with: NSRect(x: textRect.minX, y: floor(rect.midY - h / 2), width: max(0, textRect.width), height: h),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let asc = sortAscending {
            let r = NSRect(x: rect.maxX - pad - 10 + off, y: rect.midY - 5 + off, width: 10, height: 10)
            BevelDrawing.triangle(asc ? .up : .down, in: r, color: Theme.color(theme.header.sortIndicator), size: 7)
        }
    }
}

open class ThemedHeaderCell: NSTableHeaderCell {
    public var themeOverride: Theme?
    public var sortAscending: Bool?
    public var isPressedState = false

    @MainActor
    public var theme: Theme { themeOverride ?? ThemeManager.shared.current }

    override open func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        MainActor.assumeIsolated {
            let t = theme
            guard t.header.style != .native else {
                super.draw(withFrame: cellFrame, in: controlView)
                return
            }
            HeaderRenderer.drawCell(in: cellFrame, theme: t, pressed: isPressedState || isHighlighted, sorted: sortAscending != nil)
            HeaderRenderer.drawTitle(stringValue, in: cellFrame, theme: t, alignment: alignment, sortAscending: sortAscending, pressed: isPressedState || isHighlighted)
        }
    }

    override open func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let native = MainActor.assumeIsolated { theme.header.style == .native }
        if native { super.drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: priority) }
    }
}

open class ThemedHeaderView: NSTableHeaderView {
    public var themeOverride: Theme?

    public var theme: Theme { themeOverride ?? ThemeManager.shared.current }

    override open func draw(_ dirtyRect: NSRect) {
        let t = theme
        guard t.header.style != .native, let table = tableView else {
            super.draw(dirtyRect)
            return
        }
        HeaderRenderer.drawBar(in: bounds, theme: t)
        let sort = table.sortDescriptors.first
        let cols = table.columnIndexes(in: dirtyRect)
        for i in cols {
            let col = table.tableColumns[i]
            let rect = headerRect(ofColumn: i)
            if let cell = col.headerCell as? ThemedHeaderCell {
                cell.themeOverride = t
                if let sort, let proto = col.sortDescriptorPrototype, proto.key == sort.key {
                    cell.sortAscending = sort.ascending
                } else {
                    cell.sortAscending = nil
                }
                cell.isPressedState = false
                cell.draw(withFrame: rect, in: self)
            } else {
                col.headerCell.draw(withFrame: rect, in: self)
            }
        }
        if let last = table.tableColumns.indices.last {
            let end = headerRect(ofColumn: last).maxX
            if end < bounds.maxX, t.header.style == .win3d {
                let filler = NSRect(x: end, y: bounds.minY, width: bounds.maxX - end, height: bounds.height)
                BevelDrawing.draw(.raised, in: filler, palette: t.bevelPalette.withFace(Theme.color(t.header.background)))
            }
        }
    }
}

open class PaddedHeaderCell: NSTableHeaderCell {
    public static let builtInInset: CGFloat = 3
    public var horizontalPadding: CGFloat = 0

    override open func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: horizontalPadding, dy: 0), in: controlView)
    }

    override open func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: horizontalPadding, dy: 0))
    }
}

@MainActor
public enum TableTheming {
    static let nativeHeaderFont: NSFont = NSTableHeaderCell(textCell: "").font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)

    public static func headerFont(for theme: Theme) -> NSFont {
        theme.header.style == .native && theme.header.font == nil ? nativeHeaderFont : theme.headerFont
    }

    public static func headerHeight(for theme: Theme, fallback: CGFloat?) -> CGFloat? {
        let base: CGFloat? = theme.header.height > 0 ? CGFloat(theme.header.height) : fallback
        return base.map { fittedHeaderHeight($0, theme: theme) }
    }

    private static func fittedHeaderHeight(_ minimum: CGFloat, theme: Theme) -> CGFloat {
        ThemeLayout.fittedHeight(minimum, font: headerFont(for: theme), verticalPadding: ThemeLayout.headerTextPadding)
    }

    public static func apply(_ theme: Theme, to table: NSTableView, headerHeight: CGFloat? = nil) {
        let native = theme.header.style == .native
        let font = headerFont(for: theme)
        for col in table.tableColumns {
            let old = col.headerCell
            if native {
                let isOutline = (table as? NSOutlineView)?.outlineTableColumn === col
                let padding = isOutline ? 0 : max(0, CGFloat(theme.metrics.cellHorizontalInset) - PaddedHeaderCell.builtInInset)
                if let padded = old as? PaddedHeaderCell {
                    padded.horizontalPadding = padding
                    padded.font = font
                } else if old is ThemedHeaderCell || type(of: old) == NSTableHeaderCell.self {
                    let cell = PaddedHeaderCell(textCell: old.stringValue)
                    cell.alignment = old.alignment
                    cell.horizontalPadding = padding
                    cell.font = font
                    col.headerCell = cell
                }
            } else {
                let cell = (old as? ThemedHeaderCell) ?? {
                    let c = ThemedHeaderCell(textCell: old.stringValue)
                    c.alignment = old.alignment
                    c.lineBreakMode = .byTruncatingTail
                    return c
                }()
                cell.font = font
                cell.themeOverride = theme
                if col.headerCell !== cell { col.headerCell = cell }
            }
        }
        if let header = table.headerView {
            let wanted = self.headerHeight(for: theme, fallback: headerHeight)
            if native, header is ThemedHeaderView {
                table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: header.frame.width, height: wanted ?? fittedHeaderHeight(28, theme: theme)))
            } else if !native, !(header is ThemedHeaderView) {
                table.headerView = ThemedHeaderView(frame: NSRect(x: 0, y: 0, width: header.frame.width, height: wanted ?? fittedHeaderHeight(max(header.frame.height, 20), theme: theme)))
            } else {
                let target = wanted ?? fittedHeaderHeight(header.frame.height, theme: theme)
                if header.frame.height != target { header.frame.size.height = target }
            }
            (table.headerView as? ThemedHeaderView)?.themeOverride = theme
            table.headerView?.needsDisplay = true
        }

        var mask: NSTableView.GridLineStyle = []
        let g = theme.grid
        if g.horizontal { mask.insert(g.style == .solid ? .solidHorizontalGridLineMask : .dashedHorizontalGridLineMask) }
        if g.vertical { mask.insert(.solidVerticalGridLineMask) }
        table.gridStyleMask = mask
        table.gridColor = Theme.color(g.color)
        table.enclosingScrollView?.tile()
        table.needsDisplay = true
    }
}
