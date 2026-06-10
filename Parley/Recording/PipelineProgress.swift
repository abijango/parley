import Foundation

// MARK: - JobProgress

/// A point-in-time snapshot of one offline job's pipeline position. Kept separate from
/// `JobUIState` (queue membership) so high-rate fraction updates do not invalidate
/// queue-membership observers. Stage order mirrors the actual execution order; Summarize
/// is SummaryService-owned and fused in the UI layer rather than tracked here.
struct JobProgress: Equatable, Sendable {
    enum Stage: Int, CaseIterable, Comparable, Sendable {
        case mix, transcribeAndDiarize, attribute, compact

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var stage: Stage
    /// 0…1 fill for the current segment. `nil` means indeterminate (UI renders a shimmer).
    var fraction: Double?
    /// Human-readable detail beneath the bar, e.g. "transcribe 52% · speakers 74%".
    var sublabel: String?
    var startedAt: Date
}

// MARK: - JobProgressRelay

/// Converts raw `EngineProgressEvent` signals (fired at arbitrary rate from arbitrary
/// threads) into throttled `JobProgress` snapshots published on the main actor.
///
/// Coalescing rules (≤5 Hz):
/// - A stage change always publishes immediately.
/// - Within a stage, fraction updates are batched: a publish fires only when ≥0.2 s have
///   elapsed since the last one.
///
/// Thread safety: an `NSLock` guards the mutable state; the only MainActor hop is the
/// `Task { @MainActor in }` that calls the publish closure.
final class JobProgressRelay: @unchecked Sendable {

    private let jobID: String
    private let publish: @MainActor (String, JobProgress) -> Void

    private let lock = NSLock()

    // Internal tracking
    private var stage: JobProgress.Stage = .mix
    private var startedAt: Date = .init()
    private var asrFraction: Double? = nil    // nil = no signal yet
    private var diarFraction: Double? = nil   // nil = no signal yet
    private var asrDone = false
    private var diarDone = false
    private var compactFraction: Double? = nil
    private var sublabel: String? = nil
    private var lastPublishTime: Date = .distantPast
    private var pendingPublish = false

    init(jobID: String, publish: @escaping @MainActor (String, JobProgress) -> Void) {
        self.jobID = jobID
        self.publish = publish
    }

    // MARK: Engine-driven events (any thread)

    /// Forward a raw engine event. High-rate: may be called many times per second.
    /// Stage-change events publish immediately; fraction-update events are throttled.
    func report(_ event: EngineProgressEvent) {
        lock.lock()
        // The very first snapshot always publishes immediately — the relay's internal
        // stage starts at .mix, so a plain "did the stage change?" test would swallow it.
        let isFirstPublish = lastPublishTime == .distantPast
        // stageChanged = true → publish immediately; false → throttled publish.
        let stageChanged: Bool
        let hasUpdate: Bool
        switch event {
        case .mixStarted:
            stageChanged = transition(to: .mix, fraction: nil, sublabel: nil)
            hasUpdate = stageChanged
        case .mixDone:
            // Advance to the concurrent transcribe+diarize stage now that the mix is ready.
            // Reset the asr/diar tracking so late stray events from a previous pass don't
            // pollute the new stage.
            asrFraction = nil; diarFraction = nil; asrDone = false; diarDone = false
            stageChanged = transition(to: .transcribeAndDiarize, fraction: nil, sublabel: nil)
            hasUpdate = stageChanged
        case .asr(let f):
            asrFraction = max(asrFraction ?? 0, f)
            stageChanged = false
            hasUpdate = updateTranscribeStage()
        case .diarization(let f):
            diarFraction = max(diarFraction ?? 0, f)
            stageChanged = false
            hasUpdate = updateTranscribeStage()
        case .asrDone:
            asrDone = true
            asrFraction = 1.0
            stageChanged = false
            hasUpdate = updateTranscribeStage()
        case .diarizationDone:
            diarDone = true
            diarFraction = 1.0
            stageChanged = false
            hasUpdate = updateTranscribeStage()
        case .attributeStarted:
            stageChanged = transition(to: .attribute, fraction: nil, sublabel: nil)
            hasUpdate = stageChanged
        case .attributeDone:
            // Stay on .attribute; the service drives the transition to .compact.
            stageChanged = false
            hasUpdate = false
        }
        lock.unlock()
        if stageChanged || (isFirstPublish && hasUpdate) {
            schedulePublish(immediate: true)
        } else if hasUpdate {
            schedulePublish(immediate: false)
        }
    }

    /// Service-driven stage transitions and override values (any thread). Stage changes
    /// publish immediately; compact fraction updates are throttled (≤5 Hz) since
    /// AudioCompactor calls this every ~50 buffer iterations.
    func set(stage: JobProgress.Stage, fraction: Double?, sublabel: String?) {
        lock.lock()
        let isFirstPublish = lastPublishTime == .distantPast
        if stage == .transcribeAndDiarize {
            // Reset concurrent tracking when entering this stage.
            asrFraction = nil
            diarFraction = nil
            asrDone = false
            diarDone = false
        }
        let stageChanged = transition(to: stage, fraction: fraction, sublabel: sublabel)
        lock.unlock()
        if stageChanged || isFirstPublish {
            // Stage transitions (and the first-ever snapshot) are immediately visible.
            schedulePublish(immediate: true)
        } else if fraction != nil {
            // Fraction-only update (e.g. compact progress) — apply throttling.
            schedulePublish(immediate: false)
        }
    }

