# Design Polish Brief — Elevate a Working Mac App to a High Design Standard

## Context
This is a native macOS app (Swift + SwiftUI, Xcode) whose **functionality is already built and working correctly**. This is a polish pass: elevate the UI to a polished, elegant, native-feeling standard aligned with macOS Tahoe (macOS 26) and Liquid Glass — **without changing behavior**.

## Hard Constraint (read first, applies to everything)
**Presentation-layer changes only.** Do NOT modify logic, data flow, state management, networking, persistence, or view-model behavior. Same data, same actions, same wiring — only how it looks and feels.
- Existing functional tests must stay green throughout. Run them after each phase/screen.
- No new third-party UI frameworks; no Electron or web views. SwiftUI-first; thin AppKit bridge only if unavoidable and approved.

## Operating Mode & Permission Boundaries (Auto Mode)
This brief is built to run under Claude Code **auto mode**. The auto-mode safety classifier blocks generically risky actions (mass deletions, prompt injection) but does **not** understand "presentation-only." That rule is enforced by the boundaries below, not by trust.

- **Run isolated:** execute in a dedicated git worktree/branch (e.g. `design-polish`).
- **Protected paths — never edit these.** Add to `.claudeignore` and `permissions.deny` in `.claude/settings.json` (adjust globs to this project's folder names):
  - `**/ViewModels/**`, `**/Models/**`, `**/Services/**`, `**/Networking/**`, `**/Persistence/**`, `**/Stores/**`, `*.xcdatamodeld/**`, anything containing business logic.
  - Editable: views, view styling, design-system/theme files, assets, and new presentation-only files.
- **Checkpoints are the only human gates.** There is no per-action approval in auto mode, so every **STOP** below is a hard gate: complete the phase, then halt and wait for explicit sign-off before continuing.
- **Tests are an automated gate.** After each screen, run the functional suite. A failure is a hard stop — do not proceed or paper over it.
- **If a styling change appears to need a protected-path edit, STOP and ask.** Never route around a permission boundary.

## North Star
Content is the star; chrome recedes. Polish comes from **restraint, consistency, and hierarchy** — not decoration. Consistency across screens is what the eye reads as "quality." When in doubt, remove visual weight rather than add it.

---

## Phase 0 — UI Audit (run in PLAN MODE; deliverable, then STOP)
Before changing anything, read the existing UI and produce `UI_AUDIT.md`. Do not edit app code in this phase.
- List every view/screen.
- For each view, list **all of its states**: default, empty, loading, error, hover, selected, focused, disabled, and edge cases.
- Note inconsistencies: ad-hoc colors, one-off paddings, mismatched fonts, missing states, non-native patterns.
- Flag the most important / most representative screen as the candidate "reference screen" for Phase 2.

**STOP. Wait for sign-off on the audit (and the reference-screen pick) before proceeding.**

---

## Phase 1 — Centralized Design System (foundation, then STOP)
Create the design system in one place before touching individual screens. Styling is consumed from tokens, never sprinkled per-view.
- Add a `DesignSystem`/`Theme` layer:
  - **Type scale** via semantic fonts (`.largeTitle`, `.title`, `.headline`, `.body`, `.callout`, `.caption`).
  - **Spacing scale** — one base unit (e.g. 8pt), use only multiples.
  - **Color** — one accent; semantic colors only (`Color.primary`, `.secondary`, `Color.accentColor`, materials). No hardcoded hex that fights dark mode.
  - **Materials** — `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial` for floating surfaces.
  - **Corner radii, shadows, animation curves** — define once (e.g. a standard spring).
- Build reusable `ViewModifier`s and custom `ButtonStyle`s (including `.glass` / `.glassProminent`) for views to adopt.
- Do not restyle screens yet — establish the system and confirm it compiles.

**STOP. Wait for sign-off on the design system before proceeding.**

---

## Phase 2 — Reference Screen (set the bar, then STOP)
Polish the flagged screen **fully** to target quality, consuming only Phase 1 tokens.
- Layering: content at base; toolbar/sidebar float above on Liquid Glass.
- Apply the type scale, spacing, accent, and materials consistently.
- Polish **every state** from the audit: real empty states (icon + short message + primary action), hover, focus rings, loading, error.
- Subtle, purposeful motion: spring on selection/transitions; `matchedGeometryEffect` where an element moves between contexts.
- Verify light/dark mode, Dynamic Type, and that it stays legible if Liquid Glass is disabled.
- Run functional tests.

**STOP. Get sign-off. This screen becomes the canonical pattern for everything else.**

---

## Phase 3 — Rollout (one screen per commit)
Propagate the established patterns to remaining screens, matching the reference screen exactly.
- One screen per commit; small, reviewable diffs.
- Reuse Phase 1 tokens/modifiers — invent no one-off styles. If a screen genuinely needs a new pattern, add it to the design system first, then use it.
- Polish all states per screen, same as the reference.
- Run functional tests after each screen; a failure is a hard stop.

---

## Liquid Glass / Tahoe Principles (target aesthetic)
- **Layering:** content at base; navigation (toolbar, sidebar) floats above on glass. Consistent everywhere — never "glass here, flat there."
- **Materials adapt** to what's behind them; avoid fixed frosted colors.
- **One accent color**, generous whitespace, strong typographic hierarchy.
- **Motion** is subtle and explanatory, never spectacle.
- **Legible without glass** — layout and contrast hold up if the effect is disabled.

## Quality Bar / References
Aim for the craft level of: **Play** (Apple Design Award 2025, SwiftUI Mac), **Craft**, **Reeder**, **Things 3**, **Tot**. Use Apple's own macOS Tahoe apps as the benchmark for materials and hierarchy.

## Workflow Rules
- Presentation-only diffs; respect every protected-path boundary.
- After each phase/screen, summarize what changed and what it improves, with before/after notes, before moving on.
- Honor every STOP as a hard gate.
- Keep functional tests green at every step.
