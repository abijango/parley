# FluidSmoke — Phase 1 smoke test

Isolated SwiftPM executable that validates the FluidAudio engine on this machine
**without touching the app**. Proves ASR (Parakeet TDT) and diarization (+ 256-d
speaker embeddings) load, run on the ANE, and produce sane output on a known
two-speaker clip.

## Run

```sh
cd tools/FluidSmoke
swift run FluidSmoke Fixtures/two-speakers.wav            # default clusteringThreshold 0.7
swift run FluidSmoke Fixtures/two-speakers.wav 0.65       # override threshold (2nd arg)
```

The fixture is a 25 s, 16 kHz mono clip of two `say` voices (Samantha / Daniel,
4 alternating turns), generated with `ffmpeg`.

## Pinned versions / identifiers (Phase-0/1 verified against the resolved source)

| Item | Value |
|------|-------|
| FluidAudio | **0.14.8** (latest tag), SPM `from: "0.14.8"`, min macOS 14 / Swift-tools 6.0 |
| ASR model | **Parakeet TDT 0.6b v3** (multilingual) via `AsrModels.downloadAndLoad(version: .v3)`; v2 = English-only |
| ASR timings | `ASRResult.tokenTimings` — **token-level** `startTime`/`endTime`/`confidence` |
| Diarizer | `DiarizerManager.performCompleteDiarization(_:sampleRate:)` → `DiarizationResult.segments: [TimedSpeakerSegment]` |
| Embedding model | **wespeaker_v2** (256-d, L2-normalized); exposed per segment as `TimedSpeakerSegment.embedding` and per chunk as `ChunkEmbedding.embedding256` |
| Segmentation model | **pyannote_segmentation** |
| In-session knob | `DiarizerConfig.clusteringThreshold` (library default **0.7**) |
| Known-speaker preload | `DiarizerManager.initializeKnownSpeakers(_ speakers: [Speaker])` (single-arg in 0.14.8) |
| Model cache | `~/Library/Application Support/FluidAudio/Models/` |

## Phase 1 results (M4 Pro, macOS 26.5)

- **ASR ✅** — near-verbatim transcript, confidence 0.972, 146 token timings, Encoder on `cpuAndNeuralEngine`.
- **Diarization ✅** — embeddings cleanly separate the two voices: within-speaker cosine **~0.87–1.00**, cross-speaker **~0.16–0.21**.
- **Threshold finding** — the library default `clusteringThreshold: 0.7` **over-merges** (1 speaker on this clip). **0.60–0.65** correctly yields 2 speakers with correct turn attribution; ≤0.55 over-splits (a low-quality tail segment becomes a spurious 3rd). → threshold must be **configurable**, not hardcoded (matches the brief), and should be re-validated on real human audio. TTS voices are adequate for a smoke test but are imperfect test material (one tail segment produced a degenerate, quality-0.21 embedding).
