import Foundation

/// What caused a note to (potentially) enter the summary queue. Drives the
/// auto-vs-confirm decision so a fresh single recording summarizes silently while a
/// bulk wave (assigning speakers across a backlog, or pending work found at launch)
/// asks once instead of firing a burst that could exhaust Claude usage.
enum SummaryTrigger: Equatable {
    case freshRecording          // a non-speaker engine recording just finished
    case speakerReviewCompleted  // user finished naming speakers
    case offlinePassCompleted    // an async offline pass auto-resolved all speakers
    case launchBacklog           // pending-summary intent found on disk at launch
    case userInitiated           // explicit "Summarize" / "Summarize anyway" press
}

/// The decision for one enqueue attempt.
enum EnqueueDecision: Equatable {
    case enqueue                 // run it (subject to throttle/idle gates downstream)
    case skipAutoOff             // auto-summarize is off and this isn't user-initiated
    case confirmBulk(count: Int) // would queue ≥ threshold at once → ask the user first
}

/// Pure policy: given the trigger, the auto-run setting, the bulk threshold, and how
/// many summaries are already queued/pending, decide whether to enqueue silently, skip,
/// or ask for one bulk confirmation. Unit-tested in isolation.
struct SummaryEnqueuePolicy: Equatable {
    var autoRunClaude: Bool
    var bulkThreshold: Int

    func decide(trigger: SummaryTrigger, alreadyQueuedOrPending: Int) -> EnqueueDecision {
        // An explicit press always runs and never asks.
        if trigger == .userInitiated { return .enqueue }
        // Auto-summary off → only user-initiated runs.
        guard autoRunClaude else { return .skipAutoOff }
        // This attempt would make the in-flight count cross the threshold → confirm once.
        if alreadyQueuedOrPending + 1 >= max(2, bulkThreshold) { return .confirmBulk(count: alreadyQueuedOrPending + 1) }
        return .enqueue
    }
}
