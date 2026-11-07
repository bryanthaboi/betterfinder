import AppKit
import Foundation

public protocol ThemeEnum: RawRepresentable, Codable, CaseIterable, Hashable, Sendable where RawValue == String {
    static var fallbackCase: Self { get }
}

public extension ThemeEnum {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: raw)
            ?? Self.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
            ?? Self.fallbackCase
    }

    var displayName: String {
        var out = ""
        for ch in rawValue {
            if ch.isUppercase || (ch.isNumber && !(out.last?.isNumber ?? true)) { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) -> T {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        return fallback()
    }
}

public struct Theme: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var base: Base
    public var colors: Colors
    public var fonts: Fonts
    public var metrics: Metrics
    public var chrome: Chrome
    public var icons: Icons
    public var sounds: [String: String]
    public var window: WindowChrome = .init()
    public var toolbar: Toolbar = .init()
    public var header: Header = .init()
    public var pathBar: PathBar = .init()
    public var surfaces: Surfaces = .init()
    public var grid: Grid = .init()
    public var iconLabels: IconLabels = .init()
    public var scrollbar: Scrollbar = .init()
    public var bevelColors: BevelColors = .init()
    public var desktopPattern: Pattern? = nil
    public var author: String? = nil

    public enum Base: String, ThemeEnum {
        case light, dark, system
        public static var fallbackCase: Base { .system }
    }

    public struct Colors: Codable, Hashable, Sendable {
        public var windowBg: String
        public var listBg: String
        public var rowAlt: String
        public var selection: String
        public var selectionText: String
        public var text: String
        public var secondaryText: String
        public var sidebarBg: String
        public var sidebarText: String
        public var statusBarBg: String
        public var statusBarText: String
        public var toolbarBg: String
        public var accent: String
        public var border: String
        public var inactiveSelection: String = "system:inactiveSelection"
        public var inactiveSelectionText: String = "system:text"
        public var sidebarSelection: String = "system:selection"
        public var sidebarSelectionText: String = "system:selectionText"
        public var toolbarText: String = "system:text"
        public var sidebarIcon: String = "system:accent"
    }

    public struct FontSpec: Codable, Hashable, Sendable {
        public var family: String
        public var size: Double
        public var weight: String?

        public init(family: String = "system", size: Double = 13, weight: String? = nil) {
            self.family = family
            self.size = size
            self.weight = weight
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            family = c.value(.family, or: "system")
            size = c.value(.size, or: 13)
            weight = c.value(.weight, or: nil)
        }
    }

    public struct Fonts: Codable, Hashable, Sendable {
        public var list: FontSpec
        public var ui: FontSpec
        public var sidebar: FontSpec? = nil
        public var statusBar: FontSpec? = nil
    }

    public struct Metrics: Codable, Hashable, Sendable {
        public var rowHeight: Double
        public var cornerRadius: Double
        public var bevel: Bevel
        public var borderWidth: Double
        public var sidebarRowHeight: Double = 0
        public var statusBarHeight: Double = 24
        public var listIconSize: Double = 16
        public var selectionInset: Double = 0
        public var pathBarHeight: Double = 32
        public var cellHorizontalInset: Double = 8
        public var iconTextGap: Double = 8
        public var selectionVerticalInset: Double = 0
        public var iconGridGapH: Double = 12
        public var iconGridGapV: Double = 16
        public var iconGridInset: Double = 16
        public var defaultDensity: Density? = nil
    }

    public enum Bevel: String, ThemeEnum {
        case none, raised, sunken
        public static var fallbackCase: Bevel { .none }
    }

    public struct Chrome: Codable, Hashable, Sendable {
        public var titlebar: String
        public var toolbarStyle: String
        public var scrollbar: String
        public var useNativeChrome: Bool
    }

    public struct Icons: Codable, Hashable, Sendable {
        public var set: String
    }

    public enum TitlebarFill: String, ThemeEnum {
        case native, solid, gradient, stripedGradient, pinstripe, lines, brushedMetal
        public static var fallbackCase: TitlebarFill { .native }
    }

    public enum TitleAlignment: String, ThemeEnum {
        case center, leading
        public static var fallbackCase: TitleAlignment { .center }
    }

    public enum WindowButtonStyle: String, ThemeEnum {
        case native, classicBoxes, winCaption
        public static var fallbackCase: WindowButtonStyle { .native }
    }

    public enum ToolbarButtonStyle: String, ThemeEnum {
        case native, bevel, flat, win3d, glossy
        public static var fallbackCase: ToolbarButtonStyle { .native }
    }

    public enum SurfaceStyle: String, ThemeEnum {
        case native, flat, raised, win3d, sunken, etched
        public static var fallbackCase: SurfaceStyle { .native }
    }

    public enum ScrollerStyle: String, ThemeEnum {
        case native, flat, platinum, win3d, system7, aqua
        public static var fallbackCase: ScrollerStyle { .native }
    }

    public enum GridLineStyle: String, ThemeEnum {
        case solid, dashed, dotted
        public static var fallbackCase: GridLineStyle { .solid }
    }

    public enum IconLabelShape: String, ThemeEnum {
        case pill, rect, none
        public static var fallbackCase: IconLabelShape { .pill }
    }

    public enum PatternKind: String, ThemeEnum {
        case solid, checkerboard, dither50, dither25, pinstripe, hlines, vlines, dots, grid, brushedMetal, image
        public static var fallbackCase: PatternKind { .solid }
    }

    public struct Pattern: Codable, Hashable, Sendable {
        public var kind: PatternKind
        public var foreground: String
        public var background: String
        public var scale: Double
        public var image: String?

        public init(kind: PatternKind = .solid, foreground: String = "#000000", background: String = "#FFFFFF", scale: Double = 1, image: String? = nil) {
            self.kind = kind
            self.foreground = foreground
            self.background = background
            self.scale = scale
            self.image = image
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Pattern()
            kind = c.value(.kind, or: d.kind)
            foreground = c.value(.foreground, or: d.foreground)
            background = c.value(.background, or: d.background)
            scale = c.value(.scale, or: d.scale)
            image = c.value(.image, or: d.image)
        }
    }

    public struct WindowChrome: Codable, Hashable, Sendable {
        public var titlebar: TitlebarFill
        public var colors: [String]
        public var horizontalGradient: Bool
        public var inactiveColors: [String]
        public var titleColor: String
        public var inactiveTitleColor: String
        public var titleShadow: String?
        public var titleAlignment: TitleAlignment
        public var titleFont: FontSpec
        public var buttons: WindowButtonStyle
        public var buttonFace: String
        public var buttonGlyph: String
        public var closeButtonFace: String
        public var buttonCornerRadius: Double
        public var buttonSize: Double
        public var buttonBevel: Bool
        public var showsMinimize: Bool
        public var captionInset: Double
        public var frameColor: String
        public var separator: Bool
        public var brushedMetal: Bool
        public var backgroundPattern: Pattern?

        public init(
            titlebar: TitlebarFill = .native,
            colors: [String] = ["system:windowBackground"],
            horizontalGradient: Bool = false,
            inactiveColors: [String] = [],
            titleColor: String = "system:text",
            inactiveTitleColor: String = "system:secondaryText",
            titleShadow: String? = nil,
            titleAlignment: TitleAlignment = .center,
            titleFont: FontSpec = .init(family: "system", size: 13, weight: "bold"),
            buttons: WindowButtonStyle = .native,
            buttonFace: String = "system:control",
            buttonGlyph: String = "system:text",
            closeButtonFace: String = "",
            buttonCornerRadius: Double = 0,
            buttonSize: Double = 0,
            buttonBevel: Bool = true,
            showsMinimize: Bool = true,
            captionInset: Double = 0,
            frameColor: String = "system:separator",
            separator: Bool = true,
            brushedMetal: Bool = false,
            backgroundPattern: Pattern? = nil
        ) {
            self.titlebar = titlebar
            self.colors = colors
            self.horizontalGradient = horizontalGradient
            self.inactiveColors = inactiveColors
            self.titleColor = titleColor
            self.inactiveTitleColor = inactiveTitleColor
            self.titleShadow = titleShadow
            self.titleAlignment = titleAlignment
            self.titleFont = titleFont
            self.buttons = buttons
            self.buttonFace = buttonFace
            self.buttonGlyph = buttonGlyph
            self.closeButtonFace = closeButtonFace
            self.buttonCornerRadius = buttonCornerRadius
            self.buttonSize = buttonSize
            self.buttonBevel = buttonBevel
            self.showsMinimize = showsMinimize
            self.captionInset = captionInset
            self.frameColor = frameColor
            self.separator = separator
            self.brushedMetal = brushedMetal
            self.backgroundPattern = backgroundPattern
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = WindowChrome()
            titlebar = c.value(.titlebar, or: d.titlebar)
            colors = c.value(.colors, or: d.colors)
            horizontalGradient = c.value(.horizontalGradient, or: d.horizontalGradient)
            inactiveColors = c.value(.inactiveColors, or: d.inactiveColors)
            titleColor = c.value(.titleColor, or: d.titleColor)
            inactiveTitleColor = c.value(.inactiveTitleColor, or: d.inactiveTitleColor)
            titleShadow = c.value(.titleShadow, or: d.titleShadow)
            titleAlignment = c.value(.titleAlignment, or: d.titleAlignment)
            titleFont = c.value(.titleFont, or: d.titleFont)
            buttons = c.value(.buttons, or: d.buttons)
            buttonFace = c.value(.buttonFace, or: d.buttonFace)
            buttonGlyph = c.value(.buttonGlyph, or: d.buttonGlyph)
            closeButtonFace = c.value(.closeButtonFace, or: d.closeButtonFace)
            buttonCornerRadius = c.value(.buttonCornerRadius, or: d.buttonCornerRadius)
            buttonSize = c.value(.buttonSize, or: d.buttonSize)
            buttonBevel = c.value(.buttonBevel, or: d.buttonBevel)
            showsMinimize = c.value(.showsMinimize, or: d.showsMinimize)
            captionInset = c.value(.captionInset, or: d.captionInset)
            frameColor = c.value(.frameColor, or: d.frameColor)
            separator = c.value(.separator, or: d.separator)
            brushedMetal = c.value(.brushedMetal, or: d.brushedMetal)
            backgroundPattern = c.value(.backgroundPattern, or: d.backgroundPattern)
        }

        public var isNative: Bool { titlebar == .native && buttons == .native && !brushedMetal && backgroundPattern == nil }
        public var effectiveFill: TitlebarFill { brushedMetal ? .brushedMetal : titlebar }
    }

    public struct Toolbar: Codable, Hashable, Sendable {
        public var style: ToolbarButtonStyle
        public var surface: SurfaceStyle
        public var background: String
        public var text: String
        public var buttonFace: String
        public var buttonBorder: String
        public var hover: String
        public var pressed: String
        public var cornerRadius: Double

        public init(
            style: ToolbarButtonStyle = .native,
            surface: SurfaceStyle = .native,
            background: String = "system:windowBackground",
            text: String = "system:text",
            buttonFace: String = "system:control",
            buttonBorder: String = "system:separator",
            hover: String = "system:hover",
            pressed: String = "system:pressed",
            cornerRadius: Double = 4
        ) {
            self.style = style
            self.surface = surface
            self.background = background
            self.text = text
            self.buttonFace = buttonFace
            self.buttonBorder = buttonBorder
            self.hover = hover
            self.pressed = pressed
            self.cornerRadius = cornerRadius
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Toolbar()
            style = c.value(.style, or: d.style)
            surface = c.value(.surface, or: d.surface)
            background = c.value(.background, or: d.background)
            text = c.value(.text, or: d.text)
            buttonFace = c.value(.buttonFace, or: d.buttonFace)
            buttonBorder = c.value(.buttonBorder, or: d.buttonBorder)
            hover = c.value(.hover, or: d.hover)
            pressed = c.value(.pressed, or: d.pressed)
            cornerRadius = c.value(.cornerRadius, or: d.cornerRadius)
        }
    }

    public struct Header: Codable, Hashable, Sendable {
        public var style: SurfaceStyle
        public var background: String
        public var text: String
        public var separator: String
        public var sortIndicator: String
        public var height: Double
        public var font: FontSpec?

        public init(
            style: SurfaceStyle = .native,
            background: String = "system:controlBackground",
            text: String = "system:secondaryText",
            separator: String = "system:separator",
            sortIndicator: String = "system:secondaryText",
            height: Double = 0,
            font: FontSpec? = nil
        ) {
            self.style = style
            self.background = background
            self.text = text
            self.separator = separator
            self.sortIndicator = sortIndicator
            self.height = height
            self.font = font
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Header()
            style = c.value(.style, or: d.style)
            background = c.value(.background, or: d.background)
            text = c.value(.text, or: d.text)
            separator = c.value(.separator, or: d.separator)
            sortIndicator = c.value(.sortIndicator, or: d.sortIndicator)
            height = c.value(.height, or: d.height)
            font = c.value(.font, or: d.font)
        }
    }

    public struct PathBar: Codable, Hashable, Sendable {
        public var style: SurfaceStyle
        public var background: String
        public var text: String
        public var separator: String
        public var highlight: String
        public var font: FontSpec?

        public init(
            style: SurfaceStyle = .native,
            background: String = "system:windowBackground",
            text: String = "system:secondaryText",
            separator: String = "system:tertiaryText",
            highlight: String = "system:accent",
            font: FontSpec? = nil
        ) {
            self.style = style
            self.background = background
            self.text = text
            self.separator = separator
            self.highlight = highlight
            self.font = font
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = PathBar()
            style = c.value(.style, or: d.style)
            background = c.value(.background, or: d.background)
            text = c.value(.text, or: d.text)
            separator = c.value(.separator, or: d.separator)
            highlight = c.value(.highlight, or: d.highlight)
            font = c.value(.font, or: d.font)
        }
    }

    public struct Surfaces: Codable, Hashable, Sendable {
        public var statusBar: SurfaceStyle
        public var sidebar: SurfaceStyle
        public var list: SurfaceStyle

        public init(statusBar: SurfaceStyle = .native, sidebar: SurfaceStyle = .native, list: SurfaceStyle = .native) {
            self.statusBar = statusBar
            self.sidebar = sidebar
            self.list = list
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Surfaces()
            statusBar = c.value(.statusBar, or: d.statusBar)
            sidebar = c.value(.sidebar, or: d.sidebar)
            list = c.value(.list, or: d.list)
        }
    }

    public struct Grid: Codable, Hashable, Sendable {
        public var horizontal: Bool
        public var vertical: Bool
        public var color: String
        public var style: GridLineStyle
        public var width: Double

        public init(horizontal: Bool = false, vertical: Bool = false, color: String = "system:grid", style: GridLineStyle = .solid, width: Double = 1) {
            self.horizontal = horizontal
            self.vertical = vertical
            self.color = color
            self.style = style
            self.width = width
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Grid()
            horizontal = c.value(.horizontal, or: d.horizontal)
            vertical = c.value(.vertical, or: d.vertical)
            color = c.value(.color, or: d.color)
            style = c.value(.style, or: d.style)
            width = c.value(.width, or: d.width)
        }
    }

    public struct IconLabels: Codable, Hashable, Sendable {
        public var text: String
        public var background: String
        public var selectionBackground: String
        public var selectionText: String
        public var shape: IconLabelShape
        public var maxLines: Int
        public var font: FontSpec?

        public init(
            text: String = "system:text",
            background: String = "system:clear",
            selectionBackground: String = "system:selection",
            selectionText: String = "system:selectionText",
            shape: IconLabelShape = .pill,
            maxLines: Int = 2,
            font: FontSpec? = nil
        ) {
            self.text = text
            self.background = background
            self.selectionBackground = selectionBackground
            self.selectionText = selectionText
            self.shape = shape
            self.maxLines = maxLines
            self.font = font
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = IconLabels()
            text = c.value(.text, or: d.text)
            background = c.value(.background, or: d.background)
            selectionBackground = c.value(.selectionBackground, or: d.selectionBackground)
            selectionText = c.value(.selectionText, or: d.selectionText)
            shape = c.value(.shape, or: d.shape)
            maxLines = c.value(.maxLines, or: d.maxLines)
            font = c.value(.font, or: d.font)
        }
    }

    public struct Scrollbar: Codable, Hashable, Sendable {
        public var style: ScrollerStyle
        public var track: String
        public var thumb: String
        public var thumbBorder: String
        public var arrows: Bool
        public var width: Double
        public var minimumThumb: Double

        public init(
            style: ScrollerStyle = .native,
            track: String = "system:controlBackground",
            thumb: String = "system:secondaryText",
            thumbBorder: String = "system:clear",
            arrows: Bool = false,
            width: Double = 15,
            minimumThumb: Double = 20
        ) {
            self.style = style
            self.track = track
            self.thumb = thumb
            self.thumbBorder = thumbBorder
            self.arrows = arrows
            self.width = width
            self.minimumThumb = minimumThumb
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Scrollbar()
            style = c.value(.style, or: d.style)
            track = c.value(.track, or: d.track)
            thumb = c.value(.thumb, or: d.thumb)
            thumbBorder = c.value(.thumbBorder, or: d.thumbBorder)
            arrows = c.value(.arrows, or: d.arrows)
            width = c.value(.width, or: d.width)
            minimumThumb = c.value(.minimumThumb, or: d.minimumThumb)
        }
    }

    public struct BevelColors: Codable, Hashable, Sendable {
        public var face: String
        public var highlight: String
        public var light: String
        public var shadow: String
        public var darkShadow: String
        public var frame: String

        public init(
            face: String = "#C0C0C0",
            highlight: String = "#FFFFFF",
            light: String = "#DFDFDF",
            shadow: String = "#808080",
            darkShadow: String = "#000000",
            frame: String = "#000000"
        ) {
            self.face = face
            self.highlight = highlight
            self.light = light
            self.shadow = shadow
            self.darkShadow = darkShadow
            self.frame = frame
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = BevelColors()
            face = c.value(.face, or: d.face)
            highlight = c.value(.highlight, or: d.highlight)
            light = c.value(.light, or: d.light)
            shadow = c.value(.shadow, or: d.shadow)
            darkShadow = c.value(.darkShadow, or: d.darkShadow)
            frame = c.value(.frame, or: d.frame)
        }
    }
}

