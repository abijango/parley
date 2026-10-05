# Meeting presence — caller's view (candidate A)

Presence is a **parse distinction**, not a controller invention. Parsers tag each discovered person as `present`, `invited`, or `unknown` at the moment AX rows are read. `MeetingMetadataResolver` stays the deep module (poll, title lock, calendar rationing, AX queue). The controller applies one thin policy at the boundary: admit present people, drop invited-not-joined, chip only uncertain names.

## Quickstart

Import nothing new beyond existing Detection + Recording modules. Wire stays the same:

```swift
metadataResolver.onUpdate = { [weak self] meta in
    self?.applyDiscoveredMetadata(meta)
}
```

`DiscoveredMetadata` now carries `[MeetingParticipant]` instead of flat `[RosterEntry]`. Each participant already knows whether they were in the "In this meeting" section, the "Others invited" section, or could not be classified.

**Policy defaults (product):**

| `ParticipantPresence` | Attendees field | Suggestion chips |
|---|---|---|
| `.present` | Auto-added on first sighting | Hidden (already admitted) |
| `.invited` | Never | Never shown |
| `.unknown` | Never until tap | Shown; tap or dismiss |

Title behavior is unchanged: auto-fill while default; chip after user edit.

---

## Call site 1 — `RecordingController.startCallDetection` (metadata callback)

Today this calls `mergeRoster(meta.roster)` and treats every name the same. Replace with a single boundary function that trusts parser presence:

```swift
metadataResolver.onUpdate = { [weak self] meta in
    guard let self else { return }

    if let title = meta.title {
        self.meeting.setDiscoveredTitle(title, source: meta.titleSource ?? "")
        if !self.meeting.titleWasUserEdited,
           self.meeting.isDefaultTitle {
            self.meeting.meetingTitle = title
            self.meeting.titleSource = meta.titleSource
        }
    }

    self.applyParticipantDiscovery(meta.participants)
    self.scheduleMetadataSync()
}

/// Boundary policy: parsers decided presence; controller only routes.
private func applyParticipantDiscovery(_ participants: [MeetingParticipant]) {
    for person in participants {
        let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }

        switch person.presence {
        case .present:
            addAttendeeIfAbsent(name)
            upsertSuggestion(
                name: name,
                role: person.role,
                presence: .present,
                markAccepted: true
            )

        case .invited:
            // Outlook invite list — intentionally dropped. Do not chip, do not admit.
            continue

        case .unknown:
            upsertSuggestion(
                name: name,
                role: person.role,
                presence: .unknown,
                markAccepted: false
            )
        }
    }
}
```

`upsertSuggestion` preserves existing union semantics: `firstSeen` stamped once, role backfilled, entries never removed when someone leaves. Present people get `accepted = true` so chips stay empty for names already in the attendees field.

---

## Call site 2 — `MeetingMetadataResolver` (unchanged wiring, richer payload)

Resolver callers do not learn Teams section headers or Zoom tile heuristics. They receive domain participants:

```swift
// Inside scan(_:) after AX walk — background queue only
if job.wantRoster, let pid = job.callPid {
    if isTeamsCall {
        ensureElectronAX(pid: pid)
        let nodes = walkCallWindows(pid: pid) {
            MeetingParsers.teamsCallTitle(windowTitle: $0) != nil
        }
        result.participants = MeetingParsers.teamsParticipants(nodes)
    } else if isZoomCall {
        let nodes = walkCallWindows(pid: pid) { $0 == "Zoom Meeting" }
        result.participants = MeetingParsers.zoomParticipants(nodes)
    } else if isWebexCall {
        // Dump-driven later; stub returns [] until MeetingProbe capture lands.
        result.participants = MeetingParsers.webexParticipants(nodes: [])
    }
}
```

Title resolution, `titleLocked`, calendar ticks, and `onUpdate` gating are unchanged. Resolver also sets `AXUIElementSetMessagingTimeout` once per walk so a wedged Teams tree cannot block `parley.meeting-ax` indefinitely.

---

## Call site 3 — `SuggestionChips` (defense-in-depth filter)

Chips should only render uncertain names. Present people are already in attendees; invited people never enter `suggestedAttendees`. The view adds a cheap guard so a policy regression does not resurrect invite-list chips:

```swift
private var pending: [SuggestedAttendee] {
    meeting.suggestedAttendees.filter {
        !$0.accepted && !$0.dismissed && $0.recommendationKind == .needsConfirmation
    }
}
```

`recommendationKind` is derived from stored `presence` (`.unknown` → needs confirmation; `.present` → already handled). No AX types, no merge logic, no section-header strings in the view.

---

## What callers do **not** do

- Parse `"Others invited, N total"` or `"In this meeting, N total"`.
- Decide join time beyond first sighting of a **present** participant.
- Click People/Calendar or depend on Graph/EventKit.
- Block recording when AX returns empty participants.

## Manifest compatibility

`SuggestedAttendee` gains an optional `presence` field (`"present" | "invited" | "unknown"`). Old `session.json` files decode with `presence == nil` → treated as `.unknown` for chip display (safe default: opt-in tap). New sessions stamp presence on every suggestion.
