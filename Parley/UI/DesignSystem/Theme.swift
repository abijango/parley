import SwiftUI

/// Centralized design tokens. Everything visual — spacing, corner radius, motion,
/// elevation, tint strengths, status semantics, and type roles — is defined here
/// once and consumed by views. Views must not re-specify these inline.
///
/// Phase 1 of the design-polish pass establishes this layer; existing screens are
/// **not** yet adopting it (that's Phase 2+). The system compiles and is exercised
/// in isolation by the `#Preview` gallery in `DesignSystemGallery.swift`.
///
/// Target note: the app targets macOS 26+ (Tahoe). Liquid-Glass APIs are used
/// directly in `Surfaces.swift` / `ButtonStyles.swift` — no availability guards.
/// (Glass auto-falls-back to opaque under the *Reduce Transparency* accessibility
/// setting, so the UI stays legible without manual handling.)
enum Theme {

    // MARK: Spacing
    //
    // One even-numbered progression on a 2pt sub-grid (an 8pt rhythm with the
    // half-steps dense Mac layouts need). Use these names, never raw numbers — the
    // audit found 2/4/6/8/10/12/14/16/20/24/32 sprinkled ad hoc; these consolidate it.

    enum Spacing {
        /// 2pt — hairline gaps (icon ↔ badge, stacked caption lines).
        static let xxSmall: CGFloat = 2
        /// 4pt — within a single control (label ↔ value).
        static let xSmall: CGFloat = 4
        /// 8pt — the base unit. Default gap between related elements; row padding.
        static let small: CGFloat = 8
        /// 12pt — between controls in a row or group.
        static let medium: CGFloat = 12
        /// 16pt — section padding, card insets, window gutters.
        static let large: CGFloat = 16
        /// 24pt — between major sections.
        static let xLarge: CGFloat = 24
        /// 32pt — empty-state / hero breathing room.
        static let xxLarge: CGFloat = 32
    }

    // MARK: Corner radius
    //
    // Continuous curvature (the Tahoe / Liquid-Glass curve). Always build rounded
    // surfaces via `Theme.Radius.rect(_:)` so the style is consistent.

    enum Radius {
        /// 6pt — chips, compact controls.
        static let small: CGFloat = 6
        /// 10pt — cards, banners, list surfaces.
        static let medium: CGFloat = 10
        /// 16pt — sheets, large floating panels.
        static let large: CGFloat = 16

        /// A continuous-corner rounded rectangle at the given radius.
        static func rect(_ radius: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }
    }

    // MARK: Motion
    //
    // One spring for selection/transition, plus two tuned curves for the existing
    // disclosure (0.15 easeInOut) and content-settle (0.2 easeOut) behaviors.

    enum Motion {
        /// Default selection / view-transition spring. Use for most state changes.
        static let spring: Animation = .spring(response: 0.34, dampingFraction: 0.86)
        /// Fast disclosure toggles (sidebar collapse, section expand/collapse).
        static let quick: Animation = .easeInOut(duration: 0.15)
        /// Content settling (auto-scroll, list inserts).
        static let gentle: Animation = .easeOut(duration: 0.2)
    }

