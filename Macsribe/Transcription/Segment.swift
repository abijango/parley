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

    /// Diarization cluster id within a session (FluidAudio engine), e.g. "1", "2".
    /// `nil` when diarization hasn't attributed this segment (or for WhisperKit).
    var speakerId: String?
    /// Resolved display name once a speaker is mapped to a known person (Phase 5).
    /// `nil` until mapped.
    var speakerName: String?

    init(id: UUID = UUID(), track: SpeakerTrack, start: TimeInterval, end: TimeInterval,
         text: String, confirmed: Bool, speakerId: String? = nil, speakerName: String? = nil) {
        self.id = id
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.confirmed = confirmed
        self.speakerId = speakerId
        self.speakerName = speakerName
    }

    /// The label shown/written for this segment: a mapped name if known, else the
    /// diarized "Speaker N", else the capture track ("Me"/"Remote").
    var displaySpeaker: String {
        if let speakerName, !speakerName.isEmpty { return speakerName }
        if let speakerId { return "Speaker \(speakerId)" }
        return track.label
    }

    /// `[HH:MM:SS]` timestamp from `start`.
    var timestamp: String {
        let total = Int(start.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "[%02d:%02d:%02d]", h, m, s)
    }

    /// One transcript line, e.g. `[00:03:12] Me: text`.
    var transcriptLine: String {
        "\(timestamp) \(displaySpeaker): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Markdown form with a bold speaker label, e.g. `**[00:03:12] Me:** text`.
    /// Rendered as its own line/paragraph when joined by blank lines.
    var markdownLine: String {
        "**\(timestamp) \(displaySpeaker):** \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
