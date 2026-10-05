# Candidate 3 — Per-app `MeetingSource`

**Shape:** one source object per conferencing app. `TeamsSource`, `ZoomSource`, `WebexSource` each
own everything app-specific — which windows are the call window, when the Electron switches must be
flipped, how often a tree walk is affordable, what "the People pane is closed" means, whether a
missing name proves absence. Each returns the same two domain values: an optional `TitleCandidate`
and a `RosterSnapshot`. The poller is a dumb clock: it fires a timer, snapshots running pids, hands
the source a `ScanContext`, and forwards what comes back. It contains no app names.

Adding Webex is a new file plus one registry line. There is no `if isTeamsCall` anywhere.

---

## README (the consumer's view)

```swift
import Parley   // Detection + Meeting

// 1. The registry is the single source of truth about conferencing apps:
//    which bundle ids they own, what to call them, and whether we can read
//    metadata out of them at all. CallDetector's known-app set and display-name
//    map are derived from it, not maintained beside it.
MeetingSourceRegistry.claimedBundleIDs      // ["com.microsoft.teams2", "us.zoom.xos", "cisco-systems.spark", …]
MeetingSourceRegistry.displayName(for: "cisco-systems.spark")   // "Webex"

// 2. One poller per app run. It knows nothing about Teams, Zoom, or Webex.
let poller = MeetingSourcePoller()
poller.onReading = { reading in … }
poller.start(for: call)     // no-op when no source claims call.bundleID
poller.freeze()             // stop scanning, keep what was found (preview / call ended)

// 3. Every tick delivers one reading. `title` is ranked by authority, not by
//    arrival order. `roster` is always present — `.unreadable` coverage is a
//    fact ("we could not see"), not an empty list ("nobody is here").
struct SourceReading {
    let title: TitleCandidate?
    let roster: RosterSnapshot
}

// 4. The session folds snapshots into a MeetingRoster. Presence, arrival, and
//    the user's admit/dismiss decisions live there; nothing else accumulates.
meeting.roster.presentNow           // [KnownPerson] — in the call right now
meeting.roster.invited              // [KnownPerson] — on the invite list, never observed in-call
meeting.roster.person(named:)       // lookup by comma-free DisplayName
```

The whole public vocabulary is six types: `DisplayName`, `Presence`, `KnownPerson`,
`RosterSnapshot`, `TitleCandidate`, `MeetingRoster`. No `AXUIElement`, no `AXNode`, no window
titles, no bundle-id branching reaches the controller or the UI.

---

## Call site 1 — `RecordingController.startCallDetection`

Replaces the `metadataResolver.onUpdate` closure and deletes `mergeRoster` entirely.

```swift
sourcePoller.onReading = { [weak self] reading in
    guard let self else { return }

    // Title: authority-ranked. A late call-window title still wins over an
    // early calendar guess, so `titleLocked` (first-wins) is gone.
    if let candidate = reading.title {
        self.meeting.offerTitle(candidate)
    }

    // Roster: a pure fold. `.unreadable` snapshots change nothing; `.complete`
    // snapshots can mark someone as having left; `.sightings` only ever adds.
    self.meeting.roster.apply(reading.roster)

    // Policy is one pure function over the fold. People clearly in the call
    // become attendees without a tap; everything uncertain stays a chip.
    for name in AttendeePolicy.admissions(in: self.meeting.roster) {
        self.meeting.roster.record(.admitted(.automatic), for: name)
        self.addAttendeeIfAbsent(name.value)
    }
    self.scheduleMetadataSync()
}

callDetector.onCallStart = { [weak self] call in
    guard let self else { return }
    self.meeting.resetDiscovery()          // clears roster + title locks, including titleWasUserEdited
    self.sourcePoller.start(for: call)     // silently does nothing for Chrome/Safari/unclaimed apps
    …
}

callDetector.onCallEnd = { [weak self] _ in
    self?.sourcePoller.freeze()            // chips and names stay usable for speaker matching
    …
}
```

`admissions(in:)` is idempotent: it only returns people whose `decision` is still `.undecided`, so
re-running it on every tick admits each person exactly once, and a user dismissal is permanent.