    // MARK: Private helpers — must be called with lock held

    /// Move to a new stage. Returns true if the stage actually changed.
    @discardableResult
    private func transition(to newStage: JobProgress.Stage, fraction: Double?, sublabel: String?) -> Bool {
        let changed = newStage != stage
        if changed {
            stage = newStage
            startedAt = Date()
        }
        self.sublabel = sublabel
        // For .compact we set the fraction directly.
        if newStage == .compact { compactFraction = fraction }
        return changed
    }

    /// Recompute the .transcribeAndDiarize fraction from the latest asr/diar values.
    /// Called with lock held; returns whether a publish should fire.
    private func updateTranscribeStage() -> Bool {
        guard stage == .transcribeAndDiarize else {
            // Events can arrive late while already on a later stage — ignore.
            return false
        }

        // Effective value for each side:
        //   - nil:  no signal yet → treat the whole bar as indeterminate until EITHER side reports
        //   - done: 1.0
        //   - in-progress: the fraction itself
        let effAsr: Double? = asrDone ? 1.0 : asrFraction
        let effDiar: Double? = diarDone ? 1.0 : diarFraction

        // Build the sublabel (only show percentages that have arrived).
        let asrPct  = effAsr.map  { Int(($0 * 100).rounded()) }
        let diarPct = effDiar.map { Int(($0 * 100).rounded()) }
        if let a = asrPct, let d = diarPct {
            sublabel = "transcribe \(a)% · speakers \(d)%"
        } else if let a = asrPct {
            sublabel = "transcribe \(a)%"
        } else if let d = diarPct {
            sublabel = "speakers \(d)%"
        } else {
            sublabel = nil
        }

        // Segment fill = min(asr, diar) — monotone, completes only when BOTH sides do.
        // If neither side has sent a signal yet the fraction is nil (indeterminate shimmer).
        // Once one side completes it counts as 1.0, so the bar can't stall waiting for the other.
        switch (effAsr, effDiar) {
        case (nil, nil):
            return false  // still indeterminate, nothing changed visually
        case (let a?, nil):
            // Only ASR has reported; diar is silent — treat as indeterminate for now so
            // the bar doesn't jump to a specific fraction prematurely. We show the sublabel
            // though so the user sees SOME progress.
            _ = a   // keep for the sublabel path above
            return true  // sublabel changed
        case (nil, let d?):
            _ = d
            return true
        case (let a?, let d?):
            // Both sides active; sublabel already updated. Fraction advances.
            _ = (a, d)   // satisfy the exhaustive switch
            return true
        }
    }

    // MARK: Snapshot (lock-free snapshot building — called after lock released)

    private func currentSnapshot() -> JobProgress {
        lock.lock()
        defer { lock.unlock() }
        return snapshot()
    }

    /// Atomically stamp the deferred publish as fired and snapshot the latest state.
    /// Synchronous so the async deferred-publish Task never touches the lock directly
    /// (NSLock lock/unlock is illegal in async contexts under Swift 6).
    private func consumeDeferredPublish() -> JobProgress {
        lock.lock()
        defer { lock.unlock() }
        lastPublishTime = Date()
        pendingPublish = false
        return snapshot()
    }

    /// Build a snapshot from current state. Must be called with lock held.
    private func snapshot() -> JobProgress {
        let f: Double?
        switch stage {
        case .mix:
            f = nil
        case .transcribeAndDiarize:
            let effAsr: Double? = asrDone ? 1.0 : asrFraction
            let effDiar: Double? = diarDone ? 1.0 : diarFraction
            switch (effAsr, effDiar) {
            case (nil, nil): f = nil
            case (let a?, nil): f = a   // one side only → show that side's fraction
            case (nil, let d?): f = d
            case (let a?, let d?): f = min(a, d)
            }
        case .attribute:
            f = nil
        case .compact:
            f = compactFraction
        }
        return JobProgress(stage: stage, fraction: f, sublabel: sublabel, startedAt: startedAt)
    }

    // MARK: Publish scheduling

    private func schedulePublish(immediate: Bool) {
        lock.lock()
        if immediate {
            lastPublishTime = Date()
            let snap = snapshot()
            pendingPublish = false
            lock.unlock()
            let id = jobID
            let pub = publish
            Task { @MainActor in pub(id, snap) }
            return
        }

        // A scheduled deferred publish re-snapshots at fire time, so it already carries
        // whatever this update changed — bail out rather than double-publish at the
        // throttle boundary (fast path + deferred firing back-to-back).
        guard !pendingPublish else { lock.unlock(); return }

        let elapsed = Date().timeIntervalSince(lastPublishTime)
        if elapsed >= 0.2 {
            lastPublishTime = Date()
            let snap = snapshot()
            lock.unlock()
            let id = jobID
            let pub = publish
            Task { @MainActor in pub(id, snap) }
        } else {
            pendingPublish = true
            let delay = 0.2 - elapsed
            lock.unlock()
            let id = jobID
            let pub = publish
            let relay = self
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Re-snapshot at fire time so we always publish the latest state.
                let latest = relay.consumeDeferredPublish()
                await MainActor.run { pub(id, latest) }
            }
        }
    }

}
