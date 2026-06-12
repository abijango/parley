# Cross-engine voiceprints: SpeakerKit clip-embedding helper, recovery, auto-enroll

> Status: **planned, not implemented.** Stop-the-bleeding fix already shipped
> (commit `f4c843f`). This doc covers the two optional follow-ups, which both
> depend on one missing primitive.
>
> Author context: written after diagnosing why known speakers (Naufal, Andre,
> Lucy, …) stopped being recognised under WhisperKit. Root cause was the
> "Re-enroll outdated" button converting `pyannote_v3` prints to `wespeaker_v2`.
> See the commit and `memory/whisper-offline-perf-and-voiceprint.md`.

## Background (why this is needed)

Parley has two speaker-ID engines that write **incompatible** embeddings:

| Engine | Embedding model tag | Dim | Extractor available today |
|---|---|---|---|
| FluidAudio | `wespeaker_v2` (`VoiceprintStore.embeddingModel`) | 256 | ✅ `FluidAudioEngine.embeddings(forClip:)` |
| WhisperKit + SpeakerKit | `pyannote_v3` (`VoiceprintStore.speakerKitEmbeddingModel`) | 256 | ❌ **none** |

`VoiceprintStore.match()` only compares prints whose `embeddingModel` matches the
querying engine (`VoiceprintStore.swift:42`). So a person enrolled under one
engine is invisible to the other. A person must hold **one print per engine** to
be recognised on both, and there is currently no automatic way to create the
second one.

Both follow-ups below bottleneck on the **same missing function**: *given a short
audio clip, return a `pyannote_v3` speaker embedding.* Build that once and both
features unlock.

---

## Part 0 — The shared primitive: a SpeakerKit clip→embedding helper

### Goal
Mirror `FluidAudioEngine.embeddings(forClip:)` (`FluidAudioEngine.swift:456-462`)
for the SpeakerKit side. That existing helper is the reference pattern:

```swift
// FluidAudioEngine.swift:456 — the wespeaker reference implementation
nonisolated static func embeddings(forClip samples: [Float], clusterThreshold: Float) async -> [[Float]]? {
    guard samples.count >= 16_000 else { return nil }          // < 1 s too short
    guard let diar = try? await makeDiarizer(clusterThreshold: clusterThreshold),
          let result = try? diar.performCompleteDiarization(samples, sampleRate: 16_000) else { return nil }
    let embs = result.segments.filter { !$0.embedding.isEmpty }.map { $0.embedding }
    return embs.isEmpty ? nil : embs
}
```

### Where it goes
Add an **instance method** on `SpeakerKitDiarizer` (`Parley/Transcription/SpeakerKitDiarizer.swift`)
so a batch caller (recovery) can load the SpeakerKit CoreML models **once** and
reuse them across many clips — the model load is expensive and must not happen
per-clip. `SpeakerKitDiarizer` is `@MainActor` and already owns `ensureLoaded()`
/ `unload()` / `diarize()`.

### Proposed API

```swift
// SpeakerKitDiarizer.swift
/// Embed a single-speaker enrollment clip into the pyannote_v3 space — the
/// SpeakerKit counterpart to FluidAudioEngine.embeddings(forClip:). Runs
/// diarization on the clip and returns the DOMINANT speaker's centroid (the clip
/// is one person, but background noise can spawn minor clusters). nil if the clip
/// is too short or no embedding could be derived.
///
/// Reuses the loaded SpeakerKit model — call on a diarizer you keep alive across a
/// batch, then unload() once at the end.
func embedding(forClip samples: [Float],
               clusterThreshold: Double? = nil) async -> [Float]? {
    guard samples.count >= 16_000 else { return nil }          // mirror FluidAudio's < 1 s guard
    guard let out = try? await diarize(samples, clusterThreshold: clusterThreshold) else { return nil }
    // Dominant speaker = most total speech in the clip. `out.centroids` is
    // [speakerId: 256-d pyannote vector]; `out.turns` gives per-speaker duration.
    var talk: [String: TimeInterval] = [:]
    for t in out.turns { talk[t.speakerId, default: 0] += max(0, t.end - t.start) }
    guard let dominant = talk.max(by: { $0.value < $1.value })?.key,
          let centroid = out.centroids[dominant], !centroid.isEmpty else { return nil }
    return centroid
}
```

Notes:
- Returns a **single centroid** (`[Float]`), not `[[Float]]`. SpeakerKit exposes
  per-speaker centroids (`result.speakerCentroidEmbeddings`, surfaced as
  `Output.centroids`) but not clean per-segment embeddings, so we can't cheaply
  return a list the way FluidAudio does. A single centroid is sufficient — it is
  exactly what `match()` compares against. Callers that need `[[Float]]` (e.g.
  `reEnroll`) wrap it: `[centroid]`.
