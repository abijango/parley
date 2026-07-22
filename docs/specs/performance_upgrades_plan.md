# Performance Upgrades — Implementation Plan

Companion to `performance_upgrades.md`. That document is the audit; this is the
build plan. Every finding was re-verified against the current source before
writing this — all eight patterns are present as described.

The work is partitioned into **five work packages (WPs) with disjoint file
ownership** so they can be built by parallel subagents without merge conflicts.
One cross-WP dependency exists (the `refresh()` interface) and is handled by a
**Phase 0 interface freeze** that runs before the parallel fan-out.

---

## Verification summary (what's actually in the code)

| # | Finding | Verdict | Load-bearing? |
|---|---------|---------|---------------|
| 1 | `HistoryView` recomputes stage/status/bar per row, per publish | **Confirmed** — `filteredItems`, `needsYouCount`, `rowIndicator`, `statusBadge` each call `stage()`; `stage()` → `PipelineStage.derive` → `isPendingSummary` does an **O(queue) scan per item**. All are computed `var`s re-run on every publish from 5 observed objects. | **Yes — top win** |
| 2 | Content search = synchronous file I/O on main | **Confirmed** — `matchesSearch` (HistoryView.swift:99) reads each note inline when `searchInContents` is on. | **Yes** |
| 3 | Preview + review-pane = synchronous main-thread reads | **Confirmed** — `TranscriptPreviewView.load()` reads full file on main; `reviewPane` (HistoryView.swift:495) reads the *staged* file a **second time** every body eval for affiliation parsing. | **Yes** |
| 4 | `launchWarmup` runs heavy work synchronously on main | **Confirmed** (structural) — RecordingController.swift:492 runs vault/store refresh + recovery scans + queue rebuild inline. | Latency bet |
| 5 | `VaultDirectory.refresh()` / `TranscriptStore.refresh()` are main-actor disk scans | **Confirmed** — `TranscriptStore.scan` reads **every** transcript file fully to parse frontmatter + speaker labels; both run `@MainActor`; refresh fires in debounced bursts from vnode watchers. | **Yes** |
| 6 | `PeopleView` rebuilds the joined model repeatedly | **Confirmed** — `allPeople` (PeopleView.swift:28) computes `PeopleJoin.build` (O(contacts×voiceprints)); read from `filteredPeople`, `selectedPerson`, `deletableNames`, toolbar count, search `onChange`. | Medium |
| 7 | `updateLiveWordCount` rebuilds a Set + auto-scroll on two triggers | **Confirmed** — RecordingController.swift:240; guarded ("fine at current scale"). | Guarded |
| 8 | `RecordingsStore.refresh()` computes recursive folder sizes eagerly | **Confirmed** — RecordingsStore.swift:41 calls `MeetingFiles.size(of:)` per session. | Guarded |

---

## Phase 0 — Interface freeze (DO FIRST, blocks the fan-out)

The **only** cross-package integration risk is the `refresh()` contract on
`TranscriptStore` / `VaultDirectory`. WP-A recomputes its row-model off
`store.items` publishing; WP-D's `launchWarmup` calls `vault.refresh()` /
`store.refresh()`. If WP-B changes those semantics while A and D assume the old
ones, we get either a hydration gap or a double-deferral.

**Before any parallel agent starts**, land these stubs on `main` (no behavior
change yet — just the shape A and D code against):

1. `TranscriptStore.refresh()` **stays a sync-returning call** from the caller's
   point of view but internally schedules a background scan and publishes
   `items` on the main actor when done. It must **cancel/supersede** any in-flight
   scan (reuse the existing `refreshTask` pattern at TranscriptStore.swift:110)
   so bursty vnode + `didBecomeActive` events can't publish out of order and
   flicker the list.
2. Same fire-and-forget-with-main-publish contract for `VaultDirectory.refresh()`.
3. Document the **publish guarantee** in a doc comment on each: "callers observe
   the result via the `@Published` property; `refresh()` returns immediately and
   does not block the caller."

Deliverable of Phase 0: the two method signatures + doc comments + the
`refreshTask`-style supersede scaffold, merged to `main`. WP-A and WP-D branch
from that commit.

---

## Parallel work packages

Each WP owns a disjoint set of files. Each agent runs its **own** verify command
(files are disjoint, so compile errors attribute cleanly per WP):

```
xcodegen generate && \
  xcodebuild test -project Parley.xcodeproj -scheme Parley \
    -destination 'platform=macOS,arch=arm64'
```

**Build isolation:** the project gotcha forbids concurrent builds (a Release
whole-module compile reading files mid-edit crashes `swift-frontend`), and
parallel FluidAudio/WhisperKit builds thrash. Give **each agent its own git
worktree** (`isolation: "worktree"`) so each has an independent checkout +
DerivedData and runs `xcodegen generate` locally. Merge order after all pass:
B (already on main via Phase 0) → A → C → D → E. Disjoint files ⇒ merges are
trivial.

---

### WP-A — HistoryView row view-model + async search + async preview (Findings 1, 2, 3)

