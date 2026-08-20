import Foundation

/// Owns auto-admit, uncertain chips, and session exclusions from TokenField deletes.
@MainActor
final class MeetingAdmission {
    private unowned let meeting: MeetingSessionState
    private var lastTokens: [String] = []

    init(meeting: MeetingSessionState) {
        self.meeting = meeting
    }

    func reset() {
        lastTokens = TranscriptWriter.splitAttendees(meeting.attendees)
        meeting.roster.reset()
        meeting.suggestedAttendees = []
    }

    func ingest(_ reading: SourceReading) {
        meeting.roster.apply(reading.roster)
        for name in AttendeePolicy.admissions(in: meeting.roster) {
            meeting.roster.record(.admitted(.automatic), for: name)
            appendAttendee(name.value)
        }
        publishUncertainChips()
        lastTokens = TranscriptWriter.splitAttendees(meeting.attendees)
    }

    func tokenFieldChanged(to names: [String]) {
        let normalized = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if normalized == lastTokens { return }
        let newKeys = Set(normalized.map { $0.lowercased() })
        for old in lastTokens where !newKeys.contains(old.lowercased()) {
            if let display = DisplayName(raw: old) {
                meeting.roster.exclude(display)
            }
        }
        lastTokens = normalized
        let joined = normalized.joined(separator: ", ")
        if meeting.attendees != joined {
            meeting.attendees = joined
        }
        publishUncertainChips()
    }

    func admitUncertain(_ name: String) {
        guard let display = DisplayName(raw: name) else { return }
        meeting.roster.record(.admitted(.user), for: display)
        appendAttendee(display.value)
        publishUncertainChips()
    }

    func dismissUncertain(_ name: String) {
        guard let display = DisplayName(raw: name) else { return }
        meeting.roster.exclude(display)
        publishUncertainChips()
    }

    func addRecognized(_ rawName: String) {
        guard let display = DisplayName(raw: rawName) else { return }
        meeting.roster.record(.admitted(.user), for: display)
        appendAttendee(display.value)
    }

    func restoreSuggestions(_ suggestions: [SuggestedAttendee]?) {
        meeting.roster.restore(from: suggestions)
        publishUncertainChips()
        lastTokens = TranscriptWriter.splitAttendees(meeting.attendees)
    }

    private func appendAttendee(_ name: String) {
        let current = TranscriptWriter.splitAttendees(meeting.attendees)
        guard !current.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        meeting.attendees = current.isEmpty ? name : meeting.attendees + ", " + name
    }

    private func publishUncertainChips() {
        meeting.suggestedAttendees = AttendeePolicy.uncertainChips(in: meeting.roster).map { person in
            let firstSeen: Date
            switch person.arrival {
            case .joined(let at): firstSeen = at
            case .presentBeforeFirstSight(let noticed): firstSeen = noticed
            case .neverObserved: firstSeen = Date()
            }
            return SuggestedAttendee(
                name: person.name.value,
                role: person.uncertainKind?.caption ?? person.role?.display,
                firstSeen: firstSeen,
                accepted: false,
                dismissed: false)
        }
    }
}
