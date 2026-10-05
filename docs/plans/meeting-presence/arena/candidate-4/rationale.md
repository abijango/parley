## Problem

Parley already knows a call is happening (mic) and already scrapes conferencing UI (AX). The Record tab still treats every parsed name as a suggestion chip. Teams' People pane lists **In this meeting** and **Others invited** in one outline; the parser skips the headers and emits both as `RosterEntry`. Tests lock that. `mergeRoster` unions the bag forever, stamps poll/pane-open time as join, and the inspector requires a tap — including for people clearly in the call. Speaker-ID already auto-appends names via `addAttendeeIfAbsent`. The UX bug is not missing detection; it is recommending the Outlook invite list and charging a tap for presence. Constraints that stay: recording never depends on AX; do not click People/Calendar; EventKit is empty here; Graph is not live presence; old `session.json` must decode; names cannot contain commas; AX off the main actor with a messaging timeout; English-only anchors; Webex parsers wait on MeetingProbe dumps.

## Usage (caller's view)

See `usage.md`. The inspector binds `meeting.attendees` and `meeting.pendingUncertain`. `RecordingController` calls `admission.ingest(sighting)` on each resolver tick, `admission.tokenFieldChanged` when the TokenField commits, and `admission.restore` on crash resume. Present people appear in the TokenField with no chip. Invited names are not a field the controller can show. Uncertain labels (rooms, devices) are the only chips. Token delete / Clear all is undo for the session.

## Shape

**Admission is the product.** A present person is an attendee. That rule lives in `MeetingAdmission`, not in a view filter on today's `SuggestedAttendee` bag.

Data structures, then flow:

1. `MeetingParsers.teamsAttendees` returns `TeamsRosterParse` — `paneMissing` vs `sectioned(present:invited:)`. Zoom/Webex emit `PresentSnapshot`. Invited exists only so tests can prove it was parsed and dropped.
2. `MeetingMetadataResolver` is still a timer. Its public type is `MeetingSighting { title?, present }` — no AX, no invited, no role bag. `PresentSnapshot.unobserved` vs `observed([])` vs `observed([names])` encodes pane-closed vs empty vs people. Empty snapshots are no longer silently dropped as if they carried no information.
3. `DisplayName.parse` is the comma/badge boundary. `NameClassifier` (next to admission, not per app) splits in-meeting labels into person vs room/device.
4. `MeetingAdmission.ingest` writes people into `meeting.attendees` unless excluded; upserts uncertain chips; never removes a name because they left. `tokenFieldChanged` diffs the TokenField and records exclusions. `addRecognized` is the speaker-ID path and bypasses AX exclusion.
5. Session projection: `attendees` + `uncertainChips`. `suggestedAttendees` remains optional Codable for old files and is not written on the live path. Restore refuses to auto-admit leftover bag rows (they mixed invite with presence).
6. Title stays two-lock (`titleWasUserEdited` resets with the session; resolver only hard-locks on `callWindow` or give-up). `TitleSource` is ranked so a calendar fallback cannot freeze out the Teams call window.
7. `AXClient.setMessagingTimeout` is part of `start(for:)`. Webex is a known bundle plus stub parsers, not a guessed selector set and not a `MeetingSource` protocol.

Invariants in types: invited cannot be recommended (`MeetingSighting` has no field); present people cannot be chips (`UncertainChip` is the only chip type); pane-closed cannot look like an empty room (`PresentSnapshot`); user undo cannot be forgotten next tick (`excluded`); storage cannot split a name (`DisplayName.parse`). Validation at the parser/classifier boundary; admission trusts `DisplayName`. Ingest and token-field diffs are idempotent. People leaving is not a write.

Interface depth: the controller's roster surface is `ingest` / `tokenFieldChanged` / `clearAll` / `admitUncertain` / `dismissUncertain` / `addRecognized` / `restore`. Hidden behind it: section split, snapshot emptiness, classification, exclusion, old-manifest mapping, comma-safety, chip lifecycle. Callers do not coordinate a merge. The resolver stays a clock; it is not the deep module.

Deliberately not done: a present-now ledger, a per-app `MeetingSource` protocol, a collapsed invited list, "Add all", fake join times, Graph/EventKit, driving conferencing UI, Screen Recording titles.

## Synthesis decision

(arena will fill)

## Tradeoffs accepted

- We accept that leaving the call does not remove a token, in exchange for never making presence-now a second list the inspector must understand. The note is "who was in," which matches speaker matching and summaries.
- We accept heuristic room/device classification, in exchange for not putting every in-meeting label on the attendees field. Misclassifying a person as uncertain is a tap; misclassifying a room as a person is a token delete.
- We accept that Teams presence still requires the People pane to be open, in exchange for not clicking it. Auto-admit cannot invent names that AX did not see; when the pane opens, the field fills at once instead of dumping chips.
- We accept speaker-ID re-adding a name the user excluded from AX auto-admit, in exchange for one attendee string rather than competing writers with different exclusion rules.
- We accept keeping `SuggestedAttendee` as a decode-only fossil, in exchange for old `session.json` surviving without a migration pass.
- We accept dropping "Add all" and "joined HH:mm", in exchange for chips meaning "this might not be a person."
- We accept not modeling present-now, in exchange for not building a ledger whose natural UI is still a recommendation list (shape B).

## Alternatives considered

- **Parse distinction + chip filter (shape A).** Parsers emit present vs invited; UI hides invited. Smallest diff, shallowest module: callers still tap to admit, `SuggestedAttendee` remains the bag, and "never auto-enter attendees" stays as compensation. Exposes the recommendation lifecycle to every caller. Rejected because the product default is no tap for someone clearly in-call, and speaker-ID already auto-writes the same field.
- **Presence ledger (shape B).** A domain object owns first-seen / present-now / recommended / accepted. Controller stops merging. Deeper than A, but it keeps a parallel roster whose job is to decide chips vs admit. Callers still think in recommendations. Rejected: once present means attendee, present-now is not a UI state and a ledger is extra surface.
- **Per-app MeetingSource (shape C).** `TeamsSource` / `ZoomSource` / `WebexSource` hide AX quirks; the poller is a clock. Hides per-app I/O well, exposes a protocol and three facades before Webex has a dump to implement. Adding Webex is a new type, not a stub in the existing scan. Rejected for this candidate: the UX failure is admission policy, not the `if isTeams` scan. Webex is a parser stub plus a known-bundle line.

## Open questions and risks

- How aggressive should `NameClassifier` be on short ambiguous labels (a first name that is also a room code)? Prefer chip or auto-admit?
- Should Clear all exclude names the user typed, or only names admission auto-wrote? The sketch excludes everyone currently in the field so the next tick cannot refill — is that the undo the user wants?
- When the People pane is closed all call, the TokenField stays empty. Is a static caption ("Open People in Teams to fill attendees") in scope, or is silent AX still the rule?
- Resume of an old bag: leftover unaccepted rows become conservative uncertain chips. Should they be dropped instead, so a recovered session does not suddenly grow room-like chips for invited people?
- Title rank: should `zoomHome` outrank a stale Teams calendar hit when both are visible (Zoom call while Teams Calendar is open)?

## Next implementation step

Change `MeetingParsers.teamsAttendees` to `TeamsRosterParse` and flip `testTeamsAttendeesParsesRosterRows` so invited names are asserted as invited, not present — then wire `MeetingSighting` + `MeetingAdmission.ingest` and delete `mergeRoster`.