public extension Theme.Colors {
    static let system = Theme.Colors(
        windowBg: "system:windowBackground", listBg: "system:controlBackground", rowAlt: "system:alternateRow",
        selection: "system:selection", selectionText: "system:selectionText", text: "system:text",
        secondaryText: "system:secondaryText", sidebarBg: "system:clear", sidebarText: "system:text",
        statusBarBg: "system:windowBackground", statusBarText: "system:secondaryText", toolbarBg: "system:windowBackground",
        accent: "system:accent", border: "system:separator"
    )

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Theme.Colors.system
        windowBg = c.value(.windowBg, or: d.windowBg)
        listBg = c.value(.listBg, or: d.listBg)
        rowAlt = c.value(.rowAlt, or: d.rowAlt)
        selection = c.value(.selection, or: d.selection)
        selectionText = c.value(.selectionText, or: d.selectionText)
        text = c.value(.text, or: d.text)
        secondaryText = c.value(.secondaryText, or: d.secondaryText)
        sidebarBg = c.value(.sidebarBg, or: d.sidebarBg)
        sidebarText = c.value(.sidebarText, or: d.sidebarText)
        statusBarBg = c.value(.statusBarBg, or: d.statusBarBg)
        statusBarText = c.value(.statusBarText, or: d.statusBarText)
        toolbarBg = c.value(.toolbarBg, or: d.toolbarBg)
        accent = c.value(.accent, or: d.accent)
        border = c.value(.border, or: d.border)
        let systemSelection = selection.lowercased().hasPrefix("system:")
        inactiveSelection = c.value(.inactiveSelection, or: systemSelection ? d.inactiveSelection : selection)
        inactiveSelectionText = c.value(.inactiveSelectionText, or: systemSelection ? d.inactiveSelectionText : selectionText)
        sidebarSelection = c.value(.sidebarSelection, or: selection)
        sidebarSelectionText = c.value(.sidebarSelectionText, or: selectionText)
        toolbarText = c.value(.toolbarText, or: text)
        sidebarIcon = c.value(.sidebarIcon, or: accent)
    }
}

