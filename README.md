<!-- TODO(app-name): "Macsribe" is a placeholder name throughout. -->
# Macsribe

A native macOS menu-bar app that records your **microphone** and **system / per-app
audio** as two separate tracks, transcribes them live with Whisper (on-device), and
writes a speaker-labeled Markdown transcript into your Obsidian vault — then optionally
runs your existing `process-meeting-transcript` Claude skill to produce a polished note.

Capturing the mic and the other side of the call **separately** is the whole point: it
labels who said what ("Me" vs "Remote") with no diarization ML, and it fixes the
"my mic filtered out everyone else" problem of single-stream recording.

## How it works

```
Mic (AVAudioEngine)  ─┐                         ┌─ "Me" pipeline ─┐
                      ├─ ring buffers ─ 16kHz ──┤                 ├─ merge ─→ live UI
System / per-app  ───┘  (Core Audio taps)       └─ "Remote" pipe ─┘    │
  (CATapDescription, no Screen Recording perm)                          │ on stop
                                                                        ▼
   ~/ObsidianVault/Unsorted Transcripts/YYYY-MM-DD-HHMM - <title>.md  + raw audio
                                                                        │ (optional)
                                                                        ▼
   claude -p "/process-meeting-transcript …"  → polished note in Internal/Customers/…
```

Both transcription pipelines share **one** WhisperKit model behind a serializing actor
(lower memory + no Neural Engine contention); the per-track labeling comes from the
separate audio buffers, not separate models. Segment times are anchored to one shared
clock so the two tracks don't drift apart over a long meeting.

## Transcription engines

Macsribe has **two interchangeable transcription engines** behind one
`TranscriptionEngine` protocol. Choose in **Settings → Transcription → Engine**; the
choice applies to the *next* recording (no mid-session switch).

| Engine | ASR | Speaker labels | Latency |
|--------|-----|----------------|---------|
| **WhisperKit** | OpenAI Whisper (small / medium / large-v3 / turbo) | "Me" vs "Remote" from the two capture tracks | ~1 s (re-transcribes the buffer) |
| **FluidAudio** *(default)* | Parakeet TDT 0.6b **v3** (multilingual) | Per-speaker diarization + cross-session voiceprint ID | ~11 s live; corrected at stop |

