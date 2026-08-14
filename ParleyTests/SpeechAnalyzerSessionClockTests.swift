import XCTest
@testable import Parley

final class SpeechAnalyzerSessionClockTests: XCTestCase {

    func testResumeOffsetShiftsAnalyzerLocalTimes() {
        let local = DiarizationAttribution.Token(text: "hello", start: 1.0, end: 1.4)
        let shifted = SpeechAnalyzerSessionClock.tokens([local], offset: 1_800)
        XCTAssertEqual(shifted[0].start, 1_801, accuracy: 0.001)
        XCTAssertEqual(shifted[0].end, 1_801.4, accuracy: 0.001)
        XCTAssertEqual(shifted[0].text, "hello")
    }

    func testZeroOffsetLeavesTokensUnchanged() {
        let local = DiarizationAttribution.Token(text: "hi", start: 0.2, end: 0.5)
        let same = SpeechAnalyzerSessionClock.tokens([local], offset: 0)
        XCTAssertEqual(same[0].start, 0.2, accuracy: 0.001)
        XCTAssertEqual(same[0].end, 0.5, accuracy: 0.001)
    }

    func testFallbackRangeUsesSessionClock() {
        let start = SpeechAnalyzerSessionClock.time(2.5, offset: 1_800)
        XCTAssertEqual(start, 1_802.5, accuracy: 0.001)
    }

    func testDiarizationChunkStartsAfterPriorDuration() {
        let start = SpeechAnalyzerSessionClock.diarizationStart(
            processedSamples: 160_000, offset: 1_800)
        XCTAssertEqual(start, 1_810, accuracy: 0.001)
    }

    func testFreshStartDiarizationStaysLocal() {
        let start = SpeechAnalyzerSessionClock.diarizationStart(
            processedSamples: 80_000, offset: 0)
        XCTAssertEqual(start, 5, accuracy: 0.001)
    }

    func testEngineStartStoresResumeOffsetInsteadOfDiscardingIt() throws {
        let src = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Parley/Transcription/SpeechAnalyzerEngine.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("sessionElapsed = startElapsed"))
        XCTAssertFalse(src.contains("_ = startElapsed"))
        XCTAssertTrue(src.contains("SpeechAnalyzerSessionClock.tokens"))
        XCTAssertTrue(src.contains("SpeechAnalyzerSessionClock.diarizationStart"))
    }

    func testRecordingControllerDoesNotKeepAnUnusedClock() throws {
        let src = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Parley/Recording/RecordingController.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.contains("RecordingClock"))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
