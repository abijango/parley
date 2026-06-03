# UI Audit — Phase 0

A read-only inventory of every screen, every state, and every cross-screen
inconsistency in the current UI, produced before any styling work. No app code
was changed. Scope: `Parley/UI/*.swift` (15 files, ~3.6k lines) plus the scene
graph in `Parley/App/ParleyApp.swift`.

---

## 1. Scene graph — where screens live

The app (`ParleyApp.swift`) has **three top-level surfaces**:

| Scene | Type | Root view | Default size |
|---|---|---|---|
| Main window | `Window` (single, not `WindowGroup`) | `MainWindowView` | 560×700 (min 720×560) |
| Menu bar | `MenuBarExtra(style: .window)` | `MenuBarView` | 280 wide |
| Settings | `Settings` scene | `SettingsView` (8 tabs) | 540–600 wide |

Everything else is a child view, a sheet, or a popover hung off one of these.

There is **no `Assets.xcassets` / no `AccentColor` color set** in the project, so
`Color.accentColor` resolves to the *system* tint (whatever the user picked in
System Settings), not an app-owned accent. This matters for Phase 1: "one accent"
currently means "the OS accent," which is a reasonable native default but is not
yet a deliberate design choice.

---

## 2. Screen-by-screen inventory & states

Legend for states checked: **default · empty · loading · error · hover · selected ·
focused · disabled · edge cases**.

### 2.1 `MainWindowView` — the window shell (sidebar + detail)
`Parley/UI/MainWindowView.swift:6`

A hand-rolled `HStack { sidebar | Divider | detail }` — **deliberately not**
`NavigationSplitView` (documented reason at `:33`: NavigationSplitView misrendered
on narrow built-in displays). Sidebar switches between **Record** and **History**;
Settings is pinned at the bottom via `SettingsLink`.

States:
- **Default:** Record selected, sidebar expanded (170pt).
- **Collapsed sidebar:** icon-only rail (52pt), `@AppStorage`-persisted, animated `.easeInOut(0.15)`.
- **Selected nav item:** accent-tinted background (`Color.accentColor.opacity(0.18)`), label turns accent.
- **History badge:** blue capsule count (expanded) / blue 7pt dot (collapsed) when summaries are running/ready.
- **Recovery sheet:** auto-presents on launch if `pendingRecoveries` non-empty; auto-dismisses when drained.
- **Hover:** none — plain `Button(.plain)` rows have no hover affordance.
- **Edge cases:** `selection ?? .record` fallback; sidebar background is a flat `Color(nsColor: .windowBackgroundColor)` (no material).

### 2.2 `RecordDetailView` — the live recording experience  ⭐ reference candidate
`Parley/UI/MainWindowView.swift:158`

The app's home screen. Vertical stack: **control bar → divider → content (Live |
Preview) → offline-pass bar → divider → footer**. The richest state surface in the app.

Recording state machine (`recording.state`): **idle · preparing · recording · stopping · error**, each driving:
- **Record button:** "Start recording" (accent) ↔ "Stop" (red); disabled during preparing/stopping.
- **Status badge:** colored dot + text — Ready (secondary) / Preparing… (orange) / Recording (red) / Stopping… (orange) / Error (red); idle further reflects model status (Downloading… / loading stage / Model error).
- **Timer:** monospaced `TimelineView` ticking 1s while recording, with `.numericText()` transition; absent when idle.

Other states:
- **Mode picker:** segmented Live / Preview; auto-switches to Preview when a transcript finishes writing.
- **Audio section:** collapsible disclosure (`@AppStorage`); expanded shows capture-mode picker, per-app picker (only in `.perApp`), and live Me/Remote level meters (only while recording).
- **Model loading bar:** linear `ProgressView` + stage text, shown only while downloading/loading.
- **Advisory banners (persistent):** mic denied (red), system-audio off (red), memory advisory (orange) — each a tinted `RoundedRectangle(opacity 0.10)` with an optional "Open Settings" action.
- **Error row:** red triangle + message, conditional "Open Settings" if the message mentions "microphone".
- **Metadata fields:** `Grid` of Title / Filing (`DestinationField`) / Attendees (`TokenField`) / Notes (`TextEditor`) — editable mid-recording.
- **Offline-pass bar:** idle (hidden) / running (spinner + "Offline Speaker Detection…") / done (green seal + note); lingers until next recording.
- **Footer:** last result OR segment count, "Assign speakers (N)" (when pending review), "Reveal in Finder" (when transcript exists), Settings link.
- **Empty:** delegated to `LiveTranscriptView` empty state.
- **Edge cases:** speaker-naming only wired when engine is FluidAudio; `liveDisabled` when WhisperKit + live transcript off.

