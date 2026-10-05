# Layout-explosion audit — the recording freeze

> **⚠ Correction, Aug 10 2026 — fix 1a's premise was wrong.** This document says text
> line-breaking is "the dominant cost" and ranks 1a highest-leverage. Self-time
> attribution over the captures says otherwise: **CoreText self-time is 0–1 samples out of
> ~4070, before *and* after the fix.** Text measurement was never in the profile, so 1a
> could not have helped — and measurably didn't. The cost is the layout *negotiation
> machinery*, spread thin with no hotspot. Full measurement in *Where the time actually
> goes* below; treat that section as authoritative over the "Why it detonates" hypothesis
> and the ranking that follows from it.

Companion to `RECORDING_FREEZE_INVESTIGATION.md`. That document establishes *what* the main
thread is doing during a freeze (a combinatorial SwiftUI layout pass, 9 nested `StackLayout`
levels, 232 frames). This one names *which views* form that nesting and ranks the fixes.

**Scope:** audit per Phase 0 of `DESIGN_POLISH_BRIEF.md`, followed by the presentation-only
subset of its recommendations. Fixes 1a, 3 and 4 are **applied and installed** — see *What
was applied* at the end. Fixes 1b and 2 are deliberately held pending verification.

## The ancestry, window root → transcript text

Traced from `MainWindowView.body` down to the `Text` in a transcript row. Every level that
participates in layout negotiation is listed; `S` marks a stack, `F` marks a flexible frame.

| # | Kind | Where | Code |
|---|---|---|---|
| — | root | — | `NSHostingView` → `RootGeometry` |
| F | frame | `MainWindowView.swift:50` | `.frame(minWidth: 720, minHeight: 560)` |
| **S1** | `HStack(spacing: 0)` | `:35` | sidebar + detail |
| F | frame | `:48` | `.frame(maxWidth: .infinity, maxHeight: .infinity)` |
| F | frame | `RecordDetailView :263` | `.frame(minWidth: 480, minHeight: 520)` |
| **S2** | `VStack(spacing: 0)` | `:247` | content + offlinePassBar + footer |
| F | frame | `:254` | `.frame(maxWidth: .infinity, maxHeight: .infinity)` |
| **S3** | `HStack(spacing: 0)` | `:248` | content + divider + inspector |
| F | frame | `:250` | `.frame(maxWidth: .infinity, maxHeight: .infinity)` on `content` |
| F | frame | `:352` | `.frame(maxWidth: .infinity, maxHeight: .infinity)` |
| **S4** | `VStack(spacing: 0)` | `:322` | control strip + divider + transcript |
| F | frame | `:349` | `.frame(maxWidth: .infinity, maxHeight: .infinity)` on `ZStack` |
| **S5** | `ZStack` | `:330` | transcript + pre-record overlay |
| — | `ScrollViewReader` | `LiveTranscriptView :56` | proxy wrapper |
| — | `ScrollView` | `:57` | **proposes unconstrained height** to its content |
| **S6** | `LazyVStack(alignment: .leading)` | `:58` | row list |
| F | frame | `:79` | `.frame(maxWidth: .infinity, alignment: .leading)` |
| **S7** | `HStack` | `TranscriptRow :151` | timestamp + speaker + text + spacer |
| — | leaf | `:156` | `Text(segment.text)` — **no width constraint** |

