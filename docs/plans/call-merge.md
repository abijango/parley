# Call Merge — combine drop/rejoin recordings into one note

## Problem
A dropped + rejoined call produces two separate sessions/notes for one meeting
(e.g. `2026-06-25-1004` + `2026-06-25-1013`, identical title, 4 s apart). We want a
**manual** History action to combine them into a single note.

## Decisions (signed off)
- **Entry point:** manual "Combine with…" in History (no auto-merge).
- **Backends:** default **C2** (audio re-pass) when every leg's audio is present;
  fall back to **C1** (transcript stitch) when any leg's audio is gone.
- **Gap:** C1 butts legs together with a `**— reconnected —**` marker; C2 pads the
  real wall-clock gap with silence so timestamps stay honest.
- **Source notes:** moved to `Parley/Merged/` (recoverable), not deleted.

## Reused machinery
- `TranscriptFallbackAttribution` — `[HH:MM:SS]` line parsing pattern (C1 re-timing).
- `AudioMix` / `AudioCompactor` — `AVAudioFile` read/write + ALAC decode (C2 concat).
- `OfflineProcessingService` + `OfflineJob` + `runOfflinePass` + coverage guard +
  cross-session voiceprints (C2's transcription/diarization engine, reused verbatim).
- `resume()`'s offset model (continue at a time offset) informs C1's leg-2 shift.

## API contracts (fixed up front so the pieces compile together)
```swift
enum MergeBackend: String { case audioRepass, transcriptStitch }   // MergeTypes.swift

// TranscriptStitcher.swift — pure, no I/O
enum TranscriptStitcher {
    /// notes[0] is the base; each later note is re-timed by the running sum of
    /// durations and appended under "## Transcript" behind a "— reconnected —"
    /// marker. Frontmatter: keep notes[0] title/date/filing, union attendees.
    static func stitch(notes: [String], durations: [TimeInterval]) -> String
}

// AudioConcatenator.swift — pure file I/O
enum AudioConcatenator {
    /// Concatenate inputs into `output`, inserting `gaps[i]` seconds of silence
    /// BEFORE inputs[i] (gaps[0] == 0). Normalizes mixed sample rates/channel
    /// counts to a common format. Returns false on any read/write failure.
    static func concatenate(_ inputs: [URL], gaps: [TimeInterval], output: URL) -> Bool
}

// MergeService.swift — @MainActor orchestrator
final class MergeService {
    init(store: TranscriptStore, vault: VaultDirectory, offline: OfflineProcessingService)
    /// items in any order (service sorts by meta.date). backend == nil → auto
    /// (C2 if all legs have audio, else C1). Returns the combined note URL.
    func merge(_ items: [TranscriptItem], backend: MergeBackend?) async -> URL?
}
```
`RecordingController` gains `lazy var mergeService` + `func combineRecordings(_ items: [TranscriptItem], backend: MergeBackend?) async -> URL?` (mirrors `reprocessSpeakers`). `AppPaths` gains `mergedURL` + ensures it in `ensureVaultFolders`.

## Mechanics
**Ordering & gap:** sort by `meta.date`; `legDuration = SessionStore.audioDuration(mic.caf)`
(fallback: leg's last `[HH:MM:SS]`); `gap = legN.date − (legN-1.date + legN-1 duration)`.

**C1 (stitch):** read each leg's `.md`; `TranscriptStitcher.stitch` → one note written to
leg-0's filing in Unprocessed; move source `.md`s to `Merged/`. Instant, no audio, works
after audio deletion. *Speaker labels not unified across the seam* (shown in UI).

**C2 (re-pass):** `AudioConcatenator` builds combined `mic.caf` + `system.caf`
(silence-padded gaps) in a new session dir; seed a transcript + manifest; enqueue an
`OfflineJob` → one `mixed.caf`, one ASR + diarization over the whole meeting → one clean,
consistently-diarized note. Move source `.md`s to `Merged/`; remove source session dirs
after success. Requires every leg's audio.

## Components / ownership
| File | Agent | Notes |
|---|---|---|
| `Parley/Recording/MergeTypes.swift` (new) | haiku | `MergeBackend` enum |
| `Parley/App/AppPaths.swift` (edit) | haiku | `mergedURL` + ensure |
| `Parley/Recording/TranscriptStitcher.swift` + test (new) | sonnet | C1 core, pure |
| `Parley/Audio/AudioConcatenator.swift` + test (new) | sonnet | C2 audio join |
| `Parley/Recording/MergeService.swift` (new) | sonnet | orchestration |
| `Parley/Recording/RecordingController.swift` (edit) | sonnet | wire mergeService |
| `Parley/UI/HistoryView.swift` (edit) + `MergeSheet` | sonnet | entry point + picker |
| Build + tests, fix to green | sonnet | validation gate |

## Tests
- `TranscriptStitcherTests`: offset re-timing, seam marker, attendee union, idempotency.
- `AudioConcatenatorTests`: duration = Σlegs+gaps; same-rate and cross-rate legs.
- Validation: `xcodebuild test` green; manual merge of the real `1004`/`1013` legs.

## Risks
- Cross-rate concat (mic device change mid-meeting) → normalize on write; covered by a test.
- Already-summarized/filed leg → re-open as Unprocessed.
- `>2` legs → fold left-to-right.

## Build accounting

Implemented by a 4-phase background workflow (`wf_ed2e37a8-d64`) on **2026-06-29**:
**sonnet** agents for logic, **haiku** for boilerplate, a sonnet validation gate.
Result: clean build + **36/36 tests** pass (independently re-verified). Figures below
are reconstructed from the per-agent transcripts; totals are exact, per-phase split is
approximate (the `swift-builder` agent type spawned helper sub-agents — 9 agent
processes for 6 logical agents — and the UI agent dropped its connection mid-message and
retried, so its phase carries that extra cost).

**Wall-clock:** ~81 min total (Phase 1 ran 3 agents in parallel). **Harness-reported
subagent tokens:** 572,616 (output + non-cache input; the cache-read/-write volume below
is far larger and is what drives cost).

### By phase (model · wall-clock · est. cost)

| Phase | Agents | Model | Wall-clock | Est. cost |
|---|---|---|---|---|
| 1 — Core | TranscriptStitcher, AudioConcatenator | sonnet | ~8 min (parallel) | $1.71 |
| 1 — Core | MergeTypes + AppPaths | haiku | ~0.4 min | $0.15 |
| 2 — Service | MergeService + controller wiring | sonnet | ~8 min | $2.31 |
| 3 — UI | HistoryView + MergeSheet (failed mid-msg, retried) | sonnet | ~13 min | ~$3.3 |
| 4 — Validate | xcodegen + build + tests, integrate | sonnet | ~20 min | ~$4.3 |
| | | | **~81 min** | **≈ $11.8** |

### By model (exact token totals across all 9 agent processes)

| Model | Agents | Output tok | Cache-write tok | Cache-read tok | Cost |
|---|---|---|---|---|---|
| Sonnet 4.6 | 5 logical (8 procs) | 52,307 | 1,458,686 | 17,864,333 | $11.62 |
| Haiku 4.5 | 1 | 2,175 | 78,728 | 370,995 | $0.15 |
| **Total** | **6** | **54,482** | **1,537,414** | **18,235,328** | **≈ $11.77** |

Cost is dominated by **cache reads** (~18.2M tok ≈ $5.4) and **cache writes** (~1.54M tok
≈ $5.8) — agents re-reading the repo + prior-phase context each turn. Raw output was tiny
(~54K tok ≈ $0.8). Pricing per 1M tok: Sonnet 4.6 $3 in / $15 out / $3.75 cache-write(5m)
/ $0.30 cache-read; Haiku 4.5 $1 / $5 / $1.25 / $0.10.

**Takeaway:** haiku handled the boilerplate at ~1% of total cost; the long pole was the
validation/integration phase (reading the whole repo to compile-fix) and the UI agent's
retry. A cleaner UI-agent run and a tighter validate scope would cut ~$3–4.

## Integration + validation gate — DONE (2026-06-29)

**Build:** `xcodegen generate` + `xcodebuild build` — succeeded clean, zero errors, pre-existing
notes/warnings only (WhisperKit Sendable, etc.). No code changes were required; all agents'
contracts were mutually consistent on the first compile.

**Tests (36 total, 36 passed, 0 failed):**
- `AudioConcatenatorTests` — 6 tests: cross-rate + same-rate duration arithmetic, gaps[0]
  ignored, empty inputs, mismatched gaps, output readability. All green.
- `MeetingParsersTests` — 15 tests: pre-existing suite; all green (no regressions).
- `TranscriptStitcherTests` — 15 tests: single-note passthrough, two/three-leg timestamp
  shifting, seam markers + surrounding blank lines, attendee union (YAML + body), manual-notes
  preservation, output structure (one transcript header, trailing newline), base-meta
  preservation. All green.

**No fixes were needed.** All API contracts matched across agents:
- `TranscriptStitcher` calls `TranscriptWriter.parseFrontmatter(text:)` and
  `extractBodySections(text:)` — both exist and match the call sites.
- `MergeService` calls `SessionStore.audioDuration`, `TranscriptCoverage.spanFromTranscriptFile`,
  `MeetingFiles.sessionDir(forAudioPath:)`, `MeetingFiles.trash(_:)`,
  `OfflineProcessingService.cancel(sessionDir:)`, `enqueue(_:)`, `runNextIfIdle()`,
  `SessionStore.write(_:to:)`, `SessionStore.setOfflineStatus(_:...)` — all exist.
- `AppPaths.mergedURL` (both the vault-arg form and `@MainActor` convenience) present in
  `AppPaths.swift`; `ensureVaultFolders` includes `mergedURL`.
- `RecordingController.combineRecordings(_:backend:)` delegates to `mergeService.merge` as
  specified; `MergeSheet.confirm()` calls `recording.combineRecordings`.
- `OfflineJob` direct-construction init used in `MergeService` matches the struct definition.
