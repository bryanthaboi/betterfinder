import Foundation

struct TerminalColor: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case standard
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    var kind: Kind
    static let `default` = TerminalColor(kind: .standard)
}

struct TerminalAttributes: Equatable, Hashable {
    var fg = TerminalColor.default
    var bg = TerminalColor.default
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    var strike = false
    var hidden = false
}

struct TerminalCell: Equatable {
    var text: String
    var attrs: TerminalAttributes
    var width: UInt8

    static let blank = TerminalCell(text: " ", attrs: TerminalAttributes(), width: 1)
    static func blank(_ attrs: TerminalAttributes) -> TerminalCell {
        TerminalCell(text: " ", attrs: TerminalAttributes(bg: attrs.bg), width: 1)
    }
    static let continuation = TerminalCell(text: "", attrs: TerminalAttributes(), width: 0)
}

struct TerminalLine: Equatable {
    var cells: [TerminalCell]
    var wrapped = false

    init(cols: Int, fill: TerminalCell = .blank) {
        cells = Array(repeating: fill, count: cols)
    }

    var text: String {
        var s = ""
        for c in cells where c.width > 0 { s += c.text }
        return s
    }

    mutating func resize(_ cols: Int) {
        if cells.count > cols { cells.removeLast(cells.count - cols) } else if cells.count < cols { cells += Array(repeating: .blank, count: cols - cells.count) }
    }
}

final class TerminalEmulator {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var lines: [TerminalLine]
    private(set) var scrollback: [TerminalLine] = []
    var scrollbackLimit = 5000
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var usingAlternateScreen = false
    private(set) var title = ""

    var respond: ([UInt8]) -> Void = { _ in }
    var onTitleChange: (String) -> Void = { _ in }
    var onBell: () -> Void = {}