**Seven explicit stacks, eight flexible frames, alternating almost perfectly** — plus the
`ScrollViewReader`/`ScrollView` pair, which are not stacks but do participate in sizing. The
`ScrollView` matters on its own: it proposes *unconstrained* height to the `LazyVStack`, which
is why every realised row gets sized rather than clipped. Together these reconcile to the 9
`StackLayout` levels measured in the capture. The stack trace's `_FlexFrameLayout ↔
StackLayout` cycle is this table, walked.

No `GeometryReader` anywhere in the chain — ruling out the usual first suspect.

## Why it detonates at 3–4 minutes, not at launch

Two independent costs multiply:

**The exponential constant — nesting.** Each stack level queries each child's size several
times per pass (`prioritize`, `sizeChildrenGenerally`, `resize`, then again in `placement`).
Seven levels of that compounds into a large fixed multiplier on every layout pass. It is
paid whether there is one row or a thousand.

**The linear term — realized rows.** `LazyVStack` only materialises what's near the
viewport, but auto-scroll keeps the tail realised and the realised set grows as the meeting
runs. Every realised row carries a `Text` with no width constraint, and text is the most
expensive thing SwiftUI can size: each query re-runs line breaking at the proposed width.

Multiply them and per-pass cost climbs steadily. The cliff arrives when one pass no longer
fits inside the animation frame interval — at which point the next animated scroll starts
before the previous layout settles, passes overlap, and it never converges. Observed cliff:
**4m00s (Aug 4), 3m00s (Aug 6), 3m30s (Aug 7)**.

> **This paragraph is a hypothesis, not a finding.** The capture proves the layout pass is
> combinatorial; it does **not** prove that realised-row growth is what crosses the
> threshold. Something else that changes at the 3–4 minute mark would fit the timing equally
> well. This matters because fix #2 rests on it — if row growth is not the driver, throttling
> the scroll will not move the cliff. The 15-minute repro under *How to verify* is what
> discriminates, and it should be run before treating fix #2 as load-bearing.

### The trigger that keeps it re-entering

`LiveTranscriptView.scheduleScroll` (`:99`) still animates on every row insert:

```swift
withAnimation(Theme.Motion.gentle) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
```

An animated `scrollTo` must lay out the content to compute its offset, then re-lay it each
frame for the animation's 0.2s — roughly 12 passes per inserted row, over the full nested
chain. During active speech rows insert every few seconds. The Aug-4 fix throttled *tail
revisions* (`:101`) but deliberately left inserts animated; on this evidence, inserts are the
expensive case, because a count change is exactly when the content height changes.

## Two flexible siblings in every row — the ambiguity

`TranscriptRow` (`:151`):

```swift
HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
    Text(segment.timestamp)            // mono, intrinsic
    speakerLabel                       // .frame(width: 80) — fixed
    Text(segment.text)                 // flexible, no constraint
    Spacer(minLength: 0)               // flexible
}
```

`Text` and `Spacer` are **both** flexible, so the `HStack` has to negotiate how to split the
remaining width between them. That negotiation is what drives repeated `sizeThatFits` on the
text at different proposed widths — the single most expensive query in the tree, repeated,
per row, per pass. Collapsing to one flexible participant removes the negotiation entirely.

## Ranked fixes

All presentation-layer, all in `Parley/UI/`. Ordered by expected relief per unit of risk.

**1a. Pin the row text's height computation.** *(highest leverage, lowest risk, strictly presentation-only)*
Keep the `Spacer`; add one modifier to the text:

```swift
Text(segment.text)
    .font(Theme.Typography.reading)
    .foregroundStyle(segment.confirmed ? .primary : .secondary)
    .textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)      // ← add only this
```

`fixedSize(horizontal: false, vertical: true)` is the canonical cure: take the proposed
width, compute height **once**, stop re-negotiating. This is the expensive query — repeated
line-breaking at varying proposed widths — so this alone may absorb most of the storm. **Try
this by itself first.**

**1b. Only if 1a is insufficient — remove the flexible ambiguity.** Drop `Spacer(minLength: 0)`
and give the text `.frame(maxWidth: .infinity, alignment: .leading)`, leaving one flexible
participant instead of two.

> **Behaviour change — needs sign-off.** This is *visually* identical but not
> *interaction*-identical. With `.frame(maxWidth: .infinity)` the text view itself spans the
> full row, so `textSelection(.enabled)` extends the hit-test and click-drag region across the
> empty space right of the last glyph. With the `Spacer`, selection stops at the text.
> `DESIGN_POLISH_BRIEF.md` forbids behaviour changes, so this one is a deliberate tradeoff to
> approve, not a free win.

**2. Stop animating the scroll on insert.** Make `scheduleScroll` jump in both cases, or
apply the same 0.5s throttle to the animated path. Removes ~12 layout passes per row. The
visual cost is small; the transcript already jumps on tail revisions, so the two paths
become consistent.

**3. Collapse `ZStack` (S5) into an overlay.** During recording it holds exactly one child —
`isPreRecordIdle` is false — so the stack level buys nothing:

```swift
LiveTranscriptView(…)
    .equatable()
    .overlay { if isPreRecordIdle { preRecordIdleMessage.transition(.opacity) } }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

