# How critique — composer-2.5

Presence is wrong at the type level, not merely incomplete.

- `MeetingParsers.teamsAttendees` skips section *headers* but emits every person row under both "In this meeting" and "Others invited". Tests assert invitees are equal citizens. That is the UX bug.
- `RosterEntry` / `SuggestedAttendee` have no present vs invited. Chips and "Add all" cannot express the product distinction.
- `firstSeen` is poll/pane-open time; UI says "joined".
- `MeetingMetadataResolver` is a scheduler that dumps snapshots into the controller. Real domain knowledge is in parsers (wrong type) and `mergeRoster` (lifecycle in the wrong module).
- Webex absence is the same `scan(_:)` if/else gate, plus known-app policy — both halves must change.
- Replacement must re-home presence into Detection (section-aware outputs / events). Refuse to filter chips in the controller while still feeding invite rows into `mergeRoster`.
- Keep: mic as call truth, silent AX failure, title auto-fill vs chip locks, comma-safe names, AX off main actor, optional Codable manifests.
