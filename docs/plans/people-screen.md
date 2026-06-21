# People screen: unify voiceprints + rolodex identity in one place

> Status: **UNBLOCKED — rolodex cleanup landed as `8bc8df0`** (2026-06-21). The
> `Contact`/`Side` types and `VaultDirectory` contacts API are now committed and
> frozen. Build against them. Reference: `.claude/agent-memory/swift-builder/
> rolodex-schema.md` documents the parser/normalize internals.

## Committed API to build on (as of 8bc8df0)

- `VaultDirectory.contacts: [Contact]` (@Published) and `.people: [String]`
  (names + aliases). `Contact{ name, company:String?, side:Side, title:String?,
  linkedin:String?, aliases:[String] }`.
- `parseContacts(_:) -> [Contact]`, alias-aware `company(for:)` / `side(for:)`.
- Write path: `upsertPerson(name:title:company:linkedin:)`, `addPeople(_:)`,
  `addPerson(...)`, `normalizeContacts(dryRun:stamp:)`.
- **Two gaps the People editor must close:**
  1. **No `aliases` parameter on `upsertPerson`** — it writes name/title/company/
     linkedin only. Editing a person's aliases (the `(aka …)` list) needs either a
     new `VaultDirectory` method or a parse→mutate→render round-trip. Decide during
     slice 3; don't hand-write markdown.
  2. **No `removePerson`/rename primitive** — `upsertPerson(new)` relocates the
     *new* name's bullet but won't delete the *old* name's bullet on a rename. The
     `renamePerson` fan-out (below) needs a remove-by-name in `VaultDirectory`
     (add one) plus the voiceprint rename.

## Goal

A new top-level main-window screen (a sibling of Record and History — NOT in
Settings, which is too cramped for this) that surfaces each **person** in one
place: their identity (name, title, company, LinkedIn) editable and synced to
`Rolodex.md`, alongside their **voiceprint status** (which engines they're
enrolled in, sample/clip info), with per-person voice actions.

## Guiding model: voiceprint is the durable spine, metadata orbits it

A person's voice is stable; their company/title/even name can change. Model it
that way:

- **`Voiceprint.id` (UUID) is the durable identity anchor.** It never changes as
  the person moves companies or gets a new title — embeddings are keyed to the
  voice, not the metadata.
- **Identity metadata (name, title, company, side, LinkedIn) is mutable** and
  lives in `Rolodex.md` as a `Contact`.
- **`name` is the human-readable join key** between the two stores. It's mostly
  stable; the one operation that mutates it must keep both stores in sync.

This is why the two datastores stay **separate but surfaced together** — even
though both now live in the vault (and sync to GitHub), they differ in
sensitivity (biometric vs shareable) and format (an AES-GCM-encrypted binary blob
vs human-editable Markdown). Merging them would force biometric data into the
hand-editable contacts file, or contacts into the encrypted blob — both wrong.

## Architecture: join, don't merge

Two persisted stores, unchanged:

| Store | Owner | Location | Holds |
|---|---|---|---|
| Contacts | `VaultDirectory` | `<vault>/Rolodex.md` | name, title, company, side, linkedin (`Contact`) |
| Voiceprints | `VoiceprintStore` | `<vault>/Parley/Speakers/voiceprints.json` (encrypted) | name, embeddings ×(1–2 engines), clip (`Voiceprint`) |

> **Both stores live in the vault** (which is synced to GitHub — the user's
> backup/versioning mechanism). The voiceprint store **moves into the vault** from
> its old App Support home — see "Storage & sync" below.

A **presentation-layer aggregate** joins them by normalized name at read time —
nothing new is persisted:

```
struct Person {                       // view-model only, not persisted
    let displayName: String           // the join key (case-insensitive)
    let contact: Contact?             // from VaultDirectory.parseContacts()
    let voiceprints: [Voiceprint]     // VoiceprintStore matched by name-or-alias (1–2 records)
    var enrolledEngines: Set<String>  // derived from voiceprints[].embeddingModel
    var anchorID: UUID?               // voiceprints.first?.id — the durable identity, if enrolled
}
```

