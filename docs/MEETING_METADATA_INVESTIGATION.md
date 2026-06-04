# Meeting metadata investigation — findings

*2026-06-04. Raw data: `tools/MeetingProbe/probe.log` (live tests: Teams ×3,
Zoom ×1 scheduled, Google Meet ×2 instant in Brave). Probe: `tools/MeetingProbe`.*

**Question:** when `CallDetector` fires, what meeting metadata (title,
attendees, …) is observable from outside the conferencing app, per app?

## Per-app results

### Microsoft Teams (`com.microsoft.teams2`) — best case

- **Title: reliable.** The call runs in its own window; its AX title is
  `<meeting title> | <org> | <account> | Microsoft Teams`. The window appears
  a few seconds *before* mic capture starts, titled generically
  (`Microsoft Teams`), and settles to the real title within ~5–10s.
- **Disambiguation** (validated on live data): (1) only look at windows of the
  mic-owning app; (2) the call window is the one that *appeared around
  mic-start and took focus*; (3) the main window's first title segment is
  always a nav view (`Calendar`, `Chat`, `Activity`, …) — the call window's
  never is. Strip the trailing 3 pipe segments → title.
- **Attendees: opportunistic.** Only rendered in AX while the People pane is
  open: `AXOutline desc="Attendees"` → `AXRow` per person, e.g.
  `"Naufal Mir, Has context menu, Organizer, Muted"`, with child
  `AXStaticText`s for name/role separately. Count via `"In this meeting (N)"`.
- **Also emitted:** own mute state (`Unmute mic`/`Mute mic` button), elapsed
  time, `"Waiting for others to join..."` (solo tell), org + account email.
- **Bonus:** the main window's Calendar view leaks the whole Outlook
  calendar — see "Calendar via AX" below.

### Zoom (`us.zoom.xos`)

- **Title: NOT in the meeting window.** Always literally `"Zoom Meeting"`,
  even for a scheduled meeting with a custom topic.
- **Title fallback:** the Zoom Workplace *main* window's Home tab lists
  meetings with the running one marked `Now` — topic + `Host: <name>` are AX
  text there. Works for scheduled meetings only; instant meetings have no
  title anywhere → keep the `"Zoom call"` default.
- **Attendees:** the active-speaker tile emits
  `"<name>, Computer audio (un)muted"` *without any panel open*; with the
  Participants panel open, `AXOutline desc="Participants list"` →
  `"Naufal Mir (Host, me)"` + `"Participants (N)"`.

### Google Meet in a browser (tested: Brave)

- **Title: there is none.** Tab title is `Meet – <xxx-yyyy-zzz>` — the code,
  not a human title. Real titles only exist in the source calendar event.
- **URL/meeting code: two routes.** AppleScript tab enumeration (all tabs,
  needs Automation) and AX `AXDocument` on the window (active tab only).
