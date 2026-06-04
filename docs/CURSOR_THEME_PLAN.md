# Switchable Themes: Native (Tahoe) ↔ Cursor — Implementation Plan

## Goal
Keep the current macOS-native Tahoe look **and** add a Cursor-style look (warm paper
palette, clay accent, Geist typography, flat matte buttons, flat hairline panels),
switchable at runtime from Settings. Both looks share layout, spacing, radius, and
motion — only **color, font, and two surface/button behaviors** differ.

## Why this is cheap (audit result, 2026-06-03)
The Phase 0–3 design rollout funnelled *everything* through the design system:
- **~370** `Theme.Palette` / `Theme.Typography` token reads (no inline hex/fonts).
- **50** glass-button calls, all via 2 helpers (`glassButton`, `glassProminentButton`).
- **All** surfaces via 3 helpers (`cardSurface`, `chromeSurface`, `glassSurface`) —
  exactly **one** raw `.background(.regularMaterial)`, inside `chromeSurface()`.

=> The whole switch lives in the DesignSystem layer. **Zero view files change.**

## Architecture
- `ThemeKind { tahoe, cursor }` selects a `ThemeTokens` value set (colors + fonts).
- An `@Observable` store holds the current `ThemeTokens`.
- `Theme.Palette` / `Theme.Typography` become **computed** accessors reading the store
  (instead of `static let`), so all ~370 call sites keep working unchanged.
- The 2 button helpers + 3 surface helpers **branch on `kind`** (glass vs flat).
- Selection persisted in settings; a Settings picker flips it.

## Hard constraints
- Presentation-layer only (per `DESIGN_POLISH_BRIEF.md`).
- `AppSettings.swift` is a **protected path** — get explicit OK before editing, or use
  a presentation-only store for persistence.
- Keep functional tests green; both looks must read correctly on every screen.

---

## Task list

- [x] **Step 1 — Reactivity spike (de-risk). ✅ PASSED.** Proved that a computed
  `static var` reading an `@Observable` store is tracked by SwiftUI's Observation.
  Verified headlessly via `withObservationTracking` (the exact primitive SwiftUI uses
  to drive body re-evaluation): reading `Theme.Palette.accent` inside the tracking
  scope fires `onChange` when the store flips. **No `.id` fallback needed — the
  zero-call-site-change approach is reactive.** Caveat carried forward: tokens must be
  read *inside* `body` (the existing code does; don't cache a token in `init`/a stored
  `let`, or that read won't be tracked).
- [x] **Step 2 — Bundle Geist. ✅** 18 static TTFs (Geist + Geist Mono, 9 weights each,
  v1.7.2) in `Parley/Resources/Fonts/` + `OFL.txt`. `project.yml`: folder reference
  (`type: folder`, excluded from main glob) + `ATSApplicationFontsPath: Fonts`. Verified
  in the built `.app`: 18 ttf in `Contents/Resources/Fonts`, plist key present → fonts
  register at launch. Family names: `Geist` / `Geist Mono`; per-weight PostScript names.
- [x] **Step 3 — Theme foundation. ✅** New `ThemeTokens.swift`: `ThemeKind`,
  `GeistFont` (weight→PostScript face), `ThemeTokens` (`.tahoe` = SF Pro + NY serif +
  system colors, byte-identical to before; `.cursor` = Geist + warm paper + clay),
  `@Observable ThemeStore.shared`. `Theme.Palette` + `Theme.Typography` converted to
  computed accessors reading the store. Builds.
- [x] **Step 4 — Warm Asset color sets. ✅** 8 colorsets (light+dark) in
  `Assets.xcassets`: CursorAccent/WindowBg/PanelBg/SidebarBg/Divider/TextPrimary/
  TextSecondary/TextTertiary. Compiled into `Assets.car` (16 refs).
- [x] **Step 5 — Buttons. ✅** `ClayButtonStyle` (flat matte, prominent + secondary,
  controlSize-aware). `glassButton()` / `glassProminentButton()` branch on `kind`
  (Tahoe glass / Cursor clay). Zero call-site changes (50 sites unchanged).
- [x] **Step 6 — Surfaces. ✅** `cardSurface()` / `chromeSurface()` / `glassSurface()`
  branch on `kind` (Cursor = flat panel + hairline; Tahoe = materials/glass). One
  consolidated **BUILD SUCCEEDED** covers Steps 2–6.

  > ⚠️ **Known gap (for Step 9):** bare SwiftUI `.foregroundStyle(.secondary)`/`.primary`
  > in views are *not* routed through `Theme.Palette`, so text-color hierarchy stays
  > system-semantic in both looks. Cursor's accent/backgrounds/fonts/buttons/surfaces
  > all switch; warm-gray *text* would need either token adoption in views (breaks the
  > zero-view-file rule) or accepting system grays. Decide in Step 9.
- [x] **Step 7 — Verify in the gallery. ✅ (build)** Added a live Native↔Cursor
  segmented `Picker` to `DesignSystemGallery` (DEBUG-only) that calls
  `ThemeStore.select(...)`; gallery reskins via Observation + a `windowBg` backdrop.
  **BUILD SUCCEEDED.** Visual review is in Xcode's preview canvas (open
  `DesignSystemGallery.swift` → canvas → flip the segmented control). Real-app
  spot-check of `LiveTranscriptView`/`MainWindowView` pending a flip mechanism (temp
  default or Step 8 toggle).
