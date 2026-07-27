# Plan — Fix Summary v2 checker grounding (checker deletes rolodex-sourced facts)

**Status:** IMPLEMENTED 2026-07-27 — all 5 tasks + tests. 383 tests pass, 0 failures.
Reviewed independently (verdict: ship-with-notes); all six root causes confirmed fixed.
Not yet committed, and **not yet validated against a real meeting** — see §8.
**Files touched:** 5 source + 2 test files. No schema migration required.

---

## 1. The bug

In Summary v2, the checker (Grok 4.5 via Cursor) proposes deleting correct
attendee titles and restructuring the Attendees table, because it is given
strictly less grounding context than the writer.

Observed output (real run):

```
- | Naufal Mir | Director of AI, FSI | Intellias |          ← checker proposes deleting
- | Asitha Mallawaarachchi | Senior Security Architect | Intellias |
+ | Naufal Mir | Intellias |                                 ← checker's replacement
+ | Asitha Mallawaarachchi | Intellias |
  reason: "Transcript lists attendees by name only; Director of AI /
           Senior Security Architect roles are not stated and must not be invented."
```

Those titles are verbatim from the user's rolodex:

```
/Users/naufalmir/ObsidianVault/Rolodex.md:60   - **Naufal Mir** (aka naufal) - Director of AI, FSI
/Users/naufalmir/ObsidianVault/Rolodex.md:18   - [Asitha Mallawaarachchi](…) - Senior Security Architect, Intellias
```

