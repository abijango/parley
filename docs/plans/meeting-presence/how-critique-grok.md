# How critique — grok-4.6

Grow-only name bag, not a presence system. Teams section split exists in AX; types throw it away; controller invents “joined” from poll time.

New points:
- Empty roster snapshots are dropped (`title != nil || !roster.isEmpty`), so “present now” cannot be observed — only additions.
- `applyDiscoveredTitleIfAllowed` exists but is unused; controller reimplements title policy. `titleWasUserEdited` is never cleared in `resetDiscovery` / `clearForNextMeeting` — one edit can kill auto-fill for the rest of the process.
- Grounding invariant “suggestions never auto-enter attendees” is compensation for an undifferentiated bag, not a law about present people. Keep tap-to-add for uncertain names; do not keep “every AX name is a chip.”
- `FluidVocabularyBuilder` consumes accepted attendees; dumping invite-list into `attendees` would pollute ASR.
- `conferencingBundleIDs` is auto-record policy, not the metadata registry. Adding Webex to defaults without a source still yields `"spark call"`.
- Replacement: presence as a parse distinction or per-app `RosterSnapshot` with present vs invited. Poller can stay a dumb clock. Controller must not merge arrays or invent join times.
