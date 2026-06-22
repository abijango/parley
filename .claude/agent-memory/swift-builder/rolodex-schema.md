---
name: rolodex-schema
description: Contact/Side schema, parser state machine, normalize/dedupe implementation details for VaultDirectory
metadata:
  type: project
---

## Contact shape (as of 2026-06-12, updated slice 8a)

```swift
struct Contact: Equatable {
    let name: String
    let company: String?      // nil for Other/before-any-section
    let side: Side            // .internalTeam | .customer | .other
    let title: String?        // opaque trailing text; nil when absent (NOT empty string)
    let linkedin: String?
    var aliases: [String] = []  // other observed display names; sorted for determinism
    var displayRole: String { title ?? "" }  // backward-compat alias
}
enum Side: String, Equatable, CaseIterable { case internalTeam, customer, other }
```

IMPORTANT: `aliases` is a `var` with default `[]` (not `let`) so all existing init call sites compile unchanged. The memberwise init gains `aliases:` as a last parameter with default.

## Parser state machine (parseContacts)

Heading lines (starting with `#` OR non-bullet bare lines OR colon-suffix lines):
- `"Customers"` (any case) -> customerMode = true, no company emitted
- `"Other"` (any case) -> customerMode = false, side = .other, company = nil
- `"Intellias"` OR `"Intellias Team"` -> customerMode = false, company = "Intellias", side = .internalTeam
- `## Foo` (level 2) -> customerMode = false, company = "Foo", side = .internalTeam
- `### Bar` (level 3) -> company = "Bar", side = .customer
- bare/colon level-0 -> customerMode ? .customer : .internalTeam (does NOT exit customerMode)

Key insight: bare headings do NOT exit customer mode. Only canonical ## or Intellias/Other headings reset it.

## Bullet extraction (extractBulletFields)

Priority: **bold** > [link](url) > plain split on " - " (space-dash-space preserves hyphenated names).
Empty title after strip -> nil (not empty string). Stray chars after ")" in link form are dropped.

## Near-duplicate detection (isNearDuplicate)

`longer.lowercased().hasPrefix(shorter.lowercased())` MUST be true BEFORE checking the suffix is "(...)".
The previous version lacked the prefix check, producing false positives (e.g. Kirill Velikanov vs Tushara Fernando (London)).

## Normalize function name collision

`VaultDirectory` already had `private static func normalize(_ s: String) -> String` for reconciliation.
Renamed to `collapsedKey` to allow the public `normalize(_ text: String) -> (canonical: String, report: String)`.

## loadFileCustomers

Now derives customer companies from `contacts.filter { $0.side == .customer }` rather than scanning
for colon headers. Eliminates incorrect inclusion of "Other" and internal sections.

**Why:** to preserve correctness with the new side model, ensuring fileCustomers matches the
canonical definition of customer contacts.

## Real-file preview (2026-06-12, after slice 8a)

- Input: 177 contacts, Output: 165 (12 total: 9 name-merge + 1 linkedin-merge + 1 explicit drop + 1 Christina merge)
- Internal: 75, Customer: 67, Other: 23
- LinkedIn-merge: Tushara Fernando (London) + Tushara Fernando -> Tushara Fernando
- Explicit drop: "Dubhashi" orphan
- Title rewrites: "Partnership Director, Intellias" -> "Partnership Director"; "Head of Revenue Operations, IG Group" -> "Head of Revenue Operations"; "AWS" under AWS -> nil
- Christina merge: "Christina Wharf" + "Christina Wharf-Bulsara" -> authoritative entry with linkedin + alias
- Christina canonical line: `- [Christina Wharf-Bulsara](https://www.linkedin.com/in/christina-wharf-bulsara-1860353b/) (aka Christina Wharf) - Partnership Director`
- No near-dup pairs remain
- Preview: /Users/naufalmir/Vaults/ObsidianVault/Rolodex.normalized.md
- Report: /Users/naufalmir/Vaults/ObsidianVault/Rolodex.normalize-report.md
- Rolodex.md: SHA 7a01a48f69c0916ebcf3c87979c1e2cfdfacc71dd8e8f56b17864124de36c3b8 (UNCHANGED)

