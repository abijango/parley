# Plan — Summary run metrics (time + cost), v1 rename, and the v2 audio-deletion bug

**Status:** not started
**Owner:** unassigned (hand to `swift-builder`)
**Three independent workstreams.** A is a bug fix and should land first — it is
small, self-contained, and unrelated to B/C. B is the feature. C is cosmetic.

- **A.** Summary v2 (and Compare) never delete session audio after filing.
- **B.** Show generation time and estimated cost for every summary run, both pipelines.
- **C.** Rename the "Classic" pipeline to "Summary v1".

---

## Workstream A — v2 never deletes the session audio

### The bug

Two near-duplicate commit functions in `Parley/Summary/SummaryService.swift`:

| Function | Called by | Deletes audio? | Clears queue? |
|---|---|---|---|
| `commit(_:destination:stagedURL:)` `:1249` | `HistoryView.swift:575` (**v1**) | **Yes** `:1301` | **Yes** `:1294` |
| `commitGeneratedMarkdown(_:destination:body:overwriteExisting:)` `:1130` | `SummaryMarkupReviewView.swift:570` (**v2**), `SummaryCompareView.swift:368` (**Compare**) | **No** | **No** |

`commitGeneratedMarkdown` was forked from `commit` to add re-filing (the
`overwriteExisting` flag and the `item.isProcessed` branch at `:1165-1167` that
updates frontmatter instead of moving the file). The audio-reclaim block was not
carried across. `deleteAudioAfterFiling` is read in exactly **one** place in the
whole codebase — `:1301`, inside `commit` — so v2 has no path to it.

**Compare-view filing leaks audio too**, for the same reason. Two call sites, one
missing block.

**Second divergence — real, but narrower than it looks.** `commit` does
`queue.removeAll { $0.id == item.id }` (`:1294`); `commitGeneratedMarkdown` does
not. Traced before writing this: `runNext()` removes the item from `queue` at
`:366` *before* running, and the only re-inserts (`:465` v1, `:563` v2) are the
`usageLimited` branches, both of which `return` without ever reaching a commit.
So in the normal flow the item is **not** in `queue` at file time and
`commit`'s removal is already a defensive no-op.

It only bites in one edge case: the user re-enqueues a summary
(`enqueue` → `queue.append` at `:235`, via auto-summarize or a manual
Summarize press) *while* a staged note is still awaiting review, then files the
old staged note. v1 cancels the queued re-run; v2 leaves it queued and it runs
against a now-filed transcript.

Do not treat this as the headline bug. Fold the removal into the shared tail
because it belongs there, not because v2 is visibly leaking queue entries.

### Idempotency: verified safe, no guard needed

`commit` nils `audio` in frontmatter after deleting, and
`MeetingFiles.sessionDir(forAudioPath:)` (`MeetingFiles.swift:53`) returns `nil`
when the directory no longer exists, falling through to a `try?` remove that
no-ops on a missing path. Re-filing the same note is therefore harmless. Do not
add an idempotency guard; it would be dead code.

### The fix

Do **not** paste the block into the second function. These two functions share
roughly 80% of their bodies, and this bug is the proof that parallel copies
drift. Collapse them onto one implementation.

Suggested shape — keep both public entry points (call sites and their semantics
differ), extract the shared tail:

```swift
/// Everything that happens once the note content is written: move/relink,
/// clear staging + queue state, reclaim audio. Shared by both commit paths.
@discardableResult
private func finishFiling(item: TranscriptItem,
                          noteURL: URL,
                          destination: String,
                          alreadyProcessed: Bool) -> URL
```

`finishFiling` owns: the move-to-Processed vs update-frontmatter branch,
`crossLinkSummaryOntoRaw`, `removeAllStaging`, `jobs[item.id] = nil`,
`queue.removeAll`, `setSummaryStatus(.done,…)`, the audio-reclaim block, the
`AppLog` line, and `store.refresh()`.

`commit` keeps its staged-file resolution and `composeNote` call; then delegates.
`commitGeneratedMarkdown` keeps its `overwriteExisting` filename logic and
`composeNote` call; then delegates with `alreadyProcessed: item.isProcessed`.

**Preserve the ordering comment at `:1293`** — `setSummaryStatus(.done,…)` must
run *before* any audio delete (it clears pending-summary intent first). That
ordering is load-bearing; carry the comment with it.

