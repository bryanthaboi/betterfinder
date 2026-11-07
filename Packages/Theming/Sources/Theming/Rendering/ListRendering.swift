import AppKit

@MainActor
public enum ListRenderer {
    public static func selectionColor(_ theme: Theme, emphasized: Bool) -> NSColor {
        Theme.color(emphasized ? theme.colors.selection : theme.colors.inactiveSelection)
    }

    public static func selectionTextColor(_ theme: Theme, emphasized: Bool) -> NSColor {
        Theme.color(emphasized ? theme.colors.selectionText : theme.colors.inactiveSelectionText)
    }

    public static func drawSelection(in rect: NSRect, theme: Theme, emphasized: Bool) {
        drawSelection(in: rect, theme: theme, emphasized: emphasized, joinsPrevious: false, joinsNext: false)
    }

    public static func selectionRect(for rect: NSRect, theme: Theme, joinsPrevious: Bool = false, joinsNext: Bool = false, flipped: Bool = true) -> NSRect {
        let dx = CGFloat(theme.metrics.selectionInset)
        let dy = CGFloat(theme.metrics.selectionVerticalInset)
        var r = rect.insetBy(dx: dx, dy: 0)
        let top = joinsPrevious ? 0 : dy
        let bottom = joinsNext ? 0 : dy
        r.origin.y += flipped ? top : bottom
        r.size.height = max(0, r.height - top - bottom)
        return r
    }

    public static func drawSelection(in rect: NSRect, theme: Theme, emphasized: Bool, joinsPrevious: Bool, joinsNext: Bool, flipped: Bool = true) {
        let r = selectionRect(for: rect, theme: theme, joinsPrevious: joinsPrevious, joinsNext: joinsNext, flipped: flipped)
        let radius = min(CGFloat(theme.metrics.cornerRadius), r.height / 2)
        let roundTop = !joinsPrevious
        let roundBottom = !joinsNext
        func shape(_ rect: NSRect) -> NSBezierPath {
            guard radius > 0 else { return NSBezierPath(rect: rect) }
            if roundTop && roundBottom { return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) }
            return partiallyRounded(rect, radius: radius, roundMinY: flipped ? roundTop : roundBottom, roundMaxY: flipped ? roundBottom : roundTop)
        }
        selectionColor(theme, emphasized: emphasized).setFill()
        if radius > 0 {
            shape(r).fill()
        } else {
            r.fill(using: .sourceOver)
        }
        let bw = CGFloat(theme.metrics.borderWidth)
        if bw > 0, emphasized {
            Theme.color(theme.colors.accent).setStroke()
            let path = shape(r.insetBy(dx: bw / 2, dy: bw / 2))
            path.lineWidth = bw
            path.stroke()
        }
        if ThemeAccessibility.increaseContrast {
            let width = max(1, bw)
            contrastOutlineColor(theme, emphasized: emphasized).setStroke()
            let path = shape(r.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.stroke()
        }
    }

    public static func contrastOutlineColor(_ theme: Theme, emphasized: Bool) -> NSColor {
        let text = selectionTextColor(theme, emphasized: emphasized)
        let fill = selectionColor(theme, emphasized: emphasized)
        if NSColor.contrastRatio(text, fill) >= NSColor.glyphContrastMinimum { return text.withAlphaComponent(1) }
        return ThemeAccessibility.contrastOutlineColor(against: fill)
    }