**Owns:** `Parley/UI/HistoryView.swift`, `Parley/UI/TranscriptPreviewView.swift`,
`Parley/UI/PipelineStage.swift`, `Parley/UI/StageBarModel.swift`, plus a new
`Parley/UI/HistoryRowModel.swift`.

This is the highest-value package. Three sub-tasks, in order:

**A1 — Precompute the coarse row state once per publish (Finding 1).**
- Add a small `@MainActor` `ObservableObject` (e.g. `HistoryRowIndex`) held by
  `HistoryView` as `@StateObject`. It observes `store`, `offline`, `summary` and
  rebuilds a `[TranscriptItem.ID: HistoryRowModel]` map **only when one of those
  publishes** (coalesce with a tiny debounce so a burst = one rebuild).
- `HistoryRowModel` caches the **coarse** `PipelineStage` + the derived
  `statusBadge` label/severity + `rowIndicator` kind + `needsYou`/`isProcessing`
  flags. `filteredItems`, `needsYouCount`, `processingOrderedItems`, and the
  badges then read the map — **O(1) per row**.
- Add `PipelineStage.deriveBatch(items:offline:summary:)` (or have the index
  build a snapshot): compute the **pending-ID `Set` once** (`Set(queue.map(\.id))`
  ∪ bulk ids), snapshot `runningID`/`jobs`/`throttle`, then derive each item
  against those with O(1) lookups. This is what kills the O(N×queue) cost —
  `isPendingSummary`'s `queue.contains{}` must not run per-item.
- **Keep `StageBarModel.derive` live — do NOT put it in the cached map.** It is
  progress-driven (reads `offline.progress(...)`, `runningActivity`), changes on
  every throttled progress tick, and only renders for in-flight rows. Caching it
  would either rebuild the whole map on every tick (no win) or show a stale bar.
  Leave the `if let bar = StageBarModel.derive(...)` calls in `row(_:)` and
  `detailHeader(_:)` as they are.

*Acceptance:* switching tabs / typing / a summary-progress tick must not trigger
a full `store.items` walk of `stage()`. The `needsYou` badge count and filter
results are unchanged.

**A2 — Move content search off the main thread (Finding 2).**
- `matchesSearch` must stop reading files inline. Title/filing/attendees stay
  synchronous (cheap, in-memory). For `searchInContents`, run the body scan as a
  **debounced async query** (cancellable `Task`) that reads files off-main and
  publishes a `Set<ID>` of content-matches back; the filter intersects with it.
- Cache read results keyed by URL + file mtime so repeated searches don't re-read.

*Acceptance:* typing in search with "search inside" on never blocks the main
thread; results converge after the debounce.

**A3 — Async preview + kill the double read (Finding 3).**
- `TranscriptPreviewView.load()` reads off-main (`Task.detached` or a file-read
  actor) and publishes `content`/`loadError` on the main actor. Keep the
  `onChange(of: url)` / `reloadToken` reload triggers.
- In `reviewPane`, stop reading `staged` inline for affiliation parsing. Either
  (a) parse `InferredAffiliation` from the content the preview already loaded
  (lift the load into the shared async path and pass both down), or (b) do the
  affiliation parse in the same async read. Net: the staged file is read **once**,
  off-main.

*Acceptance:* selecting a large note or flipping between notes does not hitch;
the staged file is read a single time per selection.

---

### WP-B — Background vault/transcript scans (Finding 5)

**Owns:** `Parley/Recording/TranscriptStore.swift`,
`Parley/Recording/VaultDirectory.swift`.

*Phase 0 already landed the interface + supersede scaffold.* WP-B fills in the
bodies:
- Move `TranscriptStore.scan` (directory walk + per-file `String(contentsOf:)`
  + frontmatter parse + `hasGenericSpeakerLabels`) onto a background executor.
  Build the full `[TranscriptItem]` snapshot off-main, then hop to `@MainActor`
  for the single `if found != items { items = found }` publish.
- Same shape for `VaultDirectory.refresh()`: parse contacts + build the
  company/side indexes off-main, publish `people`/`contacts`/`destinations`/
  `companyIndex`/`sideIndex`/`fileCustomers` in one main-actor assignment.
- Preserve the debounced-supersede behavior so out-of-order publishes can't
  flicker the list (the vnode watchers at TranscriptStore.swift:78 and the
  `didBecomeActive` observer fire in bursts).
- Keep the `nonisolated static` parsing helpers `nonisolated` (they're already
  safe to call off-main — VaultDirectory.swift:157).

*Acceptance:* a refresh over a large vault does not block the main actor;
`items` / `people` still publish exactly once per settled change.

---

### WP-C — PeopleView memoized join (Finding 6)

**Owns:** `Parley/UI/PeopleView.swift` (may add a small `@StateObject` cache
type in the same file or a sibling `PeopleIndex.swift`).

