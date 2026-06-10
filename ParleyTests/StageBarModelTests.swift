import XCTest
@testable import Parley

/// Pure-logic coverage for `StageBarModel.fuse(...)`.
/// All tests exercise the side-effect-free `fuse` method so there are no live-service
/// or MainActor dependencies — they run in any context without async overhead.
final class StageBarModelTests: XCTestCase {

    // MARK: Helpers

    private typealias S = SegmentedStageBar.Segment
    private typealias SS = SegmentedStageBar.SegmentState
    private typealias JPS = JobProgress.Stage

    /// Build a `JobProgress` with explicit stage and optional fraction.
    private func progress(stage: JPS, fraction: Double? = nil,
                          sublabel: String? = nil) -> JobProgress {
        JobProgress(stage: stage, fraction: fraction, sublabel: sublabel, startedAt: Date())
    }

    /// Shorthand: call `fuse` with no summary involvement.
    private func fuseOffline(state: OfflineProcessingService.JobUIState?,
                             progress p: JobProgress? = nil) -> StageBarModel? {
        StageBarModel.fuse(
            offlineState: state, offlineProgress: p,
            summaryRunning: false, summaryQueued: false,
            summaryFailed: nil, summaryPaused: false, summaryActivity: nil)
    }

    /// Shorthand: call `fuse` with no offline involvement.
    private func fuseSummary(running: Bool = false, queued: Bool = false,
                             failed: String? = nil, paused: Bool = false,
                             activity: String? = nil) -> StageBarModel? {
        StageBarModel.fuse(
            offlineState: nil, offlineProgress: nil,
            summaryRunning: running, summaryQueued: queued,
            summaryFailed: failed, summaryPaused: paused, summaryActivity: activity)
    }

    // MARK: Nil → nil

    func testAllNilInputReturnsNil() {
        let result = StageBarModel.fuse(
            offlineState: nil, offlineProgress: nil,
            summaryRunning: false, summaryQueued: false,
            summaryFailed: nil, summaryPaused: false, summaryActivity: nil)
        XCTAssertNil(result, "No work in flight → nil so callers keep static UI")
    }

    // MARK: Offline queued

