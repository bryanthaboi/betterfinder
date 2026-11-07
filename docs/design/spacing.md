# Spacing spec

The values are proposed point sizes based on Apple's layout guidance and Tahoe's grouping principles; they weren't measured from Finder.

## Global scale

Use these steps:

| Step | Where it's used |
|---:|---|
| 4 pt | Gaps between related text |
| 8 pt | Icon–text and control gaps |
| 12 pt | Compact container padding |
| 16 pt | Panels and section separation |
| 20 pt | Settings and dialog margins |
| 28 pt | Onboarding margins |

Reserve 1–2 pt for borders and optical adjustments.

The insets below are effective totals: count AppKit's and SwiftUI's built-in margins only once. Heights are minimums, so grow them for larger fonts.

## Modern themes, Regular density

| Surface | Values |
|---|---|
| Sidebar | Rows 32. Content 16 from pane edges. Selection inset 8 horizontal / 2 vertical, radius 6. Icons 16, text gap 8. Top inset 8 below the safe area. Section headings get 12 above and 4 below, with no extra space above the first heading. Eject target 28×28. |
| List | Rows 28. Cell leading/trailing insets 8/8. Icons 16, gap 8. Outline indentation 16 per level. Header 28 high, horizontal padding 8, 20 reserved for the sort indicator. Selection inset 6 horizontal / 2 vertical, radius 6. Intercell spacing 0×0, because cell padding provides the separation. |
| Columns | Same row and cell values as the list. Keep the 240 column width. Content padding 8 top and bottom. Reserve 24 at the trailing edge: an 8 pt chevron, 8 trailing margin and 8 text gap. Preview padding 16. |
| Icons | At 64 pt icons, items are 112×120: icon top 8, icon–label gap 8, 32 for a two-line label, bottom 8. Minimum grid gaps 12 horizontal / 16 vertical, section insets 16. For a slider size `s`, the width is `max(112, s+48)` and the height is `s+56`; give the label more room when it needs it. |
| Path bar | Height 32, outer horizontal padding 12. Crumbs 24 high, padding 8 horizontal / 4 vertical. Separators 8 wide with a 4 gap on each side. The editing field uses the same outer alignment. |
| Status bar | Height 28, horizontal padding 12, gaps between segments 12. For 11 pt text, put the baseline 18 below the top; center other fonts using font metrics. Baseline-align text segments. |
| Toolbar | Keep native unified `NSToolbar` sizing and grouping. Custom controls are at least 32 high, 8 apart within a group and 16 between groups. Don't add padding around native groups. |
| Info / Get Info | Width 360, outer padding 20, section gaps 16. Metadata grid 12 horizontal / 8 vertical. Gap between primary and secondary text 4. |
| Command palette | Keep the 520 width. Padding 16 below the safe area and at the sides. Search field 32 high, gap of 8 before the results. Two-line rows 48 high, horizontal padding 16, title–detail gap 4. |
| Slide-out panels | Body padding 16, applied once for both declarative and custom content. Header 44 high with padding 16 horizontal / 8 vertical. Close target 28×28. |
| Operations | Rows 80, padding 16 horizontal / 12 vertical. Gaps of 8 between title, progress and detail. Action targets 28×28, 8 apart. Footer padding 16 horizontal / 12 vertical. |
| Settings and Mods | Grouped forms have an effective outer inset of 20, section gaps of 16, 8 between related controls and 4 above help text. Mods: filters 12; list rows 12 horizontal / 8 vertical, with 4 between lines of text; detail padding 20 and section gaps 16. |
| Updates | Keep the outer 20 and the 16 gap between icon and content. Release-notes padding 12, gaps between blocks 16, buttons 8 apart. The footer spans the full window width, below the icon and content columns. |
| Onboarding | Keep the outer 28 and the footer padding of 16. Main section gaps 16, heading–subtitle gap 8, feature-row gaps 12. |

## Density presets

Offer three presets. They change browsing density only, not dialog margins or typography.

| Modern | Compact | Regular (default) | Comfortable |
|---|---:|---:|---:|
| List and column rows | 24 | 28 | 32 |
| Sidebar rows | 28 | 32 | 36 |
| List icons | 16 | 16 | 20 |
| Grid gaps (H/V) | 8/12 | 12/16 | 16/20 |
| Grid section inset | 12 | 16 | 20 |

**Retro themes** default to Compact, keeping their original tight sizes:

| Retro theme | List row | Sidebar row |
|---|---:|---:|
| Platinum | 18 | 20 |
| System 7 | 18 | 20 |
| Classic Windows (95/98) | 17 | 20 |
| Luna (XP) | 18 | 22 |
| Aqua | 19 | 22 |

They also keep:
- the header and status bar heights their theme sets
- square selections
- a path bar height of 24
- cell padding and gaps of 4

If the user explicitly picks Regular or Comfortable, add 4 or 8 to the retro row heights.

**High Contrast** uses Comfortable. Don't treat it as retro through `isRetro`, which also matches its beveled toolbar.

## Theme metrics vs constants

- **Theme metrics to reuse:** `rowHeight`, `sidebarRowHeight`, `statusBarHeight`, `listIconSize`, `selectionInset`, `cornerRadius`, and the existing `header.height`.
- **Theme metrics to add:** `pathBarHeight`, `cellHorizontalInset`, `iconTextGap`, `selectionVerticalInset`, and the icon grid gaps and inset.
- **Constants:** put the dialog and panel margins, control gaps and target sizes, which don't vary by theme, in one public `Spacing` enum in Theming.
- **Wiring:** live layout must actually use these metrics. The sidebar and status bar heights and the file icon sizes currently ignore their theme fields.
- **Compatibility:** keep old theme JSON decoding. Update the modern theme JSON files, the fallback theme, the editor and the preview together.
