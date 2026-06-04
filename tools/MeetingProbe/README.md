# MeetingProbe

Investigation spike: when `CallDetector` fires (a conferencing app starts
capturing the mic), what meeting metadata is observable from outside the
process — and which source carries the human-readable **meeting title** per
app? Run this during real meetings and review the log afterwards.

## Usage

```sh
cd tools/MeetingProbe
swift run MeetingProbe                                  # one full snapshot
swift run MeetingProbe --watch --log ~/meetingprobe.log # change-only timeline
swift run MeetingProbe --watch --interval 10            # slower polling
swift run MeetingProbe --dump-ax com.microsoft.teams2   # walk an app's full AX tree NOW
```

In `--watch` mode, ~10s after a probed app takes the mic the probe
automatically deep-dumps that app's Accessibility tree (section 6) — for
Electron apps like Teams this mirrors the web app's ARIA tree, so participant
tiles, the roster panel (open it during the call to capture names!), the call
timer and mute states all show up as labeled elements. Chromium only builds
this tree for assistive clients, so the dump first flips the documented
`AXManualAccessibility`/`AXEnhancedUserInterface` switches.

Leave `--watch` running in a terminal through a few meetings (Teams, Zoom,
Meet-in-browser, Slack huddle…). It only logs *changes*, so the log reads as
a timeline: mic acquired → window title flipped to the meeting name → mic
released.

## What it probes

| # | Source | Permission needed | What it can yield |
|---|--------|-------------------|-------------------|
| 1 | Core Audio mic snapshot | none (same API Parley uses) | which app is in a call — ground truth for correlating the rest |
| 2 | `CGWindowList` window titles | Screen Recording | window titles incl. meeting name (heavyweight permission) |
| 3 | Accessibility (`AXTitle`, `AXDocument`) | Accessibility | same titles with a lighter permission; Chromium also exposes the active-tab URL via `AXDocument` |
| 4 | Browser tabs via AppleScript | Automation (per browser) | meeting tab title **and URL** even when the tab isn't frontmost; Firefox unsupported |
| 5 | EventKit calendar | Calendars | event title/attendees/organizer — only for accounts synced into macOS Calendar.app (Outlook-app-only accounts are invisible) |

Grant permissions to the **terminal app** you run this from (it's the TCC
responsible process for a CLI tool).

## Early findings (baseline, 2026-06-04)

- **Teams** (`com.microsoft.teams2`): window title is pipe-delimited and
  carries the selected/active meeting name, e.g.
  `Calendar | Interview: ProAG Case Study | Intellias | <account> | Microsoft Teams`.
  Need an in-call sample to confirm the in-call window format.
- **Chromium browsers**: AX exposes `AXDocument` (active-tab URL) on the
  focused window — title + URL without AppleScript, but only for the
  *frontmost* tab. AppleScript sees all tabs.
- **EventKit**: granted but empty when the Exchange account lives only in
  Outlook — calendar correlation is not viable here without Outlook/Graph
  integration.