## User-approved auto-cleanups in normalize(_:) (2026-06-12)

### Rule 1: LinkedIn-merge (after name-merge, before near-dup)
- normalizedLinkedinKey(_:): lowercase, strip scheme (http/https), strip www., strip trailing /
- mergeByLinkedin(_:_:): prefer name without trailing parenthetical; longer title wins
- Guards: nil/empty linkedin -> never grouped (prevents unrelated contacts collapsing)

### Rule 2: Dubhashi targeted drop
- Exact case-insensitive name == "Dubhashi" filter only; does not touch other Other entries

### Rule 3: Redundant company suffix strip
- Strip ", <SectionCompany>" from title when it case-insensitively matches contact.company
- Does NOT fire when trailing company differs (e.g. "Account Manager, ProAg" under Intellias safe)
- Applied as map on deduped array BEFORE renderCanonical (keeps renderer pure)

### Rule 4: Title equals company blank
- After Rule 3, title case-insensitively equal to section company -> nil

## Slice 8a: Aliases system (2026-06-12)

### Contact.aliases
`var aliases: [String] = []` added last in the struct. Parsed from `(aka A, B)` after the name token; stored sorted. Rendered in bulletLine as ` (aka A, B)` between name markup and title.

### (aka ...) parsing
`extractAka(_ rest: String) -> (aliases: [String], remainder: String)`: called from `extractBulletFields` after the name capture (for bold and link forms). Detects `(` followed by `aka` (ci) as the delimiter. Plain split does NOT support aka (no need; plain bullets are legacy). TRAP: `extractLink`'s stray-char code originally stripped `(` -- fixed to guard `!rest.hasPrefix("(")` so `(aka ...)` survives.

### extractBulletFields return type
Changed from `(name: String, title: String?, linkedin: String?)` to `(name: String, title: String?, linkedin: String?, aliases: [String])`. Three call sites updated: `parseContacts`, `extractName`, `trailingRole`.

### Index building (refresh())
Both `companyIndex` and `sideIndex` now register all aliases as additional keys (same company/side as canonical). `people` list also includes alias display names. `VaultDirectory.company(for: "Christina Wharf")` -> "Intellias" after parsing a contact with that alias.

### SummaryPromptBuilder.annotate()
Also indexes aliases in its local `companyIndex`. Independent of `refresh()`.

### Normalize pipeline (after slice 8a)
Order: Step 1 (name-merge) -> Step 1b (alias-merge) -> Step 2 (linkedin-merge) -> Step 2b (explicit Christina) -> Step 3 (Dubhashi drop) -> Step 4 (title rewrites) -> Step 5 (near-dup detection).

**alias-merge (Step 1b)**: if A.name == any B.alias or B.name == any A.alias, merge them; the non-alias entry is canonical; union alias sets. Only fires when `(aka ...)` tags are present in source.

**explicit Christina merge (Step 2b)**: unconditional directive. Removes both "Christina Wharf" and "Christina Wharf-Bulsara" entries (if present), inserts authoritative: name=Wharf-Bulsara, title="Partnership Director", linkedin=`https://www.linkedin.com/in/christina-wharf-bulsara-1860353b/`, aliases=["Christina Wharf"].

### addAlias(_:toCanonical:) instance method
Surgical line-level rewrite: finds the bullet, adds alias to `(aka ...)` set idempotently, rewrites that one line (canonicalizes markup for that bullet), writes file, refresh(). Does NOT reparse/render the whole file (live-writer switch is still pending approval in a later slice).

### mergeByLinkedin / mergeGroup
Both now union alias sets across merged entries. Aliases from all input contacts are merged; canonical name excluded from alias set.

## Slice 7: Live-writer switch (2026-06-12)

### Write path: parse->mutate->render
`upsertPerson` and `addPeople` now use parse->renderCanonical. Do NOT call `normalize()` in the writer -- that pipeline has destructive directives (Christina merge, Dubhashi drop) that should only run during the one-time cleanup, not on every write.