### 2.3 `HistoryView` — transcript browser  ⭐ secondary reference candidate
`Parley/UI/HistoryView.swift:7`

A resizable `HSplitView { list | detail }`. List is newest-first with search +
filter; detail renders the selected note and exposes per-item file actions.

**List** states:
- **Default:** `List(.inset)` of rows; each row = title + status badge + date/type icon + attendees, plus a per-row spinner (summarizing) or orange "needs review" person icon.
- **Filter picker:** segmented All / Review(N) / Unassigned / Processed / Unprocessed.
- **Search bar:** magnifier + clear (×) + "search inside contents" toggle button.
- **Empty:** icon (clock or magnifier) + contextual message ("No transcripts yet." / "No meetings match …").
- **Selected:** native list selection; **multi-select** supported.
- **Status badge:** Review (blue) / Processed (green) / Unprocessed (orange) capsule.
- **Context menu / delete key:** rename, refile, reveal, delete.

**Detail** states:
- **None selected:** empty placeholder (doc icon + "Select a transcript to preview it.").
- **Single selected:** header (title, metadata, ⋯ menu, status badge) + files strip (chips) + optional unassigned-speakers warning + action row + transcript preview.
- **Summary staged → review pane:** editable destination + rendered note + Discard / Regenerate / Commit & File.
- **Summary running:** "Summarizing in the background…" bar (spinner).
- **Summary failed:** orange bar + Retry.
- **Multi-select → bulk panel:** count + linked-audio size + Refile / Summarize / Delete.
- **Disabled:** action buttons gated on `busy` (notes running or offline pass running).
- **Edge cases:** audio-missing variants of the warning + "Detect speakers" hidden when no audio; "Summarize anyway" confirmation dialog when speakers unnamed.

**Modals owned here:** rename sheet, refile sheet, delete sheet (with audio/note toggles), add-attendee popover, assign-speakers sheet, unnamed-speaker confirmation dialog.

### 2.4 `SettingsView` — 8-tab settings
`Parley/UI/SettingsView.swift:6`

`TabView` with tabs: **General · Transcription · Speakers · Notes · Summary ·
Detection · Storage · Vault**. A grab-bag of three different layout idioms (see §3).

- **General** (`Form`): vault path, transcript-dir readout, default capture mode, log reveal/clear.
- **Transcription** (`ScrollView`+`VStack`): engine picker, then a large branch — WhisperKit (live toggle, live model menu, final-model radio list, compute, memory/idle-unload, reset cache, speaker recognition sliders) vs FluidAudio (`FluidModelSection`, separation slider, recognition sliders, final-transcript toggle). Most controls **disabled while recording**.
- **Speakers:** embeds `SpeakersSettingsView` (§2.12).
- **Notes** (`Form`): auto-run toggle, claude path, model, prompt template editor.
- **Summary** (`ScrollView`): auto-summarize + delete-audio toggles, claude model/CLI, prompt `TextEditor`, reset-to-default. **Overlaps Notes** (see §3).
- **Detection** (`Form`): toggles, permission rows, known-apps editor, verbose-log toggle, live detector status.
- **Storage** (`VStack`): recordings list with checkboxes, bulk/purge delete, orphan detection, per-row reveal/delete; confirmation dialogs.
- **Vault** (`VStack`): scan-roots editor, contacts file, customer reconciliation (clean state vs near-matches/file-only/folder-only sections).
- **Model row** (`modelRow`): radio circle (active = accent), label+size+blurb, and a trailing control that is one of **download progress / "Active" label / "Use" button / "Download" button**.
- **`FluidModelSection`** statuses: unknown/notDownloaded (Download) · downloading (spinner) · downloaded (green Active) · failed (Retry + red msg).
- Empty states: "No recordings yet." / "No saved speakers yet." / reconciliation "All customers reconciled."

### 2.5 `MenuBarView` — menu-bar companion
`Parley/UI/MenuBarView.swift:5`

