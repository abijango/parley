import XCTest
@testable import Parley

/// Pure-logic coverage for the processing-queue / throttle work: the Claude usage-limit
/// detector, the bulk-vs-fresh enqueue policy, and the backoff schedule.
final class ProcessingQueueTests: XCTestCase {

    // MARK: ClaudeUsageLimit.detect

    func testUsageLimitStringsTrip() {
        XCTAssertNotNil(ClaudeUsageLimit.detect(stdout: "", stderr: "Claude AI usage limit reached", exitCode: 1))
        XCTAssertNotNil(ClaudeUsageLimit.detect(stdout: "", stderr: "Error 429: too many requests", exitCode: 1))
        XCTAssertNotNil(ClaudeUsageLimit.detect(stdout: "overloaded_error", stderr: "", exitCode: 1))
        XCTAssertNotNil(ClaudeUsageLimit.detect(stdout: "", stderr: "you have exceeded your quota", exitCode: 1))
    }

    func testPlainFailureDoesNotTrip() {
        XCTAssertNil(ClaudeUsageLimit.detect(stdout: "", stderr: "command not found: claude", exitCode: 127))
        XCTAssertNil(ClaudeUsageLimit.detect(stdout: "", stderr: "unexpected token", exitCode: 1))
    }

    func testSuccessNeverTripsEvenIfTranscriptMentionsLimits() {
        // A successful run whose summary text discusses "rate limits" must NOT trip.
        XCTAssertNil(ClaudeUsageLimit.detect(
            stdout: "We discussed API rate limits and usage quota planning.", stderr: "", exitCode: 0))
    }

    func testResumeAtParsing() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // retry-after seconds
        let a = ClaudeUsageLimit.parseResumeAt("retry-after: 60", lower: "retry-after: 60", now: base)
        XCTAssertEqual(a?.timeIntervalSince1970 ?? 0, 1_000_060, accuracy: 1)
        // relative minutes
        let b = ClaudeUsageLimit.parseResumeAt("try again in 5 minutes", lower: "try again in 5 minutes", now: base)
        XCTAssertEqual(b?.timeIntervalSince1970 ?? 0, 1_000_300, accuracy: 1)
        // ISO reset time
        let iso = "resets at 2026-06-09T15:40:00Z"
        let c = ClaudeUsageLimit.parseResumeAt(iso, lower: iso.lowercased(), now: base)
        XCTAssertNotNil(c)
        // garbage → nil
        XCTAssertNil(ClaudeUsageLimit.parseResumeAt("limited, sorry", lower: "limited, sorry", now: base))
    }

    // MARK: SummaryEnqueuePolicy.decide

    func testUserInitiatedAlwaysEnqueues() {
        let p = SummaryEnqueuePolicy(autoRunClaude: false, bulkThreshold: 3)
        XCTAssertEqual(p.decide(trigger: .userInitiated, alreadyQueuedOrPending: 99), .enqueue)
    }

    func testAutoOffSkipsNonUser() {
        let p = SummaryEnqueuePolicy(autoRunClaude: false, bulkThreshold: 3)
        XCTAssertEqual(p.decide(trigger: .freshRecording, alreadyQueuedOrPending: 0), .skipAutoOff)
    }

    func testFreshSingleEnqueuesButBulkConfirms() {
        let p = SummaryEnqueuePolicy(autoRunClaude: true, bulkThreshold: 3)
        XCTAssertEqual(p.decide(trigger: .freshRecording, alreadyQueuedOrPending: 0), .enqueue)
        XCTAssertEqual(p.decide(trigger: .offlinePassCompleted, alreadyQueuedOrPending: 1), .enqueue)
        // 2 already in flight + this one = 3 ≥ threshold → confirm.
        XCTAssertEqual(p.decide(trigger: .offlinePassCompleted, alreadyQueuedOrPending: 2), .confirmBulk(count: 3))
        XCTAssertEqual(p.decide(trigger: .launchBacklog, alreadyQueuedOrPending: 9), .confirmBulk(count: 10))
    }

    // MARK: backoff

    func testBackoffIsMonotonicAndCapped() {
        let s1 = SummaryService.backoffSeconds(attempt: 1)
        let s2 = SummaryService.backoffSeconds(attempt: 2)
        let s3 = SummaryService.backoffSeconds(attempt: 3)
        XCTAssertEqual(s1, 60, accuracy: 0.1)
        XCTAssertTrue(s2 > s1 && s3 > s2)
        XCTAssertEqual(SummaryService.backoffSeconds(attempt: 99), 3600, accuracy: 0.1)  // capped at 1h
    }
}