public extension Theme.Fonts {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        list = c.value(.list, or: .init(family: "system", size: 13))
        ui = c.value(.ui, or: .init(family: "system", size: 11))
        sidebar = c.value(.sidebar, or: nil)
        statusBar = c.value(.statusBar, or: nil)
    }
}

public extension Theme.Metrics {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowHeight = c.value(.rowHeight, or: 22)
        cornerRadius = c.value(.cornerRadius, or: 6)
        bevel = c.value(.bevel, or: .none)
        borderWidth = c.value(.borderWidth, or: 0)
        sidebarRowHeight = c.value(.sidebarRowHeight, or: 0)
        statusBarHeight = c.value(.statusBarHeight, or: 24)
        listIconSize = c.value(.listIconSize, or: 16)
        selectionInset = c.value(.selectionInset, or: 0)
        defaultDensity = c.value(.defaultDensity, or: nil)
        let legacyCompact = defaultDensity == .compact || (defaultDensity == nil && rowHeight < 24 && cornerRadius == 0)
        func spacing(_ key: CodingKeys, _ modern: Double, _ compact: Double) -> Double {
            c.value(key, or: legacyCompact ? compact : modern)
        }
        pathBarHeight = spacing(.pathBarHeight, 32, 24)
        cellHorizontalInset = spacing(.cellHorizontalInset, 8, 4)
        iconTextGap = spacing(.iconTextGap, 8, 4)
        selectionVerticalInset = c.value(.selectionVerticalInset, or: 0)
        iconGridGapH = spacing(.iconGridGapH, 12, 8)
        iconGridGapV = spacing(.iconGridGapV, 16, 12)
        iconGridInset = spacing(.iconGridInset, 16, 12)
    }
}

