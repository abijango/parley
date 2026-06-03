import Foundation

/// Merges the two tracks' segments into one chronological timeline.
///
/// Each track reports its confirmed and unconfirmed segments separately; the
/// merger keeps the latest set per track and produces a single array sorted by
/// start time (shared-clock seconds). Runs on the main actor so it can publish
/// straight to the UI.
@MainActor
final class TranscriptMerger {
    private var confirmed: [SpeakerTrack: [Segment]] = [:]
    private var unconfirmed: [SpeakerTrack: [Segment]] = [:]
    /// Prior segments loaded on resume (from a crashed session's journal). Kept
    /// separate so live pipeline updates to `confirmed` don't overwrite them, yet
    /// they still appear in the timeline and the final transcript.
    private var seeded: [SpeakerTrack: [Segment]] = [:]

    /// Called whenever a `onChange` recomputes the merged timeline.
    var onChange: (([Segment]) -> Void)?

    func update(track: SpeakerTrack, confirmed: [Segment], unconfirmed: [Segment]) {
        self.confirmed[track] = confirmed
        self.unconfirmed[track] = unconfirmed
        onChange?(merged())
    }

    /// All confirmed segments, sorted.
    func confirmedTimeline() -> [Segment] {
        confirmed.values.flatMap { $0 }.sorted { $0.start < $1.start }
    }

    /// Confirmed PLUS the trailing unconfirmed tail — used when writing the final
    /// transcript on stop: there's no more audio coming to confirm the tail, so
    /// those tentative segments are final and must be included.
    func finalTimeline() -> [Segment] {
        merged()
    }

    /// Seed prior segments (resume): they show immediately and are included on
    /// finalize, but are NOT part of `confirmedTimeline()` (already journaled).
    func seed(_ segments: [Segment]) {
        for track in [SpeakerTrack.me, .remote] {
            seeded[track] = segments.filter { $0.track == track }
        }
        onChange?(merged())
    }

    func reset() {
        confirmed.removeAll()
        unconfirmed.removeAll()
        seeded.removeAll()
    }

    private func merged() -> [Segment] {
        let all = seeded.values.flatMap { $0 }
            + confirmed.values.flatMap { $0 }
            + unconfirmed.values.flatMap { $0 }
        return all.sorted { $0.start < $1.start }
    }
}
