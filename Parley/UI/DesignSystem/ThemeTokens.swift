import SwiftUI
import AppKit

// MARK: - The one look: off-white, ink, and a little color
//
// Parley has a single look, modeled on the Claude desktop app: a neutral off-white
// canvas, a light-grey sidebar, white fields and panels, hairline dividers, a neutral
// selection wash, near-black "ink" for the primary action, blue for links and active
// filters, and red reserved for Record. Colors are
// Asset color sets (`Brand*`, light + dark) so both appearances come from one place.
//
// Type: Hanken Grotesk everywhere — chrome, the live transcript, and prose (summaries,
// rendered notes, My notes) — with Geist Mono for timestamps / paths / code. Both are
// OFL and bundled under Resources/Fonts (registered via ATSApplicationFontsPath).
//
// Structure (spacing, radius, motion, opacity, severity) stays static on `Theme`; this
// file only holds the values `Theme.Palette` / `Theme.Typography` delegate to.

// MARK: - Bundled face resolution
//
// We reference each face by its exact PostScript name so the right weight is always
// picked (SwiftUI's family-level `.weight()` matching across separately registered
// faces is unreliable). `relativeTo:` keeps Dynamic Type scaling.

enum BrandFont {
    /// Hanken Grotesk — UI chrome and the live transcript.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(sansPostScript(weight), size: size, relativeTo: style)
    }
    /// Geist Mono — timestamps, paths, model ids.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("GeistMono-" + monoSuffix(weight), size: size, relativeTo: style)
    }

    /// Family names for APIs that take a family rather than a face (MarkdownUI).
    static let sansFamily = "Hanken Grotesk"
    static let monoFamily = "Geist Mono"

    /// AppKit face for NSView-backed text (the live transcript table).
    static func nsSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: sansPostScript(weight), size: size) ?? .systemFont(ofSize: size)
    }

    // Only Regular / Medium / SemiBold are bundled; heavier requests take SemiBold.
    private static func sansPostScript(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "HankenGrotesk-Medium"
        case .semibold, .bold, .heavy, .black: return "HankenGrotesk-SemiBold"
        default: return "HankenGrotesk-Regular"
        }
    }

    private static func monoSuffix(_ w: Font.Weight) -> String {
        switch w {
        case .ultraLight: return "Thin"
        case .thin:       return "ExtraLight"
        case .light:      return "Light"
        case .medium:     return "Medium"
        case .semibold:   return "SemiBold"
        case .bold:       return "Bold"
        case .heavy:      return "ExtraBold"
        case .black:      return "Black"
        default:          return "Regular"
        }
    }
}

// MARK: - ThemeTokens

struct ThemeTokens {
    // Color — chrome
    let accent: Color           // blue: links, active filters, small highlights
    let accentText: Color       // text/icon on top of `accent`
    let windowBg: Color         // main canvas
    let panelBg: Color          // fields, cards, the composer bar
    let sidebarBg: Color        // left sidebar
    let divider: Color          // hairline separators
    let selection: Color        // neutral selected-row wash
    let record: Color           // red: the Start recording button
    let ink: Color              // primary button fill
    let inkText: Color          // text on `ink`
    // Color — text hierarchy
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    // Typography — one font per role (see Theme.Typography for role meanings)
    let screenTitle: Font
    let sheetTitle: Font
    let sectionHeader: Font
    let body: Font
    let fieldLabel: Font
    let controlLabel: Font
    let secondary: Font
    let caption: Font
    let captionSecondary: Font
    let reading: Font
    let prose: Font
    let mono: Font
    let monoLarge: Font

    static let brand = ThemeTokens(
        accent: Color("BrandAccent"),
        accentText: .white,
        windowBg: Color("BrandWindowBg"),
        panelBg: Color("BrandPanelBg"),
        sidebarBg: Color("BrandSidebarBg"),
        divider: Color("BrandDivider"),
        selection: Color("BrandSelection"),
        record: Color("BrandRecord"),
        ink: Color("BrandInk"),
        inkText: Color("BrandInkText"),
        textPrimary: Color("BrandTextPrimary"),
        textSecondary: Color("BrandTextSecondary"),
        textTertiary: Color("BrandTextTertiary"),

        screenTitle: BrandFont.sans(22, .semibold, relativeTo: .title),
        sheetTitle: BrandFont.sans(18, .semibold, relativeTo: .title2),
        sectionHeader: BrandFont.sans(15, .semibold, relativeTo: .title3),
        body: BrandFont.sans(14, .regular, relativeTo: .body),
        fieldLabel: BrandFont.sans(14, .regular, relativeTo: .body),
        controlLabel: BrandFont.sans(14, .medium, relativeTo: .body),
        secondary: BrandFont.sans(13, .regular, relativeTo: .callout),
        caption: BrandFont.sans(13, .regular, relativeTo: .callout),
        captionSecondary: BrandFont.sans(12, .regular, relativeTo: .subheadline),
        reading: BrandFont.sans(15, .regular, relativeTo: .title3),
        prose: BrandFont.sans(15, .regular, relativeTo: .title3),
        mono: BrandFont.mono(12, .regular, relativeTo: .callout),
        monoLarge: BrandFont.mono(18, .medium, relativeTo: .title2)
    )
}
