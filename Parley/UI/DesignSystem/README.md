# Design System

Centralized presentation tokens and reusable styles for the app. Established in
**Phase 1** of the design-polish pass (see `docs/DESIGN_POLISH_BRIEF.md` and
`UI_AUDIT.md`). Screens are **not** yet adopting this layer — that begins in Phase 2.

## Rule

Styling is consumed from these tokens, **never** re-specified per view. No raw
spacing numbers, no ad-hoc hex, no inline status colors. If a screen needs a new
pattern, add it here first, then adopt it.

## Files

| File | What it holds |
|---|---|
| `Theme.swift` | All tokens: `Spacing`, `Radius`, `Motion`, `Shadow`, `Opacity`, `Palette`, `Severity`, `Typography`. |
| `Surfaces.swift` | `.cardSurface()`, `.chromeSurface()`, `.glassSurface()`, `.elevation(_:)`. |
| `ButtonStyles.swift` | `.glassButton()` / `.glassProminentButton()` adoption helpers; `RowButtonStyle` (`.buttonStyle(.row(selected:))`). |
| `Components.swift` | `StatusBanner`, `StatusBadge`, `SectionHeader`. |
| `DesignSystemGallery.swift` | `#if DEBUG` preview gallery exercising everything (light + dark). |

## Liquid Glass & the deployment target

The app targets **macOS 26+ (Tahoe)** only. Liquid-Glass APIs (`.glass`,
`.glassProminent`, `glassEffect`) are used directly — no availability guards or
material fallbacks. Glass automatically degrades to an opaque appearance under the
*Reduce Transparency* accessibility setting, so "legible without glass" holds for
free. Adopt glass through the helpers here (`.glassButton()`, `.glassSurface()`) so
there's one point of control.

## Quick reference

```swift
// Spacing / radius
.padding(Theme.Spacing.large)
.background(.quaternary, in: Theme.Radius.rect(Theme.Radius.medium))

// Motion
withAnimation(Theme.Motion.spring) { … }

// Buttons
Button("Save") {}.glassProminentButton()        // primary
Button("Cancel") {}.glassButton()               // secondary
Button { … } label: { … }.buttonStyle(.row(selected: isSelected))   // sidebar/list row

// Status
StatusBanner(.danger, "Mic is off.", actionLabel: "Open Settings") { … }
StatusBadge("Review", severity: .info)

// Surfaces
someContent.cardSurface()
floatingCluster.glassSurface()                   // Liquid Glass floating surface
```
