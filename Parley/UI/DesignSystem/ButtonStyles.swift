import SwiftUI

// MARK: - Button styles
//
// Semantic button helpers, named for their *role* so call sites stay stable:
//   • `glassButton()`          — secondary: panel fill + hairline.
//   • `glassProminentButton()` — primary: solid ink (near-black / near-white in dark).
//                                One per view.
//   • `clayButton()`           — Record / Generate only: the clay accent.
// All share one shape (8pt continuous corners, ~28pt tall at regular size), matching
// the Claude desktop app. The "glass" names are historical; nothing is translucent.

extension View {

    /// Secondary action button: panel fill with a hairline border.
    func glassButton() -> some View {
        buttonStyle(InkButtonStyle(role: .secondary))
    }

    /// Primary action button: solid ink fill.
    func glassProminentButton() -> some View {
        buttonStyle(InkButtonStyle(role: .primary))
    }

    /// Record / Generate: the clay accent, reserved for capture and AI actions.
    func clayButton() -> some View {
        buttonStyle(InkButtonStyle(role: .clay))
    }
}

/// The app's push button. Flat and opaque; interaction darkens the fill a few percent.
/// `controlSize`-aware so `.controlSize(.small)` call sites stay correctly sized.
struct InkButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, clay }
    var role: Role = .secondary

    func makeBody(configuration: Configuration) -> some View {
        InkLabel(configuration: configuration, role: role)
    }

    private struct InkLabel: View {
        let configuration: Configuration
        let role: Role
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let m = Metrics(controlSize)
            let shape = Theme.Radius.rect(Theme.Radius.small)
            configuration.label
                .font(m.font)
                .foregroundStyle(foreground)
                .padding(.horizontal, m.hPad)
                .frame(minHeight: m.height)
                .background {
                    switch role {
                    case .primary:
                        shape.fill(Theme.Palette.ink).opacity(configuration.isPressed ? 0.82 : (hovering ? 0.9 : 1))
                    case .clay:
                        shape.fill(Theme.Palette.accent)
                            .brightness(configuration.isPressed ? -0.06 : (hovering ? -0.03 : 0))
                    case .secondary:
                        shape.fill(Theme.Palette.panelBg)
                            .overlay(shape.fill(Theme.Palette.textPrimary.opacity(
                                configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0))))
                            .overlay(shape.strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.quick, value: hovering)
        }

        private var foreground: Color {
            switch role {
            case .primary: return Theme.Palette.inkText
            case .clay: return Theme.Palette.accentText
            case .secondary: return Theme.Palette.textPrimary
            }
        }

        /// Height, padding, and font per control size.
        private struct Metrics {
            let hPad: CGFloat, height: CGFloat, font: Font
            init(_ size: ControlSize) {
                switch size {
                case .mini:
                    hPad = Theme.Spacing.small;      height = 20; font = Theme.Typography.captionSecondary
                case .small:
                    hPad = Theme.Spacing.small + 2;  height = 24; font = Theme.Typography.caption
                case .large, .extraLarge:
                    hPad = Theme.Spacing.large;      height = 34; font = Theme.Typography.controlLabel
                default:
                    hPad = Theme.Spacing.medium;     height = 28; font = Theme.Typography.controlLabel
                }
            }
        }
    }
}

/// Hover- and selection-aware row button for sidebars and lists. Addresses the
/// audit finding that custom `.plain` rows have no hover or selection affordance.
/// Selected → neutral wash (like the Claude sidebar); hover/press → fainter wash.
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
                .padding(.vertical, Theme.Spacing.small - 2)
                .background(background(pressed: configuration.isPressed),
                            in: Theme.Radius.rect(Theme.Radius.small))
                .contentShape(Theme.Radius.rect(Theme.Radius.small))
                .onHover { hovering = $0 }
                .animation(Theme.Motion.quick, value: hovering)
        }

        private func background(pressed: Bool) -> Color {
            if isSelected { return Theme.Palette.selection }
            if pressed    { return Theme.Palette.textPrimary.opacity(0.08) }
            if hovering   { return Theme.Palette.textPrimary.opacity(0.04) }
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

// MARK: - Text field style

/// The app's text field: 8pt corners, panel fill, hairline border that strengthens on
/// focus. Replaces `.roundedBorder`. Use `.textFieldStyle(.parley)`.
struct ParleyFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        FieldChrome(field: configuration)
    }

    private struct FieldChrome<Field: View>: View {
        let field: Field
        @FocusState private var focused: Bool
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            let shape = Theme.Radius.rect(Theme.Radius.small)
            field
                .textFieldStyle(.plain)
                .font(controlSize == .small ? Theme.Typography.caption : Theme.Typography.body)
                .focused($focused)
                .padding(.horizontal, Theme.Spacing.small + 2)
                .frame(minHeight: controlSize == .small ? 24 : 28)
                .background(shape.fill(Theme.Palette.panelBg))
                .overlay(shape.strokeBorder(focused ? Theme.Palette.textTertiary : Theme.Palette.divider,
                                            lineWidth: focused ? 1 : 0.5))
                .animation(Theme.Motion.quick, value: focused)
        }
    }
}

extension TextFieldStyle where Self == ParleyFieldStyle {
    /// The app's text field look. Use `.textFieldStyle(.parley)`.
    static var parley: ParleyFieldStyle { ParleyFieldStyle() }
}