`PeopleViewModel` builds `[Person]` by unioning rolodex contacts and voiceprint
names. Pure logic → unit-testable without UI or models.

**Match on name OR alias.** The rolodex `Contact` carries `aliases` with
name-or-alias matching, so a voiceprint named "Andre" joins the contact
"Andre Nedelcoux" that lists "Andre" as an alias. Use the rolodex's existing
name-or-alias matcher for the join key rather than raw-name equality — it absorbs
the common short-name/full-name mismatch between how a speaker was named in a
call and how they're recorded in the rolodex. A voiceprint that matches no
contact name or alias is a "voiceprint-only" person (offer to add to rolodex).

### Handle all four quadrants (all occur in real data)
- **contact + voiceprint** — happy path.
- **contact only** — known but never recorded → offer "enroll from a recording".
- **voiceprint only** — named speaker not yet in rolodex (common today) → offer
  "add to Rolodex" (prefilled name, blank company/title).
- neither — n/a.

The screen must render contact-only and voiceprint-only people gracefully, not
treat them as errors.

## Storage & sync (decided: live store in vault)

The voiceprint store moves from `~/Library/Application Support/…/Speakers/` into
the vault at `<vault>/Parley/Speakers/voiceprints.json`, co-located with the
app's existing `<vault>/Parley/` folder (Unprocessed/Processed transcripts). It
rides the same GitHub sync as `Rolodex.md`, so the vault is the single
backup/versioning surface.

Implementation implications:
- **Derive the path from `settings.vaultURL`, not a fixed App Support path** —
  the store follows the vault if the user relocates it (same pattern as
  Rolodex.md / transcripts). `VoiceprintStore`'s injectable `fileURL` already
  supports this; only the default changes. Tests inject a temp URL, unaffected.
- **One-time migration**: on first launch after the change, move the existing
  `App Support/.../Speakers/voiceprints.json` into the vault location (mirror
  `VaultDirectory.migrateContactsFileIfNeeded()` / `SupportDirectoryMigration`).
  Don't leave a copy behind (it would diverge).
- **Stays AES-GCM encrypted; key stays in the local Keychain.** GitHub only ever
  sees ciphertext. Consequence (accepted): a second machine syncing the vault
  **cannot decrypt** the blob without the Keychain key — the synced file is a
  *backup*, not a cross-machine live store. Cross-machine restore still goes
  through the existing passphrase export/import.
- **Accepted tradeoff — git churn.** The encrypted blob is rewritten in full on
  every enroll/rename/rebuild; git stores encrypted-binary deltas poorly, so
  history grows by a few-MB object per edit (~10 MB of clips today). The user
  accepted this for single-location simplicity. Optional later mitigations if it
  bloats: a `.gitattributes` binary marker, splitting clips out of the JSON, or
  periodic history pruning — none required for v1.
- Obsidian ignores non-`.md` files in content; the JSON just appears in the file
  tree under `Parley/Speakers/`.

## The one cross-store operation: renamePerson

Every edit touches exactly ONE store except a name change:
- Edit company/title/linkedin/side → `Contact` only → `vault.upsertPerson(...)`.
  Voiceprint untouched (its UUID + embeddings are stable). **This is the common
  case and needs no cross-store coordination.**
- Re-enroll / rebuild / delete a voiceprint → `VoiceprintStore` only.
- **Rename** → the single coordinated path:

```
func renamePerson(from old: String, to new: String) {
    vault.upsertPerson(name: new, … carrying over the old Contact's fields …)  // + remove old bullet
    for vp in voiceprints where vp.name ~= old { voiceprints.rename(vp.id, to: new) }  // 1–2 records
    // (transcript frontmatter attendee references: out of scope for v1; eventual-consistency)
}
```

Own this in one place; never let the UI rename one store without the other.

## Syncing to Rolodex.md (write THROUGH VaultDirectory)

- **Read** via `VaultDirectory.parseContacts()` / `vault.people`. **Write** via
  `vault.upsertPerson()` + `normalizeContacts()`. Never write `Rolodex.md`
  directly and never re-implement the parser — reuse the canonical/normalize
  logic + tests the rolodex cleanup ships.