- **WhisperKit** keeps the two-track design above ("Me"/"Remote", no diarization ML) — transcription only, behaviour unchanged.
- **FluidAudio** is a self-contained native stack ([FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio), Apache-2.0, **pinned to `0.14.8`**). It keeps both taps but **mixes mic + system into one 16 kHz mono stream** (the far side of a call isn't audible on the mic alone) and runs everything from that single buffer:
  - **Transcription** — Parakeet TDT 0.6b v3, multilingual, via `SlidingWindowAsrManager` using the `.streaming` preset (~11 s chunks). The first text therefore appears after ~11 s — higher latency than WhisperKit, but it preserves the v3 model. (The low-latency end-of-utterance manager needs different, non-v3 models, so it's not used.) `v2` is English-only; `v3` (default) is multilingual.
  - **Diarization + speaker identification** — pyannote segmentation + WeSpeaker **256-d** embeddings (`embeddingModel` `wespeaker_v2`). Live labels come from ~10 s diarization chunks; at stop, one **offline pass** re-diarizes the whole recording for a consistent speaker set, optionally re-transcribes it with the full-context batch Parakeet model, and rewrites the saved transcript. Confident matches against saved voiceprints are auto-named and added to attendees.

Models download on first use to `~/Library/Application Support/FluidAudio/Models/`
(`parakeet-tdt-0.6b-v3/`, `speaker-diarization/`, …). Settings shows a **Download / Active**
control for the FluidAudio model.

### Implementation status

| Phase | Scope | State |
|-------|-------|-------|
| 0–1 | Recon + ASR/diarization smoke test (`Tools/FluidSmoke`) | ✅ done |
| 2 | `TranscriptionEngine` protocol, `WhisperKitEngine`, live FluidAudio transcription, settings | ✅ done |
| 3 | Live diarization + per-segment speaker labels in the FluidAudio engine | ✅ done |
| 4 | `VoiceprintStore` — 256-d embeddings, cosine matching, configurable `identificationThreshold` | ✅ done |
| 5 | Enrollment / labeling UX (inline + at-stop review), auto-identify + auto-add to attendees, retained playable clips | ✅ done |
| 6 | Encrypted export / import / backup (Keychain + CryptoKit), Speakers management tab | ✅ done |
| 7 | Offline re-pass at stop: whole-recording diarization + optional batch-ASR re-transcribe | ✅ done |

> **Speaker identification is biometric data.** Each voiceprint is stored with its
> embedding-model id (`wespeaker_v2`), dimension (**256**), and a schema version, and is
> **encrypted at rest** (AES-GCM, symmetric key in the Keychain; plaintext stores are
> migrated on load). Embeddings are **not portable across models** — if FluidAudio's
> embedding model changes on upgrade, saved voiceprints stop matching. Short enrollment
> audio clips are retained alongside each voiceprint, and **Settings → Speakers →
> Re-enrollment** regenerates the vectors from those clips (flagging outdated ones) so
> identities survive a model upgrade without re-recording. Two distinct thresholds exist
> and must not be conflated: FluidAudio's in-session `clusteringThreshold` /
> `diarizationThreshold` (groups voices within one recording, default **0.6**) vs. our
> cross-session `identificationThreshold` (matches a voice to a saved person, default
> **0.6**). Both are adjustable in **Settings → Transcription**.

## Requirements

- macOS 14.4+ (Core Audio process taps), Apple Silicon recommended
- [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`)
- Xcode 15.4+ toolchain
- The `claude` CLI (only if you enable auto note generation)

## Build & run

```bash
xcodegen generate          # regenerate Macsribe.xcodeproj from project.yml
open Macsribe.xcodeproj     # then run (⌘R)
# — or —
xcodebuild build -project Macsribe.xcodeproj -scheme Macsribe \
  -destination 'platform=macOS,arch=arm64'
```

### Opening in Xcode from the command line

`open` hands a path to its default app — `.xcodeproj` / `.xcworkspace` open in Xcode:

```bash
open Macsribe.xcodeproj                                   # this project (from the repo root)
open /Users/naufalmir/work/personal/macsribe/Macsribe.xcodeproj   # by absolute path, from anywhere
open -a Xcode                                             # just launch Xcode, no project
open -a Xcode Macsribe/Recording/RecordingController.swift  # open a single file to edit
```

> `Macsribe.xcodeproj` is **generated** by `xcodegen generate`. Open it to build/run with ⌘R,
> but make project-*setting* changes in `project.yml` — edits in the Xcode UI are overwritten
> on the next `xcodegen generate`.

The app runs as a menu-bar item (no Dock icon — `LSUIElement`). First launch will
prompt for **Microphone** access; the first recording prompts for **Audio Recording**
(system audio) access. There is no API to pre-request the audio-capture permission — it
appears when the first tap is created.

> Signing: ship **non-sandboxed** (Developer ID). Process taps, spawning `claude`, and
> writing into `~/ObsidianVault` are all incompatible with the App Sandbox. Entitlements
> live in `Macsribe/App/Macsribe.entitlements` (`app-sandbox: false`, `device.audio-input`).

## Settings

- **General** — Obsidian vault path, default capture mode
- **Transcription** — pick the **engine** (WhisperKit / FluidAudio — see [Transcription engines](#transcription-engines)); for WhisperKit, the Whisper model (small default; medium / large-v3 download on first use to `~/Library/Application Support/Macsribe/models`); for FluidAudio, the Parakeet v3 download / status
- **Notes** — toggle auto-run Claude, `claude` binary path, model, and the prompt template (`{{file}}`, `{{customer}}`, `{{attendees}}` are substituted)

## Verifying it works (manual — needs a GUI session)

1. **Capture** — start a recording while playing audio + speaking; stop. Check
   `~/Library/Application Support/Macsribe/Recordings/<session>/` has `mic.caf` + `system.caf`.
2. **Live transcript** — confirm "Me" and "Remote" lines appear in the menu popover as you talk.
3. **Vault write** — confirm a `YYYY-MM-DD-HHMM - <title>.md` lands in `Unsorted Transcripts/`,
   then run the existing skill manually to confirm format compatibility.
4. **Claude** — enable auto-run, stop a recording, confirm a note appears under `Internal/Customers/<Customer>/`.

## Known follow-ups (Phase 7)

Done:
- ✅ **Bounded session buffer** — each `TrackPipeline` trims confirmed audio off the front
  (sliding window + `windowOffset`), so memory stays flat regardless of meeting length.
- ✅ **Model unload on switch** — the recording-time model ref is cleared on stop and
  `ModelManager` releases the old model before loading a new one (no RAM stacking).
- ✅ **Latency logging** — pipelines log to the `perf` category when a decode falls behind
  real-time, plus each trim event (`~/Library/Logs/Macsribe/macsribe.log`).
- ✅ Fine-grained model **download progress** in Settings (explicit byte progress).

Remaining:
- `large-v3` may still lag real-time on a shared model; a chunked/near-real-time path
  could help (the `perf` logs now show when this happens).
- Crash-recovery checkpoint: periodically autosave a `.partial` transcript so a `SIGKILL`
  mid-recording doesn't lose the session.
- Audio level meters + notification-app filtering on the system track (capture confidence).
- Hard-crash cleanup: an aggregate-device leak is only possible on `SIGKILL` (normal quit
  tears it down via `applicationWillTerminate`).
