# Red-flag self-screen (candidate A)

**Shallow module:** `MeetingMetadataResolver` remains deep — it owns AX scheduling, title authority, Electron enable, calendar rationing, and timeout policy. `applyParticipantDiscovery` is intentionally thin (a switch, not a second parser). `upsertSuggestion` carries real union semantics but does not re-derive presence. **Pass.**

**Information leakage:** Section-header strings (`"Others invited"`, `"In this meeting"`) live only in `MeetingParsers.teamsParticipants`. Controller and UI see `ParticipantPresence`, not AX copy. Invited rows never enter `suggestedAttendees`, so the manifest and chips cannot drift. **Pass** — fixes the current leakage where invite-list policy would have to be duplicated in merge, view, and tests.

**Temporal decomposition:** No separate load/validate/transform/save stages. Parse (with presence) and poll (with title lock) stay co-located in resolver + parsers per domain ownership. **Pass.**

**Pass-through methods:** `recommendationKind` on `SuggestedAttendee` is derived from stored `presence`, not a forwarding wrapper. `applyParticipantDiscovery` adds policy (auto-admit vs drop vs chip) that parsers correctly do not own. **Pass.**

**Residual watch:** `upsertSuggestion` could become a pass-through if it only forwards to today's merge loop without the presence switch — implementation must keep the three-way branch at the controller boundary. Zoom dedup inside `zoomParticipants` must happen in the parser, not as a second merge pass, to avoid reintroducing a bag type.
