import SwiftUI

/// Uncertain in-call labels (rooms, devices). People clearly in the meeting are
/// auto-added to attendees; invite-list names are not shown.
struct SuggestionChips: View {
    @ObservedObject var meeting: MeetingSessionState
    @ObservedObject var recording: RecordingController

    private var pending: [SuggestedAttendee] {
        meeting.suggestedAttendees.filter { !$0.accepted && !$0.dismissed }
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text("Might not be a person")
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
                                if let role = suggestion.role {
                                    Text(role).foregroundStyle(.secondary)
                                }
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
                        .help("Ignore this label")
                    }
                }
                if pending.count > 1 {
                    Button("Add all") { recording.acceptAllSuggestions() }
                        .buttonStyle(.chip)
                }
            }
        }
    }
}
