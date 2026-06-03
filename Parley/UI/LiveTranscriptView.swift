import SwiftUI

/// The live transcription stream: one chronological row per segment, with a
/// monospaced timestamp, a speaker label, and the text. Tentative (unconfirmed)
/// segments are dimmed; the view auto-scrolls to the newest row.
///
/// When `onNameSpeaker` is set (FluidAudio engine), the speaker label is a tappable
/// chip — clicking it names that speaker (free text or a Rolodex contact), which
/// relabels all their lines and enrols their voiceprint.
struct LiveTranscriptView: View {
    let segments: [Segment]
    let isRecording: Bool
    var people: [String] = []
    /// The attendees already selected for this call — shown as one-tap picks.
    var attendees: [String] = []
    var onNameSpeaker: ((String, String) -> Void)? = nil
    /// Offline-only mode: no live stream is produced; show a "generated at stop"
    /// placeholder while recording instead of "Listening…".
    var liveDisabled: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(segments) { segment in
                        TranscriptRow(segment: segment, people: people, attendees: attendees, onNameSpeaker: onNameSpeaker)
                            .id(segment.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay { if segments.isEmpty { emptyState } }
            .onChange(of: segments.count) {
                withAnimation(Theme.Motion.gentle) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    // The primary action (Start recording) lives in the always-visible control bar
    // above, so these empty states are informational — no redundant action button.
    @ViewBuilder private var emptyState: some View {
        if liveDisabled {
            EmptyStateView(
                icon: isRecording ? "waveform.badge.magnifyingglass" : "doc.text",
                title: isRecording ? "Recording" : "Offline-only mode",
                detail: isRecording ? "The transcript is generated when you stop."
                                    : "The transcript appears after you stop recording.",
                animateIcon: isRecording)
        } else {
            EmptyStateView(
                icon: isRecording ? "waveform" : "text.bubble",
                title: isRecording ? "Listening…" : "Start recording",
                detail: isRecording ? "Transcribed text will appear here in real time."
                                    : "Your live transcript will appear here as people speak.",
                animateIcon: isRecording)
        }
    }

    private static let bottomID = "transcript-bottom"
}

/// One transcript line. The speaker label is a naming affordance when the segment
/// is diarized (`speakerId != nil`) and a naming callback is provided.
private struct TranscriptRow: View {
    let segment: Segment
    let people: [String]
    let attendees: [String]
    let onNameSpeaker: ((String, String) -> Void)?

    @State private var showNamer = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Text(segment.timestamp)
                .font(Theme.Typography.mono)
                .foregroundStyle(.tertiary)
            speakerLabel
            Text(segment.text)
                .font(Theme.Typography.reading)
                .foregroundStyle(segment.confirmed ? .primary : .secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .opacity(segment.confirmed ? 1.0 : 0.6)
    }

    @ViewBuilder private var speakerLabel: some View {
        let label = Text(segment.displaySpeaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Self.color(for: segment))
            .frame(width: 80, alignment: .leading)
            .lineLimit(1)

        if let id = segment.speakerId, let onNameSpeaker {
            Button { draft = segment.speakerName ?? ""; showNamer = true } label: { label }
                .buttonStyle(.plain)
                .help("Click to name this speaker")
                .popover(isPresented: $showNamer) { namer(id: id, commit: onNameSpeaker) }
        } else {
            label
        }
    }

    private func namer(id: String, commit: @escaping (String, String) -> Void) -> some View {
        let d = draft.trimmingCharacters(in: .whitespaces)
        let attendeeSet = Set(attendees.map { $0.lowercased() })
        let matches: [String] = d.isEmpty ? [] : people.filter {
            $0.lowercased().contains(d.lowercased())
                && $0.caseInsensitiveCompare(d) != .orderedSame
                && !attendeeSet.contains($0.lowercased())
        }.prefix(5).map { $0 }

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Name this speaker").font(Theme.Typography.sheetTitle)

            // One-tap picks: people already selected as attendees for this call.
            if !attendees.isEmpty {
                Text("In this call").font(Theme.Typography.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    ForEach(attendees, id: \.self) { name in
                        Button(name) { commit(id, name); showNamer = false }
                            .glassButton()
                    }
                }
                Divider()
            }

            Text("Other name").font(Theme.Typography.caption).foregroundStyle(.secondary)
            TextField("Type a name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { save(id, commit) }

            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(matches, id: \.self) { p in
                        Button(p) { draft = p }.buttonStyle(.plain).font(Theme.Typography.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Save") { save(id, commit) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(d.isEmpty)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 264)
    }

    private func save(_ id: String, _ commit: (String, String) -> Void) {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        commit(id, name)
        showNamer = false
    }

    /// Color by diarized speaker when known (stable palette), else by capture track.
    static func color(for segment: Segment) -> Color {
        if let id = segment.speakerId {
            let palette: [Color] = [.green, .orange, .purple, .pink, .teal, .indigo, .brown, .cyan]
            return palette[abs(id.hashValue) % palette.count]
        }
        switch segment.track {
        case .me: return Theme.Palette.accent
        case .remote: return .green
        }
    }
}
