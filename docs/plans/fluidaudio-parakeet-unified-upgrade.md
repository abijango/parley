# FluidAudio Parakeet Unified upgrade path

> Status: **implemented** (Parakeet Unified English route, custom vocabulary, diarization
> compute-units audit, GPU encoder toggle, FluidSmoke unified smoke test).

## Goal

Adopt NVIDIA Parakeet Unified 0.6B and related FluidAudio 0.15.x improvements so
the FluidAudio engine path gains better English accuracy, lower streaming latency,
word-level timestamps, custom vocabulary, and more reliable diarization — while
keeping the multilingual Nemotron + Parakeet TDT v3 path for non-English sessions.

## Current state (Parley)

| Stage | Model | Notes |
|-------|-------|-------|
| Live ASR | `StreamingNemotronMultilingualAsrManager` | Cache-aware streaming; tier from `FluidStreamingTier` |
| Offline ASR | Parakeet TDT v3 batch (`AsrModels.download(version: .v3)`) | Optional re-pass via `offlineAsrRepass` |
| Diarization | FluidAudio `DiarizerManager` + Sortformer v3 | `diarizationThreshold` in Settings |

SpeechAnalyzer engine reuses the same FluidAudio diarization stack (`wespeaker_v2`
voiceprints).

## 1. Parakeet Unified 0.6B (English)

**What:** FluidAudio 0.15.5 adds `parakeet-unified-2080ms` (streaming, ~2 s latency)
and `parakeet-unified-offline-15s` (full-attention batch, ~5.91% WER on Open ASR
Leaderboard vs v3 ~6.34%).

**Routing:**

- When `settings.liveStreamingLanguage` is English (`en-US` or `en-*`) **and** user
  opts into unified (new setting, default on for English): use unified variants.
- Otherwise: keep Nemotron multilingual live + Parakeet TDT v3 offline (current path).

**Files:**

- [`Parley/Transcription/FluidAudioEngine.swift`](Parley/Transcription/FluidAudioEngine.swift) — swap ASR managers per route
- [`Parley/Settings/AppSettings.swift`](Parley/Settings/AppSettings.swift) — `useParakeetUnified` toggle
- [`Parley/Transcription/FluidModelManager.swift`](Parley/Transcription/FluidModelManager.swift) — download unified CoreML bundles

**Benefits:** one model family for live + offline on English; native word timestamps;
fewer chunk-merge seams; better streaming latency tiers.

## 2. Custom vocabulary

**What:** FluidAudio 0.15.5 per-term CTC thresholds + opt-in acoustic spotter controls.

**Integration:**

- Import attendee names + meeting title tokens from accepted metadata into a
  `CustomVocabulary` list before each session.
- Settings toggle: "Boost attendee names in transcript" (default on when attendees known).

**Files:** `FluidAudioEngine` offline + streaming config; Settings UI under FluidAudio tab.

## 3. Diarization upgrades (already in 0.15.5 pin)

- Sortformer v3 BNNS fixes, VBx re-clustering, zero-vote span re-embed
- Verify `configuration.computeUnits` is wired if not already passed to
  `OfflineDiarizerModels.load`
- Optional progress handler on `performCompleteDiarization` for offline progress bar

**Action:** audit current `makeDiarizer` / finalize path; enable any flags not yet passed.

## 4. Performance

- **GPU encoder placement** for Parakeet v3 (+~8% RTFx, WER-neutral) — expose as
  Settings advanced toggle for FluidAudio.
- Evaluate Nemotron **2240 ms B1 fusion** tier as new default vs current 560 ms tier
  (latency vs accuracy tradeoff for live).

## 5. Download infrastructure (ModelHub)

FluidAudio 0.15.5 replaced `DownloadUtils` with `ModelHub` (breaking). Parley's
[`FluidModelManager`](Parley/Transcription/FluidModelManager.swift) uses high-level
`AsrModels.download` / `StreamingNemotronMultilingualAsrManager.downloadVariant` —
verify these route through ModelHub after pin bump; no direct `DownloadUtils` usage
expected.

If resumable byte-level progress is needed in Settings, adopt `ModelHub` progress
callbacks in `FluidModelManager`.

## 6. Validation

- Extend [`tools/FluidSmoke`](tools/FluidSmoke/) with `parakeet-unified-2080ms` smoke test
- A/B on real meeting fixtures: current Nemotron+v3 vs unified English path
- AMI-style two-speaker clip: diarization threshold regression (0.60–0.65)

## Suggested order

1. Audit 0.15.5 diarization flags (low risk)
2. Parakeet Unified English route + Settings toggle
3. Custom vocabulary from attendees
4. GPU encoder + streaming tier evaluation
5. ModelHub progress UI (optional polish)
