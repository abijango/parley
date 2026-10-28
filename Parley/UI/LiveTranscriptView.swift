import SwiftUI

/// Live transcription stream: the speaker strip over an AppKit table, so SwiftUI
/// layout never sizes individual lines. Naming happens in the strip's menus.
struct LiveTranscriptView: View {
    let isRecording: Bool
    var people: [String] = []
    var attendees: [String] = []
    var onNameSpeaker: ((String, String) -> Void)? = nil
    var onMergeSpeaker: ((String, String) -> Void)? = nil
    var liveDisabled: Bool = false
    var hidesEmptyState: Bool = false

    private var store: LiveSegmentStore { RecordingController.shared.live.segmentStore }

    var body: some View {
        VStack(spacing: 0) {
            if let onNameSpeaker {
                SpeakerStrip(
                    roster: store.roster,
                    people: people,
                    attendees: attendees,
                    onName: onNameSpeaker,
                    onMerge: onMergeSpeaker ?? { _, _ in })
            }
            LiveTranscriptTable(
                store: store,
                isRecording: isRecording,
                canNameSpeakers: onNameSpeaker != nil,
                liveDisabled: liveDisabled,
                hidesEmptyState: hidesEmptyState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Speaker-naming menu opened from a strip chip (or a row's speaker label).
struct TranscriptSpeakerNamer: View {
    var title: String = "Name this speaker"
    @State var draft: String
    let people: [String]
    let attendees: [String]
    /// Other live speakers, for "Same person as…".
    var others: [LiveSpeaker] = []
    let onCommit: (String) -> Void
    var onMerge: ((String) -> Void)? = nil

    var body: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let attendeeSet = Set(attendees.map { $0.lowercased() })
        let matches: [String] = trimmed.isEmpty ? [] : people.filter {
            $0.lowercased().contains(trimmed.lowercased())
                && $0.caseInsensitiveCompare(trimmed) != .orderedSame
                && !attendeeSet.contains($0.lowercased())
        }.prefix(5).map { $0 }

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(title).font(Theme.Typography.sheetTitle)

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

            if let onMerge, !others.isEmpty {
                Divider()
                Text("Same person as").font(Theme.Typography.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: Theme.Spacing.xSmall) {
                    ForEach(others) { other in
                        Button {
                            onMerge(other.id)
                        } label: {
                            Label(other.displayName, systemImage: "circle.fill")
                                .labelStyle(SpeakerDotLabelStyle(color: SpeakerPalette.color(for: other.id)))
                        }
                        .glassButton()
                        .help("Merge into \(other.displayName)")
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

/// Small coloured dot + title, for speaker buttons in the naming menu.
private struct SpeakerDotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
        }
    }
}