The writer was **instructed** to use them (`AppSettings.swift:483`: *"use full
name, title, and company where a confident match exists"*). The checker has
never seen the rolodex, so from its point of view the titles are fabricated.
Grok is behaving correctly given the prompt it receives. The prompt is the bug.

### Root causes (three, independent — fixing only one is insufficient)

| # | Cause | Location |
|---|---|---|
| C1 | Checker prompt receives no contacts/rolodex block. Titles have no other source in the pipeline. | `SummaryCheckerPromptBuilder.build` (`Parley/Summary/SummaryCheckerPromptBuilder.swift:41`) — signature is `(transcript, draft, terminologyBlock)` only |
| C2 | The transcript handed to the checker has its YAML frontmatter stripped, and `attendees:` lives in that frontmatter. The checker sees only `Me` / `Speaker N` — no roster at all. | `SummaryPromptBuilder.readTranscript` (`:119`) → `strippingFrontmatter` (`:142`); roster written at `TranscriptStore.swift:209` |
| C3 | The checker never receives the writer's section contract, so it does not know `Name \| Role \| Company` is mandatory. Its "fix" **drops the Role column entirely** and also drops the `(customer)` marker — restructuring the note away from the app's own output format. | Writer spec at `AppSettings.swift:499-510`; never passed to checker |

Note on C1: passing only the *annotated attendee roster* would **not** fix
this. `SummaryPromptBuilder.annotate` (`:76`) emits company and the
`, customer` suffix but **never** `Contact.title`. The full contacts block is
the necessary payload — titles only exist there.

### Why this is high severity, not cosmetic

Hunks are created `.pending`, and `SummaryHunkEngine.mergedMarkdown` applies
only `.accepted` — so the staged file on disk is the clean draft. **But the
review UI treats pending as accepted:**

- `SummaryMarkupReviewView.swift:43-45` — `workingBody` promotes every
  `.pending` hunk to `.accepted` for the preview
- `SummaryMarkupReviewView.swift:544-545` — `acceptAndFile()` does the same
  before writing to the vault

The strikethrough is therefore **opt-out, not opt-in**. Pressing "Accept &
File" without explicitly rejecting each bad hunk writes the de-titled table
into the Obsidian vault.

### Two writer defects in the same table (fix together)

A checker-only fix will look like it failed, because these rows are genuinely
wrong and a correctly-grounded checker would still (rightly) flag them:

```
| Radoslav Stefanov | Man Group | Man Group (customer) |
| Batuhan Ceylan    | Man Group | Man Group (customer) |
```

- **W1 — company leaked into the Role column.** Radoslav and Batuhan have no
  title in the rolodex (`Rolodex.md:185`, `:198`), so the writer put the
  company in Role. The template never says what to do with an unknown role.
- **W2 — `(customer)` printed into the note.** That suffix is prompt plumbing
  telling the writer the person is external (`AppSettings.swift:490`); it is
  not meant to be rendered.

### Constraint

There is no settings escape hatch: `AppSettings` has `summaryCheckerBackend`
(`:357`) but **no** `summaryCheckerPromptTemplate`. The checker prompt is
hardcoded in `SummaryCheckerPromptBuilder.defaultInstructions`. This requires
a code change.

The asymmetry is specific to the v2 checker leg — `SummaryCompareView.swift:94`
already builds its prompt with attendees.

---

## 2. Design decisions (pre-agreed — do not re-litigate)

1. **Give the checker the same grounding the writer had**, via the same
   builder inputs: contacts block, annotated attendees, destination. Do *not*
   invent a second contacts-reading path — reuse `SummaryPromptBuilder`'s
   readers so writer and checker can never drift.
2. **Rewrite the checker instructions to enumerate permitted sources.** This
   is not optional. `defaultInstructions` currently names the transcript as
   sole ground truth twice ("not supported by the transcript", "absent from
   the transcript"). Adding the contacts block while leaving that wording in
   place still licenses the deletion.
3. **Add a structural-integrity rule**: the checker may not add, remove, or
   reorder sections or table columns.
4. **Make the checker prompt user-editable** (`summaryCheckerPromptTemplate`),
   mirroring `summaryPromptTemplate`. Same reason: the writer prompt is
   tunable, and a hardcoded checker prompt means every future grounding
   regression needs a rebuild.
5. **Pending hunks must no longer file silently.** Default-accept on an
   unreviewed hunk is the mechanism that turns a prompt bug into vault
   corruption. Chosen fix: keep "Accept & File" applying pending hunks (that
   is what the button says), but require explicit confirmation when any hunk
   is still `.pending`, and surface the pending count on the button. Do **not**
   silently flip the default to reject — that would discard good edits and
   confuse the existing preview.
6. Fix W1 and W2 in `defaultSummaryPrompt` in the same change.

---

## 3. Implementation

### Task 1 — Extend `SummaryCheckerPromptBuilder`

**File:** `Parley/Summary/SummaryCheckerPromptBuilder.swift`

Replace `defaultInstructions` and widen `build`.

New instruction text — the key change is the **Authoritative sources** block
replacing the transcript-only framing:

```swift
static let defaultInstructions = """
You are a meticulous meeting-note editor. You receive the same source material \
the writer received — a transcript, a contacts rolodex, and a supplied attendee \
list — plus the draft summary the writer produced. Propose precise edits to \
improve fidelity, completeness, and clarity.

Authoritative sources — a fact is supported if it appears in ANY of these, not \
just the transcript:
- TRANSCRIPT — what was said. The only source for decisions, action items, \
figures, dates, and commitments.
- CONTACTS ROLODEX — authoritative for people's full names, job titles, and \
company affiliations. A title or company that appears here is a VERIFIED FACT. \
Do NOT flag it as invented, and do NOT delete it merely because the transcript \
did not state it out loud. Titles are almost never spoken in a meeting; that is \
exactly why the rolodex is provided.
- SUPPLIED ATTENDEES — authoritative for who was present and (where annotated \
in parentheses) their company. Never override an annotated company from the \
transcript.

Structural rules — the draft follows a required note format. You must NOT:
- add, remove, rename, or reorder any `##` section;
- add, remove, or reorder columns in any Markdown table (the Attendees table is \
`Name | Role | Company`; the Action Items table is \
`Action | Owner | Due / Timeframe | Priority`);
- convert a table to prose or a list, or vice versa.
If a single cell is wrong or unsupported, replace that cell's content — or blank \
it — but keep the table shape intact.

Output ONLY valid JSON (no markdown fences, no commentary) in this shape:
{
  "edits": [
    {
      "op": "replace",
      "target": "exact substring from the draft to replace",
      "text": "replacement text",
      "reason": "why this change is needed"
    },
    {
      "op": "insert",
      "after_anchor": "exact substring after which to insert",
      "text": "text to insert",
      "reason": "why"
    },
    {
      "op": "delete",
      "target": "exact substring to remove",
      "reason": "why"
    }
  ]
}

Rules:
- `target` / `after_anchor` must match the draft verbatim (copy-paste exact).
- Prefer small, surgical edits over rewriting whole sections.
- Do not add decisions, dates, metrics, owners, or commitments that are absent \
from the transcript.
- Do not remove a name, title, or company that is present in the contacts \
rolodex or the supplied attendee list.
- If the draft is already faithful, return `{ "edits": [] }`.
"""
```

New `build` signature — **keep the parameters defaulted** so existing callers
and tests compile unchanged:

```swift
static func build(transcript: String,
                  draft: String,
                  contacts: String = "",
                  attendees: String = "",
                  destination: String = "",
                  terminologyBlock: String = "",
                  instructions: String = defaultInstructions) -> String
```

Assembly order (put the draft last so it is closest to the ask, and label
every block so the instruction text's references resolve):

1. `instructions`
2. `CONTACTS ROLODEX:` + contacts — emit `(no contacts file found)` when empty,
   matching `SummaryPromptBuilder`'s wording
3. `SUPPLIED ATTENDEES:` + attendees — emit `(none provided)` when empty
4. `Filing location (context only, do not output):` + destination — omit the
   block entirely when empty
5. Terminology glossary (unchanged from today, only when non-empty)
6. `TRANSCRIPT:` + transcript
7. `DRAFT SUMMARY:` + draft

Keep `parts.joined(separator: "\n\n")`.

### Task 2 — Thread the context through `runV2`

**File:** `Parley/Summary/SummaryService.swift`, `runV2` (`:514-643`)

Everything needed is already in scope — `runV2` builds the writer prompt from
exactly these inputs at `:520-528`. Do **not** re-read the rolodex; hoist the
values the writer used so the two prompts are provably identical inputs.

Before the `Task.detached` at `:540`, alongside the existing
`let transcriptText = ...` at `:538`, add:

```swift
let contactsText = SummaryPromptBuilder.readContacts(settings.contactsURL,
                                                     dbContacts: dbContacts)
let attendeesText = SummaryPromptBuilder.annotate(
    attendees: item.meta.attendees.joined(separator: ", "),
    contacts: SummaryPromptBuilder.parseContactsList(contactsText))
let checkerInstructions = settings.summaryCheckerPromptTemplate
```

Then at the `checkerPrompt` construction (`:579`):

```swift
let checkerPrompt = SummaryCheckerPromptBuilder.build(
    transcript: transcriptText,
    draft: draft,
    contacts: contactsText,
    attendees: attendeesText,
    destination: item.meta.filing,
    terminologyBlock: terminology,
    instructions: checkerInstructions
)
```

**Concurrency note:** `runV2` is `@MainActor` and `Task.detached` captures the
new values as immutable `let` `String`s — same pattern as the existing
`claudeBinary` / `transcriptText` hoists at `:529-538`. Do not capture
`settings` into the detached task; hoist the fields you need, as the existing
code already does. `item` **is** already captured inside the detached block
(`:557`, `:568`, `:606`, `:630`) and that is fine — read `item.meta.filing`
directly at the call site, no hoist needed.

**Careful:** `attendeesText` must be the *annotated* form (`Naufal Mir
(Intellias)`), not the raw comma-join, so the checker sees the same
`, customer` semantics the writer's instructions describe. `annotate` is
`static` and pure — safe to call before the hop.

### Task 3 — Make the checker prompt editable

**File:** `Parley/Settings/AppSettings.swift`

1. Add key next to `summaryPromptTemplate` (`:256`):
   ```swift
   static let summaryCheckerPromptTemplate = "parley.summaryCheckerPromptTemplate"
   ```
2. Add storage next to `summaryPromptTemplate` (`:469`):
   ```swift
   /// Instruction block for the Summary v2 checker. Unlike the writer template this
   /// takes no `{{…}}` tokens — the transcript, contacts, attendees, and draft are
   /// appended by `SummaryCheckerPromptBuilder`. Editable in Settings → Summary.
   @AppStorage(Key.summaryCheckerPromptTemplate) var summaryCheckerPromptTemplate: String
       = SummaryCheckerPromptBuilder.defaultInstructions
   ```

**Migration hazard — read this.** `@AppStorage` returns the stored value once
one exists, so a user who has already run v2 is *not* affected here (this key
has never been written, so they get the new default). But once shipped, a user
who edits the prompt is pinned to their edit forever. Mirror the writer's
existing affordance: a "Reset to default" button (see Task 4) is the required
escape hatch. No versioned-migration machinery needed.

**File:** `Parley/UI/SettingsView.swift`

In `summaryTab`, next to the existing writer-prompt editor (`:318-321`), add a
v2-gated section:

```swift
if settings.summaryPipeline == .v2 {
    Section("Checker instructions") {
        helpText("Rules the checker follows when reviewing the writer's draft. The transcript, contacts, attendees, and draft are appended automatically — no {{tokens}} here.")
        editorStyle(TextEditor(text: $settings.summaryCheckerPromptTemplate), height: 220)
        HStack {
            Spacer()
            Button("Reset to default") {
                settings.summaryCheckerPromptTemplate = SummaryCheckerPromptBuilder.defaultInstructions
            }
        }
    }
}
```

Match the surrounding `editorStyle` / `helpText` / `SettingRow` helpers exactly
— do not introduce new styling.

### Task 4 — Stop pending hunks filing unreviewed

**File:** `Parley/UI/SummaryMarkupReviewView.swift`

Leave `workingBody` (`:41-47`) alone. Note that it is a *different* renderer
from `SummaryHunkEngine.previewSegments` — `previewSegments` produces the
strikethrough markup seen in the bug report, while `workingBody` is the plain
preview/edit text. Keeping `workingBody`'s pending→accepted promotion is correct
precisely because that pane should show exactly what will be filed; the fix is
to gate filing, not to desync the preview from it.

Change the **file** path:

1. Add state: `@State private var showPendingConfirm = false`
2. Compute: `private var pendingCount: Int { hunks.filter { $0.status == .pending }.count }`
3. In `footer` (`:356-359`), route through a guard and surface the count:
   ```swift
   Button {
       if pendingCount > 0 { showPendingConfirm = true } else { acceptAndFile() }
   } label: {
       Label(pendingCount > 0 ? "Accept & File (\(pendingCount) unreviewed)"
                              : "Accept & File",
             systemImage: "tray.and.arrow.down")
   }
   .glassProminentButton()
   ```
4. Add a `.confirmationDialog` (or `.alert`, matching whatever this file
   already uses for destructive confirms — check `discard`'s treatment first
   and be consistent):
   - Title: `"\(pendingCount) checker edit\(pendingCount == 1 ? "" : "s") not reviewed"`
   - Message: "Filing now applies them to the note. Reject the ones you don't want first."
   - Buttons: `Apply and file` (default action → `acceptAndFile()`),
     `Cancel`.

Do not change `acceptAndFile()`'s body — its pending→accepted flip is now
explicitly confirmed rather than silent.

### Task 5 — Fix the two writer defects

**File:** `Parley/Settings/AppSettings.swift`, `defaultSummaryPrompt`
Attendees section (`:499-510`).

Add to the Attendees parenthetical, after the existing `(inferred)` rules:

- **W1:** "The Role column is for a person's job title only. If no title is
  known from the contacts list and none is stated in the transcript, leave
  Role **blank** — never put a company name, team name, or the word
  \"Attendee\" in the Role column."
- **W2:** "The `, customer` suffix in the supplied attendee list is context
  for you only — it tells you the person is external. Never print
  `(customer)`, `, customer`, or any similar marker in the note. The Company
  column contains the company name alone."

**Migration: verified a non-issue.** `@AppStorage` only writes to UserDefaults
when the value is *set*, so a never-edited template has no stored value and
picks up the new default automatically. Confirmed for this user:

```
$ defaults read com.naufalmir.parley "parley.summaryPromptTemplate"
The domain/default pair of (com.naufalmir.parley, parley.summaryPromptTemplate) does not exist
```

So editing `defaultSummaryPrompt` is sufficient — no reset, no user action, no
migration shim. (The same holds for the new checker key in Task 3, which has
never existed.) Do **not** add code that rewrites a stored template in place;
if a user *has* customised their prompt, the existing "Reset to default" button
is the correct and only escape hatch.

---

## 4. Tests

**File:** `ParleyTests/SummaryV2Tests.swift` (extend; match the existing
`XCTest` + `@testable import Parley` style — this project does not use Swift
Testing here).

```swift
func testCheckerPromptIncludesContactsAndAttendees()
```
Build with a contacts block containing `- **Naufal Mir** (aka naufal) - Director of AI, FSI`
and attendees `Naufal Mir (Intellias)`. Assert the prompt contains:
`CONTACTS ROLODEX`, `Director of AI, FSI`, `SUPPLIED ATTENDEES`,
`Naufal Mir (Intellias)`.

```swift
func testCheckerPromptSectionOrder()
```
Assert index-ordering: instructions < `CONTACTS ROLODEX:` <
`SUPPLIED ATTENDEES:` < `TRANSCRIPT:` < `DRAFT SUMMARY:`. Use
`range(of:)?.lowerBound` comparisons — mirror the existing
`testTerminologyPromptInjection` (`:71-72`) which already does this.

```swift
func testCheckerPromptEmptyContextPlaceholders()
```
Build with only `transcript` + `draft`. Assert `(no contacts file found)` and
`(none provided)` appear, and that no `Filing location` block is emitted.

```swift
func testCheckerInstructionsPermitRolodexFacts()
```
**Deliberate tripwire — not a behavioural test.** Assert `defaultInstructions`
contains `"CONTACTS ROLODEX"` and does **not** contain the old
`"not supported by the transcript"` phrase. Its only job is to make a future
reword that silently reinstates transcript-only framing fail loudly. Add a
comment in the test body saying so, so whoever hits the failure knows to
re-read this plan's §2 decision 2 and then update the assertion rather than
"fixing" the prompt back.

Do **not** add further string-matching tests on prompt wording (no assertions
on `"VERIFIED FACT"`, on the column-rule phrasing, or on
`defaultSummaryPrompt`'s W1/W2 text). They pin prose that is expected to be
tuned, and would break on rewordings that are perfectly correct. The three
builder tests above plus this one tripwire are the coverage; W1/W2 are verified
manually in §5.

**File:** `ParleyTests/SummaryPromptBuilderTests.swift`

```swift
func testAnnotateMatchesCheckerInput()
```
Assert `annotate` output for a customer contact is
`Radoslav Stefanov (Man Group, customer)` — this is the exact string now fed
to the checker, so pin it. (Check whether an equivalent assertion already
exists in this file first; extend rather than duplicate.)

---

## 5. Verification

1. **Unit tests (authoritative):**
   ```
   xcodegen generate
   xcodebuild test -project Parley.xcodeproj -scheme Parley \
     -destination 'platform=macOS,arch=arm64'
   ```
   Ignore SourceKit/IDE diagnostics that disagree with `xcodebuild`.

2. **Build:** `tools/localrelease.sh` (per CLAUDE.md — preserves TCC grants,
   keychain, and the ANE cache).

3. **End-to-end regression, using the meeting from the bug report:**
   - Settings → Summary → confirm Pipeline = Summary v2, Checker = Grok 4.5.
   - History → the 4-attendee Intellias / Man Group note → **Regenerate**.
     (No prompt reset needed — see Task 5.)
   - **Expected:** no hunk proposing deletion of `Director of AI, FSI` or
     `Senior Security Architect`. No hunk that rewrites the Attendees table to
     two columns.
   - **Expected:** Radoslav/Batuhan rows now read
     `| Radoslav Stefanov |  | Man Group |` — blank Role, no `(customer)`.
   - Inspect the raw checker output to confirm the model saw the context:
     `SummaryRunStore().run(id:)` → `checkerRaw`, or the run picker label in
     the review pane. If `checkerRaw` shows the model still complaining about
     unstated titles, the instruction text — not the plumbing — needs another
     pass.

4. **Confirm the new file guard:** with at least one pending hunk, press
   "Accept & File" → confirmation dialog appears and names the count; Cancel
   leaves the vault untouched.

5. **Manual sanity on the real vault:** the note filed to Obsidian must retain
   the three-column Attendees table.

---

## 6. Out of scope — do not do these

- Un-stripping YAML frontmatter from the transcript (C2). Passing the
  annotated roster explicitly is the cleaner fix; changing
  `readTranscript` would also alter the *writer's* input and every
  compare-view run. Leave `strippingFrontmatter` alone.
- Any change to `SummaryHunkEngine`, `SummaryEditJSONParser`,
  `KnowledgeDatabase` schema, or `SummaryRunStore`.
- Adding a structural validator that programmatically rejects
  column-changing hunks. Worth considering later as defence-in-depth
  (the prompt is the primary fix); raise it as a follow-up, don't build it.
- The "your writer prompt is out of date" Settings hint (Task 5) — ask the
  user first.
- `SummaryCompareView` — it already passes attendees and is not affected.

---

## 7. Commit

Single commit on `main` (this project develops directly on main — no feature
branch, no PR).

Suggested message:

```
Summary v2: give the checker the writer's grounding context

The checker only received the transcript and the draft, so rolodex-sourced
attendee titles looked fabricated and it proposed deleting them — along with
the whole Role column, since it never saw the required note format either.

- SummaryCheckerPromptBuilder now takes contacts, attendees, and destination,
  and its instructions name the rolodex and attendee list as authoritative
  rather than treating the transcript as sole ground truth.
- Added a structural rule: no adding/removing/reordering sections or table
  columns.
- Checker instructions are now editable (parley.summaryCheckerPromptTemplate)
  with a Reset to default, mirroring the writer prompt.
- Filing with unreviewed hunks now requires confirmation — pending hunks were
  applied silently on Accept & File.
- Writer prompt: Role is a job title only (blank when unknown, never the
  company), and the ", customer" annotation is never printed into the note.

No migration needed: neither template has ever been written to UserDefaults, so
@AppStorage serves the new defaults. Stored templates are never rewritten in place.

Co-Authored-By: Claude
```

---

## 8. Implementation notes (filled in 2026-07-27)

### Deviations from the plan, all deliberate and reviewed

- **W2 wording narrowed.** The plan said "never print `(customer)` or any
  similar marker". Taken literally that would also suppress the pre-existing
  ` (inferred)` provenance tag the same parenthetical mandates two sentences
  earlier. The shipped rule forbids "external-party markers" and names
  ` (inferred)` as the sole permitted Company-column addition.
- **Confirm idiom.** Plan said to mirror `discard`'s treatment — `discard` has
  no confirmation at all. `grep` found zero `.alert(` in `Parley/UI/` and
  `.confirmationDialog` in seven places; used that, shaped after
  `PeopleView.swift:61`.

### Review findings, resolved

- *Tautological assertion* — `XCTAssertTrue(prompt.startIndex < contactsIndex)`
  could never fail. Re-anchored on `"Authoritative sources"`. **Fixed.**
- *Empty checker template was a silent footgun* — clearing the new Settings
  editor stripped the JSON output contract, so the backend would answer in
  prose, `SummaryEditJSONParser` would fail, and the run would produce zero
  hunks with no user-visible reason. `build` now falls back to
  `defaultInstructions` on blank/whitespace input, covered by
  `testCheckerPromptFallsBackWhenInstructionsCleared`. **Fixed.**

### Open follow-ups (not done — deliberately out of scope)

1. **Column contract can desync.** The `Name | Role | Company` and
   `Action | Owner | Due / Timeframe | Priority` shapes are hardcoded in
   `SummaryCheckerPromptBuilder.defaultInstructions`, while the writer's
   section spec lives in the now-editable `summaryPromptTemplate`. Editing the
   writer template silently desyncs the checker's structural rule. Cheapest
   guard: a test asserting both strings contain `Name | Role | Company`.
2. **`checkerParseOK == false` is invisible** in the review pane. A broken
   checker run is indistinguishable from "draft already faithful".
3. **Structural validator** rejecting column-changing hunks programmatically,
   as defence-in-depth behind the prompt fix (originally §6).