Fixed 280pt panel: title + status text, optional error (red) / last-result (secondary)
line, Start/Stop button (accent ↔ red, disabled during transitions), "Open … Window"
button, Settings + Quit footer. The menu-bar *symbol* itself (`ParleyApp.swift:45`)
swaps by state: `record.circle.fill` / `waveform.circle` / `exclamationmark.triangle` / `waveform`.

### 2.6 `LiveTranscriptView` (+ `TranscriptRow`)
`Parley/UI/LiveTranscriptView.swift:10`

Auto-scrolling `LazyVStack` of segment rows.
- **Empty:** 4 variants by (`isRecording` × `liveDisabled`) — "Listening…" / "Start recording…" / "Recording… transcript generated when you stop" / "Offline-only mode…".
- **Row:** monospaced timestamp (tertiary) + speaker label (semibold, palette color) + body text; **tentative segments dimmed** (`opacity 0.6`, secondary text).
- **Speaker label:** a tappable chip → naming popover **only** when `speakerId != nil` and `onNameSpeaker` provided (FluidAudio); otherwise plain text.
- **Naming popover:** "In this call" one-tap attendee buttons + free-text field + Rolodex autocomplete + Save.
- **Speaker color:** stable 8-color palette hashed by speaker id, else by track (me = accent, remote = green).
- **Edge cases:** new-segment animated scroll-to-bottom; `Spacer(minLength: 0)`.

### 2.7 `TranscriptPreviewView`
`Parley/UI/TranscriptPreviewView.swift:7`

Renders a saved `.md` via **MarkdownUI** (the one third-party render dependency).
- **Content:** scrollable Markdown, monospaced code, selectable, 20pt padding.
- **Placeholder:** doc icon + "No transcript yet…".
- **Error:** "moved or processed" / "Couldn't read the note: …".
- **Edge cases:** strips YAML frontmatter; reloads on `url` or `reloadToken` change.

### 2.8 `NotesActionBar`
`Parley/UI/NotesActionBar.swift:5`

State machine over `NotesGenerator.state`, on a `.background(.bar)` strip (**the only
material surface in the app**):
- **idle:** "Generate meeting notes" (prominent) → confirm popover (filing/attendees/model grid).
- **running:** spinner + elapsed timer + Cancel + a 120pt monospaced activity feed (auto-scroll).
- **finished:** green "Notes ready" + Open in Obsidian / Reveal / Re-run.
- **failed:** red triangle + message + Settings + Retry.

### 2.9 `NoteDiffView`
`Parley/UI/NoteDiffView.swift:7`

Unified line diff (Swift `CollectionDifference`) for a re-processed note.
- **Default:** scrollable +/− rows, green/red tinted backgrounds, monospaced.
- **No changes:** "equal.circle" + "identical to the existing one."
- **Footer:** Discard (cancel) / Accept (prominent).
- Note: min size 560×480. *(Reachability unclear — see §3 dead/uncertain code.)*

### 2.10 `RecoveryView` (sheet)
`Parley/UI/RecoveryView.swift:7`

Launch-time crash-recovery sheet (540×440). Per interrupted session: title + duration/date
+ filing, optional "Call still live" green label, and **Resume** (prominent, green if live) /
**Recover** menu (instant vs re-transcribe) / **Discard**. Global "Re-transcribing audio…"
spinner; "Later" dismiss. Buttons disabled while busy/recovering. Each row on a
`.quaternary.opacity(0.4)` rounded card.

### 2.11 `AssignSpeakersView` (sheet)
`Parley/UI/AssignSpeakersView.swift:7`

At-stop FluidAudio speaker assignment (520×440). Per speaker: ▶ play-sample button,
name + talk-seconds + first-line quote, Name…/Rename… → naming popover (same pattern
as §2.6). "Done" finalizes. Edge case: `displayName` falls back to "Speaker {id}".

### 2.12 `SpeakersSettingsView` (Settings → Speakers tab)
`Parley/UI/SpeakersSettingsView.swift:6`

- **Empty:** "No saved speakers yet…".
- **List:** scrollable rows (max 220pt) on a `.quaternary` rounded surface — play-clip button (disabled if no clip), name + sample count/clip/updated date, Rename, trash.
- **Re-enrollment section:** stale-warning label (orange), regenerate button + progress, status text.
- **Backup/transfer:** export/import secure-field + buttons, status line.
- **Rename sheet:** 300pt, name field + Cancel/Save.
- Uses `NSSavePanel`/`NSOpenPanel` (native).

### 2.13 `NewPersonSheet` (sheet)
`Parley/UI/NewPersonSheet.swift:5`

