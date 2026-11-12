import AppKit
import FSCore
import Theming

enum HeatScale {
    static let megabyte: Int64 = 1024 * 1024
    static let steps: [Int64] = ([1, 3, 10, 30, 100, 300, 1024, 3072, 10240, 30720] as [Int64]).map { $0 * megabyte }
    static let words = ["tiny", "small", "small", "medium", "medium", "large", "large", "big", "big", "huge", "huge"]
    static let top = steps.count

    static func level(_ bytes: Int64) -> Int {
        steps.reduce(0) { $0 + (bytes >= $1 ? 1 : 0) }
    }

    static func hue(level: Int) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), top))
        return 0.6 * (1 - clamped / CGFloat(top))
    }

    static func color(level: Int) -> NSColor {
        NSColor(calibratedHue: hue(level: level), saturation: 0.78, brightness: 0.92, alpha: 1)
    }

    static func color(fraction: Double) -> NSColor {
        color(level: Int((min(max(fraction, 0), 1) * Double(top)).rounded()))
    }

    static func label(_ bytes: Int64?) -> String {
        guard let bytes else { return "Not measured yet" }
        return "\(words[level(bytes)]), \(SizeFormatter.string(bytes))"
    }
}

final class HeatBarView: NSView {
    static let segments = 5

    var bytes: Int64? { didSet { if bytes != oldValue { needsDisplay = true } } }
    var isSettled = true { didSet { if isSettled != oldValue { needsDisplay = true } } }
    var trackColor: NSColor = .labelColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    static func fills(level: Int) -> [CGFloat] {
        (0..<segments).map { CGFloat(min(2, max(0, level - $0 * 2))) / 2 }
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let height = min(8, max(4, bounds.height - 8))
        let width = (bounds.width - gap * CGFloat(Self.segments - 1)) / CGFloat(Self.segments)
        guard width > 1 else { return }
        let y = ((bounds.height - height) / 2).rounded()
        let level = bytes.map(HeatScale.level) ?? 0
        let fills = Self.fills(level: level)
        let fill = HeatScale.color(level: level).withAlphaComponent(isSettled ? 1 : 0.55)
        for index in 0..<Self.segments {
            let rect = NSRect(x: (width + gap) * CGFloat(index), y: y, width: width, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if bytes == nil {
                trackColor.withAlphaComponent(0.22).setStroke()
                path.lineWidth = 1
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
                continue
            }
            trackColor.withAlphaComponent(0.12).setFill()
            path.fill()
            guard fills[index] > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            fill.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width * fills[index], height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

final class HeatCellView: NSTableCellView {
    let bar = HeatBarView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(bar)
        setAccessibilityRole(.levelIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = ThemeManager.shared.layout.cellHorizontalInset
        bar.frame = NSRect(x: inset, y: 0, width: max(0, min(120, bounds.width - inset * 2)), height: bounds.height)
    }

    func show(bytes: Int64?, settled: Bool, trackColor: NSColor) {
        bar.bytes = bytes
        bar.isSettled = settled
        bar.trackColor = trackColor
        let label = HeatScale.label(bytes)
        toolTip = label
        setAccessibilityLabel("Heat")
        setAccessibilityValue(label)
    }
}
