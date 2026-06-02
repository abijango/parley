> **Option 1 — shelved on 2026-06-02.** Approach for splitting the single "Remote"
> system-audio mix into individual speakers via Argmax **SpeakerKit** + a custom
> on-device **ECAPA** speaker-embedding model, with cross-call voice learning
> (enroll a voice once, auto-identify and auto-add the person in future calls).
> **Not currently being pursued.** This is preserved as a reference design; the
> baseline commit it was planned against is the initial commit of this repo.

---

# Macsribe — Multi-Speaker Diarization + Voiceprint Enrollment

## Context

Macsribe today separates speakers the cheap way: it captures two physical audio streams — your mic (`.me` → "Me") and the call's system audio (`.remote` → "Remote") — and transcribes each independently. `Segment.track` is the *only* speaker label in the app and drives UI colour, Markdown output, and the Claude prompt.

The gap: the **Remote stream is a single mixed-down track containing all other call participants**, so every remote person collapses into one "Remote" label. The goal is to split each track into its individual speakers, show per-speaker labels live in the transcript, let the user map a speaker to a real attendee (Speaker 2 = Andre), and — over time — **learn voices** so known people are auto-identified in future calls and auto-added to the attendee list.

Confirmed scope decisions (all maximal):
- **Diarize both tracks** (mic may have multiple in-room people; remote is the call mix). Speakers from both tracks share one identity space via voiceprints.
- **Periodic live-ish diarization** during the call using open-source SpeakerKit (batch-only): re-run every ~20–30 s on accumulated audio, update labels live without flicker.
- **Custom voiceprint enrollment now.** OSS SpeakerKit does *not* expose embeddings (cross-session ID is an Argmax roadmap item), so we integrate a **separate on-device speaker-embedding model** (ECAPA-TDNN, ~192-d). Those embeddings do double duty: stabilise labels across passes/tracks within a call, *and* match against a persistent profile store across calls.
- **Mapping UX in both places:** an "Assign speakers" review panel at stop, plus inline chip reassignment in the live/preview transcript.

Key architectural fit (verified against code): diarization is a **parallel consumer**, not a transcription stage. The streaming `TrackPipeline`/`TranscriptionService` actors are untouched; a new `DiarizationCoordinator` reads the session `.caf` files on a timer and overlays speaker identity at the `TranscriptMerger` seam. The `.caf` archives survive `finalize()` (only `segments.jsonl`/`.partial` are deleted), so at-stop sample playback works. `Segment: Codable` with new *optional* fields means old journals decode unchanged (no migration).

## Recommended approach

### Data model (`Macsribe/Transcription/Segment.swift`)
Keep `track` (physical source; still drives the resume `seed` filter). Add optional, defaulted fields so all call sites and old journals are unaffected:
```swift
var speakerId: UUID?      // stable per-call speaker identity, nil until diarized
var speakerLabel: String? // resolved name ("Andre") or nil → falls back to "Speaker N"/track
```
Add `var displaySpeaker: String { speakerLabel ?? track.label }` and route `transcriptLine`/`markdownLine` through it (one-line change each; `TranscriptWriter.makeBody` then needs no change).

New types — `Macsribe/Transcription/SpeakerProfile.swift`:
- `SpeakerProfile` (persistent): `id, name, embeddings: [[Float]], embeddingDim, modelVersion, createdAt, updatedAt, sampleCount`. `name` links to a Rolodex person.
- `CallSpeaker` (transient per call): `id (== Segment.speakerId), ordinal, centroid: [Float], sampleCount, resolvedName?, sourceTracks: Set<SpeakerTrack>`.

New persistent store — `Macsribe/Recording/SpeakerProfileStore.swift`, modeled on `SessionStore`/`TranscriptStore` (JSON, atomic write, `@MainActor ObservableObject`). Lives **outside the vault** (binary embeddings, not notes) at `AppPaths.speakersDirectory/voiceprints.json` (add `speakersDirectory` next to `recordingsDirectory`). API: `profiles`, `add(name:embedding:)`, `merge(into:embedding:)`, `bestMatch(for:threshold:) -> (SpeakerProfile, score)?`. Owned by `RecordingController` alongside `vault`/`store`.

