import SwiftUI

// MARK: - Button styles
//
// Liquid-Glass button adoption helpers + a hover/selection-aware row style. The
// glass helpers wrap the native macOS 26 `.glass` / `.glassProminent` styles behind
// a semantic name (secondary / primary), giving views one stable vocabulary and a
// single point of control. (Glass auto-falls-back to opaque under the *Reduce
// Transparency* accessibility setting.)

extension View {

    /// Secondary action button (Liquid Glass). Rounded-rectangle shape to match the
    /// app's segmented controls — less round than the default glass capsule.
    func glassButton() -> some View {
        buttonStyle(.glass).buttonBorderShape(.roundedRectangle)
    }

    /// Primary action button (Liquid Glass, prominent). Rounded-rectangle shape to
    /// match the app's segmented controls.
    func glassProminentButton() -> some View {
        buttonStyle(.glassProminent).buttonBorderShape(.roundedRectangle)
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
