# Implementation Prompt: Native FluidAudio Transcription + Speaker Identification Engine

> Paste this into Claude Code as the task brief. It assumes an existing macOS app with working live WhisperKit transcription and live transcript rendering. **The WhisperKit path is left exactly as it is** — no speaker identification is added to it. This brief builds a *separate, self-contained* transcription engine powered entirely by FluidAudio.

---

## Mission

The app currently transcribes with WhisperKit. Keep that as-is. Add a **second, fully native FluidAudio engine** the user can select, which does everything in one stack:

- **Transcription** — Parakeet TDT ASR, streaming for live view. **Default model: Parakeet TDT 0.6b v3 (multilingual);** v2 (English-only) selectable as an alternative.
- **Diarization** — "who spoke when" via FluidAudio's pyannote/WeSpeaker pipeline.
- **Speaker identification** — persistent voiceprints built from FluidAudio's speaker embeddings.

No mixing of frameworks: in this engine, FluidAudio does ASR *and* speaker ID. WhisperKit is not involved.

**End state:**
1. The user can pick the transcription engine in settings: **WhisperKit** (existing, transcription only, no speaker ID) or **FluidAudio** (transcription + speaker ID).
2. In the FluidAudio engine, each spoken segment in the live transcript is attributed to a speaker.
3. A user can manually label an unknown speaker; that label + voiceprint is saved.
4. In future FluidAudio sessions, saved speakers are recognised automatically.
5. The voiceprint store grows over time, is encrypted at rest, and is exportable / importable / backupable.

Engine: **FluidAudio** (`https://github.com/FluidInference/FluidAudio`, Apache-2.0) — Swift-native, CoreML, runs on the Apple Neural Engine, low memory, and exposes raw speaker embeddings (which is what makes the persistent store possible).

---

## Phase 0 — Recon first, code second (do not skip)

Before writing any integration code:

1. **Read the actual FluidAudio API.** The snippets below are illustrative and may be stale. Verify against:
   - `https://github.com/FluidInference/FluidAudio` (README + `/Documentation/ASR/` + `/Documentation/Diarization/` + `/Documentation/API.md`)
   - `https://docs.fluidinference.com`
   - The installed package source once added (read the real `.swift` headers).
   - **ASR:** `AsrModels` (`downloadAndLoad(version: .v2/.v3)`), `AsrManager` / `ASRResult`, and the streaming managers `StreamingEouAsrManager` and `SlidingWindowAsrManager`. Confirm whether `ASRResult` carries token/word timings.
   - **Diarization + embeddings:** `DiarizerManager`, `DiarizerModels`, `DiarizerConfig`, `Speaker`, `SpeakerManager`, `DiarizationResult`, the embedding-extraction entry point, and the embedding vector type/dimension.
   - **Audio:** `AudioConverter` (use it — never hand-decode buffers). Optional: Silero VAD for speech gating.
   - **Pin a specific FluidAudio version** in `Package.swift` and record it.

2. **Map the existing app.** Document briefly for me:
   - Where audio is captured (the `AVAudioEngine` tap / capture node feeding WhisperKit) and the sample format (rate, channels, Float32?).
   - The transcript model and how the live view renders it.
   - The cleanest seam to introduce engine selection (where transcription is started/owned).

3. **Produce a short integration plan** confirming the seams, then proceed. Do not start Phase 1 until Phase 0 findings are written down.

---

## Architecture decisions (already made — implement these, don't re-litigate)

- **Two independent engines behind one protocol.** Define a light `TranscriptionEngine` protocol that emits the shared transcript model. `WhisperKitEngine` wraps the existing path with **zero behaviour change and no speaker ID**. `FluidAudioEngine` is the new self-contained native stack. Engine choice is a settings toggle; **no mid-session switching** (a change applies on the next recording session).
- **The FluidAudio engine is fully self-contained.** ASR, diarization, and embeddings all come from FluidAudio, sharing one capture buffer and one preprocessing path. No WhisperKit, no second tap.
- **One capture → 16 kHz mono Float32 via `AudioConverter`.** All FluidAudio models (ASR, diarization, embedding) consume the same normalised buffer. Never hand-decode — wrong bit-depth/channel/metadata handling silently yields empty or garbage transcripts.
- **Word→speaker mapping is an interval-overlap join.** ASR and diarization are separate models even inside FluidAudio, so attribute each transcript word/segment to the diarization segment with maximum temporal overlap. Both timelines come from one SDK and one audio source, so this is clean.
- **The embedding IS the voiceprint.** Store **multiple embeddings per identity plus a running centroid**; match by cosine similarity against centroids. This is what lets accuracy build over time.
- **The store is biometric data.** Encrypt at rest, key in Keychain.

