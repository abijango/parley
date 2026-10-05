# How critique — gpt-5.6-sol-high

Agrees: presence is destroyed in parsing, not recovered later.

New points:
- `CallDetector.bestCandidate` conflates known-to-record vs metadata-capable vs app priority; first mic capturer wins, not Teams > Zoom > Webex.
- Three drifting registries: settings defaults, `displayName` map, resolver `isTeams`/`isZoom`.
- `titleLocked` can freeze a calendar fallback before the Teams call-window title settles — documented priority is not globally true.
- `walkAll` / `walkCallWindows` erase observation context; section membership is then discarded again by the parser.
- `normalizeDisplayName` should not encode comma-storage inside Teams parsing; enforce at the attendee-string boundary.
- Resolver is orchestration complexity, not interface depth. A deep boundary would hide polling, ranking, dedup, and temporal reconciliation, and expose stable meeting facts.
