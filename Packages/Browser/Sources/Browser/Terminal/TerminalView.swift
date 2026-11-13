import AppKit

enum TerminalPalette {
    static let ansi: [NSColor] = [
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.27, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.70, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.84, green: 0.66, blue: 0.22, alpha: 1),
        NSColor(srgbRed: 0.27, green: 0.50, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.70, green: 0.38, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.66, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.45, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.50, green: 0.86, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.82, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.66, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.88, green: 0.56, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.85, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]

    static func color(_ index: UInt8) -> NSColor {
        let i = Int(index)
        if i < 16 { return ansi[i] }
        if i < 232 {
            let v = i - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: steps[v / 36] / 255, green: steps[(v / 6) % 6] / 255, blue: steps[v % 6] / 255, alpha: 1)
        }
        let g = CGFloat(8 + (i - 232) * 10) / 255
        return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
    }

    static func resolve(_ c: TerminalColor, bold: Bool = false) -> NSColor? {
        switch c.kind {
        case .standard: return nil
        case .indexed(let i): return color(bold && i < 8 ? i + 8 : i)
        case .rgb(let r, let g, let b): return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }
}

struct TerminalPoint: Comparable, Equatable {
    var row: Int
    var col: Int
    static func < (a: TerminalPoint, b: TerminalPoint) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }
}

