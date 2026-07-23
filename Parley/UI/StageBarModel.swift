import Foundation

// MARK: - StageBarModel
//
// Fuses live state from `OfflineProcessingService` + `SummaryService` into the five
// `SegmentedStageBar.Segment` values for one transcript item.
//
// This type COMPLEMENTS `PipelineStage` — it derives richer, stage-by-stage progress
// data where `PipelineStage` gives a single coarse badge. Both exist without conflict:
// `PipelineStage` drives badges / list filtering; `StageBarModel` drives the bar.
//
// Derive → nil means "nothing interesting in flight" — the caller keeps its static UI.

struct StageBarModel: Equatable {

    // MARK: Always five segments, in pipeline order.
    var segments: [SegmentedStageBar.Segment]   // count == 5
    var statusLabel: String
    var sublabel: String?

    // MARK: - Segment identity constants

    static let segmentIDs = ["mix", "transcribeDiarize", "attribute", "compact", "summarize"]

    static let segmentLabels: [String] = [
        "Building clean mix",
        "Transcribing & detecting speakers",
        "Attributing words to speakers",
        "Compacting audio",
        "Summarizing",
    ]

    /// Live label for the summarize stage / status line, reflecting Settings pipeline.
    @MainActor
    static func summarizeStatusLabel(settings: AppSettings = .shared) -> String {
        switch settings.summaryPipeline {
        case .v2:
            return "Summarizing with \(settings.summaryWriterBackend.displayName) → \(settings.summaryCheckerBackend.displayName)"
        case .classic:
            return "Summarizing with \(settings.summaryBackend.displayName)"
        }
    }

    // MARK: - Live entry point

    /// Derives a bar model from the live services. Returns nil when nothing is in
    /// flight or failed for this item — callers should hide the bar in that case.
    @MainActor
    static func derive(item: TranscriptItem,
                       offline: OfflineProcessingService,
                       summary: SummaryService) -> StageBarModel? {
        // Mirror PipelineStage.derive's accessor pattern exactly.
        let offlineState    = offline.jobState(forAudioPath: item.meta.audio)
        let offlineProgress = offline.progress(forAudioPath: item.meta.audio)

        let summaryRunning  = summary.isSummarizing(item)
        let summaryQueued   = summary.isPendingSummary(item)

        // Failed state from the summary job map.
        let summaryFailed: String?
        if case .failed(let msg)? = summary.state(for: item) { summaryFailed = msg }
        else { summaryFailed = nil }

        // Usage-limit pause holding THIS item's summary (mirrors PipelineStage line 40–43).
        let summaryPaused: Bool
        if case .paused(let reason, _) = summary.throttle,
           reason == .usageLimit, summaryQueued {
            summaryPaused = true
        } else {
            summaryPaused = false
        }

        let summaryActivity = summary.runningActivity
        let summarizeLabel = summarizeStatusLabel()

        return fuse(
            offlineState:    offlineState,
            offlineProgress: offlineProgress,
            summaryRunning:  summaryRunning,
            summaryQueued:   summaryQueued,
            summaryFailed:   summaryFailed,
            summaryPaused:   summaryPaused,
            summaryActivity: summaryActivity,
            summarizeLabel:  summarizeLabel
        )
    }

    // MARK: - Pure fusion core (testable without live services)

