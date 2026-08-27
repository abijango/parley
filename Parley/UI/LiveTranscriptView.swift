import SwiftUI

/// Live transcription stream. Rows render in an AppKit table so SwiftUI layout
/// never sizes individual lines. Naming still uses a SwiftUI popover.
struct LiveTranscriptView: View {
    let isRecording: Bool
    var people: [String] = []
    var attendees: [String] = []
    var onNameSpeaker: ((String, String) -> Void)? = nil
    var liveDisabled: Bool = false
    var hidesEmptyState: Bool = false

    var body: some View {
        LiveTranscriptTable(
            store: RecordingController.shared.live.segmentStore,
            isRecording: isRecording,
            people: people,
            attendees: attendees,
            onNameSpeaker: onNameSpeaker,
            liveDisabled: liveDisabled,
            hidesEmptyState: hidesEmptyState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Speaker-naming sheet used from the AppKit row popover.
struct TranscriptSpeakerNamer: View {
    @State var draft: String
    let people: [String]
    let attendees: [String]
    let onCommit: (String) -> Void

    var body: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let attendeeSet = Set(attendees.map { $0.lowercased() })
        let matches: [String] = trimmed.isEmpty ? [] : people.filter {
            $0.lowercased().contains(trimmed.lowercased())
                && $0.caseInsensitiveCompare(trimmed) != .orderedSame
                && !attendeeSet.contains($0.lowercased())
        }.prefix(5).map { $0 }

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Name this speaker").font(Theme.Typography.sheetTitle)

            if !attendees.isEmpty {
                Text("In this call").font(Theme.Typography.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        ForEach(attendees, id: \.self) { name in
                            Button(name) { onCommit(name) }
                                .glassButton()
                        }
                    }
                }
                .frame(maxHeight: 120)
                Divider()
            }

            Text("Other name").font(Theme.Typography.caption).foregroundStyle(.secondary)
            TextField("Type a name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { save() }

            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(matches, id: \.self) { person in
                        Button(person) { draft = person }
                            .buttonStyle(.plain)
                            .font(Theme.Typography.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 264)
    }

    private func save() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onCommit(name)
    }
}
