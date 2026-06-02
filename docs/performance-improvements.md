# Performance Improvements — Tracking

Living checklist of performance/efficiency opportunities for the app. The app is
already memory-efficient (FluidAudio/Parakeet runs on the Neural Engine via
CoreML — model weights are clean, file-backed, mostly off-process), so these are
about **keeping it that way** and trimming the few remaining costs, not fixing a
crisis.

**Status legend:** ⬜ todo · 🚧 in progress · ✅ done · 🟢 guardrail (already good — don't regress)

## How to measure (do this before/after any change)
- **Live, quick:** the `macmem` shell function (in `~/.zshrc`) — watches the app's
  `phys_footprint` + RSS + the `aned`/`mlhostd` CoreML daemons once a second.
  Footprint *undercounts* an ANE model, so watch **RSS during active speech**.
- **Deep:** Instruments → **Time Profiler** (CPU hotspots), **Energy Log**
  (confirm work lands on the ANE / low-power state), **Allocations / Leaks**
  (catch dirty-memory regressions like the old WhisperKit unload leak).
- **In-app (planned):** a Diagnostics tab with a live footprint+RSS chart — see #4.

---

## Opportunities (prioritized)

### ⬜ 1. Adaptive call-detection poll cadence + timer tolerance  *(highest energy win)*
`CallDetector` polls every **1.5 s, always-on** (`pollInterval`), *in addition* to
Core Audio property listeners that already fire on transitions. That's ~40 CPU
wake-ups/min even when nothing is happening — needless battery drain on a laptop.
- **Do:** poll slowly (5–10 s) when no process holds the mic; tighten to ~1.5 s
  only once any input process appears. Add `Timer.tolerance` so macOS coalesces
  wake-ups.
- **Keep the guarantee:** the listeners stay the primary, instant signal — the
  poll is just the "cannot-fail" backstop, so a slower idle cadence is safe.
- **Files:** `Macsribe/Detection/CallDetector.swift` (`pollInterval`, `start()`).
- **Measure:** Instruments Energy Log idle, before/after.

### ⬜ 2. Incremental segment publishing / lazy rendering  *(scalability on long calls)*
`onSegmentsChanged` republishes the **entire** segment array on every update
(`RecordingController.makeEngine` → `self.segments = merged`). In a 2-hour meeting
that's thousands of structs re-assigned and re-diffed by SwiftUI on each
confirmation — O(n) growth per update.
- **Do:** confirm `LiveTranscriptView` renders with a `LazyVStack`/`List` (lazy);
  consider publishing appended segments incrementally rather than replacing the
  whole array; ensure auto-scroll doesn't force a full rebuild.
- **Files:** `Macsribe/Recording/RecordingController.swift` (`makeEngine`),
  `Macsribe/UI/LiveTranscriptView.swift`, `Macsribe/Transcription/TranscriptMerger.swift`.
- **Measure:** Time Profiler during a long (30+ min) session; watch main-thread cost.

### ⬜ 3. Timer tolerance on heartbeat (5 s) + partial (15 s) timers  *(easy energy win)*
These don't need millisecond precision. Setting `.tolerance` (e.g. 1 s / 3 s) lets
the OS batch their wake-ups with others.
- **Files:** `Macsribe/Recording/RecordingController.swift`
  (`startHeartbeat`, `startPartialTimer`).

### ⬜ 4. In-app Diagnostics memory chart  *(observability — catches regressions)*
Live `phys_footprint` + RSS chart (Swift Charts) in a Settings → Diagnostics tab,
sampled via `task_info(TASK_VM_INFO)`, shaded by model-loaded / recording state,
logging per-session peak to the `model` log category. Also surface the `aned`/
`mlhostd` figures since footprint alone undercounts an ANE model.
- **Files:** new `Macsribe/UI/DiagnosticsView.swift` + a tiny `MemorySampler`.

### ⬜ 5. Protect the ANE compute path  *(protects the order-of-magnitude win)*
The biggest perf lever is *which compute unit runs the model*: ANE ≫ GPU ≫ CPU on
performance-per-watt. If a FluidAudio/CoreML config ever silently falls back to GPU
or CPU, we'd lose both the memory and the power win at once.
- **Do:** log the resolved compute unit at model load; consider asserting/warning
  if ASR isn't on the ANE. (WhisperKit's path is GPU by design — this is about the
  FluidAudio path not regressing off the ANE.)
- **Files:** `Macsribe/Transcription/FluidAudioEngine.swift`, `FluidModelManager.swift`.

### ⬜ 6. Minor: release the engine reference on stop  *(tidiness — models already freed)*
`FluidAudioEngine.stop()` already frees the heavy models (`asr.cleanup()`), so this
is **not** a memory leak. But `RecordingController.engine` is never set to `nil`
after stop, so the (now-light) engine object lingers until the next `start()`.
- **Do:** `self.engine = nil` after teardown completes, for hygiene + to drop any
  retained buffers (e.g. diarization scratch).
- **Files:** `Macsribe/Recording/RecordingController.swift` (`stop()` teardown Task).

---

## Guardrails (already good — protect these)
- 🟢 **Audio callback discipline.** The mic tap / IO proc only memcpy into the
  lock-free SPSC ring buffer — no allocation, no locks, no `async`. A single
  `malloc` here = an audible glitch. Never regress this.
  (`AudioRingBuffer`, `MicCapture`, `SystemAudioCapture`.)
- 🟢 **One model per session, loaded once.** FluidAudio `loadModels()` runs once in
  `start()`, not per chunk — no reload/re-page churn.
- 🟢 **Capture-first / model-in-parallel.** Recording starts immediately; the model
  loads in the background and the transcript backfills — no blocking on cold load.
- 🟢 **Per-engine memory lifecycle (don't "unify" them):**
  - *WhisperKit:* stays resident between sessions for fast restart, with
    **idle-unload** (`ModelManager.unload()` after N idle minutes) as the safety
    valve, plus explicit `unloadModels()` on every reload (the fix for the 12.5 GB
    leak — clean-up that ARC alone won't do).
  - *FluidAudio:* loads per session, frees on stop via `asr.cleanup()`. Nothing
    lingers between recordings — so it needs no idle-unload.
- 🟢 **Bounded buffers.** WhisperKit `TrackPipeline` trims confirmed audio off the
  front; FluidAudio's sliding window is inherently bounded.

## Related (tracked elsewhere)
- **Recordings auto-prune** — raw `.caf` audio is kept indefinitely (~330 MB/hr);
  manual management exists (Settings → Storage). A time-based auto-prune is a
  planned follow-up; `RecordingsStore.sessions(olderThan:)` already exists as the seam.
- **Defender scan load** — on a managed Mac, ask IT to exclude the dev hot-spots
  (DerivedData, `.build-xcode`, `~/Library/Application Support/<App>/`) from
  real-time scanning; it competes with the model for RAM/CPU.
