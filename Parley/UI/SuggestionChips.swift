import SwiftUI

/// Uncertain in-call labels (rooms, devices). People clearly in the meeting are
/// auto-added to attendees; invite-list names are not shown.
struct SuggestionChips: View {
    @ObservedObject var meeting: MeetingSessionState
    var onAccept: (String) -> Void
    var onDismiss: (String) -> Void
    var onAcceptAll: () -> Void

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
                            onAccept(suggestion.name)
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
                            onDismiss(suggestion.name)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Ignore this label")
                    }
                }
                if pending.count > 1 {
                    Button("Add all") { onAcceptAll() }
                        .buttonStyle(.chip)
                }
            }
        }
    }
}
