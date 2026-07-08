# Performance backlog — long-running recordings

## Completed

### Quick wins (July 2026)
- Throttled live segment UI publish (`SegmentPublishRelay`, ≤5 Hz)
- Throttled FluidAudio `publish()` with immediate confirm boundaries
- Journal append only for newly confirmed segment IDs
- Background `writePartial()` writes *(superseded by append-only partial — see large #9)*
- Incremental `liveWordCount`
- Meter publish coalescing (5 Hz + delta threshold)
- `TrackPipeline` scratch buffer reuse

### Medium refactors (July 2026)
1. **Incremental FluidAudio `derive()`** — cached confirmed segments; incremental
   unit append; invalidate on diar ingest / speaker rename / offline re-pass
2. **Slice audio before WhisperKit `transcribe`** — decode tail-only samples
3. **Single mixed WhisperKit pipeline** — one `TrackPipeline` on mixed mic+system
   (plain `WhisperKitEngine`; matches SpeakerKit path)
4. **Incremental `TranscriptMerger.merged()`** — k-way linear merge; lock-based
   `Sendable` merger; `onChange` hops to main actor
5. **Windowed live transcript** — last 300 rows + “Show earlier”; `.equatable()` on
   `LiveTranscriptView`; scroll on last-segment text changes
6. **Narrower UI observation** — cached History badge; `RecordLevelMeters` subview
7. **Cap mixer read per tick** — ~1s max per mix iteration (FluidAudio, WhisperKit,
   SpeakerKit engines)

### Large refactors (July 2026)

8. **`LiveSegmentStore` with diff/patch updates** — `RecordingController` applies
   engine timelines through `LiveSegmentStore.apply(_:)` instead of replacing
   `@Published [Segment]` every tick. Common paths (volatile tail text update,
   append-on-confirm, in-place speaker relabel) mutate only changed rows; full
   replace is the rare fallback. Tests: `ParleyTests/LiveSegmentStoreTests.swift`.

9. **Append-only partial transcript** — removed the 15s `partialTimer` and full
   `writePartial()` rebuild. `PartialTranscriptAppender` writes the document header
   once, then appends markdown lines alongside `SegmentJournal` on each newly
   confirmed segment. Crash recovery still uses `transcript.partial.md`; finalize
   deletes it after the vault write.

10. **Compact long-lived diarization state** — `FluidAudioEngine` merges adjacent
    same-speaker diar turns after each ingest and offline pass; `speakerAt()` uses
    binary search on the sorted timeline (O(log n) contain + neighbor boundary);
    raw `speakerEmbeddings` vectors are dropped once a speaker centroid is computed
    (`speakerCentroids` retained for enrollment / review cache).

11. **Split `RecordingController` published state** — `RecordingLiveState`
    (segments via `LiveSegmentStore`, meters, `RecordingState`, `liveWordCount`)
    and `MeetingSessionState` (title, filing, attendees, notes, AX discovery).
    `RecordDetailView`, `MenuBarView`, and `SuggestionChips` observe the sub-objects
    so inspector typing does not republish segment/meter updates.

---

## Profiling checklist

When validating fixes on a 30+ minute call:

1. **Time Profiler** — `derive`, `diarizationFirst`, `merged()`, SwiftUI `body`,
   `TranscriptWriter.makeBody`.
2. **Allocations** — growth in `[Segment]`, `[Tok]`, `[Float]` over time.
3. **Main thread** — segment publish should stay ≤5–10 Hz; partial writes off-main.

## References

- Throttle pattern: `JobProgressRelay` / `SegmentPublishRelay` in
  `Parley/Recording/PipelineProgress.swift`
- Segment store: `Parley/Recording/LiveSegmentStore.swift`
- Partial appender: `Parley/Recording/PartialTranscriptAppender.swift`
- Live / meeting state: `Parley/Recording/RecordingLiveState.swift`,
  `Parley/Recording/MeetingSessionState.swift`
- Merger tests: `ParleyTests/TranscriptMergerTests.swift`
- Segment store tests: `ParleyTests/LiveSegmentStoreTests.swift`