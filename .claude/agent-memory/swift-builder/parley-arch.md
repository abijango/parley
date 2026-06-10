---
name: parley-arch
description: Key file locations, session lifecycle, concurrency patterns, and test target setup in the Parley codebase
metadata:
  type: project
---

## Key file locations

- `Parley/Recording/RecordingController.swift` — `@MainActor` class; owns the full recording session end-to-end. `finalize()` is the stop sequence.
- `Parley/Recording/SessionManifest.swift` — `SessionManifest` struct + `SessionStore` enum with filesystem-scanning queries and (now) pure predicates.
- `project.yml` — XcodeGen project definition; regenerate with `xcodegen generate` after adding/removing files or changing settings.
- `ParleyTests/` — all test files; picked up by the `path: ParleyTests` glob in `project.yml` without editing it.

## Session lifecycle

1. `start()` → `beginSessionManifest(dir:)` writes `session.json` with `status: .active`; `startHeartbeat()` fires every 5s to refresh it.
2. `stop()` → `finalize()`:
   - Snapshots locals, calls `stopHeartbeat()` synchronously (no more `.active` stamps).
   - Spawns async Task for `TranscriptWriter.write(...)`.
   - On success: `stampFinalizedManifest()` → `SessionStore.setOfflineStatus(.pending, ...)` → offline enqueue.
   - On failure (catch): leaves manifest `.active` for Recovery sheet.
   - Synchronous tail: `state = .idle`, drain queues, schedule idle unload.

## Concurrency conventions

- `RecordingController` is `@MainActor`; all state mutations are on main.
- Detached `Task { ... }` blocks inside `@MainActor` methods inherit the main actor implicitly (no `Task.detached`).
- `MainActor.assumeIsolated { }` used inside Timer callbacks.

## Test target

- XCTest (`@testable import Parley`). No Swift Testing.
- `project.yml` `ParleyTests` target uses `path: ParleyTests` directory glob — just drop a `.swift` file there and `xcodegen generate`.
- Tests must be pure (no filesystem scans). Mock with value-type constructors.

## Recovery nets at launch

Four scanners: `crashedSessions()` (active manifest), `pendingOfflineSessions()` (offline pending/running), `pendingSummarySessions()` (summary queued/paused/running), `recoverOrphanedPartials()` (partial file, no manifest OR finalized-but-unlanded manifest).
