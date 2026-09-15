# Custom-vocabulary over-fire

## What went wrong

Session `2026-09-14-133208` ("Cursor/SpaceX Next Steps", 73 min, 6 attendees) produced a
transcript in which attendee names had replaced ordinary speech:

| Transcript said | Speaker actually said | Count |
|---|---|---|
| `makes Hensley` | makes sense | 14 |
| `100 Granados` | 100 grand | 6 |
| `a Ceylan size` | a certain size | 1 |
| `upcoming Batuhan` | upcoming batch | 1 |
| `Steps` | stop / staff / step | 11 |
| `Next new` | net new | — |

Worse, a lone `Carlos` in the contacts file consumed whole phrases:

| Actually said | Became |
|---|---|
| "the bare minimum **you're talking about**" | "the bare minimum **Carlos**" |
| "some kind **of revenue for us**" | "some kind **Carlos**" |
| "which **is approximately** what we can **expect**" | "which **Carlos** what we can **Carlos**" |
| "Wells **Fargo,**" | "Wells **Carlos**" |
| "**Chris**" | "**Carlos**" |

The last two matter most: an account name and a person's identity were silently
corrupted. Nothing in the UI indicated this had happened.

## Root cause

`FluidVocabularyBuilder.build` added, as separate vocabulary terms:

1. every whitespace-separated **part** of each attendee name — so `Allegra Hensley`
   contributed `Allegra` and `Hensley`; and
2. every word of the **meeting title** — so "Cursor/SpaceX Next Steps" contributed
   `Next` and `Steps`.

The floor was `count >= 3`, weight was `10`, and no per-term `minSimilarity` was set,
so every term inherited FluidAudio's default of **0.52**. A vocabulary term does not
hint to the recogniser — the rescorer **overwrites** any span whose similarity clears
the threshold. A 52% match against a 6-letter name is easy to hit in poor audio.

Two details made it worse:

- `ContextBiasingConstants.largeVocabThreshold = 10` — tighter parameters only apply
  **above** 10 terms, so a small meeting gets the *loose* settings. Small meetings are
  more vulnerable than large ones.
- The recording merged two back-to-back calls (`callEndGraceSeconds = 10`), so the
  attendee list was the union of both. `Batuhan Ceylan` spoke for **0 seconds** and
  still contributed a vocabulary term. A name nobody uttered cannot arrive
  acoustically — only from the vocabulary.

## The fix

`FluidVocabularyBuilder` now classifies every candidate:

| Tier | Applies to | Threshold |
|---|---|---|
| `.fullName` | multi-token names (`Allegra Hensley`) | library default |
| `.strictToken` | single tokens ≥5 chars, not ordinary English | **0.85** |
| `.excluded` | shorter, or ordinary English, or a lowercase title word | not boosted |

`0.85` is measured, not chosen. Re-transcribing the original audio with a worst-case
vocabulary (all bare names **and** title words):

| Threshold | Result |
|---|---|
| 0.52 (default) | corrupted 2 of 3 clips |
| 0.75 | corrupted 1 of 3 clips |
| **0.85** | **clean on 3 of 3** |

Per-term `minSimilarity` is honoured by both rescoring paths in FluidAudio
(`term.minSimilarity ?? minSimilarity`, and `max(term.minSimilarity ?? 0, configSpotterFloor)`
in the spotter-rescue path), so gating works without disabling the feature.

Note the feature is **not** purely harmful: on the same audio, an unboosted pass
rendered "Carlos" as "Pros". Boosting exists to fix exactly that. It just needs to be
unable to fire on ordinary speech.

## Why the UI changed too

The corruption was undetectable from inside the app — nothing showed that `Steps`,
`Next` and `Carlos` had been handed to the recogniser. Settings → English optimization
now lists every term the current meeting would boost, marks the ones held to strict
matching, and names each rejected term with the reason it was rejected.

## Reproducing

```sh
# build FluidAudio's CLI (Xcode licence not required)
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  swift build -c release --product fluidaudiocli

MD=~/Library/Application\ Support/FluidAudio/Models/parakeet-unified-en-0.6b
ffmpeg -i mixed.caf -ss 1180 -t 60 -ac 1 -ar 16000 -c:a pcm_s16le probe.wav

fluidaudiocli transcribe probe.wav --model-dir "$MD"
#   → "this makes sense now"
printf 'Hensley\n' > v.txt
fluidaudiocli transcribe probe.wav --model-dir "$MD" --custom-vocab v.txt
#   → "this makes Hensley now"
fluidaudiocli transcribe probe.wav --model-dir "$MD" --custom-vocab v.txt --vocab-min-similarity 0.85
#   → "this makes sense now"
```

## Remaining follow-up

`callEndGraceSeconds` defaults to 10 s, which merged two consecutive Teams calls into
one session and pulled a stale attendee into the vocabulary. Raising it would also stop
two unrelated meetings sharing one transcript.