**Verify while you are in there:** `commit` always calls
`store.moveToProcessed`; `commitGeneratedMarkdown` branches on `item.isProcessed`.
The branch is the more correct behaviour — a re-filed note must not be moved
twice. Make `finishFiling` use the branch for both, and confirm the v1 path
still behaves identically for a first-time file (where `isProcessed == false`).

---

## Workstream B — time and estimated cost per run

### What the CLIs actually report (probed empirically 2026-07-27, not assumed)

| Backend | Duration | Tokens | Dollar cost |
|---|---|---|---|
| **Claude** `claude -p` | time externally | ✓ | ✓ `total_cost_usd` — already parsed into `ClaudeStreamParser.Usage.costUSD` |
| **Cursor agent** | ✓ `duration_ms`, `duration_api_ms` | ✓ `usage.{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens}` | ✗ none |
| **Grok** | ✗ none in payload | ✓ `usage.{input_tokens,output_tokens,cache_read_input_tokens,reasoning_tokens,total_tokens}` and `modelUsage.<model>.*` | ✗ none |
| **Local MLX/Qwen** | time externally | n/a | $0 — on-device |

Real observed envelopes:

```jsonc
// cursor agent -p --mode ask --output-format json --trust
{"type":"result","subtype":"success","is_error":false,"duration_ms":3130,
 "duration_api_ms":3130,"result":"ok","session_id":"…","request_id":"…",
 "usage":{"inputTokens":13596,"outputTokens":29,"cacheReadTokens":5957,"cacheWriteTokens":0}}

// grok -p … --output-format json
{"text":"ok","stopReason":"EndTurn","sessionId":"…","requestId":"…",
 "usage":{"input_tokens":53781,"cache_read_input_tokens":128,"output_tokens":12,
          "reasoning_tokens":11,"total_tokens":53921},
 "num_turns":1,
 "modelUsage":{"grok-4.5":{"inputTokens":53781,"outputTokens":12,
                           "cacheReadInputTokens":128,"modelCalls":1}}}
```

### Decisions taken by the user (do not re-litigate)

1. **Estimated dollars everywhere, marked "est."** Use Claude's real
   `total_cost_usd` where present; derive from tokens × a maintained price table
   elsewhere. Mark any derived figure `est.`
2. **Extend `SummaryRunStore` to record v1 runs** — a v1 run is a row with one
   backend and no hunks. Both pipelines then share one query path.

The user is subscription-billed on Cursor and Grok, so an estimate is a
list-price proxy, not their actual bill. Say so in the UI help text — one short
sentence, e.g. "Estimated from token counts at list prices; subscription plans
may differ."

### Task B1 — a backend-neutral metrics type

`RunResult.success(String, ClaudeStreamParser.Usage?)` (`:1223`) is
Claude-shaped and the only carrier today. Introduce a neutral type — new file
`Parley/Summary/SummaryRunMetrics.swift`:

```swift
/// Per-leg generation metrics. `wallClock` is always populated (measured by
/// Parley); every other field is best-effort and backend-dependent.
struct SummaryRunMetrics: Equatable, Codable, Sendable {
    var wallClock: TimeInterval = 0
    var apiDurationMS: Int?          // cursor's duration_api_ms; nil elsewhere
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var reasoningTokens: Int = 0     // grok only
    var reportedCostUSD: Double?     // claude's total_cost_usd; nil elsewhere
    var model: String = ""           // for price-table lookup
}
```

**Keep every field `var` with a default, and do not write a custom
`init(from:)`.** That is precisely what makes the JSON-blob column (B5) safe as
fields are added: synthesised `Codable` decoding tolerates keys missing from
rows written by an older build. "Tidying" these into `let`s or hand-rolling the
decoder silently breaks reading old rows.

Change `RunResult.success` to carry `SummaryRunMetrics?`. Map
`ClaudeStreamParser.Usage` into it at the Claude site rather than changing
`ClaudeStreamParser` — `ClaudeUsageStore.record(_:)` (`SummaryService.swift:447`)
still consumes the Claude type and must keep working unchanged.

### Task B2 — parse usage from Cursor and Grok