One fewer level in the multiplier, no behaviour change.

**4. Narrow the animation scope at `:351`.** `.animation(Theme.Motion.spring, value: isPreRecordIdle)`
sits on the whole live `VStack`, so it governs the transcript subtree too. Move it onto
`preRecordIdleMessage` — the only thing that should animate on that value. Same precedent as
the `offlinePassBar` comment at `:256–259`, which fixed the identical mistake.

**5. Consider a fixed row height.** Only if 1–4 prove insufficient. Rows are variable-height
by design, so this trades layout cost for a visual change and needs sign-off.

### Not recommended

Flattening the `.frame(maxWidth:.infinity, maxHeight:.infinity)` chain at `:250/:254` and
`:349/:352`. These look redundant but are not: in each pair the inner frame makes a child
claim remaining space within its parent, and the outer makes the parent fill *its* parent.
Removing either changes layout. They add depth, but depth is treated by fixes 1–3.

## How to verify

The freeze is reproducible without waiting for a call — from the investigation doc: start a
recording, leave it 15+ minutes, watch `ps -o %cpu -p $(pgrep Parley)`. Climbing CPU with
`freeze.log` entries reproduces it.

After each fix, the check is the same: record for 15 minutes and confirm
`~/Library/Logs/Parley/freeze.log` stays empty and `[detect] heartbeat` keeps its ~31s
cadence. The watchdog is now the regression test.

Run the functional suite after each change (`DESIGN_POLISH_BRIEF.md` treats a failure as a
hard stop).

---

## Where the time actually goes — measured Aug 10 2026

The Aug 7 fixes are installed and the freeze recurred (Aug 10, 15:33 recording, main actor
wedged from ~15:38, 100% CPU, `STAT R`, stalled 845s when sampled). That gave a clean
before/after, so the profile was measured properly instead of inferred from the call graph's
shape.

**Method.** Self-time attribution over the main-thread subtree of each capture: a frame is a
leaf when the next line is not deeper, and its sample count is its own time. Counting *nodes*
instead — which is what "232 frames, 9 stack levels" does — overweights wide-but-cheap
subtrees and cannot tell you where cycles are spent.

Fixes 1a/3/4 installed Aug 7 **11:46**, so the 13:06 and 14:44 captures are already post-fix;
only the 10:0x captures are a true baseline.

| Capture | | main samples | SwiftUICore self | AttributeGraph self | **CoreText self** |
|---|---|---|---|---|---|
| Aug 7 10:03 | pre-fix | 3007 | 48.0% | 7.7% | **0** |
| Aug 7 10:19 | pre-fix | 4053 | 46.5% | 9.2% | **0** |
| Aug 7 13:06 | post-fix | 1793 | 48.4% | 7.3% | **1** |
| Aug 7 14:44 | post-fix | 4067 | 47.7% | 6.9% | **1** |
| Aug 10 15:52 | post-fix | 4073 | 45.6% | 10.6% | **0** |

Unchanged across the fix boundary, and **no text-related symbol appears anywhere in the
top leaf symbols** in either era. Unattributed self-time (`<deduplicated_symbol>`) is 2.5%,
so even if all of it were text sizing it could not be material. Call-graph shape is flat too:
`placeChildren` nodes 2590 → 2840, `_FlexFrameLayout.sizeThatFits` 521 → 570, max stack
depth 472 → 468 frames.