    func testQueuedYieldsAllPending() {
        let m = fuseOffline(state: .queued)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.segments.count, 5)
        XCTAssertTrue(m?.segments.allSatisfy { $0.state == .pending } ?? false,
                      "All five segments must be pending when queued")
        XCTAssertTrue(m?.statusLabel.contains("Queued") ?? false)
    }

    // MARK: Offline running — each stage

    func testRunningAtMixStageWithFraction() {
        let m = fuseOffline(state: .running, progress: progress(stage: .mix, fraction: 0.4))
        XCTAssertNotNil(m)
        guard let m else { return }
        // Stage 0 (mix) = running(0.4), stages 1–3 = pending, stage 4 = pending.
        XCTAssertEqual(m.segments[0].state, SS.running(fraction: 0.4))
        XCTAssertEqual(m.segments[1].state, SS.pending)
        XCTAssertEqual(m.segments[4].state, SS.pending)
        XCTAssertTrue(m.statusLabel.contains("40%"), "Fraction must appear in status label")
    }

    func testRunningAtTranscribeStageWithFraction() {
        let p = progress(stage: .transcribeAndDiarize, fraction: 0.52,
                         sublabel: "transcribe 52% · speakers 74%")
        let m = fuseOffline(state: .running, progress: p)
        XCTAssertNotNil(m)
        guard let m else { return }
        XCTAssertEqual(m.segments[0].state, SS.done, "Mix must be done")
        XCTAssertEqual(m.segments[1].state, SS.running(fraction: 0.52), "Transcribe must be running")
        XCTAssertEqual(m.segments[2].state, SS.pending)
        XCTAssertEqual(m.segments[4].state, SS.pending)
        XCTAssertTrue(m.statusLabel.contains("52%"))
        XCTAssertEqual(m.sublabel, "transcribe 52% · speakers 74%")
    }

    func testRunningAtAttributeStageWithFraction() {
        let m = fuseOffline(state: .running, progress: progress(stage: .attribute, fraction: 0.75))
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[0].state, SS.done)
        XCTAssertEqual(m.segments[1].state, SS.done)
        XCTAssertEqual(m.segments[2].state, SS.running(fraction: 0.75))
        XCTAssertEqual(m.segments[3].state, SS.pending)
        XCTAssertEqual(m.segments[4].state, SS.pending)
        XCTAssertTrue(m.statusLabel.contains("75%"))
    }

    func testRunningAtCompactStageWithFraction() {
        let m = fuseOffline(state: .running, progress: progress(stage: .compact, fraction: 0.80))
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[0].state, SS.done)
        XCTAssertEqual(m.segments[1].state, SS.done)
        XCTAssertEqual(m.segments[2].state, SS.done)
        XCTAssertEqual(m.segments[3].state, SS.running(fraction: 0.80))
        XCTAssertEqual(m.segments[4].state, SS.pending)
        XCTAssertTrue(m.statusLabel.contains("80%"))
    }

    // MARK: Indeterminate running (progress nil)

    func testIndeterminateWhenOfflineProgressNil() {
        // offlineState running but no progress yet → all segments shimmer from stage 0.
        let m = fuseOffline(state: .running, progress: nil)
        guard let m else { XCTFail("expected non-nil"); return }
        // With no progress, currentStageRaw = 0 → segment 0 is running(fraction: nil).
        XCTAssertEqual(m.segments[0].state, SS.running(fraction: nil),
                       "No progress info → first segment must shimmer (indeterminate)")
        XCTAssertEqual(m.segments[1].state, SS.pending)
    }

    func testIndeterminateWhenFractionNil() {
        let m = fuseOffline(state: .running, progress: progress(stage: .transcribeAndDiarize, fraction: nil))
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[1].state, SS.running(fraction: nil))
        // No fraction → label must NOT contain a %
        XCTAssertFalse(m.statusLabel.contains("%"), "Indeterminate label must not contain percentage")
    }

    // MARK: Failure freeze

    func testFailureFreezesAtCompactStage() {
        let m = fuseOffline(
            state: .failed("Compaction crashed"),
            progress: progress(stage: .compact))
        guard let m else { XCTFail("expected non-nil"); return }
        // Stages before compact (0–2) = done; compact (3) = failed; summarize (4) = pending.
        XCTAssertEqual(m.segments[0].state, SS.done)
        XCTAssertEqual(m.segments[1].state, SS.done)
        XCTAssertEqual(m.segments[2].state, SS.done)
        XCTAssertEqual(m.segments[3].state, SS.failed)
        XCTAssertEqual(m.segments[4].state, SS.pending)
        XCTAssertEqual(m.statusLabel, "Compaction crashed")
    }

    func testFailureWithNilProgressFreezesFirstSegment() {
        // No recorded progress on failure → fail the first segment so the bar isn't blank.
        let m = fuseOffline(state: .failed("Audio missing"), progress: nil)
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[0].state, SS.failed,
                       "nil progress on failure must fail the first segment")
        XCTAssertEqual(m.segments[1].state, SS.pending)
    }

    func testFailureAtTranscribeStageSegmentLayout() {
        let m = fuseOffline(
            state: .failed("Speaker detection failed"),
            progress: progress(stage: .transcribeAndDiarize))
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[0].state, SS.done)
        XCTAssertEqual(m.segments[1].state, SS.failed)
        XCTAssertEqual(m.segments[2].state, SS.pending)
    }

    // MARK: Summary states

    func testSummaryRunningWithActivitySublabel() {
        let m = fuseSummary(running: true, activity: "Writing Key Topics…")
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[0].state, SS.done)
        XCTAssertEqual(m.segments[1].state, SS.done)
        XCTAssertEqual(m.segments[2].state, SS.done)
        XCTAssertEqual(m.segments[3].state, SS.done)
        XCTAssertEqual(m.segments[4].state, SS.running(fraction: nil),
                       "Summarize segment must shimmer (indeterminate)")
        XCTAssertTrue(m.statusLabel.contains("Summariz"))
        XCTAssertEqual(m.sublabel, "Writing Key Topics…")
    }

    func testSummaryRunningWithNoActivity() {
        let m = fuseSummary(running: true, activity: nil)
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(m.segments[4].state, SS.running(fraction: nil))
        XCTAssertNil(m.sublabel)
    }

    func testSummaryQueued() {
        let m = fuseSummary(queued: true)
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertTrue(m.segments[0..<4].allSatisfy { $0.state == .done })
        XCTAssertEqual(m.segments[4].state, SS.pending,
                       "Summarize segment must be pending when queued")
        XCTAssertTrue(m.statusLabel.lowercased().contains("queue"))
    }

    func testSummaryPaused() {
        let m = fuseSummary(queued: true, paused: true)
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertTrue(m.segments[0..<4].allSatisfy { $0.state == .done })
        XCTAssertEqual(m.segments[4].state, SS.pending)
        XCTAssertTrue(m.statusLabel.lowercased().contains("paused") ||
                      m.statusLabel.lowercased().contains("usage"),
                      "Status must mention paused or usage limit")
    }

    func testSummaryFailed() {
        let m = fuseSummary(failed: "Claude timed out after 10 min — retry.")
        guard let m else { XCTFail("expected non-nil"); return }
        XCTAssertTrue(m.segments[0..<4].allSatisfy { $0.state == .done })
        XCTAssertEqual(m.segments[4].state, SS.failed)
        XCTAssertEqual(m.statusLabel, "Claude timed out after 10 min — retry.")
    }

    // MARK: Segment count invariant

    func testSegmentCountAlwaysFive() {
        // Every non-nil result must have exactly 5 segments.
        let cases: [StageBarModel?] = [
            fuseOffline(state: .queued),
            fuseOffline(state: .running, progress: progress(stage: .mix, fraction: 0.5)),
            fuseOffline(state: .running, progress: nil),
            fuseOffline(state: .failed("X"), progress: progress(stage: .compact)),
            fuseOffline(state: .failed("X"), progress: nil),
            fuseSummary(running: true, activity: nil),
            fuseSummary(queued: true),
            fuseSummary(queued: true, paused: true),
            fuseSummary(failed: "err"),
        ]
        for (i, model) in cases.enumerated() {
            XCTAssertEqual(model?.segments.count, 5,
                           "Case \(i): expected exactly 5 segments, got \(model?.segments.count ?? -1)")
        }
    }

    // MARK: Label correctness

    func testStatusLabelDisplayNameAndPercentage() {
        // Each offline stage name must appear in the status label for a running job.
        let stageLabels: [(JPS, String)] = [
            (.mix,                 "Building clean mix"),
            (.transcribeAndDiarize,"Transcribing"),
            (.attribute,           "Attributing"),
            (.compact,             "Compacting"),
        ]
        for (stage, expectedSubstring) in stageLabels {
            let m = fuseOffline(state: .running, progress: progress(stage: stage, fraction: 0.5))
            XCTAssertTrue(m?.statusLabel.contains(expectedSubstring) ?? false,
                          "Stage \(stage) label should contain '\(expectedSubstring)' — got: \(m?.statusLabel ?? "nil")")
        }
    }
}