**Do not change the existing `JSONResult` enums.** Both are `Equatable` and
covered by tests; adding associated values would churn every exhaustive switch.
Add a separate, additive parse function to each runner:

- `CursorAgentRunner.parseUsage(_ data: Data) -> SummaryRunMetrics?` — reads
  `usage.inputTokens` / `outputTokens` / `cacheReadTokens` / `cacheWriteTokens`
  and `duration_api_ms`. Reuse the existing last-`{`-object salvage logic in
  `parseJSONResult(stdout:)` (`CursorAgentRunner.swift:99-108`); factor that
  extraction out rather than duplicating it.
- `GrokRunner.parseUsage(_ data: Data) -> SummaryRunMetrics?` — reads
  `usage.input_tokens` / `output_tokens` / `cache_read_input_tokens` /
  `reasoning_tokens`. Prefer `modelUsage.<model>` when present, since it names
  the model for price lookup; fall back to the flat `usage` object.

Both must return `nil` (not zeroed metrics) when no usage object is present, so
the UI can distinguish "no data" from "zero tokens".

### Task B3 — wall-clock timing

Measure around the backend call, uniformly, so all four backends report
duration regardless of what the CLI says. Two sites:

- **v1**: the classic leg lives **inline in `runNext()`** (`SummaryService.swift:371`
  onward, after the v2 early-return at `:368`) — it is not a separate function.
  Wrap the `switch backend { … }` that produces `result` (`:415-432`).
- **v2**: `runV2` (`:514`) — wrap each `runBackend` call separately (`:544` writer,
  `:584` checker). Two legs, two durations.

Use a monotonic clock, not `Date()`: `ContinuousClock` or
`DispatchTime.now().uptimeNanoseconds`. A wall-clock summary run spans minutes,
and an NTP step or DST change during it would produce a negative or absurd
duration. (`SummaryComparison.swift:252` uses `Date()`; do not copy that.)

### Task B4 — the price table

New file `Parley/Summary/SummaryPricing.swift`. A single table mapping model id →
USD per million tokens for input / output / cache-read, plus a
`estimate(_ metrics: SummaryRunMetrics) -> Double?` that returns `nil` for an
unknown model (so the UI shows tokens without a bogus dollar figure).

**The implementing agent MUST look up current prices at implementation time from
the vendor pricing pages. Do not invent them, and do not trust any figures a
model recalls from training.** Put a `// Verified <date> against <url>` comment
above the table. Models needing entries: the `claudeModel` values in use
(`sonnet`, and whatever else the user sets), `grok-4.5`, and the four Cursor
backends (`composer25`, `composer25Fast`, `cursorGrok45`, `cursorGrok45Fast` —
see `SummaryBackend` in `AppSettings.swift`). If a price genuinely cannot be
found for a Cursor model, omit the entry and let it return `nil` — showing
tokens only is correct; guessing is not.

Cost resolution order: `metrics.reportedCostUSD` (real, unmarked) →
`SummaryPricing.estimate(metrics)` (marked `est.`) → nil (show tokens only).

### Task B5 — schema and store

`KnowledgeDatabase.migrate()` (`:54-120`) uses `CREATE TABLE IF NOT EXISTS` plus
bare `ALTER TABLE … ADD COLUMN` calls whose errors are deliberately ignored
(`_ = sqlite3_exec`, see the `terminology.scope` precedent at `:119`). Follow
that pattern exactly; bump `schema_version` to `"3"` at `:120`.

Add to `summary_runs`:

```sql
ALTER TABLE summary_runs ADD COLUMN pipeline TEXT NOT NULL DEFAULT 'v2';
ALTER TABLE summary_runs ADD COLUMN writer_metrics_json TEXT NOT NULL DEFAULT '';
ALTER TABLE summary_runs ADD COLUMN checker_metrics_json TEXT NOT NULL DEFAULT '';
```

JSON blobs rather than a column per token kind: the metrics struct will gain
fields (vendors keep adding token categories), and these values are only ever
displayed, never queried or aggregated in SQL. Encode with `JSONEncoder`.

`DEFAULT 'v2'` is correct for backfill — every existing row *is* a v2 run.