---

## Phase 1 — FluidAudio dependency + smoke tests (ASR and diarization)

- Add FluidAudio via SPM (pinned version) in an isolated module/target. Trigger model download/compile for both ASR (`AsrModels.downloadAndLoad`) and diarization (`DiarizerModels` — verify) and confirm the CoreML bundles compile and run on the ANE on this machine.
- **ASR check:** batch-transcribe a fixed test WAV with Parakeet; print the text and any token timings.
- **Diarization check:** run the offline pipeline over the same WAV; print `speakerId`, `startTimeSeconds`, `endTimeSeconds` per segment.
- **Acceptance:** both produce sane output on a known multi-speaker clip. No app UI changes yet.

---

## Phase 2 — `TranscriptionEngine` abstraction + live FluidAudio transcription

- Introduce the `TranscriptionEngine` protocol emitting the shared transcript model. Make the **existing WhisperKit path conform** as `WhisperKitEngine` — a behaviour-preserving wrapper, no other changes. Verify WhisperKit behaves identically before continuing.
- Implement `FluidAudioEngine` live transcription: drive Parakeet with a streaming manager — `StreamingEouAsrManager` (end-of-utterance segmentation, natural for turn-based calls) or `SlidingWindowAsrManager` (overlapping windows + cancellation). Try both on a test stream and report which gives better live-view parity with the current WhisperKit feel.
- Expose `parakeetVersion` as a setting, but **default to v3 (multilingual, Parakeet TDT 0.6b v3)**. Load it via `AsrModels.downloadAndLoad(version: .v3)`. v2 (English-only) remains available as an opt-in alternative, but v3 is the default the engine ships with.
- Add a settings **engine picker** (WhisperKit / FluidAudio), persisted, gated to next-session.
- **Acceptance:** selecting FluidAudio gives a working live transcript with no speaker labels yet; selecting WhisperKit gives the untouched original behaviour.

---

## Phase 3 — Diarization + speaker labels inside the FluidAudio engine

- Within `FluidAudioEngine`, feed the same normalised buffer into a **streaming** diarizer running on its own actor/queue. Keep **one `DiarizerManager` instance alive for the whole session** so in-session IDs stay consistent; rebase per-chunk timestamps by `chunkStartSample / sampleRate`; use chunks of ≥5s, prefer 10s. Buffer the session audio (ring buffer or rolling file) for the optional offline re-pass.
- Implement the overlap-join: attach each ASR word/segment to the best-overlapping diarization segment; leave `unknown` if no overlap clears a small minimum.
- Extend the transcript model so each chunk carries a `speakerId` (later a resolved display name); render the label in the live view.
- **Acceptance:** FluidAudio-engine transcript shows per-segment speaker attribution, stable within a turn. WhisperKit engine unaffected.

---

## Phase 4 — VoiceprintStore (data model, persistence, matching)

Build a `VoiceprintStore`. Reference schema (adapt to the real embedding type):

```swift
struct Voiceprint: Codable, Identifiable {
    let id: UUID
    var name: String
    var embeddings: [[Float]]    // accumulated enrollment samples
    var centroid: [Float]        // mean of embeddings, recomputed on update
    var sampleCount: Int
    let createdAt: Date
    var updatedAt: Date
    let embeddingModel: String   // e.g. "wespeaker_v2" — VERIFY actual id
    let embeddingDim: Int
    let schemaVersion: Int
}
```

Operations:
- `match(_ embedding: [Float]) -> (Voiceprint, score)?` — cosine similarity vs every stored `centroid`; return best match **only if** it clears a configurable `identificationThreshold` (expose as a setting, not hardcoded).
- `enroll(name:embedding:)` — create a new `Voiceprint`.
- `addSample(to:embedding:)` — append an embedding, recompute centroid, bump `sampleCount` / `updatedAt`.
- Live backing store: **SwiftData** (preferred on this OS target) or GRDB/SQLite; on-disk form must be cleanly serialisable for Phase 6.

Cosine similarity = `dot(a,b) / (‖a‖·‖b‖)`; normalise once and cache norms if perf matters.

