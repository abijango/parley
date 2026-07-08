import Foundation

/// Merges the two tracks' segments into one chronological timeline.
///
/// Each track reports its confirmed and unconfirmed segments separately; the
/// merger keeps the latest set per track and produces a single array sorted by
/// start time (shared-clock seconds). Per-track arrays are assumed sorted by
/// `start`; merging uses a linear k-way combine instead of sorting the full
/// concatenation on every update.
final class TranscriptMerger: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed: [SpeakerTrack: [Segment]] = [:]
    private var unconfirmed: [SpeakerTrack: [Segment]] = [:]
    /// Prior segments loaded on resume (from a crashed session's journal). Kept
    /// separate so live pipeline updates to `confirmed` don't overwrite them, yet
    /// they still appear in the timeline and the final transcript.
    private var seeded: [SpeakerTrack: [Segment]] = [:]

    /// Called whenever an update recomputes the merged timeline (always on the main actor).
    var onChange: (@MainActor ([Segment]) -> Void)?

    func update(track: SpeakerTrack, confirmed: [Segment], unconfirmed: [Segment]) {
        lock.lock()
        self.confirmed[track] = confirmed
        self.unconfirmed[track] = unconfirmed
        let merged = mergedLocked()
        lock.unlock()
        if let onChange {
            Task { @MainActor in onChange(merged) }
        }
    }

    /// All confirmed segments, sorted.
    func confirmedTimeline() -> [Segment] {
        lock.lock()
        defer { lock.unlock() }
        return mergeSortedLocked(lists: [
            seeded[.me] ?? [],
            seeded[.remote] ?? [],
            confirmed[.me] ?? [],
            confirmed[.remote] ?? [],
        ])
    }

    /// Confirmed PLUS the trailing unconfirmed tail — used when writing the final
    /// transcript on stop: there's no more audio coming to confirm the tail, so
    /// those tentative segments are final and must be included.
    func finalTimeline() -> [Segment] {
        lock.lock()
        defer { lock.unlock() }
        return mergedLocked()
    }

    /// Seed prior segments (resume): they show immediately and are included on
    /// finalize, but are NOT part of `confirmedTimeline()` (already journaled).
    func seed(_ segments: [Segment]) {
        lock.lock()
        for track in [SpeakerTrack.me, .remote] {
            seeded[track] = segments.filter { $0.track == track }
        }
        let merged = mergedLocked()
        lock.unlock()
        if let onChange {
            Task { @MainActor in onChange(merged) }
        }
    }

    func reset() {
        lock.lock()
        confirmed.removeAll()
        unconfirmed.removeAll()
        seeded.removeAll()
        lock.unlock()
    }

    // MARK: - Merge (lock held)

    private func mergedLocked() -> [Segment] {
        mergeSortedLocked(lists: [
            seeded[.me] ?? [],
            seeded[.remote] ?? [],
            confirmed[.me] ?? [],
            confirmed[.remote] ?? [],
            unconfirmed[.me] ?? [],
            unconfirmed[.remote] ?? [],
        ])
    }

    /// Linear merge of sorted segment lists (each list sorted by `start`).
    private func mergeSortedLocked(lists: [[Segment]]) -> [Segment] {
        var indices = [Int](repeating: 0, count: lists.count)
        var out: [Segment] = []
        out.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        while true {
            var bestList: Int?
            var bestStart = TimeInterval.greatestFiniteMagnitude
            for i in lists.indices where indices[i] < lists[i].count {
                let start = lists[i][indices[i]].start
                if start < bestStart {
                    bestStart = start
                    bestList = i
                }
            }
            guard let pick = bestList else { break }
            out.append(lists[pick][indices[pick]])
            indices[pick] += 1
        }
        return out
    }
}