**Top self-time, Aug 10 capture** — the distribution is the finding:

| Self | Symbol |
|---|---|
| 4.6% | `DisplayList.Properties` OptionSet witness (stub dispatch) |
| 4.5% | `AGGraphGetInputValue` |
| 4.3% + 3.9% | `swift_release` / `swift_retain` |
| 3.3% | `_platform_memmove` |
| 2.9% | `___chkstk_darwin` — stack probing, i.e. deep recursion |
| 2.9% + 1.5% | `_ProposedSize.==` / `ProposedViewSize.==` — layout-cache probes |
| 2.3% + 2.2% | `UnaryLayoutEngine` / `ViewLayoutEngine.sizeThatFits` |

No hotspot. Time goes to graph traversal, ARC, cache probes and recursion overhead — the
cost of *how many* size queries the pass performs, not of any single query. `___chkstk_darwin`
at 2.9% independently corroborates the 468-frame depth.

**What this implies for the ranking.** Per-query cost is the wrong target; 1a proved that
empirically. What remains are the levers that reduce query *count* or pass *frequency*:

- **#2 (stop animating the scroll on insert)** is now the highest-leverage unapplied fix. It
  attacks frequency — the audit's own estimate is ~12 layout passes per inserted row — and is
  independent of the nesting multiplier. It is also the only one whose cost model does not
  depend on the unproven realized-row hypothesis.
- **1b (remove the flexible-sibling ambiguity)** removes a negotiation dimension per row,
  which is a count reduction. It carries the documented hit-testing behaviour change.
- Removing one nesting level (fixes 3, 4) is a small divisor on a product of ~9 levels, which
  is consistent with their measured effect: none. Don't expect more from level-shaving alone.

## What was applied — Aug 7 2026

Fixes **1a, 3 and 4** landed together; full suite green (426 tests, 0 failures). Built and
installed to `/Applications/Parley.app` at **11:46:35**, `MainActorWatchdog` verified still
present in the binary.

**1a — `TranscriptRow` text height pinned** (`LiveTranscriptView.swift:156`). Added
`.fixedSize(horizontal: false, vertical: true)` to `Text(segment.text)`. `Spacer(minLength: 0)`
**kept**, so selection behaviour is untouched. This targets the dominant cost: repeated line
breaking at varying proposed widths, per row, per pass.

**3 — `ZStack` → `.overlay`** (`MainWindowView.swift:330`). The stack held exactly one child
during recording. One fewer level in the multiplier; no behaviour change.

**4 — animation scope narrowed** (`MainWindowView.swift:351`). `.animation(Theme.Motion.spring,
value: isPreRecordIdle)` moved off the live `VStack` and onto a `Group` wrapping only
`preRecordIdleMessage` inside the new overlay. `Group` is layout-transparent, so it adds no
level.

> Minor presentation change worth knowing: the transcript's own empty-state swap (driven by
> `hidesEmptyState: isPreRecordIdle`) no longer rides the spring — only the idle message
> animates. That is the intended narrowing, but it is a visible difference if you look for it.

**Deliberately NOT applied, pending the verification run:**

- **1b** (drop the `Spacer`) — carries the `textSelection` hit-region change; needs sign-off.
- **2** (stop animating scroll on insert) — rests on the unproven realised-row-growth
  hypothesis. Run the 15-minute repro first; if the cliff still arrives, this is next.

### Verification still owed

One 15-minute recording. Success = `~/Library/Logs/Parley/freeze.log` gains no new entries
and `[detect] heartbeat` holds its ~31s cadence throughout. The watchdog is the regression
test — it has now caught the failure once, so silence from it is meaningful.

## Verification attempt 1 — Aug 7, 12:00 call — **inconclusive, not a pass**

Session `2026-08-07-120027` ("FSI Horizons 2026", Teams, ~13m21s) ran on the fixed build with
**no freeze**. But it does not validate the fixes, because a second variable changed at the
same time.

### The confound

