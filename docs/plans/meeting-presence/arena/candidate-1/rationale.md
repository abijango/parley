# Candidate A rationale — presence as a parse distinction

## Problem

Parley's Teams roster parser reads the People pane correctly at the row level but collapses "In this meeting" and "Others invited" into the same `RosterEntry`. Tests assert invited-not-joined people as suggestions. Downstream `mergeRoster` unions every name forever and stamps poll time as "joined", so the Record tab recommends the Outlook invite list and `Add all` becomes dangerous. The fix is not a smarter merge — presence is knowable at parse time from section headers the parser already skips. The design must keep mic capture as call truth, AX as silent best-effort metadata, and avoid driving conferencing UI or adding Graph/OAuth. Webex is unknown-app today; Zoom has no invite section but still needs explicit `.present` tagging. Old `session.json` must decode; attendee strings stay comma-delimited.

## Usage (caller's view)

See [usage.md](./usage.md). Callers wire `metadataResolver.onUpdate` to `applyParticipantDiscovery(_:)`, receive `[MeetingParticipant]` with `presence` already set, auto-admit `.present`, drop `.invited`, chip only `.unknown`. `SuggestionChips` filters by `recommendationKind == .needsConfirmation`. No caller parses section-header strings or re-derives presence from role badges like "Tentative".

## Shape

**Data structures first.** Replace `RosterEntry { name, role }` with `MeetingParticipant { name, role, presence: ParticipantPresence }` where `ParticipantPresence` is `.present | .invited | .unknown`. This is the single source of truth for "should this person be recommended?" — encoded in types per **encode-lessons-in-structure**.

**Parser ownership.** `MeetingParsers.teamsParticipants` tracks the current AX section while walking `AXOutline desc="Attendees"`. Header rows flip `sectionPresence`; person rows inherit it. Zoom parsers tag every tile and panel row `.present` (no invite analogue). Webex returns `[]` until MeetingProbe defines anchors — stub body, not guessed selectors. Name normalization (`stripStatusBadges`, `normalizeDisplayName`) and comma rejection stay at the parse boundary per **boundary-discipline**.

**Deep module unchanged in role.** `MeetingMetadataResolver` keeps title lock, calendar rationing (ticks 3 and 6), Electron AX enable, background `axQueue`, and `onUpdate` gating. It emits `DiscoveredMetadata.participants` instead of `.roster`. New responsibility: call `AXClient.setMessagingTimeout` before walks so hung Teams/Webex trees cannot block the serial queue forever. Resolver does not apply product policy (no auto-admit) — it concentrates transport + scan + parse per **interface depth**.

**Thin controller policy.** `applyParticipantDiscovery` replaces `mergeRoster`. Three-way switch on `presence`: `.present` → `addAttendeeIfAbsent` + suggestion with `accepted = true`; `.invited` → `continue`; `.unknown` → suggestion awaiting tap. Union/`firstSeen`/role-backfill logic moves into `upsertSuggestion` unchanged in spirit. No invited rows enter `suggestedAttendees`, so the view never filters a bag the type system still treats as homogeneous.

**UI surface.** `SuggestedAttendee` gains optional `presence` (Codable; nil decodes as `.unknown` for legacy manifests). Computed `recommendationKind` drives chip visibility — view does not branch on raw presence strings. Present people disappear from chips because they are already admitted, matching product default "do not require a tap for someone clearly in-call".

**Invariants encoded in types:**
- Invited-not-joined cannot reach chip UI without a type escape (`presence == .invited` filtered at controller).
- Comma-containing names rejected at `MeetingParticipant.make`.
- AX/wire types (`AXNode`, `AXUIElement`) never cross to `RecordingController` or SwiftUI.

**Deliberately not done:** presence ledger, per-app `MeetingSource` protocol, join-event inference, collapsing empty snapshots into "everyone left", Graph/EventKit roster, driving People pane open.

## Synthesis decision

(arena will fill)

## Tradeoffs accepted

- We accept **re-parse section context on every roster tick** in exchange for **zero new state machine** — no ledger, no snapshot diff, no "present-now" boolean to merge across ticks.
- We accept **auto-admit present people without undo in v1** in exchange for **Record tab that fills as people appear** — aligns with existing speaker-ID `addAttendeeIfAbsent` path; chips remain for uncertain names only.
- We accept **dropping invited people entirely (no collapsed secondary list)** in exchange for **smallest UX fix** — user priority is stop recommending the Outlook invite list, not browse it inside Parley.
- We accept **`.unknown` legacy manifests showing chips again** in exchange for **backward-compatible Codable** — nil `presence` decodes safe-opt-in rather than silently auto-admitting old invite-list suggestions.
- We accept **Teams presence still requiring the People pane rendered** in exchange for **not driving conferencing UI** — parse distinction fixes invite-vs-present when the pane is open; tile-based presence without opening People is out of scope for this shape.
- We accept **keeping resolver `if isTeams / isZoom / isWebex` branches** in exchange for **minimal module churn** — Webex stub is one branch, not a registry refactor (that is candidate C's trade).

## Alternatives considered

**B. Presence ledger** — a domain type owns first-seen, present-now, recommended, accepted; controller stops merging arrays. Rejected because it introduces a second source of truth for presence that must diff snapshots the parser could already classify. Exposes merge policy *and* ledger API to callers; hides less behind the same AX inputs. Higher implementation surface for the same Teams section-header fix.

**C. Per-app MeetingSource** — `TeamsSource` / `ZoomSource` / `WebexSource` behind `TitleCandidate + RosterSnapshot`; poller is a dumb clock. Rejected for this iteration: registry indirection does not change the presence encoding problem, adds protocol surface and file scatter, and violates "smallest surface change" constraint. Better fit when Webex + Meet + browser helpers multiply; overkill for tagging two Teams sections.

**D. Auto-admit present (experience-first)** — largely overlaps A's controller policy but would keep flat `RosterEntry` and filter in the view. Rejected because filtering chips while the transport type remains a bag is exactly what how-critique flagged as information leakage — invited rows would still flow through merge, manifest, and tests unless parsers change anyway. A subsumes D's product outcome with the type fix upstream.

**View-layer filter only (status quo + `if invited`)** — rejected: tests and manifest would still store invited names; `Add all` and speaker matching would still see them; changing the filter without changing parse output fails **single source of truth per invariant**.

## Open questions and risks

- Should `.present` auto-admit also write a visible "Added from call" toast, or stay silent like speaker-ID auto-add today?
- When the same person appears in both `.present` and `.invited` sections (organizer not yet joined then joins), does section order in AX guarantee `.present` wins on upsert, or do we need explicit precedence in `upsertSuggestion`?
- Zoom tile vs panel dedup currently produces duplicate `RosterEntry` rows — should `zoomParticipants` collapse to one `.present` with merged role before the controller sees them?
- Is `presence: nil → .unknown` the right legacy decode, or should nil mean `.present` for manifests recorded before this change (likely all-invite-list era)?
- Teams with People pane closed yields empty participants — is empty snapshot acceptable for "as they join", or do we need tile/count heuristics in a follow-on without abandoning parse distinction?

## Next implementation step

Change `teamsAttendees` → `teamsParticipants` with section tracking, update `MeetingParsersTests.testTeamsAttendeesParsesRosterRows` to assert `.present` / `.invited` tags, then swap `DiscoveredMetadata.roster` for `.participants` and replace `mergeRoster` with `applyParticipantDiscovery` in `RecordingController`.