    private static func partiallyRounded(_ r: NSRect, radius: CGFloat, roundMinY: Bool, roundMaxY: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let rMin = roundMinY ? radius : 0
        let rMax = roundMaxY ? radius : 0
        p.move(to: NSPoint(x: r.minX + rMin, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - rMin, y: r.minY))
        if rMin > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - rMin, y: r.minY + rMin), radius: rMin, startAngle: 270, endAngle: 360) }
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - rMax))
        if rMax > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - rMax, y: r.maxY - rMax), radius: rMax, startAngle: 0, endAngle: 90) }
        p.line(to: NSPoint(x: r.minX + rMax, y: r.maxY))
        if rMax > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + rMax, y: r.maxY - rMax), radius: rMax, startAngle: 90, endAngle: 180) }
        p.line(to: NSPoint(x: r.minX, y: r.minY + rMin))
        if rMin > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + rMin, y: r.minY + rMin), radius: rMin, startAngle: 180, endAngle: 270) }
        p.close()
        return p
    }

    public static func drawBackground(of table: NSTableView, clipRect: NSRect, theme: Theme) {
        let bg = Theme.color(theme.colors.listBg)
        BevelDrawing.fill(clipRect, bg)
        let rowCount = table.numberOfRows
        let rowStep = table.rowHeight + table.intercellSpacing.height
        let contentBottom = rowCount > 0 ? table.rect(ofRow: rowCount - 1).maxY : 0
        let alt = theme.colors.rowAlt.isEmpty ? nil : Theme.color(theme.colors.rowAlt)
        if let alt {
            let range = table.rows(in: clipRect)
            if range.length > 0 {
                for row in range.location..<(range.location + range.length) where row % 2 == 1 {
                    BevelDrawing.fill(table.rect(ofRow: row).intersection(clipRect), alt)
                }
            }
        }
        guard clipRect.maxY > contentBottom else { return }
        let empty = NSRect(x: clipRect.minX, y: max(contentBottom, clipRect.minY), width: clipRect.width, height: clipRect.maxY - max(contentBottom, clipRect.minY))
        if let p = theme.desktopPattern {
            ThemePatterns.fill(empty, with: ThemePatterns.color(for: p, themeID: theme.id), in: table)
        } else if let alt, rowStep > 0 {
            var row = rowCount
            var y = contentBottom
            while y < empty.maxY {
                if row % 2 == 1, y + rowStep > empty.minY {
                    BevelDrawing.fill(NSRect(x: clipRect.minX, y: y, width: clipRect.width, height: rowStep).intersection(empty), alt)
                }
                y += rowStep
                row += 1
            }
        }
    }

    public static func drawGrid(of table: NSTableView, clipRect: NSRect, theme: Theme) {
        let g = theme.grid
        guard g.horizontal || g.vertical else { return }
        let color = Theme.color(g.color)
        let path = NSBezierPath()
        path.lineWidth = CGFloat(g.width)
        switch g.style {
        case .solid: break
        case .dashed:
            var d: [CGFloat] = [3, 2]
            path.setLineDash(&d, count: 2, phase: 0)
        case .dotted:
            var d: [CGFloat] = [1, 1]
            path.setLineDash(&d, count: 2, phase: 0)
        }
        if g.horizontal {
            let range = table.rows(in: clipRect)
            if range.length > 0 {
                for row in range.location..<(range.location + range.length) {
                    let y = floor(table.rect(ofRow: row).maxY) - 0.5
                    path.move(to: NSPoint(x: clipRect.minX, y: y))
                    path.line(to: NSPoint(x: clipRect.maxX, y: y))
                }
            }
        }
        if g.vertical {
            let rowCount = table.numberOfRows
            let bottom = rowCount > 0 ? min(clipRect.maxY, table.rect(ofRow: rowCount - 1).maxY) : clipRect.minY
            for i in table.columnIndexes(in: clipRect) {
                let x = floor(table.rect(ofColumn: i).maxX) - 0.5
                path.move(to: NSPoint(x: x, y: clipRect.minY))
                path.line(to: NSPoint(x: x, y: bottom))
            }
        }
        color.setStroke()
        path.stroke()
    }

    public static func sidebarHeadingColor(_ theme: Theme) -> NSColor {
        let text = Theme.color(theme.colors.sidebarText)
        let dimmed = text.withAlphaComponent(text.alphaComponent * 0.6)
        let window = Theme.color(theme.colors.windowBg)
        let sidebar = Theme.color(theme.colors.sidebarBg)
        let ratio = NSColor.contrastRatio(dimmed, sidebar.alphaComponent > 0 ? sidebar : window, over: window)
        return ratio >= NSColor.textContrastMinimum ? dimmed : text
    }

    public static func sidebarSelectionRect(for row: NSRect, compact: Bool) -> NSRect {
        row.insetBy(dx: compact ? Spacing.xxs : Spacing.xs, dy: compact ? 0 : 2)
    }

    public static func drawSidebarSelection(in row: NSRect, theme: Theme, compact: Bool) {
        drawSidebarSelection(in: row, theme: theme, compact: compact, cornerRadius: CGFloat(theme.metrics.cornerRadius))
    }

    public static func drawSidebarSelection(in row: NSRect, theme: Theme, compact: Bool, cornerRadius: CGFloat) {
        let sel = sidebarSelectionRect(for: row, compact: compact)
        let r = max(0, min(cornerRadius, sel.height / 2))
        let path = r > 0 ? NSBezierPath(roundedRect: sel, xRadius: r, yRadius: r) : NSBezierPath(rect: sel)
        let fill = Theme.color(theme.colors.sidebarSelection)
        fill.setFill()
        path.fill()
        if ThemeAccessibility.increaseContrast {
            let text = Theme.color(theme.colors.sidebarSelectionText)
            (NSColor.contrastRatio(text, fill) >= NSColor.glyphContrastMinimum ? text : ThemeAccessibility.contrastOutlineColor(against: fill)).setStroke()
            let outline = r > 0 ? NSBezierPath(roundedRect: sel.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r) : NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    public static func iconLabelBackgroundColor(_ theme: Theme, selected: Bool, emphasized: Bool = true) -> NSColor? {
        let il = theme.iconLabels
        if selected { return Theme.color(emphasized ? il.selectionBackground : theme.colors.inactiveSelection) }
        if Theme.isSystemToken(il.background), il.background.lowercased() == "system:clear" { return nil }
        return Theme.color(il.background)
    }

    public static func iconLabelPath(in box: NSRect, theme: Theme, selected: Bool) -> NSBezierPath? {
        switch theme.iconLabels.shape {
        case .pill: return NSBezierPath(roundedRect: box, xRadius: min(box.height / 2, 5), yRadius: min(box.height / 2, 5))
        case .rect: return NSBezierPath(rect: box)
        case .none: return selected ? NSBezierPath(rect: box) : nil
        }
    }

    public static func iconLabelAttributes(_ theme: Theme, selected: Bool, emphasized: Bool = true, alignment: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byTruncatingMiddle
        let il = theme.iconLabels
        let color = selected ? Theme.color(emphasized ? il.selectionText : theme.colors.inactiveSelectionText) : Theme.color(il.text)
        return [.font: theme.iconLabelFont, .foregroundColor: color, .paragraphStyle: para]
    }

    @discardableResult
    public static func drawIconLabel(_ text: String, in rect: NSRect, theme: Theme, selected: Bool, emphasized: Bool = true) -> NSRect {
        let il = theme.iconLabels
        let attrs = iconLabelAttributes(theme, selected: selected, emphasized: emphasized)
        let str = NSAttributedString(string: text, attributes: attrs)
        let font = theme.iconLabelFont
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let maxH = lineH * CGFloat(max(1, il.maxLines))
        let bounding = str.boundingRect(with: NSSize(width: rect.width - 8, height: maxH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let w = min(rect.width, ceil(bounding.width) + 8)
        let h = min(maxH, ceil(bounding.height)) + 2
        let flipped = BevelDrawing.isFlipped
        let box = NSRect(x: floor(rect.midX - w / 2), y: flipped ? rect.minY : rect.maxY - h, width: w, height: h)
        if let bg = iconLabelBackgroundColor(theme, selected: selected, emphasized: emphasized) {
            bg.setFill()
            let path = iconLabelPath(in: box, theme: theme, selected: selected)
            path?.fill()
            if selected, let path, ThemeAccessibility.increaseContrast {
                contrastOutlineColor(theme, emphasized: emphasized).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        str.draw(with: box.insetBy(dx: 4, dy: 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return box
    }
}

open class ThemedTableRowView: NSTableRowView {
    public var themeOverride: Theme?

    public var theme: Theme { themeOverride ?? ThemeManager.shared.current }

    override open func drawSelection(in dirtyRect: NSRect) {
        let t = theme
        if Theme.isSystemToken(t.colors.selection), t.metrics.selectionInset == 0, t.metrics.selectionVerticalInset == 0, t.metrics.borderWidth == 0, !ThemeAccessibility.increaseContrast {
            super.drawSelection(in: dirtyRect)
            return
        }
        ListRenderer.drawSelection(in: bounds, theme: t, emphasized: isEmphasized, joinsPrevious: isPreviousRowSelected, joinsNext: isNextRowSelected, flipped: isFlipped)
    }

    override open var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}
