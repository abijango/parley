# Arena task — meeting title & presence design

You are one architect runner. Read the architect skill and this file, then write ONE candidate design package into your assigned output directory.

## Inputs (read first)

- Grounding: `/Users/naufalmir/work/personal/parley/docs/plans/meeting-presence/grounding.md`
- Runner discipline: `/Users/naufalmir/.cursor/plugins/cache/cursor-public/pstack/60c641e4fad674784b30abcf9f8915dea39df38d/skills/architect/references/runner-prompt.md`
- Rationale shape: `/Users/naufalmir/.cursor/plugins/cache/cursor-public/pstack/60c641e4fad674784b30abcf9f8915dea39df38d/skills/architect/references/rationale-template.md`
- Red flags: `/Users/naufalmir/.cursor/plugins/cache/cursor-public/pstack/60c641e4fad674784b30abcf9f8915dea39df38d/skills/architect/references/design-red-flags.md`
- Current code: `Parley/Detection/*`, `Parley/Recording/MeetingSessionState.swift`, `Parley/Recording/SessionManifest.swift` (`SuggestedAttendee`), `Parley/UI/SuggestionChips.swift`, `RecordingController` merge/accept helpers

## Problem

Parley already detects calls via mic capture and scrapes conferencing UI via Accessibility. Teams titles mostly work. Attendee chips currently dump the Outlook **invite list** (Teams `"Others invited"` rows) mixed with people actually in the call. Webex (`cisco-systems.spark`) is not a known app and has no parsers. Zoom titles often stay `"Zoom call"`.

User priority: **Teams >> Zoom >> Webex/other**. Want: reliable title; recommend people **when they are present / as they join**, not everyone invited. Current method works; UX is the issue.

## Artifact to produce

Write these files in YOUR output directory only (do not edit the Parley app):

1. `usage.md` — caller's view FIRST (README + 2–3 realistic call sites in RecordingController / inspector). This is the spec.
2. `sketch.swift` — types, signatures, module map. Bodies `fatalError("not implemented")` or `// TODO` pseudocode. Encode presence vs invited in types. No AX/wire types on the public surface.
3. `rationale.md` — full rationale-template.md. Leave "Synthesis decision" as `(arena will fill)`.
4. `red-flags.md` — one paragraph self-screening against design-red-flags.md.

## Constraints (non-negotiable)

- Recording never depends on AX/calendar/Graph.
- Do not drive conferencing UI (don't click People / Calendar).
- EventKit is empty for this user's Outlook-only Exchange. Graph/OAuth is not the live-presence source.
- Do not invent Webex AX selectors; Webex parsers are dump-driven later via `tools/MeetingProbe`. The sketch can name a Webex source with `not implemented` bodies.
- Old `session.json` must still decode (`suggestedAttendees` optional).
- Attendee names cannot contain commas (storage is comma-delimited).
- AX stays off the main actor; set a messaging timeout so a wedged Teams/Webex cannot leak the AX queue forever.
- English-only AX anchors are an accepted v1 limitation (degrade to nothing).

## Exhaust the design space

Produce a **structurally distinct** whole-shape alternative, not a point fix inside today's resolver. Pick ONE of these directions (do not blend them into a mushy middle):

**A. Presence as a parse distinction** — keep `MeetingMetadataResolver` as the deep module; parsers emit present vs invited; UI/policy is a thin filter. Smallest surface change.

**B. Presence ledger** — resolver (or per-app sources) emit snapshots; a new domain type owns first-seen, present-now, recommended, accepted. Controller stops merging arrays. Policy (auto-admit present vs chips) lives in the ledger.

**C. Per-app MeetingSource** — `TeamsSource` / `ZoomSource` / `WebexSource` each hide their AX/calendar quirks behind `TitleCandidate` + `RosterSnapshot`. The poller is a dumb clock. Adding Webex is a new source, not another `if isTeams`.

**D. Auto-admit present** — present people become attendees without a tap (dismiss/undo exists); invited-not-joined are not recommended. Chips remain only for uncertain names (rooms, devices). Experience-first: the Record tab looks already filled as people join.

Do not hedge. Pick the shape your model believes is right. Name what you rejected.

## Product defaults if you must choose

If your shape needs a policy call the user did not settle: **recommend present people as they appear; do not promote invited-not-joined as the same chips; do not require a tap for someone clearly in-call** (auto-admit present, keep tap-to-add only for uncertain / invited). Title behavior stays: auto-fill defaults, chip after user edit.