- **Assume Obsidian edits the file concurrently.** `VaultDirectory.refresh()`
  already reacts to vault folder-change events — re-read on those so external
  edits show up; re-read before write (or rely on `upsertPerson`'s single-bullet
  relocate) so the app never clobbers a hand-edit.
- **Save on commit, debounced — not per-keystroke.** Each write touches the .md
  and triggers a folder-change reload; per-keystroke would thrash / feedback-loop.
- **Autocomplete company/side from the existing taxonomy** (`loadFileCustomers`,
  `company(for:)`, `internal/customer/other`) to prevent "Intellias" vs
  "intellias" drift.

## Voiceprint status, per person

Derive from `voiceprints.filter { name ~= person }`:
- Engine badges: `FluidAudio ✓ · WhisperKit ✗` (from `embeddingModel` ∈
  {`wespeaker_v2`, `pyannote_v3`}).
- Sample count, clip-retained indicator, play button (`SamplePlayer`).
- Per-person actions reusing already-shipped code: **Rebuild WhisperKit
  voiceprint** (`VoiceprintStore.clipSourcesMissing` +
  `SpeakerKitDiarizer.embedding(forClip:)`), delete, play. Cross-enroll already
  keeps new namings dual-engine. This answers "is this person recognized on both
  engines?" at a glance — the original complaint that started all this.

## Placement & navigation

- Add `case people` to `MainWindowView.SidebarSection` (alongside `record` /
  `history`); symbol e.g. `person.crop.circle`. Top-level, not Settings.
- Inside the people content area use **master–detail** (list left, editor right)
  via `NavigationSplitView`/`HSplitView` — the current sidebar is a plain VStack
  switch, so the split lives *within* the people pane.
- **Plumbing:** `vault` is already an environment object. `VoiceprintStore` is
  `recording.voiceprints` (a `StateObject`, not injected) — inject it as an
  environment object for parity instead of threading it manually.
- Leave a thin redirect in Settings → Speakers ("Manage speakers in the People
  tab →") for one release rather than silently moving it; migrate the voiceprint
  export/import + re-enroll controls into the People detail pane.

## Deferred (don't build yet)

- **Stable id for duplicate-name disambiguation.** Name-as-key collapses two
  different "John Smith"s. If that becomes real, add a sidecar map in App Support
  linking `Voiceprint.id ↔ rolodex name` — NOT a UUID embedded in Rolodex.md
  (keep that file human/Obsidian-clean). Defer until duplicates actually bite.
- **LinkedIn enrichment** — manual entry only today; no lookup pipeline.
- **Transcript-frontmatter rename propagation** — eventual consistency; out of v1.

## Sequencing (after the rolodex cleanup commits)

1. `PeopleViewModel` join layer (Contact ⨝ Voiceprints by name) + unit tests. No UI.
2. Read-only People list + detail (contact display + voiceprint status badges).
   Ship, validate the join against real data (52 prints / Rolodex).
3. Editing: write-through `upsertPerson`, debounced save, single `renamePerson`
   fan-out, company autocomplete.
4. Migrate voiceprint management (rebuild/delete/play/export-import) into the
   detail pane; redirect Settings → Speakers.
5. Optional later: contact-only / voiceprint-only nudges; duplicate-name sidecar.

## Reuse, don't reinvent

| Need | Use |
|---|---|
| Parse rolodex | `VaultDirectory.parseContacts()` / `Contact` |
| Write rolodex | `VaultDirectory.upsertPerson()`, `normalizeContacts()` |
| Voiceprint list/rename/delete | `VoiceprintStore` |
| Rebuild missing-engine print | `VoiceprintStore.clipSourcesMissing` + `SpeakerKitDiarizer.embedding(forClip:)` |
| Keep new namings dual-engine | `RecordingController.crossEnroll` (already wired) |
| Play retained clip | `SamplePlayer` |

No schema/data-model changes. No new persisted store. Presentation + a join +
one disciplined rename path.
