# How critique — opus

Agrees with the others: `RosterEntry` cannot express presence; section headers are recognized then discarded at the bottom of the stack; tests lock the defect.

Additional load-bearing constraints for synthesis:
- `AXClient.walk` truncation vs empty pane are indistinguishable; presence needs that distinction (or a timeout/truncation flag).
- Roster walks are gated on title parse (`walkCallWindows` uses `teamsCallTitle != nil`). Unsettled `"Microsoft Teams"` title → no roster for 5–10s; non-English titles → no roster for the whole call. Window identity ≠ meeting title.
- Tick counter vs wall clock: ticks increment only after AX is trusted, so late permission grant can miss the 16s title/calendar window.
- `titleLocked` is first-non-nil, not best-source. Zoom calendar can lock a wrong nearby event.
- Presence evidence (`Tentative`, `In a meeting`) is already in the row subtree and dropped because it isn’t in `roles`.
- Identity keyed on `name.lowercased()` is unstable across `"Rosen, Adam"` / `"Adam Rosen"`.
- Union-only accumulation is a *transcript* requirement (diarization / vocabulary), not UI politeness. Presence-aware must not delete leavers.
- Keep AX/threading depth (`AXClient`, Electron switches, value-types-only hop). Reject the resolver’s output contract and tick-flag scheduling.
- Make `start(for:)` idempotent instead of publishing `isPolling`. Collapse `enterPreviewMode` vs `stop`.
- One place to declare a conferencing app. Today: settings, displayName map, scan if-ladder, parsers.