`defaults read com.naufalmir.parley` → **`parley.useParakeetUnified = 0`**, plist written
`12:00` — between the 10:00 freeze and this call.

| Session | Engine | Outcome |
|---|---|---|
| Aug 5 ×3, Aug 6 ×3, Aug 7 09:01, 09:33, 10:00 | `Parakeet Unified streaming (2080ms)` | four froze |
| **Aug 7 12:00** | **`Nemotron multilingual streaming (1120ms, en-US)`** | clean |

**Every freeze ever recorded ran Parakeet Unified. The one clean run is the first session
ever to use Nemotron.** The engines differ in streaming interval (2080ms vs 1120ms), in how
often the tail row is revised, and in segment production rate — all of which drive exactly
the `onChange` → `scheduleScroll` → layout path this audit implicates. A quieter engine is a
complete alternative explanation for the absence of a freeze.

The layout fixes were installed 11:46:35; the engine changed ~12:00. Both are upstream of
the same outcome and cannot be separated from this one run.

### The decisive test

Re-enable Parakeet Unified (`useParakeetUnified = 1`) and record 15+ minutes on the fixed
build. That isolates the fixes against the exact configuration that failed four times.
Until then, treat the layout fixes as **plausibly effective, unproven**.

### Health signals from the run that *are* clean

- **No `freeze.log` entries.** No main-actor stall reached the 5s watchdog threshold.
- **Heartbeat cadence flawless** — 28 beats, min 30.0s / max 31.6s / mean 30.8s, no jitter.
  During freezes this stops dead; sub-threshold stalls would show as gaps. There are none.
- Session finalized normally: 41 segments, offline re-pass 65.0s, 7 speakers, compacted
  603.2 MB → 67.9 MB. CPU back to 0.0% after.
- A clean `exit(0)` at 12:00:33 (11.4s after launch, user-initiated) was picked up by
  **AUTO-RESUME** at 12:01:10 at offset 5s, and the multi-leg archive stitched both legs
  (`2 mic leg(s), 2 system leg(s), ~801s`). Crash recovery works unattended.

## Other issues surfaced by this run

**1. Disk-writes threshold report.** `Parley_2026-08-07-121508_hijarna.diag` — 2147 MB of
file-backed memory dirtied over 842s (2.55 MB/s), against a system limit of ~2.1 GB/day.
Heaviest stack is **CoreML on-device AOT compilation** (`E5RT::OnDeviceAOTCompilerInterface::Compile`
→ `Espresso::AOT::E5AOTCompilerBackend::Run`) — i.e. ANE specialization of the
newly-selected Nemotron model, which had no cache entry. Expected as a one-off; **confirm it
does not recur** on the next Nemotron session. If it does, the ANE cache is not being
retained and that is a real bug (see `CLAUDE.md` on the stable-signing-cert contract).

**2. Swap pressure is climbing and has passed the app's own danger threshold.**

| Launch | Swap |
|---|---|
| Aug 5 08:36 | 0.0 GB |
| Aug 6 15:04 / 15:43 | 2.2 GB |
| Aug 7 10:23 | 4.0 GB |
| Aug 7 11:43 | 4.7 GB |
| Aug 7 12:00 / 12:01 | **5.7 GB** |

`MemoryGuard.swapPressureThreshold` is **4 GB**, documented as "sustained pressure, the
regime that previously corrupted the compiled-model cache". The machine is above it and
rising, and a large CoreML compile just ran in exactly that regime. Worth a reboot before
the next long call, and worth checking whether `MemoryGuard.advisory` actually surfaced a
warning — it should have.

**3. `repAudioSample: no mixed.caf`** — fired at 12:02:45 and 12:11:25, and in the 10:00
session too. `mixed.caf` is only written by the offline pass at stop, so the
representative-sample playback path can never succeed *during* recording. Harmless but it
means a feature silently no-ops mid-call. Either gate the affordance while recording or fall
back to the per-track CAF.