    private var attrs = TerminalAttributes()
    private var wrapPending = false
    private var autowrap = true
    private var originMode = false
    private var insertMode = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: Set<Int> = []
    private var saved: (x: Int, y: Int, attrs: TerminalAttributes, origin: Bool) = (0, 0, TerminalAttributes(), false)
    private var mainLines: [TerminalLine] = []
    private var mainSaved: (x: Int, y: Int, attrs: TerminalAttributes, origin: Bool) = (0, 0, TerminalAttributes(), false)
    private var lastPrinted: String?

    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape, ignoreString, ignoreStringEscape, charset }
    private var state = State.ground
    private var params: [Int] = []
    private var currentParam: Int?
    private var subParamSeen = false
    private var privateMarker: UInt8 = 0
    private var intermediates: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var utf8Expected = 0

    init(cols: Int, rows: Int) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        scrollBottom = max(1, rows) - 1
        lines = Array(repeating: TerminalLine(cols: max(2, cols)), count: max(1, rows))
        resetTabStops()
    }

    var screenText: String { lines.map { $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n") }

    func line(at index: Int) -> TerminalLine {
        if index < 0 {
            let i = scrollback.count + index
            return scrollback.indices.contains(i) ? scrollback[i] : TerminalLine(cols: cols)
        }
        return lines.indices.contains(index) ? lines[index] : TerminalLine(cols: cols)
    }

    func feed(_ bytes: [UInt8]) {
        for b in bytes { feed(byte: b) }
    }

    func feed(_ string: String) { feed(Array(string.utf8)) }

    private func feed(byte b: UInt8) {
        switch state {
        case .ground:
            if utf8Expected > 0 {
                if b & 0xC0 == 0x80 {
                    utf8Buffer.append(b)
                    if utf8Buffer.count == utf8Expected {
                        print(String(decoding: utf8Buffer, as: UTF8.self))
                        utf8Buffer.removeAll()
                        utf8Expected = 0
                    }
                    return
                }
                print("\u{FFFD}")
                utf8Buffer.removeAll()
                utf8Expected = 0
            }
            if b < 0x20 || b == 0x7F { control(b); return }
            if b < 0x80 { print(String(UnicodeScalar(b))); return }
            let need: Int
            switch b {
            case 0xC2...0xDF: need = 2
            case 0xE0...0xEF: need = 3
            case 0xF0...0xF4: need = 4
            default: print("\u{FFFD}"); return
            }
            utf8Buffer = [b]
            utf8Expected = need
        case .escape:
            escape(b)
        case .escapeIntermediate:
            if b >= 0x30 { state = .ground } else if b < 0x20 { control(b) }
        case .charset:
            state = .ground
        case .csi:
            csiByte(b)
        case .osc:
            if b == 0x07 { finishOSC() } else if b == 0x1B { state = .oscEscape } else { oscBuffer.append(b) }
        case .oscEscape:
            if b == 0x5C { finishOSC() } else { oscBuffer.removeAll(); state = .ground; feed(byte: 0x1B); feed(byte: b) }
        case .ignoreString:
            if b == 0x1B { state = .ignoreStringEscape } else if b == 0x07 { state = .ground }
        case .ignoreStringEscape:
            state = b == 0x5C ? .ground : .ignoreString
        }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x07: onBell()
        case 0x08: wrapPending = false; if cursorX > 0 { cursorX -= 1 }
        case 0x09: tab(1)
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: wrapPending = false; cursorX = 0
        case 0x1B: state = .escape; intermediates.removeAll()
        default: break
        }
    }

    private func escape(_ b: UInt8) {
        state = .ground
        switch b {
        case UInt8(ascii: "["):
            state = .csi
            params.removeAll(); currentParam = nil; privateMarker = 0; intermediates.removeAll(); subParamSeen = false
        case UInt8(ascii: "]"): state = .osc; oscBuffer.removeAll()
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .ignoreString
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"): state = .charset
        case UInt8(ascii: "#"), UInt8(ascii: "%"), UInt8(ascii: " "): state = .escapeIntermediate
        case UInt8(ascii: "7"): saveCursor()
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"): lineFeed()
        case UInt8(ascii: "E"): cursorX = 0; lineFeed()
        case UInt8(ascii: "H"): tabStops.insert(cursorX)
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "c"): reset()
        default: break
        }
    }

    private func csiByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            currentParam = min((currentParam ?? 0) * 10 + Int(b - 0x30), 65535)
        case UInt8(ascii: ";"):
            params.append(currentParam ?? -1); currentParam = nil
        case UInt8(ascii: ":"):
            params.append(currentParam ?? -1); currentParam = nil; subParamSeen = true
        case 0x3C...0x3F:
            if params.isEmpty && currentParam == nil { privateMarker = b }
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x40...0x7E:
            if currentParam != nil || !params.isEmpty { params.append(currentParam ?? -1) }
            state = .ground
            dispatchCSI(b)
        case 0x18, 0x1A:
            state = .ground
        case 0x1B:
            state = .escape
        default:
            if b < 0x20 { control(b) }
        }
    }

    private func param(_ i: Int, _ fallback: Int) -> Int {
        guard params.indices.contains(i), params[i] >= 0 else { return fallback }
        return params[i] == 0 && fallback > 0 ? fallback : params[i]
    }

    private func dispatchCSI(_ final: UInt8) {
        let f = Character(UnicodeScalar(final))
        if privateMarker == UInt8(ascii: "?") {
            if f == "h" || f == "l" { for p in params where p >= 0 { setDECMode(p, f == "h") } }
            return
        }
        if privateMarker == UInt8(ascii: ">") {
            if f == "c" { respond(Array("\u{1B}[>0;276;0c".utf8)) }
            return
        }
        guard privateMarker == 0, intermediates.isEmpty else { return }
        switch f {
        case "@": insertChars(param(0, 1))
        case "A": moveCursor(dy: -param(0, 1))
        case "B", "e": moveCursor(dy: param(0, 1))
        case "C", "a": moveCursor(dx: param(0, 1))
        case "D": moveCursor(dx: -param(0, 1))
        case "E": moveCursor(dy: param(0, 1)); cursorX = 0
        case "F": moveCursor(dy: -param(0, 1)); cursorX = 0
        case "G", "`": wrapPending = false; cursorX = clampX(param(0, 1) - 1)
        case "H", "f": setCursor(row: param(0, 1) - 1, col: param(1, 1) - 1)
        case "I": tab(param(0, 1))
        case "J": eraseDisplay(param(0, 0))
        case "K": eraseLine(param(0, 0))
        case "L": insertLines(param(0, 1))
        case "M": deleteLines(param(0, 1))
        case "P": deleteChars(param(0, 1))
        case "S": scrollUp(param(0, 1))
        case "T": scrollDown(param(0, 1))
        case "X": eraseChars(param(0, 1))
        case "Z": backTab(param(0, 1))
        case "b": if let lastPrinted { for _ in 0..<min(param(0, 1), cols * rows) { print(lastPrinted) } }
        case "c": respond(Array("\u{1B}[?62;22c".utf8))
        case "d": wrapPending = false; cursorY = clampY(originMode ? scrollTop + param(0, 1) - 1 : param(0, 1) - 1)
        case "g": if param(0, 0) == 3 { tabStops.removeAll() } else { tabStops.remove(cursorX) }
        case "h", "l": for p in params where p == 4 { insertMode = f == "h" }
        case "m": sgr()
        case "n":
            if param(0, 0) == 5 { respond(Array("\u{1B}[0n".utf8)) }
            if param(0, 0) == 6 {
                let row = originMode ? cursorY - scrollTop + 1 : cursorY + 1
                respond(Array("\u{1B}[\(row);\(cursorX + 1)R".utf8))
            }
        case "r":
            let top = param(0, 1) - 1
            let bottom = param(1, rows) - 1
            if top < bottom, bottom < rows {
                scrollTop = top; scrollBottom = bottom
                setCursor(row: 0, col: 0)
            }
        case "s": saveCursor()
        case "u": restoreCursor()
        default: break
        }
    }

    private func setDECMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: applicationCursorKeys = on
        case 6: originMode = on; setCursor(row: 0, col: 0)
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 47, 1047: setAlternateScreen(on, saveCursor: false)
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049: setAlternateScreen(on, saveCursor: true)
        case 2004: bracketedPaste = on
        default: break
        }
    }

    private func setAlternateScreen(_ on: Bool, saveCursor save: Bool) {
        guard on != usingAlternateScreen else { return }
        if on {
            if save { saveCursor() }
            mainLines = lines
            mainSaved = saved
            lines = Array(repeating: TerminalLine(cols: cols), count: rows)
            usingAlternateScreen = true
        } else {
            lines = mainLines.count == rows ? mainLines : resized(mainLines, cols: cols, rows: rows)
            for i in lines.indices { lines[i].resize(cols) }
            mainLines.removeAll()
            usingAlternateScreen = false
            saved = mainSaved
            if save { restoreCursor() }
        }
        scrollTop = 0
        scrollBottom = rows - 1
        wrapPending = false
    }

    private func sgr() {
        if params.isEmpty { attrs = TerminalAttributes(); return }
        var i = 0
        func color(_ i: inout Int) -> TerminalColor? {
            guard i + 1 < params.count else { return nil }
            if params[i + 1] == 5, i + 2 < params.count {
                i += 2
                return TerminalColor(kind: .indexed(UInt8(clamping: max(0, params[i]))))
            }
            if params[i + 1] == 2 {
                var start = i + 2
                if subParamSeen, params.count > i + 5, params.count - i >= 6 { start = i + 3 }
                guard start + 2 < params.count else { i = params.count; return nil }
                i = start + 2
                return TerminalColor(kind: .rgb(UInt8(clamping: max(0, params[start])), UInt8(clamping: max(0, params[start + 1])), UInt8(clamping: max(0, params[start + 2]))))
            }
            return nil
        }
        while i < params.count {
            let p = max(0, params[i])
            switch p {
            case 0: attrs = TerminalAttributes()
            case 1: attrs.bold = true
            case 2: attrs.dim = true
            case 3: attrs.italic = true
            case 4: attrs.underline = true
            case 7: attrs.inverse = true
            case 8: attrs.hidden = true
            case 9: attrs.strike = true
            case 21, 22: attrs.bold = false; attrs.dim = false
            case 23: attrs.italic = false
            case 24: attrs.underline = false
            case 27: attrs.inverse = false
            case 28: attrs.hidden = false
            case 29: attrs.strike = false
            case 30...37: attrs.fg = TerminalColor(kind: .indexed(UInt8(p - 30)))
            case 38: if let c = color(&i) { attrs.fg = c }
            case 39: attrs.fg = .default
            case 40...47: attrs.bg = TerminalColor(kind: .indexed(UInt8(p - 40)))
            case 48: if let c = color(&i) { attrs.bg = c }
            case 49: attrs.bg = .default
            case 90...97: attrs.fg = TerminalColor(kind: .indexed(UInt8(p - 90 + 8)))
            case 100...107: attrs.bg = TerminalColor(kind: .indexed(UInt8(p - 100 + 8)))
            default: break
            }
            i += 1
        }
    }

    private func finishOSC() {
        state = .ground
        let text = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer.removeAll()
        guard let semi = text.firstIndex(of: ";") else { return }
        let code = text[..<semi]
        if code == "0" || code == "2" {
            title = String(text[text.index(after: semi)...])
            onTitleChange(title)
        }
    }

    static func cellWidth(_ s: String) -> Int {
        guard let scalar = s.unicodeScalars.first else { return 1 }
        let v = scalar.value
        if scalar.properties.isEmojiPresentation { return 2 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    private func print(_ s: String) {
        if let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1,
           scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark || scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) {
            appendCombining(s)
            return
        }
        let width = Self.cellWidth(s)
        if wrapPending {
            if autowrap {
                lines[cursorY].wrapped = true
                cursorX = 0
                lineFeed()
            }
            wrapPending = false
        }
        if width == 2 && cursorX == cols - 1 {
            if autowrap {
                lines[cursorY].cells[cursorX] = .blank(attrs)
                lines[cursorY].wrapped = true
                cursorX = 0
                lineFeed()
            } else {
                return
            }
        }
        if insertMode { insertChars(width) }
        clearWide(at: cursorX)
        lines[cursorY].cells[cursorX] = TerminalCell(text: s, attrs: attrs, width: UInt8(width))
        if width == 2, cursorX + 1 < cols {
            clearWide(at: cursorX + 1)
            lines[cursorY].cells[cursorX + 1] = TerminalCell(text: "", attrs: attrs, width: 0)
        }
        lastPrinted = s
        if cursorX + width >= cols {
            cursorX = cols - 1
            wrapPending = true
        } else {
            cursorX += width
        }
    }

    private func appendCombining(_ s: String) {
        var x = wrapPending ? cursorX : cursorX - 1
        guard x >= 0 else { return }
        if lines[cursorY].cells[x].width == 0, x > 0 { x -= 1 }
        lines[cursorY].cells[x].text += s
    }

    private func clearWide(at x: Int) {
        let cell = lines[cursorY].cells[x]
        if cell.width == 0, x > 0 { lines[cursorY].cells[x - 1] = .blank(attrs) }
        if cell.width == 2, x + 1 < cols { lines[cursorY].cells[x + 1] = .blank(attrs) }
    }

    private func clampX(_ x: Int) -> Int { min(max(0, x), cols - 1) }
    private func clampY(_ y: Int) -> Int { min(max(0, y), rows - 1) }

    private func setCursor(row: Int, col: Int) {
        wrapPending = false
        cursorX = clampX(col)
        if originMode {
            cursorY = min(max(scrollTop, scrollTop + row), scrollBottom)
        } else {
            cursorY = clampY(row)
        }
    }

    private func moveCursor(dx: Int = 0, dy: Int = 0) {
        wrapPending = false
        cursorX = clampX(cursorX + dx)
        if dy != 0 {
            let top = cursorY >= scrollTop ? scrollTop : 0
            let bottom = cursorY <= scrollBottom ? scrollBottom : rows - 1
            cursorY = min(max(top, cursorY + dy), bottom)
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorY == scrollTop { scrollDown(1) } else if cursorY > 0 { cursorY -= 1 }
    }

    private func tab(_ count: Int) {
        wrapPending = false
        for _ in 0..<max(1, count) {
            var x = cursorX + 1
            while x < cols - 1 && !tabStops.contains(x) { x += 1 }
            cursorX = min(x, cols - 1)
        }
    }

    private func backTab(_ count: Int) {
        wrapPending = false
        for _ in 0..<max(1, count) {
            var x = cursorX - 1
            while x > 0 && !tabStops.contains(x) { x -= 1 }
            cursorX = max(0, x)
        }
    }

    private func resetTabStops() {
        tabStops = Set(stride(from: 8, to: cols, by: 8))
    }

    private func blankLine() -> TerminalLine { TerminalLine(cols: cols, fill: .blank(attrs)) }

    private func scrollUp(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            let removed = lines.remove(at: scrollTop)
            if scrollTop == 0 && !usingAlternateScreen {
                scrollback.append(removed)
                if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
            }
            lines.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: scrollTop)
        }
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: cursorY)
        }
        cursorX = 0
        wrapPending = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n {
            lines.remove(at: cursorY)
            lines.insert(blankLine(), at: scrollBottom)
        }
        cursorX = 0
        wrapPending = false
    }

    private func insertChars(_ n: Int) {
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        var cells = lines[cursorY].cells
        cells.insert(contentsOf: Array(repeating: TerminalCell.blank(attrs), count: n), at: cursorX)
        cells.removeLast(n)
        lines[cursorY].cells = cells
        wrapPending = false
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        var cells = lines[cursorY].cells
        cells.removeSubrange(cursorX..<(cursorX + n))
        cells += Array(repeating: TerminalCell.blank(attrs), count: n)
        lines[cursorY].cells = cells
        wrapPending = false
    }

    private func eraseChars(_ n: Int) {
        let end = min(cols, cursorX + max(1, n))
        for x in cursorX..<end { lines[cursorY].cells[x] = .blank(attrs) }
        wrapPending = false
    }

    private func eraseLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 1: range = 0..<min(cols, cursorX + 1)
        case 2: range = 0..<cols
        default: range = cursorX..<cols
        }
        for x in range { lines[cursorY].cells[x] = .blank(attrs) }
        if mode != 1 { lines[cursorY].wrapped = false }
        wrapPending = false
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for y in (cursorY + 1)..<max(cursorY + 1, rows) { lines[y] = blankLine() }
        case 1:
            eraseLine(1)
            for y in 0..<cursorY { lines[y] = blankLine() }
        case 2:
            for y in 0..<rows { lines[y] = blankLine() }
        case 3:
            scrollback.removeAll()
        default:
            break
        }
        wrapPending = false
    }

    private func saveCursor() {
        saved = (cursorX, cursorY, attrs, originMode)
    }

    private func restoreCursor() {
        cursorX = clampX(saved.x)
        cursorY = clampY(saved.y)
        attrs = saved.attrs
        originMode = saved.origin
        wrapPending = false
    }

    private func reset() {
        attrs = TerminalAttributes()
        if usingAlternateScreen { setAlternateScreen(false, saveCursor: false) }
        lines = Array(repeating: TerminalLine(cols: cols), count: rows)
        scrollback.removeAll()
        cursorX = 0; cursorY = 0
        scrollTop = 0; scrollBottom = rows - 1
        autowrap = true; originMode = false; insertMode = false
        cursorVisible = true; applicationCursorKeys = false; bracketedPaste = false
        wrapPending = false
        resetTabStops()
    }

    private func resized(_ source: [TerminalLine], cols: Int, rows: Int) -> [TerminalLine] {
        var out = source
        if out.count > rows { out.removeFirst(out.count - rows) }
        while out.count < rows { out.append(TerminalLine(cols: cols)) }
        return out
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols)
        let newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }
        for i in lines.indices { lines[i].resize(newCols) }
        if newRows < rows {
            let surplus = rows - newRows
            var trailingBlank = 0
            for y in stride(from: rows - 1, to: cursorY, by: -1) {
                if lines[y].cells.allSatisfy({ $0 == .blank }) { trailingBlank += 1 } else { break }
            }
            let dropBottom = min(surplus, trailingBlank)
            lines.removeLast(dropBottom)
            let dropTop = surplus - dropBottom
            if dropTop > 0 {
                let removed = lines.prefix(dropTop)
                if !usingAlternateScreen { scrollback.append(contentsOf: removed) }
                lines.removeFirst(dropTop)
                cursorY -= dropTop
            }
        } else if newRows > rows {
            var extra = newRows - rows
            if !usingAlternateScreen {
                while extra > 0, var restored = scrollback.popLast() {
                    restored.resize(newCols)
                    lines.insert(restored, at: 0)
                    cursorY += 1
                    extra -= 1
                }
            }
            lines += Array(repeating: TerminalLine(cols: newCols), count: extra)
        }
        if !mainLines.isEmpty {
            for i in mainLines.indices { mainLines[i].resize(newCols) }
            mainLines = resized(mainLines, cols: newCols, rows: newRows)
        }
        cols = newCols
        rows = newRows
        cursorX = clampX(cursorX)
        cursorY = clampY(cursorY)
        scrollTop = 0
        scrollBottom = rows - 1
        wrapPending = false
        resetTabStops()
    }
}
