## Problem

Parley currently destroys the distinction it needs: Teams parsing emits people under “In this meeting” and “Others invited” as the same flat `RosterEntry`, then `RecordingController` unions those rows forever, invents a join time, and exposes accepted/dismissed flags for the view to filter. Empty observations are dropped, so “present now” cannot be represented. The replacement must preserve mic capture as the only call/recording truth, keep AX failure silent and off the main actor, bound wedged AX messaging, retain title user-edit behavior, decode old manifests, and avoid guessing Webex structure before a live dump.

## Usage (caller's view)

The full caller contract is in `usage.md`. `MeetingMetadataResolver` emits a `MeetingMetadataSnapshot` heartbeat on every discovery tick, with findings from a bounded scan when AX is available. Its optional `RosterSnapshot` separates confirmed-present, ambiguous-present, and invite-only values; `nil` means no roster surface was observed, while a non-nil empty complete snapshot means nobody is currently present.

`RecordingController` performs one domain transition per resolver callback:

```swift
let change = presenceLedger.apply(.observe(snapshot.roster, at: snapshot.observedAt))
meeting.presence = change.view
meeting.attendees = change.view.accepted.commaDelimited
```

The inspector reads `meeting.presence.recommendations` and sends `ParticipantID` intents back through `.accept` or `.dismissRecommendation`. Its token field reads accepted names and replaces them with `.replaceAccepted`; it does not filter flags or merge discoveries. Speaker identification validates a `PersonName` and sends `.acceptName(..., origin: .speakerIdentification)`. Persistence stores `presenceLedger.storedState` and derives the comma-delimited attendee string; a manifest adapter migrates optional legacy `SuggestedAttendee` values only when the new optional state is absent.

## Shape

The load-bearing structure is a pure `PresenceLedger` value owned on the main actor. Records are indexed by name-derived `ParticipantID`, accepted order is separate, complete-roster observations store timestamped membership sets by surface, and partial observations are expiring leases by surface. A ledger clock advances only from resolver heartbeats, making replay and crash restore deterministic. This directly serves the dominant operations: idempotent snapshot reconciliation, O(1) user actions, ordered attendee projection, authoritative departure from complete snapshots, and expiry-to-unknown for partial observations. No later cache or controller-side index is required.

`RosterScope` encodes absence semantics: `.complete` may mark an unseen prior member not present; `.partial` may only add present evidence. Distinct `ConfirmedPresentPerson`, `AmbiguousPresentEntity`, and `InvitedPerson` types prevent invite evidence from reaching the automatic-admission branch by accident. `PersonName` validates normalization and comma safety once at parser/manual-input boundaries, per boundary-discipline and encode-lessons-in-structure.

The ledger owns the decision state: undecided, recommended, accepted, or suppressed. Confirmed presence automatically accepts unless the user previously suppressed that identity; ambiguity recommends; invite-only evidence remains undecided. Manual removal creates suppression so the next identical poll cannot undo the user. Replayed snapshots and actions are idempotent, per make-operations-idempotent. “First observed” and “first present observed” are explicit and the UI says “seen,” avoiding the false claim that poll or pane-open time is join time.

The resolver remains the single discovery shell, not a per-app source hierarchy. Existing app branches parse into domain snapshots behind its callback. It also ranks title authority, so a rendered-calendar fallback cannot lock out a later Teams call-window title. Webex bundle recognition can be added independently, but its title/roster parser bodies remain unimplemented until MeetingProbe evidence exists. AX nodes, pids, English anchors, messaging timeouts, and tree-walk budgets stay behind the resolver boundary. A generation token discards late work after stop/restart; `AXUIElementSetMessagingTimeout` plus total walk budgets bound a wedged app. Recording never awaits this path.

The public domain surface is one transition method, one current view, and one stored-state projection. It hides evidence precedence, completeness reconciliation, partial leases, suppression, admission policy, deduplication, ordering, and migration-safe state. Callers still choose only real user intent and publish projections. This is a deep module with a short call chain, per minimize-reader-load; the controller adapter is justified because it converts one domain change into observable UI and durable scheduling rather than forwarding matching arguments.

## Synthesis decision

(arena will fill)

## Tradeoffs accepted

- We accept name-derived identity collisions for two people with the same display name in exchange for matching the strongest stable identity current AX trees provide without inventing unavailable IDs.
- We accept a 12-second lease before partial tile evidence becomes unknown in exchange for avoiding false departures from an incomplete surface.
- We accept retaining invite-only identities in durable ledger state in exchange for correctly recognizing a later transition from invited to present without ever presenting invitees as current attendees.
- We accept deriving the existing attendee string from the ledger during migration in exchange for preserving transcript, vocabulary, history, and manifest call sites while establishing one owner for acceptance.
- We accept English-only parser anchors in v1 in exchange for silent failure with no recording impact.

## Alternatives considered

- Keep presence as only a parser distinction and let `RecordingController` filter and merge. This has the smallest implementation diff but remains shallow: callers must understand completeness, first observation, departures, suppression, and admission policy.
- Introduce `TeamsSource`, `ZoomSource`, and `WebexSource` as the primary architecture. This hides app-specific AX variation well, but does not own cross-snapshot history or accepted/recommended decisions; the controller would still need a second policy module or regain the merge logic.
- Auto-admit confirmed people directly in the resolver callback. This optimizes the immediate experience but leaks evidence policy into the controller and creates competing attendee writers with manual input and speaker identification.

## Open questions and risks

- Does a 12-second partial-observation lease feel stable in Zoom speaker-tile churn, or should live probe timings establish a different fixed value?
- Which observed Teams and Zoom labels are safe to classify as rooms/devices without suppressing real people, and which must remain confirmed until fixture evidence says otherwise?
- Should the inspector show only `inviteOnlyCount` in a collapsed secondary affordance, or keep invite evidence entirely invisible?
- How should the UI distinguish two simultaneous participants with the same normalized display name when AX supplies no stable participant identifier?
- What Webex roster scope and title authority do live MeetingProbe dumps justify?

## Next implementation step

Build `PersonName`, `RosterSnapshot`, and `PresenceLedger` as a pure module with transition tests for complete absence, partial expiry, invited-to-present promotion, automatic acceptance, suppression, replay idempotency, and legacy restore before changing resolver or UI code.