public extension Theme.Chrome {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titlebar = c.value(.titlebar, or: "native")
        toolbarStyle = c.value(.toolbarStyle, or: "native")
        scrollbar = c.value(.scrollbar, or: "native")
        useNativeChrome = c.value(.useNativeChrome, or: titlebar == "native")
    }
}

public extension Theme.Icons {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        set = c.value(.set, or: "system")
    }
}

public extension Theme {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, or: id)
        base = c.value(.base, or: .system)
        colors = c.value(.colors, or: .system)
        fonts = c.value(.fonts, or: Theme.modernDefault.fonts)
        metrics = c.value(.metrics, or: Theme.modernDefault.metrics)
        chrome = c.value(.chrome, or: Theme.modernDefault.chrome)
        icons = c.value(.icons, or: .init(set: "system"))
        sounds = c.value(.sounds, or: [:])
        window = c.value(.window, or: Theme.legacyWindow(chrome: chrome, colors: colors))
        toolbar = c.value(.toolbar, or: Theme.legacyToolbar(chrome: chrome, colors: colors))
        header = c.value(.header, or: Theme.Header(text: colors.secondaryText, separator: colors.border))
        pathBar = c.value(.pathBar, or: Theme.PathBar(background: colors.windowBg, text: colors.secondaryText, highlight: colors.accent))
        surfaces = c.value(.surfaces, or: .init())
        grid = c.value(.grid, or: .init())
        iconLabels = c.value(.iconLabels, or: Theme.IconLabels(text: colors.text, selectionBackground: colors.selection, selectionText: colors.selectionText))
        scrollbar = c.value(.scrollbar, or: Theme.legacyScrollbar(chrome: chrome))
        bevelColors = c.value(.bevelColors, or: .init())
        desktopPattern = c.value(.desktopPattern, or: nil)
        author = c.value(.author, or: nil)
    }

    static func legacyWindow(chrome: Chrome, colors: Colors) -> WindowChrome {
        let fill = TitlebarFill(rawValue: chrome.titlebar) ?? (chrome.titlebar == "native" ? .native : .solid)
        return WindowChrome(titlebar: chrome.useNativeChrome ? .native : fill, colors: [colors.windowBg], titleColor: colors.text, inactiveTitleColor: colors.secondaryText)
    }

    static func legacyToolbar(chrome: Chrome, colors: Colors) -> Toolbar {
        let style: ToolbarButtonStyle
        switch chrome.toolbarStyle.lowercased() {
        case "bevelbuttons", "bevel": style = .bevel
        case "flat": style = .flat
        case "win3d", "3d": style = .win3d
        case "glossy": style = .glossy
        default: style = .native
        }
        return Toolbar(style: style, background: colors.toolbarBg, text: colors.toolbarText, hover: colors.accent, pressed: colors.selection)
    }

    static func legacyScrollbar(chrome: Chrome) -> Scrollbar {
        switch chrome.scrollbar.lowercased() {
        case "classic", "platinum": return Scrollbar(style: .platinum, track: "#BBBBBB", thumb: "#CCCCFF", arrows: true, width: 15)
        case "win3d", "windows": return Scrollbar(style: .win3d, track: "#C0C0C0", thumb: "#C0C0C0", arrows: true, width: 16)
        case "system7": return Scrollbar(style: .system7, track: "#000000", thumb: "#FFFFFF", arrows: true, width: 16)
        case "aqua": return Scrollbar(style: .aqua, track: "#F0F0F0", thumb: "#3875D7", arrows: false, width: 15)
        case "flat": return Scrollbar(style: .flat)
        default: return Scrollbar()
        }
    }

    static let modernDefault = Theme(
        id: "modern",
        name: "Modern",
        base: .system,
        colors: .system,
        fonts: .init(list: .init(family: "system", size: 13, weight: nil), ui: .init(family: "system", size: 11, weight: nil)),
        metrics: .init(rowHeight: 28, cornerRadius: 6, bevel: .none, borderWidth: 0, sidebarRowHeight: 32, statusBarHeight: 28, selectionInset: 6, selectionVerticalInset: 2),
        chrome: .init(titlebar: "native", toolbarStyle: "native", scrollbar: "native", useNativeChrome: true),
        icons: .init(set: "system"),
        sounds: [:]
    )

    mutating func normalize() {
        chrome.titlebar = window.effectiveFill.rawValue
        chrome.toolbarStyle = toolbar.style.rawValue
        chrome.scrollbar = scrollbar.style.rawValue
        chrome.useNativeChrome = window.isNative
    }

    var appearance: NSAppearance? {
        switch base {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    var usesNativeChrome: Bool { window.isNative }
    var isRetro: Bool { !window.isNative || toolbar.style != .native || scrollbar.style != .native }

    func nsColor(_ keyPath: KeyPath<Theme, String>) -> NSColor {
        Theme.color(self[keyPath: keyPath])
    }
}

public extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.lowercased().hasPrefix("system:") {
            return nil
        }
        if s.count == 3 || s.count == 4 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var relativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    static let textContrastMinimum: CGFloat = 4.5
    static let glyphContrastMinimum: CGFloat = 3

    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        contrastRatio(a, b, over: .white)
    }

    static func contrastRatio(_ foreground: NSColor, _ background: NSColor, over surface: NSColor) -> CGFloat {
        let bg = background.composited(over: surface)
        let fg = foreground.composited(over: bg)
        let la = fg.relativeLuminance, lb = bg.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func composited(over background: NSColor) -> NSColor {
        guard let f = usingColorSpace(.sRGB) else { return self }
        let a = f.alphaComponent
        guard a < 1 else { return f }
        let b = (background.usingColorSpace(.sRGB) ?? .white)
        let base = b.alphaComponent < 1 ? b.composited(over: .white) : b
        return NSColor(srgbRed: f.redComponent * a + base.redComponent * (1 - a),
                       green: f.greenComponent * a + base.greenComponent * (1 - a),
                       blue: f.blueComponent * a + base.blueComponent * (1 - a),
                       alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

public extension Theme {
    static let systemColorTokens: [String] = [
        "windowBackground", "controlBackground", "alternateRow", "selection", "inactiveSelection", "selectionText",
        "text", "secondaryText", "tertiaryText", "accent", "separator", "grid", "header", "control", "controlText",
        "underPage", "hover", "pressed", "highlight", "shadow", "link", "clear", "black", "white",
    ]

    static func isSystemToken(_ value: String) -> Bool {
        value.lowercased().hasPrefix("system:")
    }

    static func color(_ value: String) -> NSColor {
        if value.lowercased().hasPrefix("system:") {
            switch value.dropFirst(7).lowercased() {
            case "windowbackground": return .windowBackgroundColor
            case "controlbackground": return .controlBackgroundColor
            case "alternaterow": return NSColor.alternatingContentBackgroundColors.count > 1 ? NSColor.alternatingContentBackgroundColors[1] : .controlBackgroundColor
            case "selection": return .selectedContentBackgroundColor
            case "inactiveselection": return .unemphasizedSelectedContentBackgroundColor
            case "selectiontext": return .alternateSelectedControlTextColor
            case "text": return .labelColor
            case "secondarytext": return accessibleSecondaryText
            case "tertiarytext": return .tertiaryLabelColor
            case "accent": return .controlAccentColor
            case "separator": return .separatorColor
            case "grid": return .gridColor
            case "header": return .headerTextColor
            case "control": return .controlColor
            case "controltext": return .controlTextColor
            case "underpage": return .underPageBackgroundColor
            case "hover": return NSColor.labelColor.withAlphaComponent(0.08)
            case "pressed": return NSColor.labelColor.withAlphaComponent(0.16)
            case "highlight": return .highlightColor
            case "shadow": return .shadowColor
            case "link": return .linkColor
            case "clear": return .clear
            case "black": return .black
            case "white": return .white
            default: return .labelColor
            }
        }
        return NSColor(hex: value) ?? .labelColor
    }

    static let accessibleSecondaryText: NSColor = NSColor(name: "betterfinderSecondaryText") { appearance in
        var resolved = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = legibleSecondaryText()
        }
        return resolved
    }

    static func legibleSecondaryText(minimum: CGFloat = NSColor.textContrastMinimum) -> NSColor {
        let system = NSColor.secondaryLabelColor
        guard let window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB), let base = system.usingColorSpace(.sRGB) else { return system }
        let surface = window.alphaComponent < 1 ? window.composited(over: .white) : window
        let backgrounds = ([NSColor.windowBackgroundColor, .controlBackgroundColor] + NSColor.alternatingContentBackgroundColors)
            .compactMap { $0.usingColorSpace(.sRGB)?.composited(over: surface) }
        func worst(_ c: NSColor) -> CGFloat {
            backgrounds.map { NSColor.contrastRatio(c, $0) }.min() ?? 21
        }
        if worst(base) >= minimum { return base }
        let lightBackground = backgrounds.map(\.relativeLuminance).reduce(0, +) / CGFloat(backgrounds.count) > 0.18
        let anchor = backgrounds.max { $0.relativeLuminance < $1.relativeLuminance }!
        let start = base.composited(over: lightBackground ? anchor : backgrounds.min { $0.relativeLuminance < $1.relativeLuminance }!)
        var r = start.redComponent, g = start.greenComponent, b = start.blueComponent
        for _ in 0..<100 {
            let candidate = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            if worst(candidate) >= minimum { return candidate }
            let step: CGFloat = 0.01
            if lightBackground {
                r = max(0, r - step); g = max(0, g - step); b = max(0, b - step)
            } else {
                r = min(1, r + step); g = min(1, g + step); b = min(1, b + step)
            }
        }
        return lightBackground ? .black : .white
    }

    static func resolveFont(_ spec: FontSpec) -> NSFont {
        if let hit = FontCache.shared.font(for: spec) { return hit }
        let resolved = resolveFontUncached(spec)
        FontCache.shared.store(resolved, for: spec)
        return resolved
    }

    static func resolveFontUncached(_ spec: FontSpec) -> NSFont {
        let size = CGFloat(spec.size > 0 ? spec.size : 13)
        let weightName = spec.weight?.lowercased()
        let weight: NSFont.Weight
        switch weightName {
        case "bold": weight = .bold
        case "semibold": weight = .semibold
        case "medium": weight = .medium
        case "light": weight = .light
        case "heavy", "black": weight = .heavy
        default: weight = .regular
        }
        let bold = weight == .bold || weight == .heavy || weight == .semibold
        for raw in spec.family.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            switch name.lowercased() {
            case "system": return .systemFont(ofSize: size, weight: weight)
            case "monospace": return .monospacedSystemFont(ofSize: size, weight: weight)
            case "rounded":
                let base = NSFont.systemFont(ofSize: size, weight: weight)
                if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
                return base
            case "serif":
                let base = NSFont.systemFont(ofSize: size, weight: weight)
                if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
                return base
            default:
                let fm = NSFontManager.shared
                if let f = fm.font(withFamily: name, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) {
                    return f
                }
                if let f = NSFont(name: name, size: size) {
                    return bold ? fm.convert(f, toHaveTrait: .boldFontMask) : f
                }
            }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func isFontAvailable(_ family: String) -> Bool {
        let lower = family.lowercased()
        if ["system", "monospace", "rounded", "serif"].contains(lower) { return true }
        return NSFontManager.shared.availableFontFamilies.contains { $0.caseInsensitiveCompare(family) == .orderedSame }
            || NSFont(name: family, size: 12) != nil
    }

    func font(_ spec: FontSpec) -> NSFont {
        Theme.resolveFont(spec)
    }

    var listFont: NSFont { font(fonts.list) }
    var uiFont: NSFont { font(fonts.ui) }
    var sidebarFont: NSFont { fonts.sidebar.map(font) ?? .systemFont(ofSize: NSFont.systemFontSize) }
    var statusBarFont: NSFont { font(fonts.statusBar ?? fonts.ui) }
    var headerFont: NSFont { header.font.map(font) ?? (fonts.ui.family == "system" ? .systemFont(ofSize: NSFont.smallSystemFontSize) : uiFont) }
    var pathBarFont: NSFont { pathBar.font.map(font) ?? uiFont }
    var titleFont: NSFont { font(window.titleFont) }
    var iconLabelFont: NSFont { iconLabels.font.map(font) ?? listFont }
}

final class FontCache: @unchecked Sendable {
    static let shared = FontCache()
    private let lock = NSLock()
    private var fonts: [Theme.FontSpec: NSFont] = [:]

    func font(for spec: Theme.FontSpec) -> NSFont? {
        lock.lock()
        defer { lock.unlock() }
        return fonts[spec]
    }

    func store(_ font: NSFont, for spec: Theme.FontSpec) {
        lock.lock()
        defer { lock.unlock() }
        if fonts.count > 256 { fonts.removeAll() }
        fonts[spec] = font
    }
}
