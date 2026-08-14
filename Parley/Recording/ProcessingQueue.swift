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
    /// Remove a queued job. No-op (let it finish) if it's the running one.
    func cancelQueued(id: String)
}
