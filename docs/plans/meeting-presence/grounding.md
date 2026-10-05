# Phase A grounding — meeting title & presence

Traced 2026-08-19 against current Detection + Record-tab metadata. Existing structure is the constraint: call detection, AX discovery, and inspector chips already exist. The design must push back on *what* they recommend, not replace recording.

## What the user wants

Priority apps: **Teams (highest)** → Zoom → other (Webex currently invisible). Reliable **meeting title**. Attendees **recommended when present / as they join**, not everyone on the invite list. Current method works; UX is the problem.

## Current data flow

```
Core Audio process objects
  CallProcessProbe.processesCapturingInput() → [AudioInputProcess]
    CallDetector.evaluate() → DetectedCall { pid, bundleID, displayName, known }
      onCallStart:
        meeting.resetDiscovery()
        metadataResolver.start(for: call)
        if known && autoRecord: meetingTitle = "<App> call"; start()
        else: notify
      MeetingMetadataResolver ticks (2.5s) on axQueue
        MeetingParsers.* → DiscoveredMetadata { title?, titleSource?, roster: [RosterEntry] }
          RecordingController.onUpdate:
            setDiscoveredTitle / maybe overwrite default title
            mergeRoster → SuggestedAttendee { name, role?, firstSeen, accepted, dismissed }
              UI: Title field + "Use …" chip; TokenField attendees; SuggestionChips
                SessionManifest.stamped → session.json
```

Mic capture is ground truth for *that a call exists*. AX is best-effort metadata. Recording must never depend on AX (Settings copy already says this).

## Ownership today

| Concern | Owner | Notes |
|---|---|---|
| Is a call happening | `CallDetector` | Debounced mic holders; known vs unknown |
| Known apps | `AppSettings.conferencingBundleIDs` | Defaults omit Webex |
| Title + roster scan | `MeetingMetadataResolver` | Main-actor timer, AX on `parley.meeting-ax` |
| Parse AX → domain | `MeetingParsers` (pure) | English-only string anchors |
| AX C API | `AXClient` only | No messaging timeout set |
| Session fields | `MeetingSessionState` | Title, attendees string, suggestion list |
| Merge / accept / persist | `RecordingController` | `mergeRoster`, `acceptSuggestion`, manifest heartbeat |
| Chips | `SuggestionChips` | Opt-in; never auto-added |

## Invariants the new design must honor

1. **AX failure is silent.** Missing trust, empty tree, parse miss → nothing; recording continues.
2. **Title auto-fill only while still a default** (`""`, `"Recorded call"`, suffix `" call"`). After `userEditedTitle()`, discovery offers a chip (`acceptDiscoveredTitle`).
3. **`titleLocked`** in the resolver: first non-nil title wins; calendar is not retried after that. Title give-up is ~16s; roster continues the whole call.
4. **Suggestions never auto-enter `meeting.attendees`.** Tap (or Add all) required. `firstSeen` is first AX sighting, not conferencing-app join time.
5. **Suggestions never disappear** when someone leaves (`mergeRoster` unions only).
6. **Helper bundle prefix-match** (`com.brave.Browser.helper` → parent). Safari/`com.apple.WebKit.GPU` remains unmatched.
7. **Electron AX switches** (`AXManualAccessibility`) flipped once per pid, then 1s sleep on the AX queue.
8. **Calendar walks rationed** to ticks 3 and 6 (whole-window trees). Teams/Outlook calendar only if that UI is already rendered — never drive the UI to Calendar.
9. **AX off the main actor.** Freeze investigation: hung AX stalls discovery, not recording — but missing `AXUIElementSetMessagingTimeout` can leak `parley.meeting-ax` forever if Teams/Webex wedges.
10. **Attendees stored comma-delimited.** Names must not contain commas (`normalizeDisplayName` flips `"Rosen, Adam"`).

## Call sites that must keep working

- `RecordingController.startCallDetection` wiring `metadataResolver.onUpdate` / `onCallStart` / `onCallEnd`
- `MeetingSessionState` published fields the inspector binds
- `SessionManifest.suggestedAttendees` / `titleSource` (optional Codable; old manifests)
- Speaker-name matching and `FluidVocabularyBuilder` using attendee names + title
- History add-attendee / Rolodex completions
- `MeetingParsersTests` fixtures from live MeetingProbe dumps (2026-06)

## Per-app reality (probe + code)

### Teams (`com.microsoft.teams2` / `.teams`) — highest priority

