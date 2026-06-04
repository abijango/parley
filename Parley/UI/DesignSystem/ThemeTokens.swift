import SwiftUI
import AppKit
import Observation

// MARK: - Switchable looks: Native (Tahoe) ↔ Cursor
//
// The design system has two "looks". They share *everything structural* — spacing,
// radius, motion, opacity, severity (all still static on `Theme`) — and differ only in
// three axes: **color**, **typography**, and two **material behaviors** (buttons +
// surfaces, which branch on `ThemeStore.shared.kind` in ButtonStyles.swift / Surfaces.swift).
//
// The differing color + font values live in a `ThemeTokens` value set. The *current*
// set is held by an `@Observable` `ThemeStore`. `Theme.Palette` / `Theme.Typography`
// are computed accessors that read the store, so the app's ~370 existing token call
// sites switch looks with **zero changes** — SwiftUI's Observation tracks the read
// through the static accessor and re-renders on flip (verified: Step 1 spike).
//
// Caveat (by design): tokens must be read *inside* a view's `body` for tracking to
// arm. Existing screens do (`.foregroundStyle(Theme.Palette.accent)` inline). Don't
// cache a token in `init` or a stored `let`.

enum ThemeKind: String, CaseIterable, Identifiable {
    case tahoe          // macOS-native: SF Pro + New York serif, system accent, Liquid Glass
    case cursor         // Cursor-style: Geist, warm paper, clay accent, flat matte chrome

    var id: String { rawValue }
    var displayName: String { self == .tahoe ? "Native" : "Cursor" }
}

// MARK: - Geist face resolution
//
// Static TTFs are bundled per weight (Resources/Fonts), each registered under the
// family "Geist" / "Geist Mono" with a per-weight PostScript name. We reference the
// exact PostScript name per weight so the right face is always picked (relying on
// SwiftUI's family-level `.weight()` matching across many registered faces is less
// reliable than naming the face outright). `relativeTo:` keeps Dynamic Type scaling.

enum GeistFont {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(sansPostScript(weight), size: size, relativeTo: style)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(monoPostScript(weight), size: size, relativeTo: style)
    }

    // Font.Weight numeric → Geist face. (ultraLight 100 … black 900.)
    private static func sansPostScript(_ w: Font.Weight) -> String { "Geist-" + suffix(w) }
    private static func monoPostScript(_ w: Font.Weight) -> String { "GeistMono-" + suffix(w) }

    private static func suffix(_ w: Font.Weight) -> String {
        switch w {
        case .ultraLight: return "Thin"        // 100
        case .thin:       return "ExtraLight"  // 200
        case .light:      return "Light"       // 300
        case .regular:    return "Regular"     // 400
        case .medium:     return "Medium"      // 500
        case .semibold:   return "SemiBold"    // 600
        case .bold:       return "Bold"        // 700
        case .heavy:      return "ExtraBold"   // 800
        case .black:      return "Black"       // 900
        default:          return "Regular"
        }
    }
}

// MARK: - ThemeTokens
//
// The values that differ between looks. Roles mirror `Theme.Typography` / the color
// surface vocabulary 1:1 so the computed accessors are a straight delegation.

struct ThemeTokens {
    // Color — chrome
    let accent: Color           // primary action / selection tint
    let accentText: Color       // text/icon on top of `accent`
    let windowBg: Color         // window base layer
    let panelBg: Color          // grouped-content / field surface
    let sidebarBg: Color        // navigation chrome
    let divider: Color          // hairline separators
    // Color — text hierarchy (for components that route through tokens; bare
    // SwiftUI `.primary`/`.secondary` in views stay system-semantic in both looks)
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
    let mono: Font
    let monoLarge: Font