380pt contact form: Name/Title/Company/LinkedIn `Grid`, helper caption, Cancel/Add.
Auto-focuses Title (name is prefilled). Add disabled until name non-empty.

### 2.14 `DestinationField` (component)
`Parley/UI/DestinationField.swift:7`

SwiftUI type-ahead filing picker. Rounded text field + suggestion list (max 170pt) +
"Create '…'" row. **Keyboard:** ↑/↓ highlight, ⏎ choose, esc close. Highlighted row =
`accentColor.opacity(0.2)`. Used in RecordDetail, History review/refile.

### 2.15 `TokenField` (component, `NSViewRepresentable`)
`Parley/UI/TokenField.swift:6`

`NSTokenField` bridge — rounded chips, native prefix completion, routes new names to
`onCreateNew`. Carries non-trivial logic to avoid a "random attendee added" bug on live
re-render. Legitimate AppKit bridge (no SwiftUI equivalent).

### 2.16 `ComboBoxField` (component, `NSViewRepresentable`) — ⚠ DEAD CODE
`Parley/UI/ComboBoxField.swift:6`

`NSComboBox` bridge. **Referenced nowhere** outside its own file (`grep` confirms zero
call sites). Candidate for deletion, or it's a leftover the `DestinationField` replaced.

---

## 3. Inconsistencies & issues (the polish backlog)

### Materials / Liquid Glass — essentially absent (biggest gap vs North Star)
- Exactly **one** material in the whole app: `.background(.bar)` (`NotesActionBar.swift:29`).
- Floating surfaces (sidebar, toolbars, list backgrounds, cards) use flat
  `Color(nsColor: .windowBackgroundColor)` or `.quaternary.opacity(0.35–0.4)` instead of
  `.ultraThinMaterial`/`.regularMaterial`. There is no content-at-base / chrome-floats-on-glass layering anywhere.

### Color — ad-hoc named colors instead of semantic tokens
- Hardcoded `Color.blue` for badges (`MainWindowView.swift:128,151`) and the "Review" status
  (`HistoryView.swift:263`) — a fourth de-facto accent alongside the system accent, green, orange, red.
- Status semantics (green=ok, orange=warn, red=error) are re-derived inline in *many* places
  (`statusColor`, `statusBadge`, permission rows, advisory banners, FluidModelSection, diff rows)
  with no shared definition. Same meaning, repeated literals.
- Tint opacities vary by site: `0.10`, `0.12`, `0.18`, `0.2`, `0.35`, `0.4` for "tinted background".
- Diff colors use explicit `Color.green/red` rather than semantic success/danger.

### Spacing — no scale; one-off paddings everywhere
- VStack/HStack spacings seen: 2, 4, 6, 8, 10, 12, 14, 16. Paddings: `.padding(8/10/12/14/16/20/32)`,
  `.horizontal,16 .vertical,6/8`, `.vertical,2/3/6/7`. No 8pt base unit is enforced.
- Corner radii: 6 and 8 used interchangeably for similar surfaces (chips/cards/banners).

### Typography — mostly semantic, but with drift
- Good: most text uses semantic fonts (`.headline`, `.callout`, `.caption`, `.caption2`, `.title3`).
- Drift: titles are sometimes `.title3.weight(.semibold)` (RecoveryView, AssignSpeakers) and sometimes
  `.headline` (most sheets) for the same role (sheet title). Section headers are `.headline` in some
  tabs, `.subheadline.weight(.semibold)` in Summary tab (`SettingsView.swift:63,77`).
- Hard-coded sizes: `Image(systemName:).font(.system(size: 30/34))` for empty-state icons (close but
  not identical — 30 vs 34), `.scaleEffect(0.7)` on small spinners repeated ad hoc.
- `Color.secondary` vs `Color.tertiary` for "caption helper text" is inconsistent (Detection/General use
  tertiary, most others secondary).

### Settings — structural duplication & three layout idioms
- **Notes tab and Summary tab overlap**: both expose `autoRunClaude`, `claudeBinaryPath`,
  `claudeModel`, and a prompt `TextEditor` (`claudePromptTemplate` vs `summaryPromptTemplate`).
  Confusing which is authoritative. (Flagging as a UX/IA issue; any *behavior* consolidation is
  out of Phase-0 scope and would need sign-off — presentation work can only restyle, not merge logic.)