### Side inference for upsert
`sideFor(company:in:)` static helper: iterates parsed contacts, returns side of first contact whose company ci-matches. No match -> .customer (brand-new external company default). Empty company -> .other.

### Title encoding
`titleStr = "\(title), \(company)"` or just title or just company if one is absent. Stored in Contact.title, which renderCanonical emits verbatim after " - ".

### Alias-matched upsert preserves canonical
When the match is via alias (not canonical name), the canonical name and all existing aliases and existing linkedin are PRESERVED. Only title/company/linkedin are updated. This prevents silent data loss (e.g. upserting "Christina Wharf" must not flip canonical to "Christina Wharf" or lose the linkedin URL).

### annotate side-aware
`annotate` now builds `Entry { companies: Set<String>, side: Side }`. Internal -> "(Company)". Customer -> "(Company, customer)". The ", customer" label tells Claude who is external.

### writeContacts overloads
`writeContacts(_ lines: [String])` (legacy for addAlias line-surgery) + `writeContacts(_ text: String)` (for render path).

## Slice 8b: Confirm-to-link UX (2026-06-12)

### VaultDirectory.contacts stored property
Added `@Published private(set) var contacts: [Contact] = []`; stored in `refresh()` from the already-parsed local `contacts` array. Previously the array was local-only; now persisted so UI can call `suggestMatches`.

### suggestMatches ranking (nonisolated static + thin instance wrapper)
`static func suggestMatches(for:in:limit:) -> [Contact]`. Fast-path: if exact name/alias hit, return [].
Tokenisation: lowercase, replace `-` with space, split by space -> Set<String>.
Scoring: 3=queryTokens subset of cTokens OR vice versa; 2=shared surname token (last whitespace token after hyphen-normalisation); 1=shared first token. 0=excluded. Tie-break: ascending name.
Key insight: hyphen-normalisation makes `{christina,wharf}` subset of `{christina,wharf,bulsara}` -> the named Christina case passes.

### RecordingController.linkAttendeeToExisting
Calls `vault.addAlias`; removes matching row from `pendingEnrichment.rows`; if rows empty calls `finishEnrichment(save: true)` (not direct nil-assignment -- must route through finishEnrichment to fire deferred summary).

### AttendeeEnrichmentSheet suggestion chips
`@State var dismissedSuggestions: Set<String>` per-row dismiss state.
`suggestionChips(rowName:suggestions:)` shows HStack of capsule buttons + "Not a match" dismiss.
Chip tap -> `linkAttendeeToExisting` (removes row). "Not a match" -> inserts rowName into dismissed set.

### AssignSpeakersView fuzzy matching
Replaced rolling-substring `vault.people.filter` with `recording.vault.suggestMatches(for: d)` returning `[Contact]`.
New `assignSuggestion(_:suggestion:typedDraft:)`: names speaker canonical + records alias when draft != canonical (ci).
Existing "In this call" attendee buttons and plain-type Submit path unchanged.

## Post-review bug fixes (2026-06-12)

### Plain-split trailing "-" baked into name
Empty-role bullets like `"- Antonio MORISCO - "` (trailing space in source) produce
`"- Antonio MORISCO -"` after outer trim. The space-dash-space split `" - "` never fires
because the separator ends without a trailing space. The parser was returning `"Antonio MORISCO -"`
as the name. Fix: in the plain-split fallback of `extractBulletFields`, strip a dangling trailing `" -"`
from the name component. Added `testTrailingDashNoSpaceAfter` to cover this case.

### Oddity detection must scan raw lines, not cleaned Contact fields
The original oddity scanner ran against the already-cleaned `Contact` struct. The parser's own fixes
(dropping `)i` stray chars, turning trailing `" - "` into nil title) erased the evidence before
detection could fire. Fix: scan `text.components(separatedBy: "\n")` raw lines in `normalize(_:)`,
checking for `\]\([^)]+\)[^\s\-\n]` (stray post-paren char) and `hasSuffix(" -")` (empty role).
The report now has `## Oddities flagged` with 4 SwissQuote empty-role entries + Addy Dubhash `)i`.
