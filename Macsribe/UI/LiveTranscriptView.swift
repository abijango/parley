import SwiftUI

/// The live transcription stream: one chronological row per segment, with a
/// monospaced timestamp, a color-coded speaker label, and the text. Tentative
/// (unconfirmed) segments are dimmed; the view auto-scrolls to the newest row.
struct LiveTranscriptView: View {
    let segments: [Segment]
    let isRecording: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        row(for: segment).id(segment.id)
                    }
                    // Anchor for auto-scroll.
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

    private func row(for segment: Segment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(segment.displaySpeaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color(for: segment))
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.confirmed ? .primary : .secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .opacity(segment.confirmed ? 1.0 : 0.6)
    }

    /// Color by diarized speaker when known (stable per-speaker palette), else by track.
    private func color(for segment: Segment) -> Color {
        if let id = segment.speakerId {
            let palette: [Color] = [.green, .orange, .purple, .pink, .teal, .indigo, .brown, .cyan]
            let idx = abs(id.hashValue) % palette.count
            return palette[idx]
        }
        switch segment.track {
        case .me: return .accentColor
        case .remote: return .green
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
