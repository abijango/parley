import SwiftUI

// MARK: - Surface treatments
//
// Three layered surfaces. Adopt via the `View` extensions below; views should not
// hand-roll `.background(...)` for these roles. Each branches on the active look
// (`ThemeStore.shared.kind`):
//   • Native (Tahoe) → macOS 26 materials / Liquid Glass.
//   • Cursor          → flat warm panels with hairline borders (no translucency).
//
// Layering model (the brief's "content at base, chrome floats above"):
//   • cardSurface  — grouped content sitting on the base layer.
//   • chromeSurface — navigation chrome (sidebar / toolbar / footer) above content.
//   • glassSurface  — genuinely floating clusters (capsular toolbars, action pods).

extension View {

    /// Grouped-content card: a low-chrome filled surface (settings groups, list
    /// rows, file chips). Tahoe = quaternary fill; Cursor = flat panel + hairline.
    func cardSurface(radius: CGFloat = Theme.Radius.medium) -> some View {
        modifier(CardSurface(radius: radius))
    }

    /// Navigation chrome (sidebar, toolbars, footers). Tahoe = `.regularMaterial`;
    /// Cursor = flat warm sidebar fill. Kept as a distinct role so chrome is
    /// consistent everywhere.
    @ViewBuilder func chromeSurface() -> some View {
        if ThemeStore.shared.kind == .cursor {
            background(Theme.Palette.sidebarBg)
        } else {
            background(.regularMaterial)
        }
    }

    /// Elements that genuinely float over content (capsular toolbars, action pods).
    /// Tahoe = Liquid Glass (falls back to opaque under *Reduce Transparency*);
    /// Cursor = flat panel fill + hairline, clipped to the shape.
    @ViewBuilder func glassSurface<S: Shape>(in shape: S) -> some View {
        if ThemeStore.shared.kind == .cursor {
            background(shape.fill(Theme.Palette.panelBg))
                .overlay(shape.stroke(Theme.Palette.divider, lineWidth: 1))
        } else {
            glassEffect(.regular, in: shape)
        }
    }

    /// Capsule-shaped `glassSurface()` — the common floating-control case.
    func glassSurface() -> some View {
        glassSurface(in: Capsule())
    }

    /// Apply a design-system shadow.
    func elevation(_ shadow: Theme.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

private struct CardSurface: ViewModifier {
    let radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        let shape = Theme.Radius.rect(radius)
        if ThemeStore.shared.kind == .cursor {
            content
                .background(shape.fill(Theme.Palette.panelBg))
                .overlay(shape.strokeBorder(Theme.Palette.divider, lineWidth: 1))
        } else {
            content.background(.quaternary.opacity(Theme.Opacity.surface), in: shape)
        }
    }
}
