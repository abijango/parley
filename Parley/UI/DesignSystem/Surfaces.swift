import SwiftUI

// MARK: - Surface treatments
//
// Three layered surfaces for macOS 26 (Tahoe). Adopt via the `View` extensions
// below; views should not hand-roll `.background(...)` for these roles.
//
// Layering model (the brief's "content at base, chrome floats above"):
//   • cardSurface  — grouped content sitting on the base layer.
//   • chromeSurface — navigation chrome (sidebar / toolbar / footer) above content.
//   • glassSurface  — genuinely floating clusters (capsular toolbars, action pods).

extension View {

    /// Grouped-content card: a low-chrome filled surface (settings groups, list
    /// rows, file chips). Quaternary fill on a continuous rounded rect.
    func cardSurface(radius: CGFloat = Theme.Radius.medium) -> some View {
        modifier(CardSurface(radius: radius))
    }

    /// Floating navigation chrome (sidebar, toolbars, footers). `.regularMaterial`
    /// today; the call site adds `glassSurface()` where a floating glass element is
    /// wanted. Kept as a distinct role so chrome is consistent everywhere.
    func chromeSurface() -> some View {
        background(.regularMaterial)
    }

    /// Liquid Glass for elements that genuinely float over content (capsular
    /// toolbars, action pods). Automatically falls back to opaque under the
    /// *Reduce Transparency* accessibility setting — no manual handling needed.
    func glassSurface<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular, in: shape)
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
    func body(content: Content) -> some View {
        content.background(.quaternary.opacity(Theme.Opacity.surface),
                           in: Theme.Radius.rect(radius))
    }
}