    // MARK: Native (Tahoe) — exactly today's values (SF Pro + New York serif, system colors)
    static let tahoe = ThemeTokens(
        accent: .accentColor,
        accentText: .white,
        windowBg: Color(nsColor: .windowBackgroundColor),
        panelBg: Color(nsColor: .controlBackgroundColor),
        sidebarBg: Color(nsColor: .windowBackgroundColor),
        divider: Color(nsColor: .separatorColor),
        textPrimary: .primary,
        textSecondary: .secondary,
        textTertiary: Color(nsColor: .tertiaryLabelColor),

        screenTitle: .title.weight(.semibold),
        sheetTitle: .title2.weight(.semibold),
        sectionHeader: .title3.weight(.semibold),
        body: .body,
        fieldLabel: .body,
        controlLabel: .body.weight(.medium),
        secondary: .callout,
        caption: .callout,
        captionSecondary: .subheadline,
        reading: .system(.title3, design: .serif),
        mono: .system(.callout, design: .monospaced),
        monoLarge: .system(.title2, design: .monospaced)
    )

    // MARK: Cursor — Geist throughout, warm paper + clay (colors are Asset sets, Step 4).
    // Titles are Bold (per the Cursor reference); hierarchy carried by weight, one family.
    static let cursor = ThemeTokens(
        accent: Color("CursorAccent"),
        accentText: .white,
        windowBg: Color("CursorWindowBg"),
        panelBg: Color("CursorPanelBg"),
        sidebarBg: Color("CursorSidebarBg"),
        divider: Color("CursorDivider"),
        textPrimary: Color("CursorTextPrimary"),
        textSecondary: Color("CursorTextSecondary"),
        textTertiary: Color("CursorTextTertiary"),

        // Sizes nudged up a notch for legibility on large/4K displays (was 22/17/15/
        // 13/13/13/12/12/11/15/12/17). Easy to retune from here.
        screenTitle: GeistFont.sans(25, .bold, relativeTo: .title),
        sheetTitle: GeistFont.sans(19, .semibold, relativeTo: .title2),
        sectionHeader: GeistFont.sans(16, .semibold, relativeTo: .title3),
        body: GeistFont.sans(14, .regular, relativeTo: .body),
        fieldLabel: GeistFont.sans(14, .regular, relativeTo: .body),
        controlLabel: GeistFont.sans(14, .medium, relativeTo: .body),
        secondary: GeistFont.sans(13, .regular, relativeTo: .callout),
        caption: GeistFont.sans(13, .regular, relativeTo: .callout),
        captionSecondary: GeistFont.sans(12, .regular, relativeTo: .subheadline),
        reading: GeistFont.sans(16, .regular, relativeTo: .title3),
        mono: GeistFont.mono(13, .regular, relativeTo: .callout),
        monoLarge: GeistFont.mono(19, .medium, relativeTo: .title2)
    )

    static func set(for kind: ThemeKind) -> ThemeTokens {
        kind == .cursor ? .cursor : .tahoe
    }
}

// MARK: - ThemeStore
//
// Single source of truth for the active look. `Theme.Palette` / `Theme.Typography`
// read `shared.tokens`; the button/surface helpers read `shared.kind`. Flipping
// `kind` reskins the whole app live (Observation re-renders the readers).

@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    /// Persisted in the presentation layer (UserDefaults), deliberately *not* in
    /// `AppSettings` — the look is a pure UI preference and `Settings/` is a
    /// protected path per the design-polish brief.
    private static let defaultsKey = "selectedThemeKind"

    private(set) var kind: ThemeKind
    private(set) var tokens: ThemeTokens

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(ThemeKind.init(rawValue:)) ?? .tahoe
        kind = saved
        tokens = .set(for: saved)
    }

    /// Flip the active look and persist it. Call on the main thread (it's a UI
    /// mutation); reskins every view reading a token via Observation.
    func select(_ kind: ThemeKind) {
        self.kind = kind
        self.tokens = .set(for: kind)
        UserDefaults.standard.set(kind.rawValue, forKey: Self.defaultsKey)
    }
}