- **Title:** reliable from the *call window* after 5–10s settle. Form `<title> \| <org> \| <account> \| Microsoft Teams`. Main window leading nav (`Calendar`, `Chat`, …) is rejected. Generic `"Microsoft Teams"` returns nil so polling continues.
- **Presence vs invite — the UX bug:** `teamsAttendees` walks `AXOutline desc="Attendees"` and skips section-header rows (`"In this meeting, N total"` / `"Others invited, N total"`) but **includes every person row in both sections**. `MeetingParsersTests.testTeamsAttendeesParsesRosterRows` asserts invited-not-joined people (Tetyana, Olga with Tentative / In a meeting) are suggestions. That is why chips dump the Outlook invite list.
- **Roster requires the People pane open.** Investigation: names only in AX while that pane is rendered. Closed pane → empty roster → empty chips, then a dump when opened (firstSeen = pane-open time, not join time).
- **No tile-based presence parser** analogous to Zoom's `"<name>, Computer audio (un)muted"` `AXTabGroup`.

### Zoom (`us.zoom.xos`)

- **Title:** meeting window is literally `"Zoom Meeting"`. Fallback: Zoom Workplace home `"Now"` group, or Teams/Outlook calendar if rendered. Instant meetings stay `"Zoom call"`.
- **Presence:** speaker tiles work *without* the Participants panel; panel adds the full list + Host role. No invite-list section analogous to Teams "Others invited" in the current parser.

### Webex (`Cisco-Systems.Spark` → lowercased `cisco-systems.spark`)

- **Not in `defaultConferencingBundleIDs`.** Mic capture still produces a `DetectedCall` with `known: false` → notify only, no auto-record. `CallDetector.displayName` has no Webex entry → last component `"spark"` if localizedName missing → `"spark call"`.
- **No parsers, no resolver branch.** `isTeamsCall` / `isZoomCall` only. A live Webex session was recorded (`2026-08-07-130135` "Rado Catchup") — detection of the process works; metadata does not.
- **No MeetingProbe dump in-repo** for Webex window title / roster. Parsers must be dump-driven, same as Teams/Zoom.
- External 2026 research (not yet probed in this repo): meeting window title is the space/meeting name; ignore the generic messaging window titled exactly `Webex`. In-call vs chat can be told via AX automation ids like `callControl_end`. Cisco documents weak screen-reader support on the participant list — expect presence gaps. Legacy bundle `com.cisco.webexmeetingsapp` may still exist.

## Extra constraints from a full code trace

- Speaker-ID already **auto-adds** recognized names via `addAttendeeIfAbsent` — chips are not the only attendee writer. Auto-admit of present people would match that path, not invent a new one.
- `resume(_:)` restores title/attendees from the manifest but **drops** `suggestedAttendees` / `discoveredTitle` from UI state.
- First `session.json` write omits suggestions; the 5s heartbeat adds them.
- Manual Start during an already-detected call **keeps** pre-record discoveries; a cold manual start clears them.
- Graph live roster (`rosterUpdated`) is cloud/app-only webhooks — not a Mac-local source. `attendanceReports` is post-call. Zoom Plugin SDK has a real live roster API but needs OAuth + same-account Marketplace app — not Parley's primary path.
- `CGWindowList` titles need Screen Recording and duplicate AX window titles. Do not add that permission for this feature.
- Do not silently AX-click People/Participants. Product already forbids driving conferencing UI.

### Google Meet / browsers

- Tab title is the meeting code, not the human title. Helper prefix-match exists. No Meet roster parser. Lower priority than Webex for this user.

### Calendar / EventKit

- EventKit empty when Exchange lives only in Outlook/Teams (this user's setup). Teams Calendar tab AX is the cross-app title fallback **if that tab is already showing**. Not an on-demand source. Graph/OAuth is out of scope unless a design explicitly accepts a new identity stack — it still would not be live presence.

## Why the current UX feels bad

1. Teams recommendations = invite list ∪ present people, indistinct.
2. Presence is invisible until the user opens People (Teams).
3. Join time is poll/pane time, so "as they join" is a lie when the pane opens late.
4. Webex never enters the metadata pipeline.
5. Zoom titles often stay the default `"Zoom call"` unless home/calendar happens to be on screen.
6. `Add all` on a large invite list is the worst action in the UI.
7. Opt-in chips are correct for *uncertain* names (rooms, "Naufal's MacBook") but wrong friction for people clearly in the call.

## Design must not

- Block or couple recording / stop / crash-recovery to AX or calendar.
- Drive conferencing UI (click People, switch to Calendar).
- Treat Graph/EventKit invite lists as presence.
- Guess Webex AX shapes without a live dump (MeetingProbe is the capture tool).
- Put wire/AX types (`AXUIElement`, raw node arrays) on the controller/UI surface.
- Walk whole Electron trees on the main actor, or without a messaging timeout.

## Open product questions (for arena, not silent defaults)

- Auto-accept **present** people into attendees vs keep tap-to-add for everyone?
- Keep invited-not-joined as a collapsed secondary list, or drop them entirely?
- How far to go hunting presence without the People pane (tiles, participant count, mute buttons)?
