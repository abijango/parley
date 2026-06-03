# FluidAudio removal map

**Status:** FluidAudio is a **secondary, optional engine**. The default and primary
engine is **WhisperKit + SpeakerKit** (chosen after the A/B in T5.3). FluidAudio is
left in the app for now. This document is the checklist for deleting it **cleanly and
completely** if/when we decide to drop it — so the removal is a mechanical, low-risk
operation rather than archaeology.

> Do this on a branch, build green after each section, then run a recording end-to-end
> on the WhisperKit + SpeakerKit engine before merging.

---

## 0. The one functional coupling to rewire FIRST

Everything else is "delete a file" or "delete an enum branch." This is the only place
shared code calls **into** FluidAudio for behavior, so handle it before deleting the
engine or the build breaks:

- **`Macsribe/UI/SpeakersSettingsView.swift:123`** — the *re-enroll a saved voiceprint
  from its retained clip* flow calls
  `FluidAudioEngine.embeddings(forClip:clusterThreshold:)`.
  - **Action:** replace with the WhisperKit + SpeakerKit embedding extractor
    (`WhisperKitSpeakerKitEngine`'s SpeakerKit centroid path — see `embeddingModelId` /
    `embeddingDim` on that engine), and switch the surrounding "stale voiceprint" copy
    from "FluidAudio update" wording to the SpeakerKit embedding model.
  - This also makes `VoiceprintStore`'s default model meaningful — see §5.

---

## 1. Files to delete entirely

| File | What it is |
|------|------------|
| `Macsribe/Transcription/FluidAudioEngine.swift` | The engine (Parakeet ASR + diarization + embeddings). Self-contained. |
| `Macsribe/Transcription/FluidModelManager.swift` | Downloads/tracks the on-disk Parakeet CoreML bundles. Only used by FluidAudio. |
| `Tools/FluidSmoke/` | FluidAudio-only validation harness (the WhisperKit+SpeakerKit equivalent is `Tools/SpeakerKitSmoke/`). |

## 2. `project.yml` (then `xcodegen generate`)

- Remove the `FluidAudio:` package block (currently ~lines 31–33).
- Remove the `- package: FluidAudio` target dependency (currently ~line 48).
- Regenerate the Xcode project: `xcodegen generate`.

## 3. `Macsribe/Settings/AppSettings.swift`

- **`TranscriptionEngineKind`** (line ~72): delete the `case fluidAudio` and its arms in
  `label` and `blurb`. Once it's the only case, consider removing the engine picker
  entirely (see §7), or keep the enum for the future offline-only / engine selection.
- Delete the FluidAudio-only settings (keys + `@AppStorage` + computed accessors):
  - `FluidParakeetVersion` enum (line ~92) + `parakeetVersion*` (keys line ~133, prop ~196, accessor ~245).
  - `diarizationThreshold` (key ~134, prop ~200) — FluidAudio in-session clustering knob.
  - `offlineAsrRepass` (key ~136, prop ~208) — FluidAudio "re-transcribe whole recording" toggle.
  - **Keep** `identificationThreshold` and `minSpeechToIdentify` — these are shared
    (used by the WhisperKit + SpeakerKit path too).

## 4. `Macsribe/Recording/RecordingController.swift`

- `let fluidModels = FluidModelManager()` (line ~79) — delete the property.
- `makeEngine()` `case .fluidAudio:` branch (lines ~132–146) — delete.
- `reprocessSpeakers` `case .fluidAudio:` branch (lines ~642–...) — delete.
- `refresh`/presence `case .fluidAudio:` arm (line ~270–271, `fluidModels.refreshPresence()`) — delete.
- `engineDesc` ternary (lines ~196–197) — simplify to the WhisperKit + SpeakerKit label.
- Comments referencing FluidAudio (lines ~55, 59, 73, 109, 148, 264, 610, 612, 766) — update wording.
- Note: the `SpeakerCapableEngine` protocol stays — `WhisperKitSpeakerKitEngine` still
  conforms. Only the FluidAudio conformance is removed (§6).

## 5. `Macsribe/Recording/VoiceprintStore.swift` + `Voiceprint.swift`

- `static let embeddingModel = "wespeaker_v2"` / `embeddingDim = 256` are the **FluidAudio**
  defaults. With FluidAudio gone, change `match(...)` / `enroll(...)` default `model:`
  params to `speakerKitEmbeddingModel` (`"pyannote_v3"`), and point `staleVoiceprints` at
  the SpeakerKit model.
- **Do NOT** rename or "version-correct" the string constants
  `embeddingModel = "wespeaker_v2"` and `speakerKitEmbeddingModel = "pyannote_v3"` — they
  are **opaque scope keys** stamped into every saved voiceprint. Changing the string
  orphans existing enrolled prints (they stop matching). Old `wespeaker_v2` prints simply
  become permanently stale once FluidAudio is gone (re-enroll from clips, §0).
- Update FluidAudio mentions in comments (`VoiceprintStore.swift` ~9, 15, 35, 61, 102; `Voiceprint.swift`).

## 6. Shared `Transcription/` files — edit, don't delete

- **`SpeakerCapableEngine.swift`**: delete the `extension FluidAudioEngine: SpeakerCapableEngine { ... }`
  block. Keep the protocol and the `WhisperKitSpeakerKitEngine` conformance.
- **`TranscriptionEngine.swift`**, **`Segment.swift`**, **`AudioMix.swift`**,
  **`DiarizationAttribution.swift`**, **`WhisperKitSpeakerKitEngine.swift`**: FluidAudio
  appears **only in comments/docstrings**. Update wording; no code changes.
  - Reminder: `AudioMix.swift` and `DiarizationAttribution.swift` were **copied** out of
    FluidAudio (per the "don't touch FluidAudio" constraint) and are now the shared,
    canonical implementations. They are NOT dependencies on FluidAudio — keep them.

## 7. UI

- **`SettingsView.swift`**: delete `FluidModelSection` (struct ~623–656) and its call
  site (~432). Delete the `if settings.transcriptionEngine == .whisperKit { ... }` /
  FluidAudio branching once there's one engine; the engine `Picker` (~321–329) can be
  removed if FluidAudio was the only alternative.
- **`MainWindowView.swift`**: simplify the `== .fluidAudio` ternaries (lines ~167, 276–277)
  to the WhisperKit + SpeakerKit label; update the comment ~129.
- **`SpeakersSettingsView.swift`**: after §0, update the FluidAudio wording (lines ~27, 85, 91).
- **`LiveTranscriptView.swift`** / **`AssignSpeakersView.swift`**: comment-only FluidAudio
  mentions; the speaker-naming UI is shared and stays.

## 8. Final checks

- `xcodegen generate && xcodebuild -project Macsribe.xcodeproj -scheme Macsribe -configuration Debug -derivedDataPath "$PWD/.build-xcode" build` → green.
- `grep -rin "fluid\|parakeet\|wespeaker" Macsribe/ project.yml` → only intentional
  residue (the opaque `wespeaker_v2` scope key in `VoiceprintStore`, if kept for old prints).
- Record a call on WhisperKit + SpeakerKit: live text → stop → speaker review →
  name a speaker → re-enroll-from-clip works (§0) → History detect works.
- `README.md`: drop the FluidAudio engine row from the status/engine table.