@MainActor
final class TerminalView: NSView {
    var session: TerminalSession? {
        didSet {
            scrollOffset = 0
            selection = nil
            syncSize()
            needsDisplay = true
        }
    }

    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { measure(); syncSize() } }
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private(set) var cellSize = NSSize(width: 7, height: 15)
    private var baselineOffset: CGFloat = 3
    private var scrollOffset = 0
    private var scrollRemainder: CGFloat = 0
    private var selection: (anchor: TerminalPoint, head: TerminalPoint)?
    private let inset = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        measure()
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    private func measure() {
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        cellSize = NSSize(width: ceil(width * 100) / 100, height: height)
        baselineOffset = ceil(font.ascender) + 1
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSize()
    }

    func gridSize(for size: NSSize) -> (cols: Int, rows: Int) {
        let cols = Int((size.width - inset.left - inset.right) / cellSize.width)
        let rows = Int((size.height - inset.top - inset.bottom) / cellSize.height)
        return (max(10, cols), max(3, rows))
    }

    private func syncSize() {
        guard let session, bounds.width > 0, bounds.height > 0 else { return }
        let g = gridSize(for: bounds.size)
        session.resize(cols: g.cols, rows: g.rows)
    }

    func contentChanged() {
        if scrollOffset > 0, let session { scrollOffset = min(scrollOffset, session.emulator.scrollback.count) }
        needsDisplay = true
    }

    private var defaultForeground: NSColor { .textColor }
    private var defaultBackground: NSColor { .textBackgroundColor }

    override func draw(_ dirtyRect: NSRect) {
        defaultBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let session else { return }
        let emu = session.emulator
        let sel = normalizedSelection
        let baseRow = emu.scrollback.count - scrollOffset
        for r in 0..<emu.rows {
            let y = inset.top + CGFloat(r) * cellSize.height
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: cellSize.height)
            guard rowRect.intersects(dirtyRect) else { continue }
            let line = emu.line(at: r - scrollOffset)
            drawLine(line, y: y, absoluteRow: baseRow + r, selection: sel)
        }
        if emu.cursorVisible, scrollOffset == 0 {
            let x = inset.left + CGFloat(emu.cursorX) * cellSize.width
            let y = inset.top + CGFloat(emu.cursorY) * cellSize.height
            let rect = NSRect(x: x, y: y, width: cellSize.width, height: cellSize.height)
            let focused = window?.firstResponder === self && window?.isKeyWindow == true
            NSColor.controlAccentColor.withAlphaComponent(focused ? 0.75 : 1).set()
            if focused {
                rect.fill()
                let cell = emu.line(at: emu.cursorY).cells[min(emu.cursorX, emu.cols - 1)]
                if cell.width > 0, cell.text != " " {
                    NSAttributedString(string: cell.text, attributes: [.font: cell.attrs.bold ? boldFont : font, .foregroundColor: NSColor.white])
                        .draw(at: NSPoint(x: x, y: y + baselineOffset - font.ascender - 1))
                }
            } else {
                rect.insetBy(dx: 0.5, dy: 0.5).frame()
            }
        }
    }

    private func colors(for a: TerminalAttributes) -> (fg: NSColor, bg: NSColor?) {
        var fg = TerminalPalette.resolve(a.fg, bold: a.bold) ?? defaultForeground
        var bg = TerminalPalette.resolve(a.bg)
        if a.inverse {
            let swapped = bg ?? defaultBackground
            bg = fg
            fg = swapped
        }
        if a.dim { fg = fg.withAlphaComponent(0.6) }
        if a.hidden { fg = .clear }
        return (fg, bg)
    }

    private func drawLine(_ line: TerminalLine, y: CGFloat, absoluteRow: Int, selection sel: (TerminalPoint, TerminalPoint)?) {
        let cells = line.cells
        var x = 0
        while x < cells.count {
            let (_, bg) = colors(for: cells[x].attrs)
            var end = x + 1
            while end < cells.count, colors(for: cells[end].attrs).bg == bg { end += 1 }
            if let bg {
                bg.setFill()
                NSRect(x: inset.left + CGFloat(x) * cellSize.width, y: y, width: CGFloat(end - x) * cellSize.width, height: cellSize.height).fill()
            }
            x = end
        }
        if let (start, end) = sel, absoluteRow >= start.row, absoluteRow <= end.row {
            let from = absoluteRow == start.row ? start.col : 0
            let to = absoluteRow == end.row ? end.col : cells.count
            if to > from {
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: inset.left + CGFloat(from) * cellSize.width, y: y, width: CGFloat(to - from) * cellSize.width, height: cellSize.height).fill()
            }
        }
        let textY = y + baselineOffset - font.ascender - 1
        x = 0
        while x < cells.count {
            let cell = cells[x]
            if cell.width == 0 || cell.text == " " { x += 1; continue }
            let attrs = cell.attrs
            var text = cell.text
            var end = x + 1
            let ascii = cell.text.utf8.count == 1
            if ascii {
                while end < cells.count, cells[end].attrs == attrs, cells[end].width == 1, cells[end].text.utf8.count == 1 {
                    text += cells[end].text
                    end += 1
                }
            } else {
                end = x + Int(max(1, cell.width))
            }
            let (fg, _) = colors(for: attrs)
            var attributes: [NSAttributedString.Key: Any] = [.font: attrs.bold ? boldFont : font, .foregroundColor: fg]
            if attrs.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if attrs.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if attrs.italic { attributes[.obliqueness] = 0.18 }
            let origin = NSPoint(x: inset.left + CGFloat(x) * cellSize.width, y: textY)
            if ascii {
                NSAttributedString(string: text, attributes: attributes).draw(at: origin)
            } else {
                let rect = NSRect(x: origin.x, y: y, width: CGFloat(cell.width) * cellSize.width, height: cellSize.height)
                NSGraphicsContext.saveGraphicsState()
                rect.clip()
                NSAttributedString(string: text, attributes: attributes).draw(at: origin)
                NSGraphicsContext.restoreGraphicsState()
            }
            x = end
        }
    }

    private var normalizedSelection: (TerminalPoint, TerminalPoint)? {
        guard let selection, selection.anchor != selection.head else { return nil }
        return selection.anchor < selection.head ? (selection.anchor, selection.head) : (selection.head, selection.anchor)
    }

    private func point(for event: NSEvent) -> TerminalPoint {
        guard let session else { return TerminalPoint(row: 0, col: 0) }
        let p = convert(event.locationInWindow, from: nil)
        let emu = session.emulator
        let r = min(max(0, Int((p.y - inset.top) / cellSize.height)), emu.rows - 1)
        let c = min(max(0, Int(((p.x - inset.left) / cellSize.width).rounded())), emu.cols)
        return TerminalPoint(row: emu.scrollback.count - scrollOffset + r, col: c)
    }

    private func absoluteLine(_ row: Int) -> TerminalLine? {
        guard let emu = session?.emulator else { return nil }
        let index = row - emu.scrollback.count
        guard index >= -emu.scrollback.count, index < emu.rows else { return nil }
        return emu.line(at: index)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(for: event)
        if event.clickCount == 2, let line = absoluteLine(p.row) {
            let isWord: (TerminalCell) -> Bool = { cell in
                cell.text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_./~".unicodeScalars.contains($0) } && cell.text != " " && !cell.text.isEmpty
            }
            var a = min(p.col, line.cells.count - 1)
            var b = a
            guard a >= 0, isWord(line.cells[a]) else { selection = nil; needsDisplay = true; return }
            while a > 0, isWord(line.cells[a - 1]) { a -= 1 }
            while b < line.cells.count - 1, isWord(line.cells[b + 1]) { b += 1 }
            selection = (TerminalPoint(row: p.row, col: a), TerminalPoint(row: p.row, col: b + 1))
        } else if event.clickCount == 3 {
            selection = (TerminalPoint(row: p.row, col: 0), TerminalPoint(row: p.row, col: session?.emulator.cols ?? 0))
        } else {
            selection = (p, p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var s = selection else { return }
        s.head = point(for: event)
        selection = s
        let local = convert(event.locationInWindow, from: nil)
        if local.y < 0 { scroll(by: 1) } else if local.y > bounds.height { scroll(by: -1) }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, !session.emulator.usingAlternateScreen else {
            if let session, session.emulator.usingAlternateScreen {
                let lines = Int(abs(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? cellSize.height : 1))
                let key = session.emulator.applicationCursorKeys ? (event.scrollingDeltaY > 0 ? "\u{1B}OA" : "\u{1B}OB") : (event.scrollingDeltaY > 0 ? "\u{1B}[A" : "\u{1B}[B")
                for _ in 0..<min(lines, 20) { session.send(key) }
            }
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellSize.height : event.scrollingDeltaY * 3
        scrollRemainder += delta
        let whole = Int(scrollRemainder)
        guard whole != 0 else { return }
        scrollRemainder -= CGFloat(whole)
        scroll(by: whole)
    }

    private func scroll(by lines: Int) {
        guard let session else { return }
        scrollOffset = min(max(0, scrollOffset + lines), session.emulator.scrollback.count)
        needsDisplay = true
    }

    private func scrollToBottom() {
        if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true }
    }

    func selectedText() -> String? {
        guard let (start, end) = normalizedSelection else { return nil }
        var out: [String] = []
        for row in start.row...end.row {
            guard let line = absoluteLine(row) else { continue }
            let from = row == start.row ? start.col : 0
            let to = min(row == end.row ? end.col : line.cells.count, line.cells.count)
            var s = ""
            if from < to { for c in line.cells[from..<to] where c.width > 0 { s += c.text } }
            if !(row != end.row && line.wrapped) { s = s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            if row != start.row, let prev = absoluteLine(row - 1), prev.wrapped, !out.isEmpty {
                out[out.count - 1] += s
            } else {
                out.append(s)
            }
        }
        return out.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                session?.paste(urls.map { TerminalSession.shellQuote($0.path) }.joined(separator: " "))
            }
            return
        }
        scrollToBottom()
        session?.paste(text)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let emu = session?.emulator else { return }
        selection = (TerminalPoint(row: 0, col: 0), TerminalPoint(row: emu.scrollback.count + emu.rows - 1, col: emu.cols))
        needsDisplay = true
    }

    @objc func clearScrollback(_ sender: Any?) {
        guard let session else { return }
        session.send([0x0C])
        session.emulator.feed("\u{1B}[3J")
        scrollOffset = 0
        selection = nil
        needsDisplay = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return normalizedSelection != nil
        case #selector(paste(_:)): return session?.exited == false
        default: return true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods.contains(.control) && !mods.contains(.command) && event.keyCode != 50 {
            keyDown(with: event)
            return true
        }
        guard mods == .command else { return false }
        switch event.keyCode {
        case 51: session?.send([0x15]); scrollToBottom(); return true
        case 123: session?.send([0x01]); scrollToBottom(); return true
        case 124: session?.send([0x05]); scrollToBottom(); return true
        case 126: scroll(by: session?.emulator.scrollback.count ?? 0); return true
        case 125: scrollToBottom(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        case "k": clearScrollback(nil); return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if session.exited { return }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .shift, event.keyCode == 116 { scroll(by: session.emulator.rows - 1); return }
        if mods == .shift, event.keyCode == 121 { scroll(by: -(session.emulator.rows - 1)); return }
        guard let bytes = Self.encode(keyCode: event.keyCode, characters: event.characters, ignoringModifiers: event.charactersIgnoringModifiers, modifiers: mods, applicationCursor: session.emulator.applicationCursorKeys) else {
            super.keyDown(with: event)
            return
        }
        selection = nil
        scrollToBottom()
        session.send(bytes)
    }

    static func encode(keyCode: UInt16, characters: String?, ignoringModifiers: String?, modifiers mods: NSEvent.ModifierFlags, applicationCursor: Bool) -> [UInt8]? {
        let esc = "\u{1B}"
        var modParam = 1
        if mods.contains(.shift) { modParam += 1 }
        if mods.contains(.option) { modParam += 2 }
        if mods.contains(.control) { modParam += 4 }
        func cursor(_ c: String) -> String {
            if modParam > 1 { return "\(esc)[1;\(modParam)\(c)" }
            return applicationCursor ? "\(esc)O\(c)" : "\(esc)[\(c)"
        }
        func tilde(_ n: Int) -> String { modParam > 1 ? "\(esc)[\(n);\(modParam)~" : "\(esc)[\(n)~" }
        let s: String?
        switch keyCode {
        case 36, 76: s = mods.contains(.option) ? "\(esc)\r" : "\r"
        case 48: s = mods.contains(.shift) ? "\(esc)[Z" : "\t"
        case 51: s = mods.contains(.option) ? "\(esc)\u{7F}" : (mods.contains(.control) ? "\u{08}" : "\u{7F}")
        case 53: s = esc
        case 117: s = tilde(3)
        case 123: s = mods == .option ? "\(esc)b" : cursor("D")
        case 124: s = mods == .option ? "\(esc)f" : cursor("C")
        case 125: s = cursor("B")
        case 126: s = cursor("A")
        case 115: s = modParam > 1 ? "\(esc)[1;\(modParam)H" : (applicationCursor ? "\(esc)OH" : "\(esc)[H")
        case 119: s = modParam > 1 ? "\(esc)[1;\(modParam)F" : (applicationCursor ? "\(esc)OF" : "\(esc)[F")
        case 116: s = tilde(5)
        case 121: s = tilde(6)
        case 122: s = modParam > 1 ? "\(esc)[1;\(modParam)P" : "\(esc)OP"
        case 120: s = modParam > 1 ? "\(esc)[1;\(modParam)Q" : "\(esc)OQ"
        case 99: s = modParam > 1 ? "\(esc)[1;\(modParam)R" : "\(esc)OR"
        case 118: s = modParam > 1 ? "\(esc)[1;\(modParam)S" : "\(esc)OS"
        case 96: s = tilde(15)
        case 97: s = tilde(17)
        case 98: s = tilde(18)
        case 100: s = tilde(19)
        case 101: s = tilde(20)
        case 109: s = tilde(21)
        case 103: s = tilde(23)
        case 111: s = tilde(24)
        default: s = nil
        }
        if let s { return Array(s.utf8) }
        if mods.contains(.control), let raw = ignoringModifiers?.lowercased().unicodeScalars.first {
            switch raw {
            case "a"..."z": return [UInt8(raw.value - 96)]
            case " ", "2", "@": return [0]
            case "[", "3": return [0x1B]
            case "\\", "4": return [0x1C]
            case "]", "5": return [0x1D]
            case "6", "^": return [0x1E]
            case "-", "_", "7", "/": return [0x1F]
            case "8": return [0x7F]
            default: break
            }
        }
        guard let characters, !characters.isEmpty else { return nil }
        if characters.unicodeScalars.allSatisfy({ (0xF700...0xF8FF).contains($0.value) }) { return nil }
        return Array(characters.utf8)
    }
}