- **Acceptance:** enroll, persist across restarts, match a held-out clip of an enrolled speaker above threshold while rejecting an unenrolled one.

---

## Phase 5 — Enrollment / labeling UX + known-speaker preload

- At **session start** (FluidAudio engine only), load all `Voiceprint`s and pass them to FluidAudio's known-speaker path (`speakerManager.initializeKnownSpeakers([...])` — verify) so matched segments come back named instead of `Speaker_N`.
- When an anonymous speaker appears, let the user type a name on that segment. On submit: extract the segment embedding (gate on quality — see constraints), `enroll` or `addSample` to the matching identity, then re-init known speakers so the rest of the session uses the name.
- Each subsequent **confident** segment for a known speaker silently appends a sample and refines the centroid.
- **Acceptance:** label once → same person auto-named for the rest of the session and in a fresh session.

---

## Phase 6 — Export / import / backup + encryption

- **Export/import:** serialise the whole store to **JSON** (embeddings are float arrays; JSON is portable, inspectable, diffable). Round-trip must be lossless.
- **Encryption at rest:** generate a symmetric key in the **Keychain**; encrypt the store file (CryptoKit, e.g. AES-GCM). Offer an optional passphrase-wrapped export for sharing/backup.
- **Backup:** make the encrypted store a single file (or directory) trivial to copy to the user's chosen backup/sync.
- **Acceptance:** export → wipe → import reproduces all identities and they still match; the at-rest file is not plaintext-readable.

---

## Phase 7 — Offline accuracy re-pass (optional but recommended)

- On turn-end or per completed ~30–60s span, re-run the **offline** diarization pipeline over the buffered audio and reconcile labels with the streaming result, correcting attributions retroactively.
- Optionally also run an **offline Parakeet** pass over the span for a higher-accuracy final transcript than the streaming output.
- **Acceptance:** measurably better attribution (and optionally transcript) on hard clips, with labels snapping to corrected values rather than staying wrong.

---

## Critical constraints (treat as hard requirements)

1. **Embeddings are not portable across models.** Persist `embeddingModel`, `embeddingDim`, `schemaVersion` in every record. If FluidAudio's embedding model changes on upgrade, old voiceprints are invalid. **Also retain the short enrollment audio snippets** alongside embeddings where storage allows, so identities can be re-enrolled (vectors regenerated) without starting over. Build this in from the start.
2. **Enrollment quality gating.** Reject enrollment/sample-append from segments <3s, overlapping, or low-SNR. Prefer 5–10s+, single-speaker, clean segments (FluidAudio's VAD can help gate). Never let low-confidence segments pollute a centroid.
3. **Biometric data handling.** Encrypt at rest, key in Keychain; don't log raw embeddings outside the encrypted store; keep the design consent- and retention-aware.
4. **Two thresholds exist.** FluidAudio's in-session `speakerThreshold`/`embeddingThreshold` are separate from our cross-session `identificationThreshold`. Don't conflate them.
5. **WhisperKit stays untouched.** It remains transcription-only with no speaker ID. The `TranscriptionEngine` conformance must be behaviour-preserving — verify WhisperKit is identical before and after. All speaker-ID work lives in the FluidAudio engine only.

---

## Out of scope / non-goals

- No speaker identification on the WhisperKit path (deferred; can be added later as a separate option).
- No WhisperKit + FluidAudio hybrid for now (deferred future work).
- No cloud/server transcription or diarization. Fully on-device.
- No mid-session engine switching.
- No automatic enrollment without a user-initiated label (auto-create anonymous IDs only; promotion to a named identity is always user-driven).

---

## Deliverables

- A light `TranscriptionEngine` abstraction with `WhisperKitEngine` (untouched, transcription-only) and `FluidAudioEngine` (Parakeet ASR + diarization + speaker ID).
- A settings engine picker, persisted and gated to next-session.
- A `VoiceprintStore` with encrypted persistence and JSON export/import, used by the FluidAudio engine.
- Updated transcript model/UI showing per-segment speaker names and a labeling affordance in the FluidAudio engine.
- A short README documenting: pinned FluidAudio version, the embedding model id recorded in the store, the chosen Parakeet version and its language scope, the threshold settings, and the re-enrollment path for model upgrades.

Work phase by phase. After each phase, summarise what changed and confirm the acceptance criteria before moving on.