    /// Pure, side-effect-free fusion. Nil = nothing to show (callers hide the bar).
    static func fuse(
        offlineState:    OfflineProcessingService.JobUIState?,
        offlineProgress: JobProgress?,
        summaryRunning:  Bool,
        summaryQueued:   Bool,
        summaryFailed:   String?,
        summaryPaused:   Bool,
        summaryActivity: String?,
        summarizeLabel:  String = "Summarizing"
    ) -> StageBarModel? {

        // ── 1. Offline queued ──────────────────────────────────────────────────────
        if offlineState == .queued {
            return StageBarModel(
                segments: makePending(summarizeLabel: summarizeLabel),
                statusLabel: "Queued — runs when idle")
        }

        // ── 2. Offline running ─────────────────────────────────────────────────────
        if offlineState == .running {
            let currentStageRaw = offlineProgress?.stage.rawValue ?? 0
            let fraction        = offlineProgress?.fraction
            let sub             = offlineProgress?.sublabel

            var segs = [SegmentedStageBar.Segment]()
            // Four offline stages map to segment indices 0–3; summarize (index 4) stays pending.
            for i in 0...3 {
                let state: SegmentedStageBar.SegmentState
                if i < currentStageRaw       { state = .done }
                else if i == currentStageRaw { state = .running(fraction: fraction) }
                else                         { state = .pending }
                segs.append(segment(at: i, state: state, summarizeLabel: summarizeLabel))
            }
            segs.append(segment(at: 4, state: .pending, summarizeLabel: summarizeLabel))

            let stageName = offlineStageName(currentStageRaw)
            let status: String
            if let f = fraction {
                status = "\(stageName) — \(Int((f * 100).rounded()))%"
            } else {
                status = stageName
            }

            return StageBarModel(segments: segs, statusLabel: status, sublabel: sub)
        }

        // ── 3. Offline failed ──────────────────────────────────────────────────────
        if case .failed(let msg)? = offlineState {
            let failStage = offlineProgress?.stage.rawValue ?? 0
            var segs = [SegmentedStageBar.Segment]()
            for i in 0...3 {
                let state: SegmentedStageBar.SegmentState
                if i < failStage       { state = .done }
                else if i == failStage { state = .failed }
                else                   { state = .pending }
                segs.append(segment(at: i, state: state, summarizeLabel: summarizeLabel))
            }
            segs.append(segment(at: 4, state: .pending, summarizeLabel: summarizeLabel))
            return StageBarModel(segments: segs, statusLabel: msg)
        }

        // ── 4. No offline job — summary states ────────────────────────────────────

        // Summary failed.
        if let msg = summaryFailed {
            var segs = firstFourDone(summarizeLabel: summarizeLabel)
            segs.append(segment(at: 4, state: .failed, summarizeLabel: summarizeLabel))
            return StageBarModel(segments: segs, statusLabel: msg)
        }

        // Summary running (shimmer).
        if summaryRunning {
            var segs = firstFourDone(summarizeLabel: summarizeLabel)
            segs.append(segment(at: 4, state: .running(fraction: nil), summarizeLabel: summarizeLabel))
            return StageBarModel(
                segments: segs,
                statusLabel: summarizeLabel,
                sublabel: summaryActivity)
        }

        // Summary paused (usage limit).
        if summaryPaused {
            var segs = firstFourDone(summarizeLabel: summarizeLabel)
            segs.append(segment(at: 4, state: .pending, summarizeLabel: summarizeLabel))
            return StageBarModel(
                segments: segs,
                statusLabel: "Paused — usage/rate limit")
        }

        // Summary queued.
        if summaryQueued {
            var segs = firstFourDone(summarizeLabel: summarizeLabel)
            segs.append(segment(at: 4, state: .pending, summarizeLabel: summarizeLabel))
            return StageBarModel(
                segments: segs,
                statusLabel: "Queued for summary")
        }

        // Nothing in flight.
        return nil
    }

    // MARK: - Helpers

    private static func segment(at index: Int,
                                 state: SegmentedStageBar.SegmentState,
                                 summarizeLabel: String) -> SegmentedStageBar.Segment {
        let label = index == 4 ? summarizeLabel : segmentLabels[index]
        return SegmentedStageBar.Segment(
            id:    segmentIDs[index],
            label: label,
            state: state)
    }

    private static func makePending(summarizeLabel: String) -> [SegmentedStageBar.Segment] {
        segmentIDs.indices.map { segment(at: $0, state: .pending, summarizeLabel: summarizeLabel) }
    }

    private static func firstFourDone(summarizeLabel: String) -> [SegmentedStageBar.Segment] {
        (0..<4).map { segment(at: $0, state: .done, summarizeLabel: summarizeLabel) }
    }

    /// Display name for an offline stage index (mirrors `JobProgress.Stage` order).
    private static func offlineStageName(_ rawValue: Int) -> String {
        switch rawValue {
        case 0: return "Building clean mix"
        case 1: return "Transcribing & detecting speakers"
        case 2: return "Attributing words to speakers"
        case 3: return "Compacting audio"
        default: return "Processing"
        }
    }
}