- Compute `PeopleJoin.build(...)` **once** per change of `vault.contacts` or
  `voiceprintStore.voiceprints`, into a stored `allPeople` array (via an
  `@StateObject` index object, mirroring WP-A's pattern). `filteredPeople`,
  `selectedPerson`, `deletableNames`, and the toolbar count read the cached array.
- `filteredPeople` can stay a computed filter over the cached `allPeople` (that's
  cheap — the expensive part was `build`). Optionally memoize by query too.

*Acceptance:* typing in People search, selecting rows, and toggling select-mode
do not re-run `PeopleJoin.build`.

---

### WP-D — Launch warmup split + live word-count/scroll (Findings 4, 7)

**Owns:** `Parley/Recording/RecordingController.swift`,
`Parley/UI/LiveTranscriptView.swift`.

**D1 — Split `launchWarmup` into critical vs deferrable (Finding 4).**
- **Must stay eager** (this is what warmup exists for — see its own comment
  "so the first recording neither prompts nor waits"):
  - `preloadModel()` — do NOT defer; deferring it regresses first-record latency.
  - the permission `Task` (mic + audio prime) — stays eager.
  - `ModelManager.recoverFromCrashedLoadIfNeeded()` / aggregate cleanup —
    cheap, self-heal; keep eager.
- **Deferrable** (schedule after first paint / on a background hop):
  `vault.refresh()`, `store.refresh()` (already non-blocking after Phase 0 —
  just don't `await` them on the launch path), `gatherRecoveries()`,
  `recoverOrphanedPartials()`, `enqueuePendingFromDisk()` (both queues).
- Net shape: "fast shell launch, deferred heavy hydration" — but the model
  preload and permission prompts remain up front.

*Acceptance:* the window is interactive before the vault/recording scans finish;
first-record latency is **not** regressed (model still preloads immediately).

**D2 — Live word-count + auto-scroll (Finding 7, guarded — cheapest fix only).**
- `updateLiveWordCount` (RecordingController.swift:240) rebuilds a `Set` and
  re-walks all segments each publish. Only recompute counts for segments whose
  text changed (keep the `[ID: count]` map, update deltas, prune removed ids
  without rebuilding the id `Set` from scratch) and keep a running total.
- In `LiveTranscriptView`, the two `onChange` auto-scroll triggers
  (`segments.count`, `segments.last?.text`) can fire back-to-back; coalesce to a
  single scroll per frame if trivial. Don't over-engineer — this is guarded.

*Acceptance:* no correctness change to the live word count; fewer allocations per
partial update.

---

### WP-E — Lazy recording folder sizes (Finding 8, guarded)

**Owns:** `Parley/Recording/RecordingsStore.swift` (and the Storage view that
reads `sizeBytes` / `totalBytes`, if a binding change is needed).

- `RecordingsStore.refresh()` (RecordingsStore.swift:25) must stop computing
  `MeetingFiles.size(of:)` recursively per session inline. Options (pick the
  simplest that keeps the UI correct):
  - Build the session list first (fast: dir listing + manifest read), publish it,
    then fill in `sizeBytes` per folder **asynchronously** and republish; or
  - Cache sizes keyed by folder mtime so an unchanged session isn't re-walked.
- `totalBytes` becomes a sum over whatever sizes have resolved (show a spinner /
  "calculating…" affordance in the Storage view while pending, if needed).

*Acceptance:* opening the Storage/Recordings screen with many sessions is
responsive; sizes populate progressively rather than blocking the list.

---

## Dependency & sequencing graph

```
Phase 0 (refresh interface freeze, on main)
        │
        ├─────────────┬───────────┬───────────┬───────────┐
        ▼             ▼           ▼           ▼           ▼
   WP-B (fill    WP-A (History  WP-C        WP-D        WP-E
   refresh       row model +    (People     (warmup     (recording
   bodies)       search +       join        split +     sizes)
                 preview)       cache)      live w/c)
        │             │           │           │           │
        └─────────────┴─────┬─────┴───────────┴───────────┘
                            ▼
              Serial integration build on main
              (merge order: B → A → C → D → E)
```

- **WP-A and WP-D depend on Phase 0** (both touch `refresh()` semantics).
- **WP-B, WP-C, WP-E are independent** of Phase 0's *behavior* but WP-B
  *implements* the bodies behind Phase 0's frozen interface, so WP-B branches
  from the Phase 0 commit too.
- No two WPs share a source file, so parallel execution is conflict-free.

## Priorities if capacity is limited

Land in this order for the most perceived speed per unit effort:
**1 → 2 → 3 (all WP-A) → 5 (WP-B) → 6 (WP-C)**, then the guarded ones
(4 in WP-D, 8 in WP-E, 7 in WP-D). Findings 4/7/8 are the doc's own "fine at
current scale" / "latency bet" items — do the cheapest correct fix and stop; do
not gold-plate them.

## Cross-cutting acceptance

- No new `String(contentsOf:)` or directory walk on the `@MainActor` render or
  launch-blocking paths.
- Row/list/people derivations are O(1)-per-row reads of a precomputed snapshot,
  rebuilt once per settled state change.
- Behavior parity: filter results, `needsYou` counts, badges, search matches,
  affiliation banners, and live word counts are unchanged.
- Each WP ships with `xcodebuild test` green in its own worktree before merge.

## Not covered (already good — leave alone)

Per the audit: `LiveSegmentStore.apply`, `OfflineProcessingService` /
`JobProgressRelay` progress throttling, and the live transcript tail-window are
already performance-aware. Don't touch them.