- The clip threshold should default to `nil` (SpeakerKit's internal 0.6) unless a
  caller has a reason to override; a single-speaker clip shouldn't need
  aggressive clustering.

### ⚠️ Validation gate (do this FIRST, before building the features)
SpeakerKit's diarizer is tuned for multi-speaker meetings, not 3–8 s isolated
clips. **Before relying on this for recovery, confirm embedding quality on a
short clip.** Concrete check: take a clip from a person who still has a *working*
`pyannote_v3` print (e.g. someone identified live recently), run
`embedding(forClip:)` on it, and cosine-compare against their live print's
centroid. Expect ≥ ~0.7. If short clips produce unstable vectors, recovery is not
trustworthy and we should fall back to "re-name under WhisperKit" only. Add this
as a throwaway test or a one-off logging probe, not production code.

---

## Part A — Recovery (one-time backfill of destroyed prints)

### What it does
For each person who has a **retained clip** but **no `pyannote_v3` print**,
generate a pyannote print from the clip. This recreates the WhisperKit-side
prints that the old re-enroll button destroyed (Naufal, Andre, Vitalii,
Christina, Lucy, …). It is **additive** — it must NOT touch the existing
`wespeaker_v2` prints (those are valid for FluidAudio).

### Data available
- Clips survived the conversion: `reEnroll` preserves `audioSample`
  (`VoiceprintStore.swift:120`). 37 of 52 prints currently carry a clip.
- `VoiceprintStore.clipSamples(id) -> [Float]?` decodes the stored clip.

### Logic (new method, e.g. in a small recovery helper or `SpeakersSettingsView`)

```swift
// Pseudocode — run on a Task, off the main actor for the heavy diarization.
let diarizer = SpeakerKitDiarizer()
defer { Task { await diarizer.unload() } }      // load models once for the whole batch

// Names that already have a pyannote print — skip them.
let havePyannote = Set(store.voiceprints
    .filter { $0.embeddingModel == VoiceprintStore.speakerKitEmbeddingModel }
    .map { $0.name.lowercased() })

// One clip-backed source print per name that lacks a pyannote version.
let targets = store.voiceprints
    .filter { $0.audioSample != nil && !havePyannote.contains($0.name.lowercased()) }
    // de-dupe by name so we don't enroll the same person twice
    .reduce(into: [String: Voiceprint]()) { acc, vp in
        acc[vp.name.lowercased()] = acc[vp.name.lowercased()] ?? vp
    }
    .values

for vp in targets {
    guard let clip = store.clipSamples(vp.id),
          let centroid = await diarizer.embedding(forClip: clip) else { failed += 1; continue }
    // Create a NEW pyannote print — do not overwrite vp (it's the wespeaker one).
    store.enroll(name: vp.name, embedding: centroid,
                 model: VoiceprintStore.speakerKitEmbeddingModel)
    done += 1
}
```

`VoiceprintStore.enroll(name:embedding:model:)` already exists
(`VoiceprintStore.swift:66`) and stamps the given model — exactly what we need.
No new store method required for the additive path.

### UI
Add a button to the "Re-enrollment" section of `SpeakersSettingsView.swift`
(distinct from the existing FluidAudio "Regenerate from clips" button), e.g.
**"Rebuild WhisperKit voiceprints from clips (N)"**, where N = count of
clip-backed names lacking a pyannote print. Show the same kind of status string
the existing `reEnrollFromClips` uses (`SpeakersSettingsView.swift:114-128`):
"Rebuilt K WhisperKit voiceprint(s); J skipped (clip too short/low quality)."

### Cheaper alternative (no code)
For a handful of people, just **re-name them once during a WhisperKit session** —
the existing naming path regenerates a fresh pyannote print
(`RecordingController.nameSpeaker` → `enrollVoiceprint`). Recovery only earns its
keep if there are many lost prints or the user won't re-name by hand.

---

## Part B — Auto-enroll the missing engine (ongoing prevention)

### What it does
When a speaker is **named** (or confidently auto-identified) under engine A, also
compute engine B's embedding from the *same* representative audio and store a
second print. After this, naming someone once makes them recognisable on **both**
engines — the "enroll once, works everywhere" behaviour.

### Hook point
`RecordingController.nameSpeaker(_:as:)` (`RecordingController.swift:230-272`) and
its helper `enrollVoiceprint(name:centroid:model:)` (`:277-287`). Today it enrolls
only for the **active** engine:

```swift
// RecordingController.swift:252 (current)
let model = eng.embeddingModelId
if let centroid = eng.setSpeakerName(speakerId, as: name) {
    let vpId = enrollVoiceprint(name: name, centroid: centroid, model: model)
    Task { [weak self] in
        guard let self, let audio = await eng.repAudioSample(for: speakerId) else { return }
        self.voiceprints.attachAudioSample(to: vpId, samples: audio)   // ← rep clip already fetched here
    }
}
```

The rep clip is **already retrieved** here for `attachAudioSample`. Extend that
same `Task` to also enroll the OTHER engine's print from that clip:

```swift
Task { [weak self] in
    guard let self, let audio = await eng.repAudioSample(for: speakerId) else { return }
    self.voiceprints.attachAudioSample(to: vpId, samples: audio)

    // Cross-enroll the other engine's space from the same clip, if not present.
    let activeModel = eng.embeddingModelId
    if activeModel == VoiceprintStore.embeddingModel {
        // Active = FluidAudio (wespeaker). Add the pyannote print.
        await self.crossEnroll(name: name, clip: audio,
                               targetModel: VoiceprintStore.speakerKitEmbeddingModel)
    } else {
        // Active = WhisperKit (pyannote). Add the wespeaker print.
        await self.crossEnroll(name: name, clip: audio,
                               targetModel: VoiceprintStore.embeddingModel)
    }
}
```

```swift
// New helper on RecordingController. Idempotent: skips if a print for
// (name, targetModel) already exists (mirrors enrollVoiceprint's dedup at :280).
private func crossEnroll(name: String, clip: [Float], targetModel: String) async {
    let exists = voiceprints.voiceprints.contains {
        $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.embeddingModel == targetModel
    }
    guard !exists else { return }
    let embedding: [Float]?
    switch targetModel {
    case VoiceprintStore.embeddingModel:                  // wespeaker
        embedding = (await FluidAudioEngine.embeddings(forClip: clip,
                       clusterThreshold: Float(settings.diarizationThreshold)))?.first
    case VoiceprintStore.speakerKitEmbeddingModel:        // pyannote
        let d = SpeakerKitDiarizer(); defer { Task { await d.unload() } }
        embedding = await d.embedding(forClip: clip)
    default:
        embedding = nil
    }
    guard let embedding else {
        AppLog.log("Cross-enroll \(name) → \(targetModel): no embedding derived", category: "record"); return
    }
    voiceprints.enroll(name: name, embedding: embedding, model: targetModel)
    AppLog.log("Cross-enrolled \(name) into \(targetModel) space from rep clip", category: "record")
}
```

### Scope decisions
- **Hook explicit naming only**, at least initially. Naming is user-confirmed and
  the rep clip is highest quality. Auto-enrolling on every *auto-identification*
  is possible but riskier (variable audio quality, fires every session) — leave
  it out of v1.
- **Both code paths** in `nameSpeaker` need this: the live path (`engine`) and the
  review/cache path (`pendingSpeakerReview`, `RecordingController.swift:238-248`).
  The cache path enrolls from a stored centroid and may not have a live clip — if
  no clip is reachable there, skip cross-enroll for that path (the recovery
  feature covers it later).
- Run cross-enroll **off the main actor** (it diarizes) and never block the naming
  UI on it — fire-and-forget like the existing `attachAudioSample` Task.

---

## Testing

- **SpeakerKitDiarizer.embedding(forClip:)** — hard to unit test (needs the
  CoreML model + real audio). Validate via the Part 0 gate (cosine vs a known
  good live print) as a one-off probe, not CI.
- **Recovery target selection** — unit-testable on `VoiceprintStore` with a temp
  file (see `ParleyTests/VoiceprintStoreTests.swift` for the pattern): given a
  store with a wespeaker print for "Andre" and a clip, the target set includes
  "Andre"; once a pyannote "Andre" exists, it's excluded. Pure set logic, no model.
- **crossEnroll idempotency** — same approach: calling it when a (name,
  targetModel) print already exists is a no-op.
- Keep matching/threshold behaviour untouched — no changes to `match()` or
  `identificationThreshold`.

## Risks & sequencing

1. **Build Part 0 + run the validation gate first.** If short-clip pyannote
   embeddings are unstable, stop — recovery/auto-enroll on the pyannote side
   aren't trustworthy, and "re-name under WhisperKit" stays the only recovery.
2. **Part A (recovery)** next — lower risk, additive, immediate payoff, gated
   behind an explicit button so it never runs silently.
3. **Part B (auto-enroll)** last — touches the hot naming path; keep it
   fire-and-forget and idempotent so a failure never affects the user's naming
   action or duplicates prints.

## File-by-file change list

| File | Change |
|---|---|
| `Parley/Transcription/SpeakerKitDiarizer.swift` | Add `embedding(forClip:clusterThreshold:)` instance method |
| `Parley/UI/SpeakersSettingsView.swift` | Add "Rebuild WhisperKit voiceprints from clips" button + handler (Part A) |
| `Parley/Recording/RecordingController.swift` | Add `crossEnroll(name:clip:targetModel:)`; call it from both `nameSpeaker` paths (Part B) |
| `ParleyTests/VoiceprintStoreTests.swift` (or new) | Recovery target-selection + crossEnroll idempotency tests |

No changes needed to `VoiceprintStore.enroll` / `match` / `Voiceprint` — the data
model already supports one print per (name, model).
