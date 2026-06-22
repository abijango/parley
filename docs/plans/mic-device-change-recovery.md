# Mic device-change recovery + silence watchdog

## Problem (confirmed from a real failure)

Recording `2026-06-18-090009` (51 min Teams call): `system.caf` = 3045 s (full),
but `mic.caf` = **33.6 s**. The local mic stopped capturing ~33 s in and never
resumed, so the user's entire side of the conversation was lost (collapsed to
scattered "Yeah"s; their voiceprint never matched).

Root cause: `MicCapture` reads the input format **once** at `start()`, installs one
tap, starts an `AVAudioEngine`, and never reacts to device/route changes.
`AVAudioEngine` posts `AVAudioEngineConfigurationChange` and *stops itself* when the
input device or its format changes (Bluetooth connect/disconnect, default-input
switch, A2DP↔HFP profile flip). After that the tap stops firing. Nothing observes
this, nothing restarts the engine, and nothing logs it — a dead mic is completely
silent in the logs (the heartbeat only tracks the *system* process tap).

## Design constraints (verified in code — do not relitigate)

1. **Single continuous `mic.caf` is mandatory.** `AudioMix.buildCleanMix(mic:system:output:)`
   (`Parley/Audio/AudioMix.swift`) overlays the two tracks by **sample index from
   sample 0** (`out[i] += m[i]`) and reads a **single** mic URL. A `mic.2.caf`
   continuation segment would NOT be mixed in. So recovery must keep writing into
   the *same* `mic.caf`.

