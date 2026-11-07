import AppKit

@MainActor
open class ThemePreviewView: NSView {
    public var theme: Theme = ThemeManager.shared.current {
        didSet {
            if theme != oldValue {
                appearance = theme.appearance
                needsDisplay = true
            }
        }
    }
    public var windowTitle = "Documents"
    public var density: Density? = ThemeManager.shared.density { didSet { if density != oldValue { needsDisplay = true } } }
    public var isActive = true { didSet { if isActive != oldValue { needsDisplay = true } } }

    override open var isFlipped: Bool { true }

    override open var intrinsicContentSize: NSSize { NSSize(width: 560, height: 360) }

    override open func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override open func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawMockWindow(in: bounds.insetBy(dx: 12, dy: 12))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMockWindow(in frame: NSRect) {
        let t = theme
        let native = t.window.isNative
        let radius: CGFloat = native ? 10 : (t.window.buttons == .winCaption && t.window.buttonBevel ? 0 : 4)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        Theme.color(t.colors.windowBg).setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        ThemePatterns.fill(frame, with: t.windowBackgroundColor, in: self)

        let inset = CGFloat(t.window.captionInset)
        let stripH: CGFloat = 26 + inset * 2
        let toolbarH: CGFloat = 34
        let strip = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: stripH)
        let buttons = buttonFrames(in: strip)
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        for (_, r) in buttons {
            if r.midX < strip.midX { leading = max(leading, r.maxX - strip.minX + 4) } else { trailing = max(trailing, strip.maxX - r.minX + 4) }
        }
        if native {
            Theme.color(t.colors.toolbarBg).setFill()
            NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: stripH + toolbarH).fill()
            TitlebarRenderer.drawTitle(windowTitle, in: strip, theme: t, active: isActive, leadingInset: leading, trailingInset: trailing, clearColor: nil)
        } else {
            TitlebarRenderer.drawStrip(in: strip, theme: t, title: windowTitle, active: isActive, leadingInset: leading, trailingInset: trailing, patternView: self)
            TitlebarRenderer.drawToolbarArea(in: NSRect(x: frame.minX, y: strip.maxY, width: frame.width, height: toolbarH), theme: t, active: isActive, patternView: self)
        }
        for (kind, r) in buttons {
            WindowButtonRenderer.draw(kind, in: r, theme: t, pressed: false, active: isActive)
        }
        if native {
            SurfaceRenderer.line(.maxY, of: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: stripH + toolbarH), Theme.color(t.colors.border))
        }

        drawToolbarItems(in: NSRect(x: frame.minX, y: strip.maxY, width: frame.width, height: toolbarH))

        let lay = t.layout(density: density)
        let statusH = min(36, max(18, lay.statusBarHeight))
        let pathH = min(40, max(18, lay.pathBarHeight))
        let bodyTop = strip.maxY + toolbarH
        let status = NSRect(x: frame.minX, y: frame.maxY - statusH, width: frame.width, height: statusH)
        let path = NSRect(x: frame.minX, y: status.minY - pathH, width: frame.width, height: pathH)
        let body = NSRect(x: frame.minX, y: bodyTop, width: frame.width, height: path.minY - bodyTop)
        let sidebarW: CGFloat = 156
        let sidebar = NSRect(x: body.minX, y: body.minY, width: sidebarW, height: body.height)
        let list = NSRect(x: sidebar.maxX, y: body.minY, width: body.width - sidebarW, height: body.height)

        drawSidebar(in: sidebar)
        drawList(in: list)
        drawPathBar(in: path)
        drawStatusBar(in: status)
        NSGraphicsContext.restoreGraphicsState()

        let border = native ? NSColor.black.withAlphaComponent(0.25) : Theme.color(t.window.frameColor)
        border.setStroke()
        let stroke = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        stroke.lineWidth = 1
        stroke.stroke()
    }

    private func buttonFrames(in strip: NSRect) -> [(WindowButtonKind, NSRect)] {
        let t = theme
        let size = WindowButtonRenderer.size(for: t)
        let spacing = WindowButtonRenderer.spacing(for: t)
        let inset = CGFloat(t.window.captionInset)
        let cy = strip.midY
        func rect(x: CGFloat) -> NSRect { NSRect(x: x, y: floor(cy - size.height / 2), width: size.width, height: size.height) }
        switch t.window.buttons {
        case .native:
            let s: CGFloat = 12
            return [WindowButtonKind.close, .minimize, .zoom].enumerated().map { i, k in
                (k, NSRect(x: strip.minX + 10 + CGFloat(i) * (s + 8), y: floor(cy - s / 2), width: s, height: s))
            }
        case .classicBoxes:
            var out: [(WindowButtonKind, NSRect)] = [(.close, rect(x: strip.minX + 9 + inset))]
            var x = strip.maxX - 9 - inset - size.width
            if t.window.showsMinimize {
                out.append((.minimize, rect(x: x)))
                x -= size.width + spacing
            }
            out.append((.zoom, rect(x: x)))
            return out
        case .winCaption:
            var out: [(WindowButtonKind, NSRect)] = []
            var x = strip.maxX - 2 - inset - size.width
            out.append((.close, rect(x: x)))
            x -= size.width + 2
            out.append((.zoom, rect(x: x)))
            if t.window.showsMinimize {
                x -= size.width + spacing
                out.append((.minimize, rect(x: x)))
            }
            return out
        }
    }

    private func drawToolbarItems(in bar: NSRect) {
        let t = theme
        let symbols = ["chevron.left", "chevron.right", "arrow.up"]
        let h: CGFloat = 24
        let w: CGFloat = 30
        var x = bar.minX + 150
        let y = floor(bar.midY - h / 2)
        for (i, name) in symbols.enumerated() {
            let r = NSRect(x: x, y: y, width: w, height: h)
            let state: ThemedControlState = i == 1 ? [.disabled] : (i == 2 ? [.hover] : [])
            drawToolbarButton(symbol: name, in: r, state: state)
            x += w + (t.toolbar.style == .win3d ? 1 : 4)
        }
        let modes = ["list.bullet", "square.grid.2x2", "rectangle.split.3x1"]
        x = bar.maxX - 12 - CGFloat(modes.count) * w
        for (i, name) in modes.enumerated() {
            let r = NSRect(x: x, y: y, width: w, height: h)
            drawToolbarButton(symbol: name, in: r, state: i == 0 ? [.on] : [])
            x += w
        }
    }

    private func drawToolbarButton(symbol: String, in r: NSRect, state: ThemedControlState) {
        let t = theme
        if t.toolbar.style == .native {
            let fill = state.contains(.on) ? NSColor.labelColor.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.05)
            fill.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        } else {
            ToolbarButtonRenderer.drawBezel(in: r, theme: t, state: state)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img?.isTemplate = true
        ToolbarButtonRenderer.drawContent(image: img, title: nil, in: r, theme: t, state: state)
    }

    private func drawSidebar(in rect: NSRect) {
        let t = theme
        let bg = Theme.color(t.colors.sidebarBg)
        if t.surfaces.sidebar == .native && Theme.isSystemToken(t.colors.sidebarBg) {
            NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .labelColor)?.setFill()
            rect.fill()
        } else {
            SurfaceRenderer.draw(t.surfaces.sidebar, in: rect, background: bg, border: Theme.color(t.colors.border), palette: t.bevelPalette, edge: .maxX)
        }
        let font = t.sidebarFont
        let lay = t.layout(density: density)
        let rowH = lay.sidebarRowHeight
        let compact = lay.isAuthenticCompact
        let edge = compact ? Spacing.xs : Spacing.m
        let selInsetX = compact ? Spacing.xxs : Spacing.xs
        var y = rect.minY + Spacing.sidebarTopInset
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ListRenderer.sidebarHeadingColor(t)]
        let heading = NSAttributedString(string: "Favorites", attributes: headerAttrs)
        heading.draw(at: NSPoint(x: rect.minX + edge, y: y))
        y += ceil(heading.size().height) + Spacing.sidebarHeadingBelow
        let items: [(String, String)] = [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"), ("Applications", "square.grid.3x3"), ("Home", "house")]
        for (i, item) in items.enumerated() {
            let row = NSRect(x: rect.minX + selInsetX, y: y, width: rect.width - selInsetX * 2, height: rowH)
            let selected = i == 1
            if selected {
                ListRenderer.drawSidebarSelection(in: NSRect(x: rect.minX, y: y, width: rect.width, height: rowH), theme: t, compact: compact, cornerRadius: compact ? 0 : CGFloat(t.metrics.cornerRadius))
            }
            let iconX = rect.minX + edge
            let iconSide: CGFloat = 16
            let textColor = Theme.color(selected ? t.colors.sidebarSelectionText : t.colors.sidebarText)
            let iconColor = selected ? textColor : Theme.color(t.colors.sidebarIcon)
            if let img = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                img.isTemplate = true
                let tinted = ToolbarButtonRenderer.tinted(img, color: iconColor)
                let s = tinted.size
                tinted.draw(in: NSRect(x: iconX + floor((iconSide - s.width) / 2), y: floor(row.midY - s.height / 2), width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let str = NSAttributedString(string: item.0, attributes: attrs)
            str.draw(at: NSPoint(x: iconX + iconSide + (compact ? Spacing.xxs + 2 : Spacing.iconText), y: floor(row.midY - str.size().height / 2)))
            y += rowH
            if y > rect.maxY - rowH { break }
        }
    }

    private func drawList(in outer: NSRect) {
        let t = theme
        var rect = outer
        if t.surfaces.list != .native {
            SurfaceRenderer.draw(t.surfaces.list, in: outer, background: Theme.color(t.colors.listBg), border: Theme.color(t.colors.border), palette: t.bevelPalette)
            rect = outer.insetBy(dx: t.surfaces.list == .sunken ? 3 : 1, dy: t.surfaces.list == .sunken ? 3 : 1)
        }
        let showScroller = t.scrollbar.style != .native
        let sbW = showScroller ? CGFloat(t.scrollbar.width) : 0
        let lay = t.layout(density: density)
        let headerH = TableTheming.headerHeight(for: t, fallback: Spacing.listHeaderHeight) ?? Spacing.listHeaderHeight
        let pad = lay.cellHorizontalInset
        let content = NSRect(x: rect.minX, y: rect.minY, width: rect.width - sbW, height: rect.height)
        BevelDrawing.fill(content, Theme.color(t.colors.listBg))

        let header = NSRect(x: content.minX, y: content.minY, width: content.width, height: headerH)
        let cols: [(String, CGFloat, NSTextAlignment)] = [("Name", 0.5, .left), ("Size", 0.18, .right), ("Kind", 0.32, .left)]
        HeaderRenderer.drawBar(in: header, theme: t)
        var cx = header.minX
        var colRects: [NSRect] = []
        for (i, c) in cols.enumerated() {
            let w = i == cols.count - 1 ? header.maxX - cx : floor(header.width * c.1)
            let r = NSRect(x: cx, y: header.minY, width: w, height: headerH)
            colRects.append(r)
            if t.header.style != .native {
                HeaderRenderer.drawCell(in: r, theme: t, pressed: false, sorted: i == 0)
            } else if i < cols.count - 1 {
                BevelDrawing.fill(NSRect(x: r.maxX - 1, y: r.minY + 5, width: 1, height: r.height - 10), Theme.color(t.header.separator))
            }
            HeaderRenderer.drawTitle(c.0, in: r, theme: t, alignment: c.2, sortAscending: i == 0 ? true : nil, pressed: false)
            cx += w
        }
        if t.header.style == .native { SurfaceRenderer.line(.maxY, of: header, Theme.color(t.header.separator)) }

        let rows: [(String, String, String, String)] = [
            ("Projects", "--", "Folder", "folder"), ("Report.pdf", "2.4 MB", "PDF Document", "doc.richtext"),
            ("Photos", "--", "Folder", "folder"), ("notes.txt", "4 KB", "Plain Text", "doc.text"),
            ("Budget.numbers", "312 KB", "Spreadsheet", "tablecells"), ("Archive.zip", "88 MB", "ZIP Archive", "doc.zipper"),
        ]
        let rowH = lay.rowHeight
        var y = header.maxY
        let selectedRow = 1
        let alt = t.colors.rowAlt.isEmpty ? nil : Theme.color(t.colors.rowAlt)
        let font = t.listFont
        for (i, row) in rows.enumerated() {
            let r = NSRect(x: content.minX, y: y, width: content.width, height: rowH)
            if let alt, i % 2 == 1 { BevelDrawing.fill(r, alt) }
            let selected = i == selectedRow
            if selected {
                ListRenderer.drawSelection(in: r, theme: t, emphasized: true)
            }
            let textColor = selected ? ListRenderer.selectionTextColor(t, emphasized: true) : Theme.color(t.colors.text)
            let secondary = selected ? textColor : Theme.color(t.colors.secondaryText)
            let iconColor = selected ? textColor : Theme.color(row.3 == "folder" ? t.colors.accent : t.colors.secondaryText)
            let iconSize = min(lay.listIconSize, rowH - 2)
            if let img = NSImage(systemSymbolName: row.3, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: iconSize * 0.8, weight: .regular)) {
                img.isTemplate = true
                let tinted = ToolbarButtonRenderer.tinted(img, color: iconColor)
                let s = tinted.size
                let iconX = colRects[0].minX + lay.listLeadingInset
                tinted.draw(in: NSRect(x: iconX + floor((iconSize - s.width) / 2), y: floor(r.midY - s.height / 2), width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let textX = colRects[0].minX + lay.listLeadingInset + iconSize + lay.iconTextGap
            drawCellText(row.0, in: NSRect(x: textX, y: r.minY, width: colRects[0].maxX - textX - pad, height: rowH), font: font, color: textColor, alignment: .left)
            drawCellText(row.1, in: NSRect(x: colRects[1].minX + pad, y: r.minY, width: colRects[1].width - pad * 2, height: rowH), font: font, color: secondary, alignment: .right)
            drawCellText(row.2, in: NSRect(x: colRects[2].minX + pad, y: r.minY, width: colRects[2].width - pad * 2, height: rowH), font: font, color: secondary, alignment: .left)
            y += rowH
            if y > content.maxY { break }
        }

        let g = t.grid
        if g.horizontal || g.vertical {
            let path = NSBezierPath()
            path.lineWidth = CGFloat(g.width)
            if g.style == .dashed { var d: [CGFloat] = [3, 2]; path.setLineDash(&d, count: 2, phase: 0) }
            if g.style == .dotted { var d: [CGFloat] = [1, 1]; path.setLineDash(&d, count: 2, phase: 0) }
            if g.horizontal {
                var gy = header.maxY + rowH
                while gy <= y {
                    path.move(to: NSPoint(x: content.minX, y: gy - 0.5))
                    path.line(to: NSPoint(x: content.maxX, y: gy - 0.5))
                    gy += rowH
                }
            }
            if g.vertical {
                for r in colRects.dropLast() {
                    path.move(to: NSPoint(x: r.maxX - 0.5, y: header.maxY))
                    path.line(to: NSPoint(x: r.maxX - 0.5, y: y))
                }
            }
            Theme.color(g.color).setStroke()
            path.stroke()
        }

        if y < content.maxY {
            let empty = NSRect(x: content.minX, y: y, width: content.width, height: content.maxY - y)
            if t.desktopPattern != nil {
                ThemePatterns.fill(empty, with: t.emptyListBackgroundColor, in: self)
                if empty.height > 56 {
                    let iconRect = NSRect(x: empty.minX + 18, y: empty.minY + 8, width: 72, height: 28)
                    if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) {
                        img.isTemplate = true
                        let tinted = ToolbarButtonRenderer.tinted(img, color: Theme.color(t.colors.accent))
                        let s = tinted.size
                        BevelDrawing.fill(NSRect(x: iconRect.midX - s.width / 2 - 1, y: iconRect.minY - 1, width: s.width + 2, height: s.height + 2), Theme.color(t.colors.listBg))
                        tinted.draw(in: NSRect(x: iconRect.midX - s.width / 2, y: iconRect.minY, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    ListRenderer.drawIconLabel("Stuff", in: NSRect(x: iconRect.minX, y: iconRect.maxY + 2, width: iconRect.width, height: 18), theme: t, selected: false)
                }
            } else if let alt {
                var i = rows.count
                var ry = y
                while ry < content.maxY {
                    if i % 2 == 1 { BevelDrawing.fill(NSRect(x: content.minX, y: ry, width: content.width, height: min(rowH, content.maxY - ry)), alt) }
                    ry += rowH
                    i += 1
                }
            }
        }

        if showScroller {
            let sb = NSRect(x: content.maxX, y: rect.minY, width: sbW, height: rect.height)
            BevelDrawing.fill(NSRect(x: sb.minX, y: sb.minY, width: sb.width, height: headerH), Theme.color(t.header.background))
            if t.header.style == .win3d {
                BevelDrawing.draw(.raised, in: NSRect(x: sb.minX, y: sb.minY, width: sb.width, height: headerH), palette: t.bevelPalette.withFace(Theme.color(t.header.background)))
            }
            ScrollbarRenderer.draw(in: NSRect(x: sb.minX, y: sb.minY + headerH, width: sb.width, height: sb.height - headerH), vertical: true, theme: t, proportion: 0.45, value: 0.15, enabled: true)
        } else {
            let k = NSRect(x: content.maxX - 9, y: header.maxY + 8, width: 6, height: content.height * 0.35)
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: k, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawCellText(_ s: String, in r: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byTruncatingTail
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let h = ceil(str.size().height)
        str.draw(with: NSRect(x: r.minX, y: floor(r.midY - h / 2), width: r.width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPathBar(in rect: NSRect) {
        let t = theme
        SurfaceRenderer.draw(t.pathBar.style, in: rect, background: Theme.color(t.pathBar.background), border: Theme.color(t.colors.border), palette: t.bevelPalette, edge: .minY)
        if t.pathBar.style == .native { SurfaceRenderer.line(.minY, of: rect, Theme.color(t.colors.border)) }
        let font = t.pathBarFont
        let compact = t.layout(density: density).isAuthenticCompact
        let crumbPad = compact ? Spacing.xxs : Spacing.crumbPaddingH
        var x = rect.minX + (compact ? Spacing.xs : Spacing.s)
        let parts = ["Macintosh HD", "Users", "you", "Documents"]
        for (i, p) in parts.enumerated() {
            let last = i == parts.count - 1
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.color(last ? t.pathBar.highlight : t.pathBar.text)]
            let s = NSAttributedString(string: p, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: x, y: floor(rect.midY - size.height / 2)))
            x += size.width + crumbPad + Spacing.crumbSeparatorGap
            if !last {
                BevelDrawing.triangle(.right, in: NSRect(x: x, y: rect.midY - 4, width: Spacing.crumbSeparatorWidth, height: 8), color: Theme.color(t.pathBar.separator), size: 6)
                x += Spacing.crumbSeparatorWidth + Spacing.crumbSeparatorGap + crumbPad
            }
        }
    }

    private func drawStatusBar(in rect: NSRect) {
        let t = theme
        SurfaceRenderer.draw(t.surfaces.statusBar, in: rect, background: Theme.color(t.colors.statusBarBg), border: Theme.color(t.colors.border), palette: t.bevelPalette, edge: .minY)
        if t.surfaces.statusBar == .native { SurfaceRenderer.line(.minY, of: rect, Theme.color(t.colors.border)) }
        let attrs: [NSAttributedString.Key: Any] = [.font: t.statusBarFont, .foregroundColor: Theme.color(t.colors.statusBarText)]
        let s = NSAttributedString(string: "6 items, 1 selected (2.4 MB) — 120.4 GB available", attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: floor(rect.midX - size.width / 2), y: floor(rect.midY - size.height / 2)))
    }
}
