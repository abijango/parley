---
name: recording-controller-finalize-race
description: Data-loss race in finalize() fixed 2026-06-10 — finalized stamp moved into async Task success path; orphan-recovery broadened
metadata:
  type: project
---

## Bug

A real 32-minute call (session `2026-06-10-130213`) was lost. `finalize()` called `finalizeManifest()` synchronously BEFORE the async Task wrote the transcript. Force-quit between the two left the manifest `.finalized` with no vault note and no offlineStatus/summaryStatus — falling through all four recovery nets.

## Fix A — close the race

- `finalizeManifest()` split into `stopHeartbeat()` (synchronous: invalidates heartbeat timer) and `stampFinalizedManifest()` (async Task success path only).
- `stopHeartbeat()` called synchronously at `finalize()` entry so no further `.active` heartbeats land.
- `stampFinalizedManifest()` called AFTER `TranscriptWriter.write(...)` succeeds, BEFORE `SessionStore.setOfflineStatus(.pending, ...)`.
- The `catch` block does NOT call `stampFinalizedManifest()` — leaves manifest `.active` for Recovery sheet.

## Fix C — orphan-recovery backstop

- `recoverOrphanedPartials()` now uses `SessionStore.isCrashed(_:)` to skip `.active` sessions (Recovery sheet handles those).
- Also catches "finalized-but-unlanded" sessions: `status == .finalized && offlineStatus == nil && summaryStatus == nil`.
- Existing no-manifest case behavior preserved.

## New predicates in SessionManifest.swift

- `SessionStore.isCrashed(_ manifest:) -> Bool` — status == .active
- `SessionStore.isFinalizedButUnlanded(_ manifest:) -> Bool` — status == .finalized && offlineStatus == nil && summaryStatus == nil

## Tests

`ParleyTests/RecoveryRaceTests.swift` — 13 XCTest cases testing pure predicates (no filesystem). All pass.

**Why:** The session `2026-06-10-130213` was recovered manually. The fix ensures this class of data loss cannot recur.
