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
- **Transcription** — Whisper model (small default; medium / large-v3 download on first use to `~/Library/Application Support/Macsribe/models`)
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