**4. Summary still gated, three sessions running.** `summary not enqueued — hasUnnamed=true
bodyAttributed=false`, plus a new variant at 10:26:59: `Speaker review done but summary not
enqueued — generic labels remain`. Diarization found **7 speakers for a 5-attendee call**, so
over-segmentation is feeding unnamed labels into the gate. Not freeze-related, but it means
summaries are not being produced without manual naming every time.

---

# Verification attempt 2 — Aug 7, 13:01 call — **the fixes did not work**

Session `2026-08-07-130135` ("Rado Catchup", **Webex**, `cisco-systems.spark`). Recording
started 13:01:35; last heartbeat 13:05:49; manifest `lastHeartbeat` 12:05:55Z. **Froze at
4m20s** — squarely in the established 3–4½ minute band. Still wedged 72 minutes later
(`main actor stalled 4318.0s`), audio still growing (229 MB mic / 471 MB system).

Two prior conclusions are now refuted, and one of them was mine.

## Refuted 1 — the engine confound does not explain the clean 12:00 run

This freeze ran **Nemotron multilingual streaming (1120ms)**, the same engine as the clean
12:00 call. So Nemotron is not protective; the 12:00 session simply did not freeze in the
13 minutes it ran. The engine change was a real confound for *attribution*, but it is not an
alternative cause. Both engines freeze.

Onset times across all five: **4m00s, 3m00s, 3m30s, 4m20s** — spanning two ASR engines with
different streaming intervals and very different segment-production rates. That consistency
argues *against* UI-update rate being the trigger.

## Refuted 2 — text line-breaking was never the bottleneck

The audit's central premise was that repeated `Text` sizing dominated. Measured:

| Capture | Total samples | Text-metrics frames | Share |
|---|---|---|---|
| Aug 7 10:05 (pre-fix) | 7119 | 229 | ~3% |
| Aug 7 14:19 (post-fix) | 6651 | 218 | ~3% |

**~3% both times.** `.fixedSize(horizontal:false, vertical:true)` was aimed at a
non-bottleneck, and the share is unchanged because there was nothing there to reclaim.

## The structure is untouched

| | Pre-fix (10:05) | Post-fix (14:19) |
|---|---|---|
| Max indent | 468 | 468 |
| Deepest chain | 232 frames | 232 frames |
| Nested `StackLayout` levels | 9 | 9 |
| Deepest-path frame sequence | — | **byte-identical** |
| `StackLayout` occurrences | 13650 | 12541 (−8%, capture noise) |
| `_ZStackLayout` occurrences | 650 | **507 — still present** |

The `ZStack` → `.overlay` swap did not remove a level. `.overlay` is itself a layout
container, and the deepest path evidently never went through the `ZStack` at
`MainWindowView:330` in the first place — the `_ZStackLayout` frames that remain sit far down
the chain (~18 samples deep), not at the top.

## What the cost actually is

Heaviest **leaf** frames — where CPU lands rather than where it passes through:

```
 188  DYLD-STUB$$protocol witness for OptionSet.init(rawValue:)
 131  _platform_memmove
  93  swift_release
  92  AG::Subgraph::update
  87  AGGraphGetInputValue
  79  ___chkstk_darwin
  78  swift::MetadataCacheKey::operator==
  61  NSAttributedString.MetricsCache.findMetrics      ← text, ~1%
```

**There is no hotspot.** The cost is spread across AttributeGraph node updates, Swift
runtime retain/release, and generic-metadata lookups — every one of them individually cheap.
This is pure *node-count* blowup: the pass is expensive because it visits an astronomical
number of layout nodes, not because any node is slow.

That reframes the fix. Shaving a constant factor off one node type cannot help. Only
reducing the **number of nodes visited** will, which means either genuinely fewer levels or
breaking the re-query fan-out.

## Where this leaves the diagnosis

Still solid: the main actor is starved by a combinatorial SwiftUI layout pass, and the
ancestry table above is accurate as a description of the tree.