- [x] **Step 8 — Settings toggle + persistence. ✅** Added an "Appearance" segmented
  picker (Native / Cursor) to Settings → General. Persistence moved into `ThemeStore`
  via `UserDefaults` (key `selectedThemeKind`) — **presentation-layer only; `AppSettings`
  untouched** (protected path avoided as planned). Debug build green; `localrelease.sh`
  installed to `~/Applications/Parley.app` (Release bundle verified: 18 ttf, plist key,
  16 Cursor color refs). Switching is instant and survives relaunch.
- [ ] **Step 9 — Tune.** Eyeball clay saturation, paper warmth, Geist sizes, hairline
  weight in light + dark across all 7 screens.

## Incidental fix — post-rename data migration (2026-06-04)
The Macsribe→Parley rename (commit 8c823c4) repointed `AppPaths.supportDirectory`
(name-keyed) at a fresh dir, stranding the old models, recordings, and summary models
in `~/Library/Application Support/Macsribe`. Not deleted — abandoned in place.
- **Durable fix:** `Parley/App/SupportDirectoryMigration.swift` — one-time,
  UserDefaults-guarded, runs in `AppDelegate.applicationWillFinishLaunching`. Moves
  only missing items, never overwrites, prunes emptied dirs. Handles any future rename
  (append to `priorNames`).
- **Performed now:** moved 6 recordings (836M) + SummaryModels (2.1G) into Parley;
  restored the large-v3-turbo tokenizer metadata; deleted redundant old models.
  **Kept** the old encrypted `Speakers` store (692K) as a backup — its `.store-key` is
  name-local so it can't be merged; user must verify Parley's speakers then delete it.
- Reinstalled via localrelease.

## Settings → Cursor layout (2026-06-04)
- Sidebar nav (NavigationSplitView) replaced top tabs; switch-style toggles (Form
  default was checkbox); big inline pane title; `SettingRow` (title+description /
  control) idiom.
- Rollout: General, Transcription (unified Live/Final model dropdowns + inline
  download/delete), Summary, Detection, Notes converted to `SettingRow`.
- Storage / Vault / Speakers are management/list UIs (sessions, reconciliation,
  voiceprint rows) — already leading-label / trailing-control HStacks, so they match
  the `SettingRow` look without conversion.
- **Gap #2 (Form backdrop stays system-grey in Cursor mode): intentionally deferred.**
  Per user, the grey backdrop matches Cursor's own light theme and is fine; the warm
  palette is correct. Focus is Cursor *layout/elements*, not colors. A true Cursor
  light-grey theme can be added later as a separate option if wanted.

## Progress log
- 2026-06-03: Plan created. Starting Step 1.
- 2026-06-03: Step 1 PASSED. `withObservationTracking` spike (`/tmp/theme_spike.swift`,
  Swift 6.3) confirmed Observation tracks reads through nested-enum static accessors;
  store flip fires onChange and re-arms each cycle. Foundation approach validated.
  Next: Step 2 (bundle Geist).
- 2026-06-03: Steps 2–6 DONE in one pass. Geist bundled + verified in the .app; theme
  foundation (ThemeTokens/ThemeStore) in place; 8 warm colorsets added; buttons +
  surfaces branch on kind. Consolidated Debug build: **BUILD SUCCEEDED**, 0 errors,
  0 view files touched. Default look is still `.tahoe` (nothing flips it yet).
  Next: Step 7 — add a flip in DesignSystemGallery + live spot-check (awaiting go-ahead).
- 2026-06-04: Step 7 DONE (build). Gallery has a live Native↔Cursor segmented toggle;
  BUILD SUCCEEDED. Review in Xcode canvas. Pending user decision: how to view the real
  running app in Cursor mode (temp default vs Step 8 Settings toggle), and the
  AppSettings protected-path OK for Step 8 persistence.
- 2026-06-04: Step 8 DONE. Settings → General → Appearance picker (Native/Cursor),
  persisted via UserDefaults inside ThemeStore (AppSettings NOT touched). Installed via
  localrelease.sh → ~/Applications/Parley.app. User can now flip the whole app live.
  Remaining: Step 9 — visual tuning (clay/paper hex, Geist sizes, hairlines) + decide
  the bare-.secondary text-color gap. Awaiting the user's eyeball pass.