    // MARK: Elevation
    //
    // Subtle shadows only — in a Liquid-Glass UI most depth comes from materials,
    // not drop shadows. Apply via `.elevation(_:)` (see `Surfaces.swift`).

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        /// Resting card lift.
        static let card = Shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 1)
        /// Floating surface (popover / sheet-like).
        static let floating = Shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 6)
    }

    // MARK: Tint opacity
    //
    // Standardized tint strengths. Replaces the drifting 0.10 / 0.12 / 0.18 / 0.2 /
    // 0.35 / 0.4 values the audit catalogued.

    enum Opacity {
        /// Status-banner fills (faint wash behind a tinted message).
        static let tintSubtle: Double = 0.10
        /// Chips / tinted capsules / badges.
        static let tintFill: Double = 0.15
        /// Selected-row background (accent wash).
        static let selection: Double = 0.18
        /// Quaternary card / grouped-content backgrounds.
        static let surface: Double = 0.35
    }

    // MARK: Color
    //
    // Now **look-dependent**: values come from the active `ThemeTokens` (see
    // `ThemeTokens.swift`) via the `ThemeStore`. The Native (Tahoe) look keeps the
    // original stance — system accent + system semantic colors, no hardcoded hex. The
    // Cursor look swaps in a warm-paper palette + clay accent (Asset color sets).
    // These are computed (not `static let`) so flipping the store reskins live; the
    // read is tracked by Observation when it happens inside a view's `body`.

    enum Palette {
        static var accent: Color      { ThemeStore.shared.tokens.accent }
        static var accentText: Color  { ThemeStore.shared.tokens.accentText }
        static var windowBg: Color    { ThemeStore.shared.tokens.windowBg }
        static var panelBg: Color     { ThemeStore.shared.tokens.panelBg }
        static var sidebarBg: Color   { ThemeStore.shared.tokens.sidebarBg }
        static var divider: Color     { ThemeStore.shared.tokens.divider }
        static var textPrimary: Color   { ThemeStore.shared.tokens.textPrimary }
        static var textSecondary: Color { ThemeStore.shared.tokens.textSecondary }
        static var textTertiary: Color  { ThemeStore.shared.tokens.textTertiary }
    }

    // MARK: Severity
    //
    // The four status meanings used across the app (advisories, banners, badges,
    // model/permission/summary state). Consolidates the repeated
    // green-seal / orange-triangle / red-triangle / blue-badge literals into one
    // vocabulary, and folds the ad-hoc `Color.blue` into the single accent.

    enum Severity {
        case info, success, warning, danger

        var color: Color {
            switch self {
            case .info:    return Theme.Palette.accent
            case .success: return .green
            case .warning: return .orange
            case .danger:  return .red
            }
        }

        /// Default leading SF Symbol for this severity (call sites may override).
        var symbol: String {
            switch self {
            case .info:    return "info.circle"
            case .success: return "checkmark.seal.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger:  return "exclamationmark.triangle.fill"
            }
        }
    }

    // MARK: Typography
    //
    // Role → font mapping. SwiftUI's semantic fonts already scale with Dynamic Type;
    // pinning the role here stops the drift the audit found (sheet titles split
    // between `.title3.weight(.semibold)` and `.headline`; section headers between
    // `.headline` and `.subheadline.weight(.semibold)`).

    // Scale: "Comfortable" — every role sits a step or two above SwiftUI's tiny
    // defaults so labels/captions read easily (the audit's "text too small"). Chrome
    // is SF Pro (the system font); reading text is New York (serif) for long-form
    // transcript/note reading — a deliberate content/chrome split.
    // Now **look-dependent** (computed from the active `ThemeTokens`). Native (Tahoe)
    // keeps SF Pro chrome + New York serif reading; Cursor swaps the whole scale to
    // Geist (one family, weight-driven hierarchy). Sizes/roles are unchanged across
    // looks — only the typeface differs — so layout stays stable when switching.
    enum Typography {
        /// Top-of-window / primary screen title.
        static var screenTitle: Font { ThemeStore.shared.tokens.screenTitle }       // ~22
        /// Sheet & dialog titles.
        static var sheetTitle: Font { ThemeStore.shared.tokens.sheetTitle }         // ~17
        /// In-pane section headers.
        static var sectionHeader: Font { ThemeStore.shared.tokens.sectionHeader }   // ~15
        /// Default body / primary UI text.
        static var body: Font { ThemeStore.shared.tokens.body }                     // ~13
        /// Form-field labels (Title, Filing, …).
        static var fieldLabel: Font { ThemeStore.shared.tokens.fieldLabel }         // ~13
        /// Inline control / disclosure-group labels.
        static var controlLabel: Font { ThemeStore.shared.tokens.controlLabel }     // ~13 medium
        /// Secondary controls / labels.
        static var secondary: Font { ThemeStore.shared.tokens.secondary }           // ~12
        /// Captions / helper text.
        static var caption: Font { ThemeStore.shared.tokens.caption }               // ~12
        /// De-emphasized fine print.
        static var captionSecondary: Font { ThemeStore.shared.tokens.captionSecondary } // ~11
        /// Reading text — transcript lines & rendered notes (NY serif / Geist sans).
        static var reading: Font { ThemeStore.shared.tokens.reading }               // ~15
        /// Timestamps, file paths, code, model ids.
        static var mono: Font { ThemeStore.shared.tokens.mono }                     // ~12
        /// Prominent monospaced numerics (elapsed timers, large counts).
        static var monoLarge: Font { ThemeStore.shared.tokens.monoLarge }           // ~17
    }
}