### New components
- **`Macsribe/Transcription/SpeakerEmbedder.swift`** — an `actor` (mirrors `TranscriptionService`) wrapping a compiled Core ML embedding model: `embed(_ samples16k:[Float]) async throws -> [Float]` (L2-normalized), `static func cosine(...)`, `dim`, `isReady`. **Bundle the `.mlpackage` in the app for v1** (~20 MB) to avoid a hosting dependency; manage compile/cache by reusing `ModelManager`'s crash-safe compiled-model pattern (add `ModelManager.prepareEmbedder()`). The model's exact input front-end (raw waveform vs log-Mel/fbank) and embedding dim must be confirmed against the chosen conversion at impl time; wrap so the rest of the code is insulated.
- **`Macsribe/Transcription/DiarizationCoordinator.swift`** — `@MainActor final class`, owned by `RecordingController`. Owns SpeakerKit + `SpeakerEmbedder`. Runs periodic batch passes (~20–30 s) per track by decoding the accumulated `.caf` via the existing `OfflineTranscriber.decodeToWhisperSamples` (NOT the 30 s ring buffers, which the pipelines consume). For each diarized sub-segment: extract a voiceprint, stabilise into a `CallSpeaker`, then map onto transcript `Segment`s by **max timestamp-overlap** (nearest-midpoint fallback). Pushes a `[UUID: (speakerId, label)]` map into a new `TranscriptMerger.applySpeakerAssignments(...)` that overlays identity onto already-merged segments and re-fires `onChange`. Heavy work is `await`ed off-main; skip a pass if the prior one is still running or under `MemoryGuard` pressure. Expose `diarizeBatch(caf:track:startOffset:)` reused by both the live timer and recovery.
- **`Macsribe/Audio/SamplePlayer.swift`** — `AVAudioFile`/`AVAudioPlayerNode` (or `AVAudioPlayer`) opened on the session `.caf`, seeks to a speaker interval and stops at its end, for the "play sample" buttons.

### Label stabilisation (anti-flicker)
Never expose SpeakerKit's raw per-pass cluster numbers. Each pass:
1. Compute a centroid per fresh cluster (mean of `embed()` over ≤5 longest/loudest voiced windows — bounds cost).
2. Match each centroid to the existing `CallSpeaker` set by cosine; one-to-one greedy by descending similarity. `score ≥ STABILIZE_THRESHOLD (~0.65)` → reuse that `CallSpeaker.id`/`ordinal` and update its running centroid; else mint the next monotonic ordinal (numbers never reused → stable "Speaker 1/2/3").
3. **Cross-track merge:** if a mic `CallSpeaker` and a remote `CallSpeaker` have `cosine ≥ CROSS_TRACK_THRESHOLD (~0.75, conservative — remote mix is noisy)`, merge them (union `sourceTracks`, weighted-mean centroids, keep lower ordinal).
4. **Pinned mappings:** a manual reassignment or a confirmed auto-ID pins that `speakerId`; later passes never override it.
Thresholds live in `AppSettings` (advanced) for tuning without rebuild.

