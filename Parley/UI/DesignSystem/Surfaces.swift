import SwiftUI

// MARK: - Surface treatments
//
// Three layered surfaces, all flat and opaque (the "paper and ink" look — no
// materials / Liquid Glass). Adopt via the `View` extensions below; views should not
// hand-roll `.background(...)` for these roles.
//
// Layering model (content at base, chrome slightly darker, floating bits lifted):
//   • cardSurface   — grouped content sitting on the base layer.
//   • chromeSurface — navigation chrome (sidebar / toolbar / footer).
//   • glassSurface  — genuinely floating clusters (composer bar, action pods). The
//                     name is kept so existing call sites don't churn.

extension View {

    /// Grouped-content card: panel fill + hairline (settings groups, list rows, file chips).
    func cardSurface(radius: CGFloat = Theme.Radius.medium) -> some View {
        let shape = Theme.Radius.rect(radius)
        return background(shape.fill(Theme.Palette.panelBg))
            .overlay(shape.strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
    }

    /// Navigation chrome (sidebar, toolbars, footers): the warm sidebar fill.
    func chromeSurface() -> some View {
        background(Theme.Palette.sidebarBg)
    }

    /// Elements that float over content: panel fill, hairline, and a soft lift.
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        background(shape.fill(Theme.Palette.panelBg))
            .overlay(shape.strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
            .elevation(.card)
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
