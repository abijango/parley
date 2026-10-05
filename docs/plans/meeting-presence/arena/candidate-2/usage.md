# Presence ledger

`MeetingMetadataResolver` still performs best-effort discovery and still has no say in whether recording starts or stops. Its callback now emits a value snapshot:

```swift
struct MeetingMetadataSnapshot {
    let observedAt: Date
    let title: TitleCandidate?
    let roster: RosterSnapshot?
}
```

`roster == nil` means “no roster surface was observed.” A non-nil empty roster is meaningful: a complete roster was observed with nobody present. The resolver emits a snapshot heartbeat on every discovery tick, even when AX is unavailable or both findings are nil, allowing the ledger to expire partial observations without treating a parse miss as absence. A snapshot separates in-call observations from invite-only observations before it leaves the resolver; callers never receive AX nodes or a flat `[RosterEntry]`.

`PresenceLedger` is the one owner of per-person history and policy. The controller sends it snapshots and user intents, then publishes the returned view. It does not union arrays, invent join times, or decide which evidence deserves a chip.

The default policy is fixed inside the ledger:

- a confirmed in-call person is accepted automatically;
- an ambiguous in-call entity, such as a room or device, becomes a recommendation;
- an invite-only person is retained as invite evidence but is neither accepted nor shown as an in-call recommendation;
- a complete snapshot can mark a previously present person not present; a partial snapshot can only add evidence;
- “first seen” means first observed by Parley, never a claimed conferencing-app join time.

The accepted attendee list is a ledger projection. Its comma-delimited form exists only for current transcript and manifest boundaries. Every `PersonName` is validated and normalized before entering the ledger, so a stored name cannot contain a comma.

## Call site 1: resolver updates in `RecordingController`

The resolver owns title-source authority and only emits a title when it improves the current candidate. The existing user-edit rule remains in `MeetingSessionState`; presence goes through one ledger command.

```swift
private var presenceLedger = PresenceLedger()

private func wireMeetingDiscovery() {
    metadataResolver.onUpdate = { [weak self] snapshot in
        guard let self else { return }

        if let title = snapshot.title {
            meeting.setDiscoveredTitle(
                title.value,
                source: title.source.manifestValue
            )
            meeting.applyDiscoveredTitleIfAllowed(
                title.value,
                source: title.source.manifestValue
            )
        }

        applyPresence(.observe(snapshot.roster, at: snapshot.observedAt))
    }
}

/// Main-actor adapter from the domain transition to existing observable and
/// persistence boundaries. It contains no roster or recommendation policy.
private func applyPresence(_ command: PresenceLedger.Command) {
    let change = presenceLedger.apply(command)
    meeting.presence = change.view
    meeting.attendees = change.view.accepted.commaDelimited

    if change.acceptedChanged || change.durableStateChanged {
        scheduleMetadataSync()
    }
}
```

When the call ends, the resolver stops. The final ledger view remains published for preview and speaker assignment. Recording teardown does not wait for either component.

## Call site 2: inspector recommendations and attendee tokens

The inspector renders projections and sends IDs back. It does not filter `accepted` and `dismissed` flags itself.

```swift
ForEach(meeting.presence.recommendations) { recommendation in
    HStack {
        Button {
            recording.acceptPresenceRecommendation(recommendation.id)
        } label: {
            Label(recommendation.person.displayName, systemImage: "plus.circle.fill")
        }

        Button {
            recording.dismissPresenceRecommendation(recommendation.id)
        } label: {
            Image(systemName: "xmark")
        }
    }
}

TokenField(
    tokens: Binding(
        get: { meeting.presence.accepted.names.map(\.displayName) },
        set: { recording.replaceAcceptedAttendees($0) }
    ),
    completions: vault.people,
    placeholder: "Add attendees"
)
```

The controller actions are intent adapters. Validation happens before commands enter the ledger.

```swift
func acceptPresenceRecommendation(_ id: ParticipantID) {
    applyPresence(.accept(id, origin: .user))
}

func dismissPresenceRecommendation(_ id: ParticipantID) {
    applyPresence(.dismissRecommendation(id))
}

func replaceAcceptedAttendees(_ rawNames: [String]) {
    let names = rawNames.compactMap(PersonName.init)
    applyPresence(.replaceAccepted(names, origin: .manualEdit))
}
```

The UI labels observation time as “seen 10:03,” not “joined 10:03.” Confirmed present people normally bypass this view because the ledger has already accepted them.

## Call site 3: speaker identification and crash-safe persistence

Speaker identification and manual entry use the same acceptance transition as presence. This removes the second attendee writer from `RecordingController`.

```swift
fluid.onSpeakerIdentified = { [weak self] rawName in
    guard let self, let name = PersonName(rawName) else { return }
    applyPresence(.acceptName(name, origin: .speakerIdentification))
}
```

`SessionManifest` adds an optional `presenceLedger` field. New writes persist the ledger and derive the legacy comma-delimited attendee string from it. `suggestedAttendees` remains optional for decoding old sessions; the adapter consumes it only when the new field is absent.

```swift
private func persistManifest(status: SessionManifest.Status) {
    var stamped = currentManifest
    stamped.status = status
    stamped.attendees = presenceLedger.view.accepted.commaDelimited
    stamped.presenceLedger = presenceLedger.storedState
    stamped.suggestedAttendees = nil
    SessionStore.write(stamped, to: sessionDirectory)
}

private func restorePresence(from manifest: SessionManifest) {
    presenceLedger = PresenceManifestAdapter.restore(from: manifest)
    meeting.presence = presenceLedger.view
    meeting.attendees = presenceLedger.view.accepted.commaDelimited
}
```

`PresenceManifestAdapter` maps legacy accepted names and `SuggestedAttendee` values into domain restore records. Old `session.json` files therefore decode and regain their prior accepted/dismissed state without making the ledger depend on the old storage type.