### Enrollment + auto-identify + auto-add
- **Auto-identify:** for each `CallSpeaker` with a stable centroid, `SpeakerProfileStore.bestMatch(...)`. Auto-commit (set `resolvedName`, label all owned segments, **append name to `attendees`** reusing `MainWindowView`'s existing add logic) only when `score ≥ ~0.70` **and** margin ≥ 0.10 over 2nd-best **and** centroid built from ≥ ~8 s of speech. Below that but above a suggest threshold → pre-select in the dropdown, don't auto-add. Below suggest → stays "Speaker N". Never auto-add the mic speaker mapped to "Me".
- **Enrollment ("remember this voice"):** in the at-stop panel, mapping Speaker N → person + ticking remember → `merge(into:)` existing profile or `add(...)` new. If the name isn't a Rolodex person yet, route through the **existing `NewPersonSheet` → `vault.addPerson`** flow so contact + voiceprint are created together.
- Guard `embeddingDim`/`modelVersion`: ignore profiles produced by a different model version (offer re-enroll) so incompatible vector spaces are never compared.

### UI
- **`Macsribe/UI/AssignSpeakersView.swift`** (new) — `.sheet` from `RecordDetailView`, triggered by a new `RecordingController.pendingSpeakerReview: [CallSpeaker]?` (mirrors the existing `pendingRecoveries` sheet pattern). Per row: "Speaker N", source track(s), talk time, **play-sample** button (`SamplePlayer`), **attendee dropdown** pre-filled from current attendees + "+ New person" + "Me"/"Skip" + auto-ID suggestion, **"remember this voice"** toggle. Apply → map all owned segments, persist profiles, rewrite the note.
- **`Macsribe/UI/LiveTranscriptView.swift`** (modify) — replace the track-label `Text` with a tappable **`SpeakerChip`** showing `displaySpeaker`, coloured by hashing `speakerId` into a stable palette (fallback me=accent/remote=green when `speakerId == nil`). Tap → popover (attendees, "+ New person", "Me", "Mark as Speaker N") → `RecordingController.reassignSpeaker(speakerId:to:)` reassigns **all** segments of that speaker and pins it. Reuse the chip in a structured preview of the just-finished session; editing arbitrary historical notes is out of scope for v1.

### Output (`Macsribe/Recording/TranscriptWriter.swift`)
- Body lines render via `displaySpeaker` automatically (`**[00:03:12] Andre:**` once mapped, else `**[00:03:12] Speaker 2:**`).
- Extend `TranscriptMeta` with optional `speakers: [String:String]?` (label → person) rendered as a nested YAML block; `parseFrontmatter` reads it leniently. `attendees` still lists everyone (incl. auto-added).
- **Write ordering:** keep the "never lose a recording" guarantee — `finalize()` writes immediately with provisional "Speaker N" labels, then rewrites the *same file* (atomic-write path) after the at-stop review maps speakers.

### Persistence & crash recovery
- Per-call diarization state (`CallSpeaker` ordinals/centroids/resolvedNames/pins) → `<session>/speakers.json` on each pass (cheap, like the heartbeat). Extend `SessionManifest` with `embeddingModelVersion` so a recovered session knows whether stored centroids are comparable.
- `Segment` now carries `speakerId`/`speakerLabel`; the journal serializes whole segments, so confirmed assignments are journaled and restored on crash automatically.
- `OfflineTranscriber.transcribe` yields `speakerId == nil`; add a post-step in `RecordingController.reTranscribeSession` that runs `DiarizationCoordinator.diarizeBatch` over each `.caf` (loading `<session>/speakers.json` first) so recovered/re-transcribed sessions are also diarized with matching ordinals.

### Dependency wiring (`project.yml`)
- Add the SpeakerKit product from the existing `argmaxinc` package (the project already uses `github.com/argmaxinc/WhisperKit.git`, now the monorepo hosting SpeakerKit — confirm exact product name/version at impl time) under `packages:` and the target `dependencies:`. Wrap SpeakerKit behind a small `DiarizationBackend` protocol so its exact Swift API (init, `diarize(...)`, result shape) is isolated and confirmable against the installed version.
- **macOS floor:** currently 14.4 (Core Audio taps). If SpeakerKit requires 15, bump `deploymentTarget.macOS`, target `deploymentTarget`, and `LSMinimumSystemVersion` to "15.0" — a decision to confirm before committing, as it raises the floor for all users.
- Regenerate with `xcodegen generate` after editing.

## Critical files
- Modify: `Macsribe/Transcription/Segment.swift`, `Macsribe/Transcription/TranscriptMerger.swift`, `Macsribe/Recording/RecordingController.swift`, `Macsribe/Recording/TranscriptWriter.swift`, `Macsribe/Transcription/OfflineTranscriber.swift`, `Macsribe/Transcription/ModelManager.swift`, `Macsribe/Recording/SessionManifest.swift`, `Macsribe/App/AppPaths.swift`, `Macsribe/Settings/AppSettings.swift`, `Macsribe/UI/LiveTranscriptView.swift`, `Macsribe/UI/MainWindowView.swift`, `project.yml`.
- Create: `Macsribe/Transcription/DiarizationCoordinator.swift`, `Macsribe/Transcription/SpeakerEmbedder.swift`, `Macsribe/Transcription/SpeakerProfile.swift`, `Macsribe/Recording/SpeakerProfileStore.swift`, `Macsribe/UI/AssignSpeakersView.swift`, `Macsribe/Audio/SamplePlayer.swift`.

## Phasing (each independently shippable)
1. **Batch diarization at stop + manual mapping** (no embeddings). Segment fields, `displaySpeaker`, writer/frontmatter, `DiarizationCoordinator.diarizeBatch` over the `.caf` at stop via SpeakerKit, overlap alignment, `applySpeakerAssignments`, `AssignSpeakersView` with sample playback + manual dropdown ("Speaker N" only).
2. **Periodic live diarization + stabilisation.** Periodic timer, `SpeakerEmbedder` + bundled model, centroid stabilisation + cross-track merge + ordinal pinning, inline chip reassignment, per-call `speakers.json` + recovery wiring.
3. **Enrollment + auto-identify + auto-add.** `SpeakerProfileStore`, "remember this voice", cross-call matching with confidence gating, auto-add to attendees, `VaultDirectory`/`NewPersonSheet` tie-in.

### Top risks & mitigations
- **Embedding model conversion/quality** (highest): wrap behind `SpeakerEmbedder`; validate dim + known-speaker cosine sanity before shipping; bundle a vetted ECAPA conversion; keep Phase 1 fully functional without embeddings.
- **Label flicker:** centroid-anchored monotonic ordinals + pinned mappings; never expose raw cluster numbers.
- **Remote mix hard to diarize cleanly** (codec/AGC on the mixed stream): accept over/under-clustering, let cross-track embedding merge + manual mapping clean up; conservative cross-track threshold.
- **Alignment mismatch** (Whisper vs diarization boundaries): max-overlap + nearest-midpoint fallback; defer mid-segment splitting to v2.
- **Perf/memory beside WhisperKit (~1 GB):** off-main serialized actor, cap windows-per-cluster, reuse idle-unload, throttle/skip passes under `MemoryGuard` pressure.

## Verification
Build after each phase:
```
xcodegen generate
xcodebuild -project Macsribe.xcodeproj -scheme Macsribe -configuration Debug build
```
Confirm the SpeakerKit package resolves and the deployment-target choice doesn't break the Core Audio tap path.
- **Phase 1:** Record 2 in-room people (mic) + 1 remote caller (system). On stop, the "Assign speakers" sheet lists the right count; sample playback plays the correct `.caf` interval; mapping rewrites the `.md` body to `**[ts] Name:**` and a frontmatter `speakers:` map. A silent recording still saves.
- **Phase 2:** Live call — speaker numbers stay stable across passes (no renumber), chips reassign all of a speaker's lines, pinned mappings survive later passes. Crash mid-call → relaunch → recover/resume and re-transcribe both restore/produce diarized notes via journaled `speakerId` + `speakers.json`.
- **Phase 3:** Enroll a person; in a later call they're auto-identified (chip shows name) and auto-added to attendees only above threshold+margin; an unknown/low-confidence voice stays "Speaker N" and is NOT auto-added; a new enrollment also creates the Rolodex contact.
