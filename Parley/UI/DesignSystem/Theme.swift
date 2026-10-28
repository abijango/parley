import SwiftUI

/// Centralized design tokens. Everything visual — spacing, corner radius, motion,
/// elevation, tint strengths, status semantics, and type roles — is defined here
/// once and consumed by views. Views must not re-specify these inline.
///
/// Phase 1 of the design-polish pass establishes this layer; existing screens are
/// **not** yet adopting it (that's Phase 2+). The system compiles and is exercised
/// in isolation by the `#Preview` gallery in `DesignSystemGallery.swift`.
///
/// Look: one flat, warm "paper and ink" style modeled on the Claude desktop app —
/// opaque surfaces with hairline borders rather than materials / Liquid Glass.
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
        /// 8pt — buttons, text fields, sidebar rows, chips.
        static let small: CGFloat = 8
        /// 12pt — cards, banners, list surfaces.
        static let medium: CGFloat = 12
        /// 18pt — the composer bar, sheets, large floating panels.
        static let large: CGFloat = 18

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
        /// Accent wash strength where a tinted selection is still wanted (chips).
        static let selection: Double = 0.18
        /// Quaternary card / grouped-content backgrounds.
        static let surface: Double = 0.35
    }

    // MARK: Color
    //
    // One look (see `ThemeTokens.swift`): warm paper canvas, darker sidebar, neutral
    // selection wash, ink for the primary action, clay accent for Record / Generate.
    // Values are `Brand*` Asset color sets, so light/dark come from one place.

    enum Palette {
        static var accent: Color        { ThemeTokens.brand.accent }
        static var accentText: Color    { ThemeTokens.brand.accentText }
        static var windowBg: Color      { ThemeTokens.brand.windowBg }
        static var panelBg: Color       { ThemeTokens.brand.panelBg }
        static var sidebarBg: Color     { ThemeTokens.brand.sidebarBg }
        static var divider: Color       { ThemeTokens.brand.divider }
        static var selection: Color     { ThemeTokens.brand.selection }
        static var ink: Color           { ThemeTokens.brand.ink }
        static var inkText: Color       { ThemeTokens.brand.inkText }
        static var textPrimary: Color   { ThemeTokens.brand.textPrimary }
        static var textSecondary: Color { ThemeTokens.brand.textSecondary }
        static var textTertiary: Color  { ThemeTokens.brand.textTertiary }
    }

    // MARK: Severity
    //
    // The four status meanings used across the app (advisories, banners, badges,
    // model/permission/summary state). Consolidates the repeated
    // green-seal / orange-triangle / red-triangle / blue-badge literals into one
    // vocabulary, and folds the ad-hoc `Color.blue` into the single accent.

    enum Severity {
        case info, success, warning, danger

        @MainActor var color: Color {
            switch self {
            case .info:    return .blue
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
    // Role → font mapping. Chrome and the live transcript are Hanken Grotesk; long-form
    // prose (summaries, rendered notes, My notes) is KF Libron; numerics/paths are Geist
    // Mono. Fonts use `relativeTo:` so they still scale with Dynamic Type.
    enum Typography {
        /// Top-of-window / primary screen title.
        static var screenTitle: Font { ThemeTokens.brand.screenTitle }           // 22
        /// Sheet & dialog titles.
        static var sheetTitle: Font { ThemeTokens.brand.sheetTitle }             // 18
        /// In-pane section headers.
        static var sectionHeader: Font { ThemeTokens.brand.sectionHeader }       // 15
        /// Default body / primary UI text.
        static var body: Font { ThemeTokens.brand.body }                         // 14
        /// Form-field labels (Title, Filing, …).
        static var fieldLabel: Font { ThemeTokens.brand.fieldLabel }             // 14
        /// Inline control / disclosure-group labels.
        static var controlLabel: Font { ThemeTokens.brand.controlLabel }         // 14 medium
        /// Secondary controls / labels.
        static var secondary: Font { ThemeTokens.brand.secondary }               // 13
        /// Captions / helper text.
        static var caption: Font { ThemeTokens.brand.caption }                   // 13
        /// De-emphasized fine print.
        static var captionSecondary: Font { ThemeTokens.brand.captionSecondary } // 12
        /// Transcript lines (sans — dense, timestamped, reads like UI text).
        static var reading: Font { ThemeTokens.brand.reading }                   // 15
        /// Long-form prose: summaries, rendered notes, the notes editor (serif).
        static var prose: Font { ThemeTokens.brand.prose }                       // 16
        /// Timestamps, file paths, code, model ids.
        static var mono: Font { ThemeTokens.brand.mono }                         // 12
        /// Prominent monospaced numerics (elapsed timers, large counts).
        static var monoLarge: Font { ThemeTokens.brand.monoLarge }               // 18
    }
}
