import SwiftUI

/// Discovered-attendee suggestions, mounted under the Attendees field in the
/// inspector rail. Each person found in the meeting roster (via Accessibility)
/// is offered as a chip — tap to add to attendees, ✕ to dismiss (e.g. a
/// conference-room roster entry that isn't a real person). Nothing is ever
/// added without an explicit tap. Chips show the join time (first sighting in
/// the roster) and stay available after the call ends, which helps when
/// matching diarized speakers to names.
struct SuggestionChips: View {
    @ObservedObject var recording: RecordingController

    private static let joinFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var pending: [SuggestedAttendee] {
        recording.suggestedAttendees.filter { !$0.accepted && !$0.dismissed }
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text("Suggested from the call")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                ForEach(pending) { suggestion in
                    HStack(spacing: Theme.Spacing.xSmall) {
                        Button {
                            recording.acceptSuggestion(suggestion.name)
                        } label: {
                            HStack(spacing: Theme.Spacing.xSmall) {
                                Image(systemName: "plus.circle.fill")
                                Text(suggestion.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(detail(for: suggestion))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.chip)
                        .help("Add to attendees")
                        Button {
                            recording.dismissSuggestion(suggestion.name)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Not an attendee (e.g. a meeting room)")
                    }
                }
                if pending.count > 1 {
                    Button("Add all") { recording.acceptAllSuggestions() }
                        .buttonStyle(.chip)
                }
            }
        }
    }

    /// "Organizer · joined 10:03" / "joined 10:03"
    private func detail(for s: SuggestedAttendee) -> String {
        let joined = "joined \(Self.joinFormatter.string(from: s.firstSeen))"
        return s.role.map { "\($0) · \(joined)" } ?? joined
    }
}