No longer supported: that the transcript rows are the expensive part. The samples are
diffuse and the spine's cost is concentrated in the *top three* levels (5747 → 2978 → 967),
i.e. the outer window chrome, before the transcript is reached.

Two footprint readings, which do **not** support a memory-pressure explanation despite the
climbing swap: **248 MB** at the 10:05 freeze (peak 1.4 GB) vs **2.4 GB** at the 14:19 freeze.
Freezes occur at wildly different footprints, so memory is unlikely to be the driver.

## The decisive next experiment — bisect, don't theorise

Sampling has given all it can; every capture will show the same diffuse cascade. Bisect the
tree instead:

1. **Bound the realised rows.** `LiveTranscriptView.defaultVisibleTail` is currently `300`.
   Set it to `20` and record 15 minutes. If the freeze still lands at ~4 minutes with only
   20 rows rendered, **the transcript is exonerated entirely** and the problem is in the
   chrome — which is where the sample's cost is concentrated anyway. One-line change, and it
   is the single most informative thing left to do.
2. **If the freeze disappears**, rows are implicated after all and the fix is virtualisation
   or fixed-height rows, not modifier tweaks.
3. **Then bisect the chrome** the same way: temporarily render the inspector rail as a fixed
   -size placeholder and repeat.

Timing note that should guide this: the ~4-minute onset is nearly constant across engines
with very different update rates. Whatever crosses the threshold is more plausibly
**time-** or **growth-**linked than tied to how often the UI is poked. The `visibleTail`
experiment discriminates that directly.

## Revert candidates

Fixes 1a and 3 are now known not to help. They are harmless and 1a is arguably still correct
practice, but they add noise to future comparisons. Consider reverting fix 3 (`ZStack` →
`.overlay`) since it changed structure for no measured benefit; keep or drop 1a as taste.
Fix 4 (animation scoping) remains independently justified.

---

# The FluidAudio live-publish path — best candidate yet

Prompted by the observation that the freezes began with the FluidAudio / Parakeet Unified
upgrade. The evidence fits, and it is sharper than "Parakeet Unified": **both engines that
have ever frozen are FluidAudio variants** (Parakeet Unified 2080ms, Nemotron 1120ms), and
they share one live-publish path.

## Mechanism, in code

`FluidAudioEngine` is `@MainActor` (`:30`), so all of the following runs on the main actor.

1. Every ASR partial → `Task { @MainActor in self?.applyPartial(…) }` (`:399`).
2. `applyPartial` (`:1052`) ends in `publish(immediate: didConfirm)` (`:1095`).
3. `publish` (`:1102`) is throttled by `publishMinInterval = 0.2` (`:109`) — a **floor of
   5 publishes per second**, firing at least once per ASR partial.
4. Every publish calls `finalTimeline()` (`:129`) → `derive(…)` (`:146`), which returns a
   **freshly-constructed array containing every segment**:
   - With no diarization yet, `:148` takes `build(units: confirmed + volatile)` — a full
     rebuild from scratch, **no cache at all**.
   - Even on the cached path (`:151–164`), `var out = seeded; out.append(contentsOf:
     derivedConfirmedCache); … out.append(volatile)` allocates and copies the whole list.
5. That array goes to `onSegmentsChanged?` → `live.segments` → `LiveTranscriptView`.

## Why `.equatable()` does not save it

`LiveTranscriptView` is `Equatable` and its `==` (`:43–53`) compares
`segments.last?.text` among other things. The **volatile tail row is rewritten on every
tick** (`:1090`, reusing the id but replacing the text), so `==` returns false every time.
Body re-evaluates, the `LazyVStack` rebuilds, and **every realised row is re-laid out** —
through the full seven-level nest documented above.

`onChange(of: segments.last?.text)` (`:86`) also fires each tick, triggering `scheduleScroll`.

## Why this explains what the layout hypothesis could not

- **Engine-independent timing.** The cliff sits at 3–4½ minutes whether the ASR interval is
  2080ms or 1120ms, because the publish throttle — not the model interval — governs the
  re-layout rate, and cost scales with accumulated rows either way.