## Call site 2 — the inspector's suggestion area

Presence is a type distinction, so the view stops being a filter over a bag.

```swift
struct SuggestionChips: View {
    @ObservedObject var meeting: MeetingSessionState
    @ObservedObject var recording: RecordingController

    var body: some View {
        // Uncertain in-call names only: rooms, "Naufal's MacBook", unmatched devices.
        // People are already in the attendees field by the time this renders.
        ForEach(AttendeePolicy.uncertainChips(in: meeting.roster)) { person in
            ChipRow(person: person,
                    detail: detail(for: person),
                    add:     { recording.admit(person) },
                    dismiss: { recording.dismiss(person) })
        }

        // Invited-but-never-joined are a separate, collapsed affordance. They are
        // never the same chip as someone in the room, and there is no "Add all".
        if !meeting.roster.invited.isEmpty {
            DisclosureGroup("\(meeting.roster.invited.count) invited, not joined") {
                ForEach(meeting.roster.invited) { person in
                    ChipRow(person: person, detail: "invited",
                            add: { recording.admit(person) }, dismiss: { recording.dismiss(person) })
                }
            }
        }
    }

    /// The UI cannot claim a join time it does not have. `Arrival` says which
    /// of these three sentences is true.
    private func detail(for person: KnownPerson) -> String {
        switch person.arrival {
        case .joined(let at):            return "joined \(Self.hhmm.string(from: at))"
        case .presentBeforeFirstSight:   return "in call"
        case .neverObserved:             return "invited"
        }
    }
}
```

Recording controls: `recording.admit(person)` / `recording.dismiss(person)` write a decision into the
roster and add/remove the name from `meeting.attendees`. Dismiss is the undo for an auto-admit.

## Call site 3 — adding Webex (the reason this shape exists)

```swift
// Parley/Detection/Sources/WebexSource.swift   ← the only new file
final class WebexSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Webex",
        matchers: [.exact("cisco-systems.spark"), .exact("com.cisco.webexmeetingsapp")],
        capability: .none)          // ← flips to .titleAndRoster when the dumps land
    …
}

// Parley/Detection/MeetingSource.swift
enum MeetingSourceRegistry {
    static let all: [any MeetingSource.Type] = [TeamsSource.self, ZoomSource.self, WebexSource.self]
    //                                                                           ^^^^^^^^^^^^^^^^ the diff
}
```

Nothing else changes. Webex immediately becomes a *known* app (auto-record eligible, display name
"Webex" instead of `"spark call"`) because the detector's known set is derived from the registry —
while its parsers are still `fatalError("not implemented")`, guarded by `capability: .none` so the
poller never calls them. `known` and *metadata-capable* are two different facts, and this is where
they stop being confused.

## Call site 4 — a source test against a recorded probe dump

Sources are pure functions of a tree reader, so the whole per-app story is testable with zero AX.

```swift
@Test func teamsSeparatesPresentFromInvited() {
    let ctx = ScanContext.fixture(tick: 2, tree: RecordedUITree(.teamsPeoplePane_2026_06))
    let reading = TeamsSource(call: .fixtureTeams).read(ctx)

    #expect(reading.roster.coverage == .complete)
    #expect(reading.roster.participants.filter(\.isInCall).map(\.name.value)
            == ["Oleksii Brodnikov", "Adam Rosen", "Naufal Mir"])
    #expect(reading.roster.participants.filter(\.isInvited).map(\.name.value)
            == ["Tetyana Kravchenko", "Olga Ivanova"])       // ← today these are chips; that is the bug
}

@Test func teamsPeoplePaneClosedIsUnreadableNotEmpty() {
    let ctx = ScanContext.fixture(tick: 2, tree: RecordedUITree(.teamsCallNoPeoplePane))
    #expect(TeamsSource(call: .fixtureTeams).read(ctx).roster.coverage == .unreadable)
}
```

The second test is the one today's code cannot express: an empty roster and a closed pane are
currently the same value, so the controller can never tell "nobody" from "we didn't look".
