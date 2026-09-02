import Foundation

/// Shared control surface for the two background queues (`OfflineProcessingService`,
/// `SummaryService`) so the Processing tab can drive them uniformly: see the order,
/// jump one to the front ("Do next"), and drop a queued one. User cancel of a
/// queued job does not touch the running one. Live capture calls
/// `yieldToLiveRecording()` separately, which does preempt the runner.
@MainActor
protocol ProcessingQueue: AnyObject {
    /// Queued job ids in run order, front-first. Excludes the currently-running job.
    var queuedIDs: [String] { get }
    /// Move a queued job to the front. No-op if it's running or not queued.
    func prioritize(id: String)
    /// Reorder a queued job to `index` (0 = front). No-op if running or not queued.
    func move(id: String, to index: Int)
    /// Skip this job while draining until released.
    func hold(id: String)
    /// Resume a held job.
    func releaseHold(id: String)
    /// True when the job is held overnight / manually skipped.
    func isHeld(id: String) -> Bool
    /// Remove a queued job. No-op (let it finish) if it's the running one.
    func cancelQueued(id: String)
}

/// Maps SwiftUI's merged-list move destination into one queue's own ordering.
/// Rows from the other queue, plus running rows, do not consume queue positions.
enum ProcessingQueueOrder {
    nonisolated static func destinationIndex<Row>(
        movingFrom sourceIndex: Int,
        to destination: Int,
        in rows: [Row],
        belongsToQueue: (Row) -> Bool
    ) -> Int? {
        guard rows.indices.contains(sourceIndex) else { return nil }
        var remaining = rows
        remaining.remove(at: sourceIndex)
        let adjusted = destination > sourceIndex ? destination - 1 : destination
        let insertion = min(max(adjusted, 0), remaining.count)
        return remaining.prefix(insertion).filter(belongsToQueue).count
    }
}
