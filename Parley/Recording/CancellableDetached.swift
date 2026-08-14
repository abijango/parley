import Foundation

/// A `Task.detached` whose cancel reaches the worker. Structured `Task { }`
/// cancel does not, which is why an offline pass kept the ANE busy after Start.
enum CancellableDetached {
    static func run<T: Sendable>(
        priority: TaskPriority? = nil,
        _ work: @Sendable @escaping () async -> T
    ) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Disk state after a live recording preempts an in-flight offline pass.
/// Attempts from the interrupted run are restored so Start cannot burn the retry budget.
enum OfflineJobPark {
    static func diskState(attemptsBeforeRun: Int) -> (status: SessionManifest.OfflineStatus, attempts: Int) {
        (.pending, attemptsBeforeRun)
    }
}

enum OfflineQueueCancel {
    static var diskStatus: SessionManifest.OfflineStatus { .cancelled }
}