- Three different container idioms across tabs: `Form` (General/Notes/Detection), bare
  `VStack` (Storage/Vault), `ScrollView+VStack` (Transcription/Summary). They render with
  different default insets/spacing, so tabs don't feel like one settings surface.
- `TextEditor` borders done three ways: `.overlay(RoundedRectangle.stroke(.quaternary))`,
  `.border(.quaternary)`, `.overlay(RoundedRectangle.strokeBorder(.quaternary))`.

### Missing / weak states
- **No hover states** on any custom `.plain`/`.borderless` buttons (sidebar rows, file chips,
  suggestion rows, speaker chips). Native-feeling hover highlight is absent throughout.
- **No focus rings** beyond what bare `TextField` gives; custom controls (DestinationField rows,
  chips) show no focus affordance.
- Empty-state icons are inconsistent in size (30 vs 34) and none offer a primary action — the brief's
  Phase 2 target is "icon + short message + **primary action**"; current empty states are icon + message only.
- Loading indicators are inconsistent: `.controlSize(.small/.mini)` + ad-hoc `.scaleEffect(0.7)`.

### Non-native / fragile patterns
- `MainWindowView` deliberately avoids `NavigationSplitView` (documented). Keep — but the manual
  sidebar misses native sidebar materials, hover, and selection styling that come for free; Phase 2
  should reproduce those deliberately.
- Badge dot uses a raw `Circle().fill(Color.blue)` rather than a native badge.

### Dead / uncertain code
- `ComboBoxField` — unused (delete candidate).
- `NoteDiffView` — present and complete, but I found no call site in `Parley/UI`; its reachability
  (History "Regenerate"/re-process path may route through `summaryReadyURL` review pane instead)
  should be confirmed before investing polish here.

### Permission-boundary note (not UI, but relevant to the polish workflow)
- `.claude/settings.json` deny globs target `**/ViewModels/**`, `**/Services/**`, `**/Stores/**`,
  etc., but **this project has none of those folders** — logic lives in `Recording/`, `Transcription/`,
  `Audio/`, `Summary/`, `Detection/`, `Settings/`. The deny rules therefore protect nothing real.
  Before Phase 1 edits begin, the deny list should be re-globbed to this project's actual layout (e.g.
  `Edit(Parley/Recording/**)`, `Edit(Parley/Transcription/**)`, `Edit(Parley/Audio/**)`, …),
  leaving `Parley/UI/**` and a new design-system folder editable. Flagging for sign-off.

---

## 4. Reference-screen recommendation

**Primary pick: `RecordDetailView` (the Record screen).**

Rationale:
- It *is* the app — the highest-traffic, first-thing-you-see screen.
- It exercises the **widest range of states** in one place (full record state machine, model
  loading, three advisory banner types, error row, level meters, collapsible audio section,
  metadata grid, Live↔Preview, offline-pass bar, footer results). Polishing it forces us to
  define the most tokens up front.
- The vocabulary it establishes — **status badge, advisory banner, control bar, level meter,
  metadata grid, footer action bar** — is reused (in ad-hoc form) by MenuBar, History, Settings,
  and the sheets. Setting the bar here makes Phase 3 rollout largely mechanical.

**Secondary candidate: `HistoryView`.** It is the cleaner showcase for the *Liquid Glass
list/detail layering* the brief targets (sidebar list on glass, content at base, floating
toolbars), so if the goal is to demonstrate materials most vividly, History is the better stage.
The tradeoff: History has more bespoke sub-states (review pane, bulk panel, file sheets) that are
less reusable elsewhere.

Suggested approach: pick **RecordDetailView** as the canonical reference (it defines the most
shared tokens), then treat **HistoryView** as the first Phase-3 screen so the list/detail material
pattern is validated immediately after.

---

## STOP — awaiting sign-off

Per the brief, Phase 0 ends here. Before Phase 1 (design system), please confirm:
1. **Reference screen:** RecordDetailView (primary) — or switch to HistoryView?
2. **Permission boundaries:** OK to re-glob `.claude/settings.json` deny rules to this project's
   real folders (`Recording/`, `Transcription/`, `Audio/`, `Summary/`, `Detection/`, `Settings/`)
   so they actually protect logic, before any edits?
3. **Out-of-scope flags** acknowledged (Notes/Summary tab overlap, `ComboBoxField` dead code,
   `NoteDiffView` reachability) — these are noted, not to be touched in this presentation-only pass
   unless you explicitly ask.
