---
name: merge-service-patterns
description: Key patterns, gotchas, and advisor guidance from implementing MergeService (call merge feature)
metadata:
  type: project
---

## MergeService orchestration patterns (2026-06-29)

**Why:** Implementing the call-merge orchestrator required specific API choices that aren't obvious from the code.

### API symbols to know
- Duration fallback: `TranscriptCoverage.spanFromTranscriptFile(url).span` — NOT `TranscriptWriter.spanFromTranscriptFile` (doesn't exist).
- Session dir from audio path: `MeetingFiles.sessionDir(forAudioPath:)` — returns `URL?`, validates under `Recordings/` root.
- Audio duration: `SessionStore.audioDuration(_ url: URL) -> Double`.
- Enqueue offline: `offline.enqueue(OfflineJob(...)) + offline.runNextIfIdle()` — always cancel stale jobs first with `offline.cancel(sessionDir:)`.
- Move to archive folder: `MeetingFiles.trash(dir)` (recoverable) preferred over `FileManager.removeItem`.
- Write manifest to disk **before** `SessionStore.setOfflineStatus` (it does read-modify-write).

### C2 manifest must be `.finalized` not `.active`
Setting `status: .active` causes `crashedSessions()` to surface it in the launch Recovery sheet. Use `.finalized` for a pre-built merged session dir.

### File ordering matters for C1 and C2
Read all source note texts into memory **before** moving them to Merged/, then write the combined note. The combined/seed filename often collides with leg-0's filename (same title + date), so move first.

### `Task.detached` for audio concat
`AudioConcatenator.concatenate` is synchronous `AVAudioFile` I/O — must be offloaded with `Task.detached` to avoid freezing the `@MainActor` main thread. Only value types (URL arrays, TimeInterval arrays) are captured — no `self`.

### OfflineJob flags for merge
`presentReviewWhenDone: false, autoSummarize: AppSettings.shared.autoRunClaude` — "mirror reprocessSpeakers" means copy the *mechanics* (setOfflineStatus → enqueue → runNextIfIdle), not the "detect speakers" UX flags.

### `stitchMerge` does not need legSessions
C1 only reads transcript text; it has no use for audio paths. Remove that parameter to avoid unused-variable warnings.

### Integration validation result (2026-06-29)
Build green first try, zero code fixes needed. All 36 tests (AudioConcatenatorTests x6, TranscriptStitcherTests x15, MeetingParsersTests x15) passed without modification. API contracts across agents were mutually consistent.

**How to apply:** Read this before touching merge-related code in a future session.
