import Foundation

/// Which track a transcript segment came from. Because we capture the mic and
/// the system/app audio as two separate streams, the source track *is* the
/// speaker label — no ML diarization required.
enum SpeakerTrack: String, Codable {
    case me = "Me"
    case remote = "Remote"

    var label: String { rawValue }
}

/// One transcribed segment, timed against the shared recording clock (seconds
/// since record-start) so segments from both tracks sort into one timeline.
struct Segment: Identifiable, Codable, Equatable {
    let id: UUID
    let track: SpeakerTrack
    /// Seconds since record-start (shared clock), NOT the per-pipeline clock.
    let start: TimeInterval
    let end: TimeInterval
    var text: String
    /// Confirmed segments are stable; unconfirmed are tentative live output.
    var confirmed: Bool

    init(id: UUID = UUID(), track: SpeakerTrack, start: TimeInterval, end: TimeInterval, text: String, confirmed: Bool) {
        self.id = id
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.confirmed = confirmed
    }

    /// `[HH:MM:SS]` timestamp from `start`.
    var timestamp: String {
        let total = Int(start.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "[%02d:%02d:%02d]", h, m, s)
    }

    /// One transcript line, e.g. `[00:03:12] Me: text`.
    var transcriptLine: String {
        "\(timestamp) \(track.label): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Markdown form with a bold speaker label, e.g. `**[00:03:12] Me:** text`.
    /// Rendered as its own line/paragraph when joined by blank lines.
    var markdownLine: String {
        "**\(timestamp) \(track.label):** \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
