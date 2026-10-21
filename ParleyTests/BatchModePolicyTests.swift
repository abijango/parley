import XCTest
@testable import Parley

final class BatchModePolicyTests: XCTestCase {

    func testRecordingBlocksOnlyWhenBatchModeIsOff() {
        XCTAssertFalse(BatchModePolicy.mayRun(
            batchMode: false, recordingActive: true, held: false, heldMayDrain: false,
            forced: false, schedule: .afterCall, inWindow: true))
        XCTAssertTrue(BatchModePolicy.mayRun(
            batchMode: true, recordingActive: true, held: false, heldMayDrain: false,
            forced: false, schedule: .afterCall, inWindow: true))
    }

    func testWindowClosedWaitsUnlessForced() {
        XCTAssertFalse(BatchModePolicy.mayRun(
            batchMode: true, recordingActive: false, held: false, heldMayDrain: false,
            forced: false, schedule: .window, inWindow: false))
        XCTAssertTrue(BatchModePolicy.mayRun(
            batchMode: true, recordingActive: true, held: true, heldMayDrain: false,
            forced: true, schedule: .window, inWindow: false))
    }

    func testHeldJobUsesQuietHoursAndIgnoresTheTranscriptionWindow() {
        XCTAssertFalse(BatchModePolicy.mayRun(
            batchMode: true, recordingActive: false, held: true, heldMayDrain: false,
            forced: false, schedule: .afterCall, inWindow: true))
        XCTAssertTrue(BatchModePolicy.mayRun(
            batchMode: true, recordingActive: false, held: true, heldMayDrain: true,
            forced: false, schedule: .window, inWindow: false))
    }

    func testStoredProfileAndScheduleBeatALaterSettingsChange() {
        XCTAssertEqual(BatchModePolicy.pinnedProfile(stored: .parakeetV3, language: "en"), .parakeetV3)
        XCTAssertEqual(BatchModePolicy.pinnedProfile(stored: nil, language: "en"), .parakeetUnified)
        XCTAssertEqual(BatchModePolicy.pinnedProfile(stored: nil, language: "ja"), .parakeetV3)
        XCTAssertEqual(
            BatchModePolicy.pinnedSchedule(batchMode: true, stored: .window, live: .afterCall),
            .window)
        XCTAssertEqual(
            BatchModePolicy.pinnedSchedule(batchMode: false, stored: .window, live: .window),
            .afterCall)
    }

    func testEnglishUsesUnifiedAndOtherLanguagesUseV3() {
        XCTAssertEqual(BatchModePolicy.profile(language: "en"), .parakeetUnified)
        XCTAssertEqual(BatchModePolicy.profile(language: "en-GB"), .parakeetUnified)
        XCTAssertEqual(BatchModePolicy.profile(language: "auto"), .parakeetV3)
        XCTAssertEqual(BatchModePolicy.profile(language: "ja"), .parakeetV3)
    }

    func testBatchModeDoesNotWaitForTheIdleDrain() {
        XCTAssertFalse(BatchModePolicy.waitsForIdleDrain(batchMode: true))
        XCTAssertTrue(BatchModePolicy.waitsForIdleDrain(batchMode: false))
    }

    func testBatchModeQueuesEvenWithNoLiveSegments() {
        XCTAssertTrue(BatchModePolicy.shouldQueue(batchMode: true, isSpeakerEngine: false, segmentCount: 0))
        XCTAssertFalse(BatchModePolicy.shouldQueue(batchMode: false, isSpeakerEngine: true, segmentCount: 0))
        XCTAssertTrue(BatchModePolicy.shouldQueue(batchMode: false, isSpeakerEngine: true, segmentCount: 3))
        XCTAssertFalse(BatchModePolicy.shouldQueue(batchMode: false, isSpeakerEngine: false, segmentCount: 3))
    }

    func testManifestRestoresTheBatchSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("note.md")
        try Data("x".utf8).write(to: transcript)
        var manifest = SessionManifest(
            id: "batch-job", title: "Standup", attendees: "", filing: "", model: "m",
            computeMode: "c", startedAt: Date(), lastHeartbeat: Date(), status: .finalized,
            startedByDetection: false, callBundleID: nil, callDisplayName: nil,
            manualNotes: "", audioTracks: ["mic.caf"])
        manifest.transcriptPath = transcript.path
        manifest.batchMode = true
        manifest.transcriptionTiming = .window
        manifest.transcriptionWindowStartHour = 22
        manifest.transcriptionWindowEndHour = 7
        manifest.offlineForced = true
        manifest.fluidAsrProfile = .parakeetUnified
        let job = try XCTUnwrap(OfflineJob(
            dir: root, manifest: manifest, autoSummarize: false,
            fallbackAsrProfile: .parakeetV3))
        XCTAssertTrue(job.accurateBatch)
        XCTAssertEqual(job.schedule, .window)
        XCTAssertEqual(job.windowStartHour, 22)
        XCTAssertEqual(job.windowEndHour, 7)
        XCTAssertTrue(job.forced)
        XCTAssertEqual(job.fluidAsrProfile, .parakeetUnified)
    }
}