Update `SummaryRunRecord` (`SummaryEditModels.swift:51`) with
`pipeline: SummaryPipeline`, `writerMetrics: SummaryRunMetrics?`,
`checkerMetrics: SummaryRunMetrics?`, and extend `insertRun` / `runRow` /
both `SELECT` lists in `SummaryRunStore.swift` (`:19-31`, `:42`, `:60`, `:182`).

**Write a v1 row at generation time.** Unlike v2 — where `runV2` writes its row
after both legs finish with `draft` in scope (`:604-615`) — the classic leg has
no run record at all today; it writes `text` to the staging file and stops.

Exact insertion point: inside `case .success(let text, let usage):`
(`SummaryService.swift:437`), **after** the staging write at `:439` succeeds, so
a failed write does not leave an orphan row. Fields:

- `transcriptID: item.url.path` — **must match v2 exactly** (`:606` uses the same),
  or `runs(forTranscriptID:)` will not return both pipelines' runs for a transcript.
- `pipeline: .classic`, `writerBackend: backend.rawValue`, `checkerBackend: ""`,
  `draftMarkdown: text`, `checkerRaw: ""`, `checkerParseOK: false`, `hunks: []`
- `writerMetrics:` the metrics from B1/B3; `checkerMetrics: nil`

Note `regenerate` overwrites the per-backend staging file but each run still
inserts its own row — that is intended, and is what makes run history useful.

### Task B6 — the two landmines this creates

Both are caused by v1 rows appearing in a table that previously held only v2 runs.
Neither is optional.

1. **`hasV2Artifacts` (`SummaryService.swift:99`) will start lying.** It returns
   true if `SummaryRunStore().hasRuns(forTranscriptID:)` is true — which will now
   be true for v1-only transcripts. **It currently has zero callers** (verified:
   `grep -rn hasV2Artifacts` finds only the definition). Either delete it as dead
   code, or add `AND pipeline = 'v2'` to a new `hasRuns(forTranscriptID:pipeline:)`.
   Deleting is cleaner — do that unless you find a caller.
2. **The v2 run picker will list v1 runs.** `SummaryMarkupReviewView.swift:34`
   loads `runStore.runs(forTranscriptID: item.url.path)` unfiltered. Filter to
   `pipeline == .v2` there, so the markup pane's run history stays coherent.

Note that `isV2Review` (`HistoryView.swift:180-183`) gates on the `.v2.md`
filename suffix, **not** on run rows — so the markup UI will not wrongly engage
for v1 transcripts. Leave it alone.

### Task B7 — display

`SummaryDurationFormat` (`SummaryComparison.swift:3`) already exists with tests
(`ParleyTests/SummaryDurationFormatTests.swift`) — reuse it, do not write another
formatter. `ClaudeConnectionView.swift:133-136` already has a `costSuffix` money
formatter (4dp under $0.01, else 2dp) — match that convention.

Add a compact metrics line in three places:

1. **v1 review pane** — `HistoryView.swift`, in the header row above
   `TranscriptPreviewView` (near `:540-548`). One line, secondary caption style.
2. **v2 markup review** — `SummaryMarkupReviewView.swift`, near the existing
   header (`:91`). Show the **total** across both legs, with the writer/checker
   split available — a `.help()` tooltip is enough; do not build a disclosure UI.
3. **v2 run picker label** — `runLabel(_:)` (`SummaryMarkupReviewView.swift:367-372`)
   currently renders `"<date> — <writer> → <checker>"`. Append **duration only**
   (`" · 1m 12s"`) so runs are comparable at a glance. Do **not** append the full
   metrics string — with two backend names the label is already long, and this is
   a picker row.

Format: `1m 12s · 48.2k tokens · ~$0.031 est.` — omit the cost clause entirely
when unknown rather than printing `$0.00`, and drop `est.` when the figure is
Claude's real `total_cost_usd`.

---

## Workstream C — rename Classic → Summary v1

### Hard constraint

`SummaryPipeline.classic`'s **rawValue is persisted** (`parley.summaryPipeline` =
`"classic"`, confirmed present in this user's plist) **and** re-read as a raw
string off the main actor at `TranscriptStore.swift:388`. Changing the rawValue
silently resets every user's pipeline choice to the default.

### Scope: display strings only

- `AppSettings.swift:199` — `"Classic (single backend)"` → `"Summary v1 (single backend)"`
- `SettingsView.swift:199` — the picker description: `"Classic runs one backend."`
  → `"Summary v1 runs one backend."`
