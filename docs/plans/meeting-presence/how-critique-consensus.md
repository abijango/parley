# How-critique consensus (all 4)

All three critics agree on the same diagnosis.

**Wrong, not incomplete:** `teamsAttendees` skips section headers then emits invited rows as the same `RosterEntry` as present people. Tests lock the defect. Downstream cannot recover presence.

**Resolver is a timer, not a deep module.** It dumps `{ title?, roster: [name, role] }` into `RecordingController.mergeRoster`, which unions forever and stamps poll/pane-open time as `firstSeen`. UI says `"joined HH:mm"`. Empty snapshots are dropped, so presence-now is unobservable.

**Must keep:** mic as call truth; silent AX failure; title auto-fill vs user-edit chip; AX off main actor + messaging timeout; comma-safe attendee strings at the storage boundary; optional Codable manifests; do not drive conferencing UI.

**Must refuse:** flat `RosterEntry`; scan→parse→merge sandwich; `mergeRoster` inventing join; `conferencingBundleIDs` as the metadata registry; filtering chips in the view while the type is still a bag; guessing Webex AX without a dump.

**Additional constraints to honor:**
- `titleLocked` can freeze a calendar fallback before the Teams call window settles — first accepted title must respect source authority.
- `titleWasUserEdited` must reset with the session.
- `known` ≠ metadata-capable. Webex needs both a known-app policy *and* a source.
- Auto-admit present is allowed; tap-to-add stays for uncertain names. “Never auto-enter attendees” was compensation for the bag.
- Window identity must not depend on title parse (unsettled/non-English titles currently hide the roster).
- Truncated AX walks must not look like an empty pane.
- Union-only names stay for transcript/diarization even after someone leaves; presence is a separate axis.
- One declaration site per conferencing app (today: settings + displayName + scan ladder + parsers).
