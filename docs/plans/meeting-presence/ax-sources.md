# AX / local sources (research, 2026)

Keep Accessibility as the only extra permission. Do not add Screen Recording for CGWindowList titles (same string as AX, no roster). Do not use Graph `attendanceReports` (post-call) or `rosterUpdated` (cloud app-only webhooks) as live presence. Zoom Plugin SDK has a real live roster but needs OAuth + Marketplace — not Parley's primary path.

| App | Title | Presence |
|---|---|---|
| Teams | High — call-window AX title | Medium — People pane “In this meeting”; tiles undocumented |
| Zoom | Low–medium — window often “Zoom Meeting”; home “Now” / meeting-info chrome | Medium–high when Participants panel is in the tree; speaker tiles already parsed |
| Webex | Medium — meeting window = space name; ignore generic `Webex` chat window | Low — Cisco a11y on participant list is weak; `callControl_*` tells in-call vs chat |

Do not silently click People/Participants. Webex parsers stay dump-driven via MeetingProbe. Legacy Webex bundle `com.cisco.webexmeetingsapp` is optional later; unified `Cisco-Systems.Spark` first.
