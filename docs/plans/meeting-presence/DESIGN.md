# Meeting title and presence — synthesized design

Base: arena candidate C (per-app `MeetingSource`). Cross-judge total 18/18 vs A 9 / B 14 / D 14. Parent scoring agreed.

## Problem

Teams already exposes **In this meeting** vs **Others invited**. Parley flattens both into one chip bag and labels poll time as “joined.” Webex is not a known app (`spark call`) and has no parsers. Zoom titles often stay generic. Recording must stay independent of Accessibility.

## Usage (caller's view)

```swift
sourcePoller.onReading = { reading in
    meeting.offerTitle(reading.title)          // authority-ranked
    meeting.roster.apply(reading.roster)       // unreadable is a no-op
    admission.applyPolicy(from: meeting.roster)
}
```

- Present, person-like names → attendees field (no tap). Token delete excludes them for the rest of the session.
- Rooms/devices → chips only (“Room” / “Device”).
- Invite-list names → not recommended. Kept internally so a later in-call sighting can promote them.
- Closed People pane → `.unreadable` (silence), not an empty meeting.
- First readable snapshot → “in call”, not “joined 10:03”. A later new name → real join time.

Webex is declared in `MeetingSourceRegistry` as known + named **Webex**, `capability: .none` until a MeetingProbe dump exists. Auto-record eligibility follows Settings like any known app.

## Shape

| Type | Job |
|---|---|
| `Presence` | `.inCall` / `.left` / `.invited` — the product distinction |
| `RosterCoverage` | `.unreadable` / `.sightings` / `.complete` — what silence means |
| `Arrival` | `.joined` vs `.presentBeforeFirstSight` vs `.neverObserved` |
| `MeetingSource.read` | One method; all app quirks behind it |
| `MeetingSourcePoller` | Dumb clock. No bundle ids. |
| `MeetingRoster` | Fold snapshots. No product policy. |
| `AttendeePolicy` + `MeetingAdmission` | Auto-admit, uncertain chips, token-delete exclusion |

`MeetingUITree` is read-only (no click/focus), so sources cannot drive conferencing UI. `AXNode` never leaves Detection. `DisplayName` is comma-free at the parse boundary.

Window identity is **not** “title already parsed.” Teams roster walks for the Attendees outline across windows, including while the call window is still titled “Microsoft Teams.”

## Synthesis decision

**Base = C.** Only candidate that distinguishes pane-closed from empty, refuses a fake join time in types, and makes Webex a registry line instead of another `if isTeams`.

**Grafted from D:** token-field deletion as session exclusion; `UncertainKind` (Room/Device); invited names off the recommendation stream (not a collapsed chip list in v1).

**Grafted from B:** Zoom tile `.sightings` never prove departure (additive only). Full lease-TTL graph and versioned `StoredState` payload rejected as premature persistence rewrite.

**Rejected:** A’s view-layer filter and `.suppressed` chip kind; B’s clearing `suggestedAttendees` on new writes; D dropping `role`; registry silently re-adding bundle IDs the user removed (registry is the default floor; Settings remains the live set; Webex is one-time seeded).

## Tradeoffs accepted

- We accept no Teams names while the People pane is closed, in exchange for never recommending the invite list.
- We accept auto-admit of in-call people, in exchange for tap-to-add only on uncertain labels. Undo is token delete.
- We accept Webex auto-record with a default “Webex call” title until parsers exist, in exchange for stopping “spark call” / notify-only.
- We accept English AX anchors in v1.

## Implementation status

Shipped in this branch: per-app sources, coverage-aware roster fold, auto-admit of present people, token-delete exclusion, Webex as a known named app with `capability: .none`.

Still dump-driven: Webex title/roster parsers (`tools/MeetingProbe` during a live call). Do not guess AX selectors. Optional later: copy that hints to open the Teams People pane — never click it via AX.
