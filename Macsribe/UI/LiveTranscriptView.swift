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
    var onNameSpeaker: ((String, String) -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        TranscriptRow(segment: segment, people: people, onNameSpeaker: onNameSpeaker)
                            .id(segment.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay { if segments.isEmpty { emptyState } }
            .onChange(of: segments.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isRecording ? "waveform" : "text.bubble")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(isRecording ? "Listening…" : "Start recording to see the live transcript")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private static let bottomID = "transcript-bottom"
}

/// One transcript line. The speaker label is a naming affordance when the segment
/// is diarized (`speakerId != nil`) and a naming callback is provided.
private struct TranscriptRow: View {
    let segment: Segment
    let people: [String]
    let onNameSpeaker: ((String, String) -> Void)?

    @State private var showNamer = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
            speakerLabel
            Text(segment.text)
                .font(.body)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Name this speaker").font(.headline)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { save(id, commit) }

            let matches = people.filter {
                !draft.trimmingCharacters(in: .whitespaces).isEmpty
                    && $0.lowercased().contains(draft.lowercased())
                    && $0.caseInsensitiveCompare(draft) != .orderedSame
            }.prefix(5)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches), id: \.self) { p in
                        Button(p) { draft = p }.buttonStyle(.plain).font(.callout)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Save") { save(id, commit) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 248)
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
        case .me: return .accentColor
        case .remote: return .green
        }
    }
}
