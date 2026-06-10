import Foundation

/// The single, fused view of where a note sits in the processing pipeline — derived
/// from the three scattered state sources (file flags on `TranscriptItem`, the offline
/// queue, the summary queue + throttle) so History renders one coherent status instead
/// of stitching ad-hoc checks. Presentation-layer only.
enum PipelineStage: Equatable {
    case detectingSpeakers      // offline pass running now
    case queuedForSpeakers      // offline pass waiting (for idle)
    case needsSpeakerNames      // offline done but generic "Speaker N" labels remain
    case summarizing            // Claude summary running now
    case queuedForSummary       // summary queued / awaiting bulk confirm
    case reviewReady            // summary staged, awaiting commit
    case processed              // committed + filed
    case idleUnprocessed        // nothing in flight, no staged summary, nothing pending
    case failed(PipelineFailure)
}

enum PipelineFailure: Equatable {
    case speakerDetection(String)
    case summary(String)
    case claudeUsageLimited(resumeAt: Date?)
}

extension PipelineStage {
    /// Fuse the three sources into one stage. Precedence (first match wins) keeps
    /// in-flight/failed states ahead of file-derived flags — e.g. a running offline pass
    /// over a not-yet-rewritten transcript reads as `detectingSpeakers`, not
    /// `needsSpeakerNames`; a staged summary outranks lingering generic labels.
    @MainActor
    static func derive(item: TranscriptItem,
                       offline: OfflineProcessingService,
                       summary: SummaryService) -> PipelineStage {
        // 1. Failures first (actionable).
        if case .failed(let r)? = summary.state(for: item) { return .failed(.summary(r)) }
        let offlineState = offline.jobState(forAudioPath: item.meta.audio)
        if case .failed(let r)? = offlineState { return .failed(.speakerDetection(r)) }

        // 2. Usage-limit pause that holds THIS item's summary → surfaced as a soft failure.
        if case .paused(let reason, let resumeAt) = summary.throttle,
           reason == .usageLimit, summary.isPendingSummary(item) {
            return .failed(.claudeUsageLimited(resumeAt: resumeAt))
        }

        // 3. In-flight work.
        if summary.isSummarizing(item) { return .summarizing }
        if offlineState == .running { return .detectingSpeakers }
        if offlineState == .queued { return .queuedForSpeakers }

        // 4. Human gates / waiting.
        if item.summaryReadyURL != nil { return .reviewReady }
        if summary.isPendingSummary(item) { return .queuedForSummary }
        if item.hasUnnamedSpeakers, let a = item.meta.audio, !a.isEmpty { return .needsSpeakerNames }

        // 5. Terminal / idle.
        if item.isProcessed { return .processed }
        return .idleUnprocessed
    }

    /// In-flight (the app is actively working on it or it's waiting to be).
    var isProcessing: Bool {
        switch self {
        case .detectingSpeakers, .queuedForSpeakers, .summarizing, .queuedForSummary: return true
        default: return false
        }
    }

    /// Needs a human action (the actionable inbox).
    var needsYou: Bool {
        switch self {
        case .needsSpeakerNames, .reviewReady, .failed: return true
        default: return false
        }
    }
}