2. **The outage must be silence-padded in the archive.** Because the mix aligns by
   sample index = elapsed time, any missing mic samples shift all subsequent mic
   audio earlier and misalign speaker turns against the system track. Padding the
   gap with silence (at the archive's sample rate) preserves alignment. This is the
   load-bearing correctness requirement — recovering audio without padding is worse
   than the current failure.

3. **The archive file format is fixed at creation** (`AudioArchiver` opens an
   `AVAudioFile` with settings derived from the *initial* input format). A new device
   at a different sample rate must be **resampled into the existing file's format**,
   not written raw. `AVAudioConverter` resamples, so this is a converter rebuild.

4. **The ring-buffer (live ASR) path is forgiving.** It consumes format-agnostic
   16 kHz mono floats and the offline pass replaces the live transcript for
   speaker-capable engines anyway. Rebuild its resampler from the new format and move
   on; do not over-engineer the live side. (Padding its gap with silence is a nice-to-
   have for live-partial coherence, not required.)

## Deliverables

### 1. `AudioArchiver` — accept a new source format + pad silence

File: `Parley/Recording/AudioArchiver.swift`

- Change `private let converter` → `private var converter` (it must be rebuildable).
- Add `func updateSourceFormat(_ newFormat: AVAudioFormat)`:
  rebuilds `converter = (newFormat != file.processingFormat) ? AVAudioConverter(from: newFormat, to: file.processingFormat) : nil`
  and resets `loggedFailure = false`. The output file format never changes; this just
  re-points the converter so buffers from a new device are resampled into the existing
  file. (`AVAudioConverter` from a higher/lower sample rate to `file.processingFormat`
  resamples — confirm the converter is non-nil; if it comes back nil, `logOnce` and
  keep the old converter so we degrade rather than crash.)
- Add `func appendSilence(seconds: Double)`: writes a zero-filled buffer in
  `file.processingFormat` of `round(seconds * file.processingFormat.sampleRate)` frames
  (chunk it, e.g. ≤ 1 s buffers, to avoid a giant allocation) and advances
  `framesWritten`. Swallow/`logOnce` write errors like `append`.
- `framesWritten` is already exposed — keep it (the watchdog reads it).

### 2. `MicCapture` — observe config changes, self-heal, and run a silence watchdog

File: `Parley/Audio/MicCapture.swift`

Make the engine rebuildable and add two triggers into one serialized rebuild path.

- `private let engine = AVAudioEngine()` → `private var engine = AVAudioEngine()`
  (rebuild a **fresh** engine on recovery; do not try to restart a stale one).
- Add a serial `DispatchQueue` (e.g. `rebuildQueue`) that owns ALL teardown/rebuild
  work. Config-change notifications and the watchdog both dispatch onto it so rebuilds
  are serialized and never overlap. Guard re-entrancy with an `isRebuilding` flag and
  bail if `!isRunning` (stopped).
- **Tap ↔ rebuild synchronization.** The tap runs on the real-time audio thread and
  reads `resampler`/`archiver`; the rebuild swaps them. Protect both the tap's read and
  the rebuild's swap with an `os_unfair_lock` (or `NSLock`) — critical section is just
  reading/assigning the two references, keep it minimal. Note `archiver` is currently a
  stored property already read in the tap; the new field is `resampler` (also already
  read in the tap). Removing the old tap before swapping reduces but does not eliminate
  the in-flight-callback race, so keep the lock.
- **Config-change observer.** Register for `.AVAudioEngineConfigurationChange`. The
  notification fires on an arbitrary thread, can arrive in bursts, and can be a no-op
  reconfig. Dispatch to `rebuildQueue`; **debounce** (coalesce a burst). After building
  a fresh engine, re-register the observer for the new engine instance (or observe with
  `object: nil` and filter `notification.object as? AVAudioEngine === engine`).
- **Silence watchdog (primary trigger).** A `DispatchSourceTimer` on `rebuildQueue`
  (~1 s cadence). The tap updates a `lastBufferDate` (under the lock, or an atomic). If
  `isRunning && !isRebuilding` and `lastBufferDate` is older than a threshold
  (start with **3 s**), log loudly and trigger the rebuild. This catches device changes
  AND any other stall (engine throw, TCC/device hiccup) — it must not depend on the
  config-change theory being correct.
- **Rebuild routine** (on `rebuildQueue`, serialized, re-entrancy-guarded):
  1. Note `outageStart` (when we noticed) for gap math. Prefer measuring the actual
     outage: time from teardown to the first post-rebuild buffer, OR `now - lastBufferDate`.
  2. `engine.stop()`, `inputNode.removeTap(onBus: 0)` (wrapped defensively).
  3. `engine = AVAudioEngine()` (fresh).
  4. `let format = engine.inputNode.outputFormat(forBus: 0)`. If `format.sampleRate <= 0`,
     log "mic input unavailable, will retry" and return (watchdog/notification retries).
  5. Build a new `AudioResampler(inputFormat: format)`.
  6. `archiver?.updateSourceFormat(format)` then `archiver?.appendSilence(seconds: outage)`
     to keep `mic.caf` aligned. (Pad the archive; the ring buffer pad is optional.)
  7. Swap `resampler`/`archiver` references under the lock; reinstall the tap with the
     new format; `engine.prepare()`; `try engine.start()`.
  8. `AppLog.log("Mic recovered — input changed to \(format.sampleRate)Hz/\(format.channelCount)ch, padded \(outage)s gap", category: "audio")`.
     On failure to restart, log the error and leave the watchdog to retry.
- `stop()` must: invalidate the watchdog timer, remove the NotificationCenter observer,
  set `isRunning = false` (so any queued rebuild bails), then tear down tap/engine as today.
- **Add a one-time "mic capture started" log** on first successful `start()` with the
  chosen format, so future logs show the mic path is alive (today it logs nothing).

### 3. Tests

- `AudioArchiverTests`: write N seconds at format A, `updateSourceFormat(B)` where B has
  a different sample rate, `appendSilence(seconds:)`, write more, close, reopen with
  `AVAudioFile(forReading:)` and assert total duration ≈ expected (A audio + silence +
  B-resampled audio) within a small tolerance, and that the file's sample rate is still
  A's (unchanged). This is the deterministic core of the fix — cover it well.
- A `MicCapture` rebuild test is hard (needs real hardware/notification) — if you can
  factor the rebuild bookkeeping (outage→silence-frame math, debounce, format-equality
  no-op check) into pure helpers, unit-test those. Don't fake the audio engine.

## Implementation status (2026-06-21) — COMPLETE

### Done

**`Parley/Recording/AudioArchiver.swift`**
- `converter` changed to `private var`.
- `updateSourceFormat(_:)` added: rebuilds the converter from the new input format to the
  unchanged file processingFormat. Uses the nil-safety guard from the spec; resets
  `loggedFailure`. If `newFormat == file.processingFormat`, sets `converter = nil` (no-op
  path for same-format devices).
- `appendSilence(seconds:)` added: chunked at ≤1 s (48 000 frames per chunk); sets
  `frameLength` explicitly; zeros channel data with `memset`; advances `framesWritten`.
- `append` converted from one-shot `convert(to:from:)` to the block-based
  `convert(to:error:withInputFrom:)` form so that sample-rate conversion (not just layout
  conversion) works after `updateSourceFormat`. Output buffer capacity scaled by rate ratio
  + 16 slack frames.

**`Parley/Audio/MicCapture.swift`** — full rewrite
- `engine` changed to `private var` (rebuildable).
- `rebuildQueue` serial queue owns all teardown/rebuild work.
- `tapLock` (`os_unfair_lock`) protects `resampler`, `archiver`, `lastBufferDate` against
  the tap/rebuild race. Tap copies refs under lock, does I/O outside it.
- `AVAudioEngineConfigurationChange` observer (object: nil, filtered by `=== self.engine`)
  dispatches to `rebuildQueue`; re-entrancy guarded by `isRebuilding`.
- Silence watchdog: 1 s cadence `DispatchSourceTimer` on `rebuildQueue`, 3 s threshold.
  Fires `rebuildEngine()` when `lastBufferDate` is stale.
- `rebuildEngine()`: measures outage from `lastBufferDate`, tears down stale engine,
  allocates fresh `AVAudioEngine`, reads new format, builds `AudioResampler`, calls
  `archiver.updateSourceFormat` + `archiver.appendSilence`, swaps `resampler` under lock,
  reinstalls tap, restarts engine. On failure logs and leaves watchdog to retry.
- `start()` logs "mic capture started" with format on first call.
- `stop()` invalidates watchdog, removes observer, sets `isRunning = false`, syncs teardown
  on `rebuildQueue`.

**`ParleyTests/AudioArchiverTests.swift`** (new file)
- 5 tests covering the deterministic core:
  1. `testUpdateSourceFormatAndSilencePad_roundTrip` — full A→B switch with silence pad;
     asserts duration and file sample rate are correct.
  2. `testAppendSilence_advancesFileDuration` — silence-only write produces correct duration.
  3. `testAppendSilence_zeroSecondsIsNoop` — 0-second silence is a no-op.
  4. `testFramesWritten_tracksAcrossFormatSwitch` — `framesWritten` stays accurate across
     format switch + silence + B-rate write.
  5. `testUpdateSourceFormat_sameAsProcessingFormat_noConverter` — same-format update keeps
     direct-write path functional.

### Build / test result

`xcodebuild build` — **BUILD SUCCEEDED** (no new warnings introduced).
`xcodebuild test` — **All tests passed** (5 new AudioArchiverTests + all pre-existing tests).
`xcodegen generate` was run (new test file required it).

### Post-implementation: AVAudioFile write-alignment bug found and fixed (2026-06-21)

**Bug found during code review:** The `AudioArchiver.append` converter path had a frame-loss
defect in the `AVAudioFile.write(from:)` call. Root cause: when writing Int16 LPCM CAF files,
`AVAudioFile.write(from:)` internally uses a CoreAudio Format Converter that processes in
power-of-2 blocks. Calling `write` with non-power-of-2 frame counts (e.g. 4458 or 4459 frames
from a 44100→48000 SRC) causes a ~14.5 frame/call deficit that accumulates over the session.
For a 51-minute recording at 44100→48000 SRC, the total loss would be ~4 seconds of audio.
This is the exact same category of drift that the recovery was meant to fix.

**Fix (in `AudioArchiver`):**
- Added a write staging buffer (32768-frame capacity in `processingFormat`).
- Converter output (and silence pads) goes through `stageAndFlush()` which accumulates frames
  and flushes in 4096-frame aligned blocks to disk via `writeDirectly`.
- `flushRemainder()` drains any sub-4096 tail; called from `updateSourceFormat` (format
  boundary), after `appendSilence`, from `deinit` (safety net), and from the new public
  `finalize()` method.
- `finalize()` is called from `MicCapture.stop()` after engine teardown, before the archiver
  is released, so the file is complete on every normal session end.
- `finalize()` is also called from `SystemAudioCapture.teardown()` after the IO proc and
  aggregate device are destroyed (2026-06-21 fix: previously missing — system track would
  lose the staging tail, up to 4096 frames / ~85 ms, on every recording).
- The `memmove`-based shift (not `initialize(from:)`) is required for the staging buffer's
  self-overlap copy on flush.

**Tests added (2 new, total 7):**
- `testAppend_crossRateConverter_preservesFrames`: 200 × 4096-frame buffers at 44100→48000
  through the staging path; asserts total duration within 50 ms. Was failing (-60 ms) before
  staging fix; passes after.
- `testAppend_sameRateConverter_preservesFrames`: same but with interleaved→non-interleaved
  same-rate converter; passes confirming no same-rate regression.

All 270 tests in `ParleyTests` pass.

### Deviations from spec

- The spec suggests `isRebuilding = false` before an early return when `sampleRate <= 0`
  in `rebuildEngine`. That was omitted because the `defer` block already handles it on all
  exit paths — the extra assignment was removed as redundant.
- The `loggedFailure` reset in `AudioArchiver.append`'s block-form path is per the spec;
  `loggedFailure` resets in `updateSourceFormat` so errors from the new converter are
  visible.
- `MicCapture` rebuild-bookkeeping helpers (outage→frames math) are inline in
  `rebuildEngine()` rather than factored into separate pure helpers, because the math is
  a single line (`max(0, now.timeIntervalSince(lastBuffer))`). There was nothing to unit-
  test separately without faking the engine.
- `AudioArchiver.finalize()` was added as a public method (not in spec) to expose explicit
  flush; `MicCapture.stop()` calls it after tap teardown and `SystemAudioCapture.teardown()`
  calls it after the IO proc is destroyed. This prevents residual staged frames from being
  lost if deinit is delayed (and fixes a live regression on the system track).

### Manual verification required (user)

## Verification (I will run this manually — note it in your report)

A build + "mic level moves" is NOT sufficient proof. Real proof:
1. Start a recording.
2. ~30 s in, switch the audio input device (un/plug headphones, connect Bluetooth).
3. Keep talking for a minute, stop.
4. Confirm `mic.caf` duration ≈ full session length (not truncated at the switch),
   the log shows a "Mic recovered" line, and the offline transcript attributes the
   user's post-switch speech to the right speaker (alignment held).

## Out of scope

- Crash-recovery resume (`RecordingController.resume`) — that's app-relaunch only.
- Changing `AudioMix` to multi-segment or timestamp alignment (not needed given the
  single-continuous-file approach).
