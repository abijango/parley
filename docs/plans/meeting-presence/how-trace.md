# How trace (explorer)

Condensed from the end-to-end Detection trace. Full constraint list lives in `grounding.md`.

Two pipelines meet only in `RecordingController`: mic call detection (always-on, no AX) and AX metadata discovery (best-effort, never gates recording).

`DiscoveredMetadata` is `{ title?, titleSource?, roster: [RosterEntry{name, role?}] }`. Controller `mergeRoster` unions into `SuggestedAttendee` chips. Speaker-ID already auto-adds names via `addAttendeeIfAbsent`. Resume restores title/attendees but drops suggestion UI state. Title auto-fill vs chip is two locks: resolver `titleLocked` and session `titleWasUserEdited`.
