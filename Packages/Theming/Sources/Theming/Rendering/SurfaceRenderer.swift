import AppKit

@MainActor
public enum SurfaceRenderer {
    public static func draw(_ style: Theme.SurfaceStyle, in rect: NSRect, background: NSColor, border: NSColor, palette: BevelPalette, edge: NSRectEdge? = nil) {
        switch style {
        case .native:
            BevelDrawing.fill(rect, background)
        case .flat:
            BevelDrawing.fill(rect, background)
            if let edge { line(edge, of: rect, border) }
        case .raised:
            BevelDrawing.fill(rect, background)
            BevelDrawing.ring(rect.integral, topLeft: palette.highlight, bottomRight: palette.shadow)
            if let edge { line(edge, of: rect, border) }
        case .win3d:
            BevelDrawing.draw(.raised, in: rect, palette: palette.withFace(background))
        case .sunken:
            BevelDrawing.fill(rect, palette.face)
            let inner = rect.insetBy(dx: 2, dy: 2)
            BevelDrawing.fill(inner, background)
            BevelDrawing.draw(.thinSunken, in: inner, palette: palette, fillFace: false)
        case .etched:
            BevelDrawing.fill(rect, background)
            let flipped = BevelDrawing.isFlipped
            let topY = flipped ? rect.minY : rect.maxY - 2
            let bottomY = flipped ? rect.maxY - 2 : rect.minY
            if edge == nil || edge == .minY || edge == .maxY {
                BevelDrawing.fill(NSRect(x: rect.minX, y: topY, width: rect.width, height: 1), flipped ? palette.highlight : palette.shadow)
                BevelDrawing.fill(NSRect(x: rect.minX, y: topY + 1, width: rect.width, height: 1), flipped ? palette.shadow : palette.highlight)
                BevelDrawing.fill(NSRect(x: rect.minX, y: bottomY, width: rect.width, height: 1), flipped ? palette.shadow : palette.highlight)
                BevelDrawing.fill(NSRect(x: rect.minX, y: bottomY + 1, width: rect.width, height: 1), flipped ? palette.highlight : palette.shadow)
            }
        }
    }

    public static func line(_ edge: NSRectEdge, of rect: NSRect, _ color: NSColor, width: CGFloat = 1) {
        let flipped = BevelDrawing.isFlipped
        let r: NSRect
        switch edge {
        case .minX: r = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        case .maxX: r = NSRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
        case .minY: r = NSRect(x: rect.minX, y: flipped ? rect.minY : rect.maxY - width, width: rect.width, height: width)
        case .maxY: r = NSRect(x: rect.minX, y: flipped ? rect.maxY - width : rect.minY, width: rect.width, height: width)
        @unknown default: return
        }
        BevelDrawing.fill(r, color)
    }
}

@MainActor
open class ThemedSurfaceView: NSView {
    public enum Role: Sendable { case statusBar, pathBar, toolbar, header, sidebar, list }

    public var role: Role { didSet { needsDisplay = true } }
    public private(set) var theme: Theme = ThemeManager.shared.current
    public var onThemeChange: ((Theme) -> Void)?
    private var observer: ThemeObserver?

    public init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        observer = ThemeObserver { [weak self] t in
            guard let self else { return }
            self.theme = t
            self.needsDisplay = true
            self.onThemeChange?(t)
        }
    }

    public required init?(coder: NSCoder) {
        self.role = .statusBar
        super.init(coder: coder)
        observer = ThemeObserver { [weak self] t in
            self?.theme = t
            self?.needsDisplay = true
        }
    }

    override open var isFlipped: Bool { true }
    override open var isOpaque: Bool { false }

    public var style: Theme.SurfaceStyle {
        switch role {
        case .statusBar: return theme.surfaces.statusBar
        case .pathBar: return theme.pathBar.style
        case .toolbar: return theme.toolbar.surface
        case .header: return theme.header.style
        case .sidebar: return theme.surfaces.sidebar
        case .list: return theme.surfaces.list
        }
    }

    public var backgroundColor: NSColor {
        switch role {
        case .statusBar: return Theme.color(theme.colors.statusBarBg)
        case .pathBar: return Theme.color(theme.pathBar.background)
        case .toolbar: return Theme.color(theme.toolbar.background)
        case .header: return Theme.color(theme.header.background)
        case .sidebar: return Theme.color(theme.colors.sidebarBg)
        case .list: return Theme.color(theme.colors.listBg)
        }
    }

    public var edge: NSRectEdge? {
        switch role {
        case .statusBar: return .minY
        case .pathBar: return .minY
        case .toolbar, .header: return .maxY
        case .sidebar: return .maxX
        case .list: return nil
        }
    }

    override open func draw(_ dirtyRect: NSRect) {
        if style == .native, role == .sidebar, Theme.isSystemToken(theme.colors.sidebarBg) { return }
        SurfaceRenderer.draw(style, in: bounds, background: backgroundColor, border: Theme.color(theme.colors.border), palette: theme.bevelPalette, edge: edge)
    }
}
