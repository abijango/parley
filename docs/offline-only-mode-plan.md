# Plan: optional "offline-only" transcription mode

**Status:** Planned, not built. This documents how to add it when we decide to.

## Motivation

On the WhisperKit + SpeakerKit engine, the **at-stop offline pass** (re-transcribe the
clean mix with the heavy model + SpeakerKit diarization + diarization-first attribution)
is fast and accurate — accurate enough that, for many users, the live transcript is a
nice-to-have rather than a requirement. The live path is also the expensive part
(continuous ASR on the small model, ANE/CPU pressure, the OVERLOAD risk).

So: make **live transcription opt-in**. Default to offline-only (capture audio, no live
text, produce the full attributed transcript at stop). Users who want a live transcript
flip a toggle. This simplifies the common path and removes live-decode load entirely
when off.

## User-facing behavior

A toggle in Settings under the WhisperKit + SpeakerKit engine, e.g.
**"Live transcript"** (On/Off), default **Off**:

- **Off (offline-only):** recording shows a "Recording… transcript generated at stop"
  state (elapsed time, audio levels — no streaming text). On stop, the existing offline
  pass produces the complete, speaker-attributed transcript, then the normal review /
  History / preview / auto-run flow runs as today.
- **On:** today's behavior — live track-labelled text via the live model, then the
  offline pass relabels by speaker at stop.

Only relevant to the WhisperKit + SpeakerKit engine. (If FluidAudio is still present, the
toggle is hidden/ignored for it — FluidAudio's live path is its own.)

## Implementation sketch

### 1. Setting
`AppSettings`: add `liveTranscriptEnabled: Bool = false`
(`@AppStorage` key `macsribe.liveTranscriptEnabled`). Default `false` = offline-only.

### 2. Engine — `WhisperKitSpeakerKitEngine.start(...)` (`Macsribe/Transcription/WhisperKitSpeakerKitEngine.swift:68`)
Guard the live wiring on the flag. When live is **off**, skip:
- the `mixerTask` (live mic+system → `mixedRing` mixing loop, lines ~71–77),
- the `TrackPipeline` creation + `livePipeline` (lines ~79–80),
- the `models.prepare(settings.liveModel)` warm-up (line ~83).

```swift
func start(micRing:systemRing:startElapsed:) {
    guard settings.liveTranscriptEnabled else {
        // Offline-only: capture archives still written by the capture layer;
        // nothing to decode live. The offline pass at stop does everything.
        return
    }
    // …existing live wiring…
}
```

Key point: the **clean-mix archives** (`micArchiveURL` / `systemArchiveURL`) are written
by the capture layer in `RecordingController.launchCapture`, **not** by the live
pipeline. So the offline pass at stop still has its audio with the live path disabled —
no other change needed for the offline pass to work.

`stop()` already no-ops safely when `mixerTask` / `livePipeline` are nil. The live-model
restore at the end of `runOfflinePass` (line ~157) should also be guarded so we don't
warm a live model that offline-only mode never uses:
```swift
if settings.liveTranscriptEnabled, settings.liveModel != settings.model { … }
```

### 3. UI
- **`SettingsView.swift`** (WhisperKit + SpeakerKit branch, ~335): add the
  "Live transcript" toggle. When off, hide/disable the **Live model** picker (only the
  offline/final model matters) — gray it with a caption like "Used only when Live
  transcript is on."
- **`MainWindowView.swift`** / **`LiveTranscriptView.swift`**: when offline-only and
  recording, show a "Transcript will be generated when you stop" placeholder instead of
  the empty live transcript view. After stop, the normal transcript renders.

### 4. No change needed
- The offline pass, speaker review, voiceprints, History detect, preview refresh, and
  auto-run-after-review all already run off the at-stop pass — they are independent of
  whether live text was shown.

## Testing
- Offline-only ON (default): record → no live text, "generated at stop" state → stop →
  full attributed transcript appears → review / naming / auto-run work.
- Live ON: unchanged from today.
- Toggle persists across sessions; switching mid-app applies next recording.
- Confirm no live-model load happens in offline-only mode (check logs — the heavy model
  loads once at stop, no small-model warm-up).

## Follow-on simplification (optional, later)
If offline-only becomes the strong default and live is rarely used, the **single live
mixed-stream** machinery (`mixedRing`, `mixerTask`, `TrackPipeline`, the live model
setting) becomes dead weight whenever the toggle is off — but keep it as long as live is
a supported option.
