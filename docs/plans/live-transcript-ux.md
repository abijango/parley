# Live Transcript UX — stable history, follow mode, speaker strip

Status: **implemented** (2026-10-28). Unit-tested; awaiting validation on a live call.

## Problem

Observed during a live call:

1. The transcript keeps scrolling back instead of following the latest text.
2. Clicking an unnamed speaker opens the naming popover, but the window "refreshes" and
   the popover disappears before a name can be picked.

### Root causes

- **Full re-derive on every diarization tick.** `ingestDiarization` calls
  `invalidateDerivedCache()` (`FluidAudioEngine.swift` ~626), so the next publish runs
  `diarizationFirst(confirmed)` over *all* confirmed units. Run boundaries shift, the
  global grouping differs from the incremental `mergeAdjacentSegments` path, and row ids
  (keyed `df@<run start>`) change mid-list. `LiveTranscriptTableDiff` can't express that
  and falls back to `.reloadAll`.
- **Volatile → confirmed handoff** also changes the last row's id (and may merge into the
  previous row), which is another `.reloadAll`.
- **`reloadData()` + `usesAutomaticRowHeights`** drops measured heights; the table height
  is re-estimated, content shifts under a fixed clip origin, and `scrollRowToVisible` lands
  on an estimated last row.
- **Pinned tracking races.** The `boundsDidChange` observer hops through `Task { @MainActor }`,
  so it runs *after* `applyingProgrammaticScroll` is reset. Our own scroll is judged as a
  user scroll; if row heights grew, the gap is ≥ 48pt and `pinnedToBottom` turns off.
- **Popover anchored to a recycled view.** `presentNamer` anchors to the row's
  `speakerButton`. Any reload of that row, a `reloadAll`, or auto-scrolling it off-screen
  (cell reuse) detaches the anchor, closing the `.transient` popover.
- No "jump to latest" affordance exists.

## Design (agreed)

### 1. Settled history (engine)

- Lines whose `end < now − 30s` are **locked**: id, text, and segmentation never change
  during the live session. Only the unlocked tail is re-derived on diarization updates.
- Speaker *names* still apply to locked lines (names are a label lookup, not
  segmentation), so naming relabels everything.
- The final transcript is unaffected: the post-stop repass (`runIds.removeAll()` +
  invalidate at ~945) re-attributes with the full diarization as today.
- Volatile → confirmed must keep a stable id for the row the user saw (reuse the
  volatile id for the first confirmed run it becomes, or make the diff treat it as an
  in-place reload).

Implementation sketch (`FluidAudioEngine.derive`):
- Keep `lockedSegments: [Segment]` and `lockedUnitCount` / `lockedUntil: TimeInterval`.
- On each derive: re-run `diarizationFirst` only on units after the lock boundary;
  output `lockedSegments + tail`, with tail start clamped so no run straddles the lock.
- Advance the lock when `tail.first.end < now − 30s`; move those segments into
  `lockedSegments`.
- `setSpeakerName` re-maps `speakerName` on locked segments in place (same ids).

### 2. Table updates (UI)

- `LiveTranscriptTableDiff`: add "same count, some ids changed" → per-row reload; and
  "locked prefix unchanged, tail replaced" → reload + insert/remove at tail. `reloadAll`
  is reserved for reset/seed.
- Preserve scroll position when not following by anchoring to the **top visible row id
  + offset** and restoring after the edit (not raw pixel offset).

### 3. Follow mode + "new lines" pill

- Following is decided synchronously from the clip view's bounds (no `Task` hop); our
  own scrolls are ignored by comparing against the target origin rather than a flag.
- Follow scroll targets the document's max Y after `layoutSubtreeIfNeeded`, not
  `scrollRowToVisible`.
- When not following: position is held exactly; a floating **"↓ N new lines"** pill
  (bottom-centre) counts appended rows. Clicking it, pressing End, or scrolling to the
  bottom resumes following and hides the pill.

### 4. Speaker strip

Pinned above the transcript, outside the table, so it never reloads.

- One chip per diarized speaker, in its transcript colour.
- **Ordering:** unnamed first (accent dot), then named (dimmed). A one-time subtle nudge
  when a new unnamed speaker appears. Overflow collapses to `+N`.
- **Hover:** popover with their last 2–3 lines and talk time.
- **Menu** (click chip): attendees first → "Type a name…" (existing
  `TranscriptSpeakerNamer` filtering) → **"Same person as → Speaker N"**.
- **While the menu is open:** that speaker's lines are tinted in the transcript, and
  auto-follow is paused (new rows still append; the pill shows if we're off the bottom).
  Resumes on close.
- Clicking a row's speaker label opens the **same menu anchored to the chip** — never to
  the row.
- **Merge:** naming two clusters the same person (or "Same person as…") merges them into
  one chip and one colour. Implemented as an alias map `speakerId → canonicalId` applied
  at display/label time; diarization itself is untouched.

## Files

- `Parley/Transcription/FluidAudioEngine.swift` — locked prefix, stable volatile handoff,
  speaker alias/merge map, per-speaker stats (recent lines, talk time) for the strip.
- `Parley/Recording/LiveSegmentStore.swift` — publish speaker summary alongside segments
  (or a sibling `@Published` store), so the strip doesn't observe `[Segment]` in a body.
- `Parley/UI/LiveTranscriptTableDiff.swift` — new edit cases.
- `Parley/UI/LiveTranscriptTableView.swift` — follow logic, anchor-restore, pill overlay,
  tint for highlighted speaker, row-label click → strip menu.
- `Parley/UI/LiveTranscriptView.swift` — host the strip + table; `TranscriptSpeakerNamer`
  gains the "Same person as" section.
- `Parley/Recording/RecordingController.swift` — `nameSpeaker` / new `mergeSpeaker`.
- New: `Parley/UI/SpeakerStripView.swift`.

Follow `docs/DESIGN_POLISH_BRIEF.md` for visual treatment.

## Tests

- Engine: diarization ingests after the lock boundary do not change ids/text of locked
  segments; naming relabels locked segments with the same ids; final timeline after stop
  is identical to today's for a fixture.
- Diff: id churn in the tail never yields `.reloadAll`; volatile → confirmed is an
  in-place edit.
- Merge: aliasing two ids yields one display speaker and one strip chip.

## Implementation notes

- Lock horizon is measured from `min(newest speech, diarization coverage)`, so a lagging
  diarizer never freezes a line with a guessed speaker.
- Frozen runs fold into the last frozen row when the same speaker continues.
- The roster holds its list (no reorder/re-render) while a chip menu is open.
- Hover peek is a multi-line tooltip, not a second popover (two popovers on one
  control are unreliable on macOS).
- End (fn-→) jumps to latest unless an editable text field has focus.

## Resolved questions

- Merge + voiceprints: same name + same embedding model goes through `addSample`, so it
  refines the existing print. "Same person as" an unnamed speaker enrols nothing.
- Batch mode: the strip is hidden (`onNameSpeaker == nil`).

## Still open

- Lock window: 30s is a guess; validate against how far back diarization revisions
  actually reach in practice.
- Live `resolvedNames` survive the final pass keyed by old cluster ids (pre-existing
  behaviour; aliases are cleared there, names are not).