- **In-call AX roster: untested** (dump didn't fire — see helper-bundle bug);
  probe v4 fixed the trigger, capture on a future Meet call.

## Calendar via AX — the Outlook data EventKit can't see

EventKit returned **zero events** here: the Exchange account lives only in
Outlook/Teams, not in macOS Calendar.app. But Teams' Calendar tab is an
**embedded Outlook web view** (`AXWebArea title="Calendar - Naufal Mir -
Outlook"`), so whenever that view is rendered, the full calendar is readable
through Accessibility. Each event is one `AXButton` whose description is a
complete record:

```
"Wickes Workshop, 09:00 to 11:00, Monday, June 01, 2026, By Alexander Kulinchenko, Tentative"
"andre on holiday, all day event, Monday, June 01, 2026 to Friday, June 05, 2026, somewhere nice, By Andre Nedelcoux, Free"
"Canceled: AI OPS and AI Data platform, 12:00 to 12:30, Thursday, June 04, 2026, Microsoft Teams Meeting, By Alexander Kulinchenko, Free, Rec…"
```

Schema per event (positional, comma-separated):
`[Canceled: ]<title>, <start> to <end> | all day event, <day>, <date>[, <location>][, Microsoft Teams Meeting], By <organizer>, <Free|Busy|Tentative>[, Recurring event | Exception to recurring event]`

**Why it matters beyond Teams:** Zoom/Meet meetings usually arrive as Outlook
invites, so they're in this calendar *with their real titles*. Detection
fires for Zoom (window says only "Zoom Meeting") → find the calendar event
overlapping "now" → real title + organizer + online-meeting flag. This is the
cross-app title source for Outlook-centric users, no Graph API needed.

The same pattern shows up twice more:

- **Zoom Workplace home tab**: running meeting listed as
  `zoom probe test / Now / Host: Naufal Mir` (see Zoom section).
- **Outlook app (native), Calendar view — tested**: weaker schema than the
  Teams web view. Events are bare buttons (`AXButton desc="<title>"`) grouped
  per day (`AXGroup desc="Thu, Jun 04, 2026"`) — title + day, **no times, no
  organizer**. However, the event that is currently joinable carries a child
  **`Join` button** — "today's event with a Join child" identifies the
  meeting happening *now* without any time math. Ad-hoc Teams "Meet now"
  meetings sync into this calendar too, so even unscheduled Teams calls can
  get a calendar identity.

**Caveats:**

- *Availability, not capability*: AX only exposes what's rendered. Teams
  sitting on Chat → no calendar in the tree (observed during the Zoom test).
  A fallback source, not an on-demand one — driving the UI to the Calendar
  tab from outside would be invasive and is out of scope.
- Only the visible date range (e.g. the rendered work week).
- Titles can contain commas (`"Christina x Wes - Intellias catch up., 15:00…"`)
  — don't comma-split; anchor on the `, HH:MM to HH:MM, ` time pattern:
  title = everything before it, fields after are positional.
- Strings are localized; treat parse failure as "no calendar match".

## Parley bug found (pre-existing, in main app)

`CallDetector.bestCandidate()` (`Parley/Detection/CallDetector.swift:122`)
**exact-matches** bundle IDs against `conferencingBundleIDs`, but browsers
capture the mic from a **helper process**: Brave reported
`com.brave.Browser.helper` (Chrome/Edge/Arc follow the same `.helper`
pattern). So browser meetings are never `known:` → auto-record doesn't
trigger, and `displayName()` falls through to the last bundle component —
the notification title becomes **"helper call"**. Fix: prefix-match
(`capturedBid.hasPrefix(knownBid + ".")`). Safari is unfixable this way —
WebKit captures as `com.apple.WebKit.GPU` (no Safari prefix).

## Proposed capture design (for the wiring task)

1. **TitleResolver, AX-based** (needs one new permission: Accessibility).
   On `onCallStart`: snapshot the app's AX windows; poll ~every 2s for up to
   ~15s; pick the new/focused window; parse per-app (Teams: strip pipe
   segments + reject nav views; Zoom: if `"Zoom Meeting"`, try the main
   window's `Now` event, else default; browser: tab title/URL, Meet code).
   Resolution order per call:
   1. call-window title (Teams — reliable when present)
   2. **calendar lookup** across whichever sources happen to be rendered:
      Teams Calendar tab (time-overlap match → title + organizer +
      online-meeting flag), Outlook Calendar view (today's event with a
      `Join` child button → title), Zoom home (`Now` entry → topic + host) —
      works across apps for Outlook-invited Zoom/Meet/Webex meetings
   3. recurring-meeting memory: same Meet code / Zoom meeting seen before →
      reuse the previous title
   4. fall back to today's `"<App> call"` — never worse than current behavior.
2. **Attendee accumulation, best-effort.** During the call, on each poll scan
   for the roster outline (`Attendees` / `Participants list`); union names
   seen over time into `SessionManifest.attendees` (field already exists).
   Names also feed speaker-name resolution for diarization.
3. **Detection fix:** prefix-match helper bundles in `bestCandidate()`.
4. **Risks:** AX label strings are localization-dependent (prefer structural
   anchors); Teams/Zoom UI updates can break parsing (degrade to the current
   default title, never worse than today); Electron trees need the
   `AXManualAccessibility` switch flipped before they exist.
