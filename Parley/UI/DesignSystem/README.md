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
| `ThemeTokens.swift` | `BrandFont` (bundled faces) and the single `ThemeTokens.brand` value set behind `Palette` / `Typography`. |
| `ButtonStyles.swift` | `.glassButton()` (secondary) / `.glassProminentButton()` (ink primary) / `InkButtonStyle(role: .record)` (Start recording only); `RowButtonStyle` (`.buttonStyle(.row(selected:))`); `.textFieldStyle(.parley)`. |
| `PillPicker.swift` | The segmented control: inset track + sliding white pill (`PillPicker(selection:options:)`). |
| `Components.swift` | `StatusBanner`, `StatusBadge`, `SectionHeader`. |
| `DesignSystemGallery.swift` | `#if DEBUG` preview gallery exercising everything (light + dark). |

## The look

One look, modeled on the Claude desktop app: flat, opaque surfaces with 0.5pt hairlines
— no materials or Liquid Glass. Neutral off-white canvas, light-grey sidebar, white
fields and panels. Colors are `Brand*` Asset color sets (light + dark). Blue
(`Palette.accent`) is for links and active filters; red (`Palette.record`) only for the
Start recording button; the primary button is solid ink; selection is a neutral wash.

Type (all OFL, bundled in `Resources/Fonts`, see `ThemeTokens.swift` → `BrandFont`):
Hanken Grotesk everywhere — chrome, the live transcript, and prose (`Typography.prose`
for My notes; `MarkdownUI.Theme.parley` for rendered notes and summaries) — and Geist
Mono for numerics.

Shapes: buttons, fields, and rows use 8pt continuous corners (~28pt tall); cards
12pt; the composer / floating panels 18pt.

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
Button("Record") {}.buttonStyle(InkButtonStyle(role: .record))   // Start recording only
TextField("Title", text: $t).textFieldStyle(.parley)
Button { … } label: { … }.buttonStyle(.row(selected: isSelected))   // sidebar/list row

// Status
StatusBanner(.danger, "Mic is off.", actionLabel: "Open Settings") { … }
StatusBadge("Review", severity: .info)

// Surfaces
someContent.cardSurface()
floatingCluster.glassSurface()                   // floating panel: fill + hairline + lift
```
