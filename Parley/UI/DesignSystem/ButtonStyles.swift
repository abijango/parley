import SwiftUI

// MARK: - Button styles
//
// Two **semantic** button helpers — `glassButton()` (secondary) and
// `glassProminentButton()` (primary) — give views one stable vocabulary and a single
// point of control. They are intentionally named for their *role*, not their material:
// the helper branches on the active look (`ThemeStore.shared.kind`):
//   • Native (Tahoe) → the native macOS 26 `.glass` / `.glassProminent` materials
//     (auto-fall-back to opaque under *Reduce Transparency*).
//   • Cursor          → a flat, matte `ClayButtonStyle` (solid clay primary / panel
//     secondary), the Cursor reference look.
// All ~50 call sites are unchanged; flipping the store reskins every button live.

extension View {

    /// Secondary action button. Tahoe = Liquid Glass; Cursor = flat panel + hairline.
    @ViewBuilder func glassButton() -> some View {
        if ThemeStore.shared.kind == .cursor {
            buttonStyle(ClayButtonStyle(prominent: false))
        } else {
            buttonStyle(.glass).buttonBorderShape(.roundedRectangle)
        }
    }

    /// Primary action button. Tahoe = prominent Liquid Glass; Cursor = solid clay fill.
    @ViewBuilder func glassProminentButton() -> some View {
        if ThemeStore.shared.kind == .cursor {
            buttonStyle(ClayButtonStyle(prominent: true))
        } else {
            buttonStyle(.glassProminent).buttonBorderShape(.roundedRectangle)
        }
    }
}

/// The Cursor-style button: flat and matte, no translucency. Primary is a solid clay
/// fill with white text; secondary is a panel fill with a hairline border. Interaction
/// is shown by darkening the fill a few percent (the matte analog of glass's material
/// response). `controlSize`-aware so `.controlSize(.small)` call sites (e.g.
/// `NotesActionBar`) stay correctly sized instead of rendering oversized.
struct ClayButtonStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        ClayLabel(configuration: configuration, prominent: prominent)
    }

    private struct ClayLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let m = Metrics(controlSize)
            let shape = Theme.Radius.rect(Theme.Radius.small)
            configuration.label
                .font(m.font)
                .foregroundStyle(prominent ? Theme.Palette.accentText : Theme.Palette.textPrimary)
                .padding(.horizontal, m.hPad)
                .padding(.vertical, m.vPad)
                .background {
                    if prominent {
                        shape.fill(Theme.Palette.accent)
                            .brightness(configuration.isPressed ? -0.06 : (hovering ? -0.03 : 0))
                    } else {
                        shape.fill(Theme.Palette.panelBg)
                            .overlay(shape.fill(Color.primary.opacity(
                                configuration.isPressed ? 0.10 : (hovering ? 0.05 : 0))))
                            .overlay(shape.strokeBorder(Theme.Palette.divider, lineWidth: 1))
                    }
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.quick, value: hovering)
        }

        /// Padding + font per control size, on the design-system scales.
        private struct Metrics {
            let hPad: CGFloat, vPad: CGFloat, font: Font
            init(_ size: ControlSize) {
                switch size {
                case .mini:
                    hPad = Theme.Spacing.small;  vPad = Theme.Spacing.xxSmall; font = Theme.Typography.captionSecondary
                case .small:
                    hPad = Theme.Spacing.small + 2; vPad = Theme.Spacing.xSmall; font = Theme.Typography.caption
                case .large, .extraLarge:
                    hPad = Theme.Spacing.large; vPad = Theme.Spacing.small + 1; font = Theme.Typography.controlLabel
                default: // .regular
                    hPad = Theme.Spacing.medium; vPad = Theme.Spacing.small - 1; font = Theme.Typography.controlLabel
                }
            }
        }
    }
}

/// Hover- and selection-aware row button for sidebars and lists. Addresses the
/// audit finding that custom `.plain` rows have no hover or selection affordance.
/// Selected → accent wash; hover/press → faint primary wash.
struct RowButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        RowLabel(configuration: configuration, isSelected: isSelected)
    }

    // A nested View is required so `@State` (hover) is backed by SwiftUI's state
    // system — a `ButtonStyle` is not itself a `View`.
    private struct RowLabel: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.small)
                .background(background(pressed: configuration.isPressed),
                            in: Theme.Radius.rect(Theme.Radius.small))
                .contentShape(Theme.Radius.rect(Theme.Radius.small))
                .onHover { hovering = $0 }
                .animation(Theme.Motion.quick, value: hovering)
        }

        private func background(pressed: Bool) -> Color {
            if isSelected { return Theme.Palette.accent.opacity(Theme.Opacity.selection) }
            if pressed    { return Color.primary.opacity(0.10) }
            if hovering   { return Color.primary.opacity(0.06) }
            return .clear
        }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    /// Hover/selection-aware row button. Use `.buttonStyle(.row(selected:))`.
    static func row(selected: Bool = false) -> RowButtonStyle {
        RowButtonStyle(isSelected: selected)
    }
}

/// Hover-aware capsule chip for compact inline affordances (file chips, token-like
/// pills). Quaternary fill at rest, brightening slightly on hover/press — the
/// missing hover affordance the audit catalogued on every custom chip.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipLabel(configuration: configuration)
    }

    private struct ChipLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.xxSmall + 1)
                .background(
                    ZStack {
                        Capsule().fill(.quaternary.opacity(Theme.Opacity.surface))
                        Capsule().fill(Color.primary.opacity(
                            configuration.isPressed ? 0.10 : (hovering ? 0.05 : 0)))
                    }
                )
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.Motion.quick, value: hovering)
        }
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    /// Hover-aware capsule chip. Use `.buttonStyle(.chip)`.
    static var chip: ChipButtonStyle { ChipButtonStyle() }
}