- **Diffuse leaf costs.** Re-laying out the entire list every tick produces exactly the
  observed profile: thousands of cheap AttributeGraph/retain-release node visits, no hotspot.
- **Why fixes 1a/3/4 did nothing.** They shaved per-row and per-level constants. The problem
  is that the *whole list is invalidated and re-laid out several times a second*, so the
  constant is irrelevant next to the node count.
- **Correlates with the upgrade.** This publish path arrived with the FluidAudio streaming
  work; the freezes began in the same window.

## Engine comparison — what each test would actually prove

| Engine | Live path | Expected | What a clean run proves |
|---|---|---|---|
| **Whisper (`whisperKit`)** | `liveTranscriptEnabled` defaults **false** (`AppSettings:377`), and `WhisperKitSpeakerKitEngine:81` guards on it → **no live stream at all** | no freeze | Only that the live-streaming path is responsible. **Confounded** — it does not isolate FluidAudio, because there are no live rows to re-lay out. |
| **SpeechAnalyzer** | Same shape — `@MainActor` (`:12`), `publish` (`:520`), `finalTimeline()` (`:72`), `onSegmentsChanged` | likely also freezes | If it *does* freeze, the bug is the pattern, not FluidAudio. If it does not, FluidAudio-specific. **Better discriminator.** |
| **FluidAudio** | as above | freezes | — |

## Cheapest test that would confirm the mechanism

Raise `publishMinInterval` from `0.2` to `1.0` and record 15 minutes. This directly cuts the
re-layout rate without touching any view code. If the cliff moves out substantially, the
mechanism is confirmed and the real fix follows from it.

## Likely real fixes (not yet applied)

1. **Split the volatile tail into its own view** so the confirmed list is not invalidated by
   tail revisions. This is the structural fix — the confirmed rows do not change and should
   not be re-laid out at all.
2. **Stop returning a fresh whole-list array per tick**; publish the confirmed prefix and the
   volatile tail separately.
3. Failing those, throttle `publishMinInterval` and drop `segments.last?.text` from the
   `Equatable` comparison so tail revisions do not force a full body re-evaluation.

## Applied: `publishMinInterval` 0.2 → 1.0 (experiment, Aug 7 16:55)

`FluidAudioEngine.swift:109`. Cuts the re-layout rate ~5× without touching view code.
426 tests green; installed to `/Applications` at 16:55:14. Visible effect: the live tail
updates at most once a second instead of five times.

### Correction to the verification plan — the freeze is intermittent

Earlier guidance in this document ("one 15-minute run verifies it") was **wrong**, and the
data says so:

| | |
|---|---|
| Recording sessions since Aug 3 | **27** |
| Known freezes | **5** (Aug 3, Aug 4, Aug 6 13:33, Aug 7 10:00, Aug 7 13:01) |
| Rate | **~18%, roughly 1 in 5** |

Sessions on the 11:46 build (fixes 1a/3/4) alone: 12:00 ran 13m21s clean, 15:24 ran 9m46s
clean, **13:01 froze at 4m20s**. Same build, same engine, different outcomes.

So the 3–4½ minute figure describes *when it freezes given that it does*, not a threshold
every session crosses. Consequences:

- **A single clean run proves nothing.** At an ~18% base rate, one clean 15-minute session
  is the expected outcome ~82% of the time even with zero improvement.
- Judging this change needs a **run of sessions** — roughly 10–15 freeze-free recordings
  before a real reduction can be distinguished from luck.
- Conversely, **one freeze refutes it quickly**. If the app freezes again on the 16:55 build,
  `publishMinInterval` is not the lever.
- If it does freeze, check the onset time: the mechanism predicts the cliff should move
  *later* (~5×) even if it still occurs. Onset is now the measurement, not pass/fail.

`freeze.log` is the counter — it records every episode with a timestamp, so the rate is
measurable from it directly rather than from recollection.
