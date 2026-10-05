# Meeting admission — caller's view

Present people are attendees. The Record tab fills as they appear in the call. There is no tap-to-add for someone the parser saw under **In this meeting**. Invited-not-joined never become chips. The only chips are names we cannot treat as people (rooms, devices). Removing a token is undo for that session: Accessibility will not put them back.

`RecordingController` does not merge a roster bag. It applies a `MeetingSighting` to `MeetingAdmission`. Admission writes `meeting.attendees` and the uncertain-chip list. Title auto-fill vs user-edit chip is unchanged.

Recording still does not depend on Accessibility. A wedged Teams tree cannot stall capture. Old `session.json` still decodes.

## What the inspector shows

- **Attendees TokenField** — already contains in-call people as they join (and anyone the user typed, plus speaker-ID names).
- **Uncertain chips** — only rooms/devices; tap admits, ✕ dismisses. No "Add all". No "joined HH:mm".
- **Title** — auto-fill while the field is still a default; chip after `userEditedTitle()`.

## Call site 1 — discovery tick (`RecordingController.startCallDetection`)

```swift
metadataResolver.onUpdate = { [weak self] sighting in
    guard let self else { return }

    if let title = sighting.title {
        self.meeting.setDiscoveredTitle(title.text, source: title.source.rawValue)
        if !self.meeting.titleWasUserEdited {
            self.meeting.applyDiscoveredTitleIfAllowed(title.text, source: title.source.rawValue)
            self.scheduleMetadataSync()
        }
    }

    self.admission.ingest(sighting)   // auto-admits present people; chips only uncertain
    self.scheduleMetadataSync()
}

callDetector.onCallStart = { [weak self] call in
    guard let self else { return }
    self.meeting.resetDiscovery()     // also clears titleWasUserEdited + admission exclusions
    self.admission.reset()
    self.metadataResolver.start(for: call)
    // … auto-record / notify unchanged; AX never gates start()
}

callDetector.onCallEnd = { [weak self] call in
    self?.metadataResolver.enterPreviewMode()
    // attendees + uncertain chips stay; freeze polling only
    // … auto-stop unchanged
}
```

`mergeRoster`, `acceptSuggestion`, `acceptAllSuggestions` are gone. Speaker-ID keeps calling `admission.addRecognized(_)` (same attendee string; does not honor AX exclusions — a voiceprint is a different signal).

## Call site 2 — Record-tab inspector (`MainWindowView` + chips)

```swift
railField("Attendees") {
    TokenField(tokens: attendeesBinding,
               completions: vault.people,
               placeholder: "Add attendees",
               onCreateNew: { name in pendingPerson = PendingPerson(name: name) })
        .onChange(of: meeting.attendees) { _, _ in
            recording.admission.tokenFieldChanged(
                to: TranscriptWriter.splitAttendees(meeting.attendees))
            recording.scheduleMetadataSync()
            recording.userInteracted()
        }
    if !attendeesBinding.wrappedValue.isEmpty {
        Button("Clear all attendees") {
            recording.admission.clearAll()   // exclusions so the next tick cannot refill
        }
        .buttonStyle(.chip)
    }
    UncertainChips(meeting: meeting, admission: recording.admission)
}

struct UncertainChips: View {
    @ObservedObject var meeting: MeetingSessionState
    var admission: MeetingAdmission

    var body: some View {
        if !meeting.pendingUncertain.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text("Might not be people")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                ForEach(meeting.pendingUncertain) { chip in
                    HStack {
                        Button {
                            admission.admitUncertain(chip.id)
                        } label: {
                            Label(chip.display.text, systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.chip)
                        .help("Add anyway")
                        Text(chip.kind.caption)   // "Room" / "Device"
                            .foregroundStyle(.secondary)
                        Button {
                            admission.dismissUncertain(chip.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .help("Ignore")
                    }
                }
            }
        }
    }
}
```

`tokenFieldChanged` diffs against the previous attendee list. Names that disappeared become session exclusions. Names that appeared because `ingest` wrote them are not treated as user intent. Do not assign `meeting.attendees = ""` from the view — that would lose the exclusion and the next AX tick would refill the field.

## Call site 3 — crash resume + heartbeat (`RecordingController.resume` / `persistManifest`)

```swift
func resume(_ session: RecoverableSession) async {
    // …
    meeting.meetingTitle = m.title
    admission.restore(from: m)   // attendees string, exclusions, uncertain chips
    // do not auto-admit leftover SuggestedAttendee rows from old manifests
    // …
}

private func persistManifest(status: SessionManifest.Status) {
    persistManifest(
        status: status,
        // …
        attendees: meeting.attendees,
        titleSource: meeting.titleSource,
        suggestedAttendees: nil,                 // stop writing the old bag
        excludedAttendees: admission.excludedDisplayNames,
        uncertainChips: meeting.uncertainChips.isEmpty ? nil : meeting.uncertainChips)
}
```

`SessionManifest.suggestedAttendees` stays optional Codable so pre-this-feature files decode. Restore maps old dismissed names into exclusions and old leftover unaccepted rows into uncertain chips — never into auto-admit (that bag mixed invite list with presence).