- Leave `case classic` and its rawValue untouched.
- Sweep for any other user-visible "Classic" string; internal identifiers,
  comments, and code references stay as `.classic`.

Renaming the enum case to `v1` with a rawValue migration is a **separate task** —
do not fold it in.

---

## Tests

`ParleyTests`, XCTest + `@testable import Parley` (this project does not use
Swift Testing). Match existing style.

**A — filing:**
- `testV2FilingDeletesAudioWhenEnabled` / `…RespectsSettingOff` — the core
  regression. Use a temp session dir; assert removal and that frontmatter `audio`
  is nil'd.
- `testFilingClearsAQueuedRerun` — pins the *edge case*, not the common path:
  enqueue a re-run while a staged note awaits review, file it, assert the item
  is gone from `pendingSummaryIDs`. Do not write a test asserting v2 filing
  normally removes a queued item — it is never queued at that point, so such a
  test would pass vacuously and pin the wrong behaviour.
- `testRefilingWithDeletedAudioIsNoOp` — idempotency, since the fix relies on it.

**B — parsing (use the real captured envelopes above as fixtures):**
- `testCursorParseUsage` — the real Cursor JSON; assert 13596/29/5957/0 and
  `apiDurationMS == 3130`.
- `testGrokParseUsage` — the real Grok JSON; assert tokens and that
  `modelUsage` supplies `model == "grok-4.5"`.
- `testParseUsageReturnsNilWhenAbsent` — for both, so "no data" ≠ "zero".
- `testPricingUnknownModelReturnsNil` — guards against a bogus $0.00.
- `testPricingEstimateIsProportional` — do **not** assert exact dollar values;
  prices change and the test would rot. Assert relationships (double the output
  tokens → double the output component).

**B — store:**
- `testV1RunRoundTripsWithMetrics` — insert a `.classic` row, read it back.
- `testExistingRowsDefaultToV2Pipeline` — the backfill. Insert via raw SQL
  without the new columns, then read through the store.
- `testRunPickerExcludesV1Runs` — pins landmine 2.

**C:** no test — display strings only.

## Verification

1. `xcodegen generate && xcodebuild test -project Parley.xcodeproj -scheme Parley -destination 'platform=macOS,arch=arm64'` — authoritative over SourceKit.
2. `tools/localrelease.sh` (preserves TCC, keychain, ANE cache).
3. **Manual, workstream A:** record or pick a note with audio → Settings → confirm
   "Delete audio after committing its summary" is on → file via v2 → confirm the
   session folder under Recordings is gone and frontmatter `audio` is cleared.
   Repeat via Compare. Then confirm v1 still deletes (regression).
4. **Manual, workstream B:** run one summary on each pipeline; confirm the metrics
   line appears in both review panes with a plausible duration. Confirm a Claude
   run shows an unmarked dollar figure and a Cursor run shows `est.`
5. **Manual, migration:** launch against the **existing** `Parley.sqlite` (do not
   delete it) and confirm prior v2 runs still load in the run picker.

## Out of scope

- Renaming `SummaryPipeline.classic`'s enum case or rawValue.
- Aggregate/lifetime cost reporting or a spend dashboard.
- Making `SummaryComparison` record runs into `summary_runs`.
- Changing `ClaudeUsageStore` or `ClaudeConnectionView`'s existing totals.
- Retrofitting metrics onto historical runs — they have no data; show nothing.
- A structural validator for checker hunks (still open from the previous plan).

## Commit

Develop directly on `main` — no feature branch, no PR. Three commits, in order.

**Land and verify A before starting B.** A is an independent bug fix that should
not wait on the feature, and the two touch adjacent code: A's `finishFiling`
refactor reshapes `commit`/`commitGeneratedMarkdown`, while B3's timing wrapper
and B5's row insertion both land inside the `case .success` block of `runNext()`.
Sequencing them avoids reconciling two rewrites of the same region.

1. `Summary: fix v2/Compare filing not reclaiming session audio`
2. `Summary: record generation time and estimated cost for both pipelines`
3. `Summary: rename the Classic pipeline to Summary v1 in the UI`

End each with `Co-Authored-By: Claude <model name>` (no email), per the user's
global convention.
