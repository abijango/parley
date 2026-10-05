import XCTest
@testable import Parley

final class SummaryAccuracyTests: XCTestCase {

    private let gold = """
    ## Executive Summary

    Naufal met with Carlos to review the training rollout and agree the survey questions are a usable starting point for weekly tracking.

    ## Decisions Made

    1. The proposed survey questions are acceptable as a starting point for longitudinal tracking.
    2. The 201 session moves to Wednesday at the same time as the 101.

    ## Action Items

    | Action | Owner | Due / Timeframe | Priority |
    | --- | --- | --- | --- |
    | Deliver first-cut analytics preview | Carlos Granados | End of next week | High |
    | Send the 201 session invite | Naufal Mir | Today or tomorrow | High |

    ## Key Metrics or Data Points

    - 267 people signed up for the program.

    ## Raw Transcript

    This raw section mentions a secret codeword zephyr that must not become a claim.
    """

    func testGoldMatchesItself() {
        let score = SummaryAccuracy.score(candidate: gold, gold: gold)
        XCTAssertGreaterThan(score.total, 4)
        XCTAssertEqual(score.matched, score.total)
        XCTAssertEqual(score.recall, 1, accuracy: 0.0001)
        XCTAssertTrue(score.missedPreviews.isEmpty)
    }

    func testMissingActionDropsRecall() {
        let candidate = gold.replacingOccurrences(
            of: "Deliver first-cut analytics preview | Carlos Granados | End of next week | High",
            with: "Follow up sometime later")
        let full = SummaryAccuracy.score(candidate: gold, gold: gold)
        let dropped = SummaryAccuracy.score(candidate: candidate, gold: gold)
        XCTAssertLessThan(dropped.matched, full.matched)
        XCTAssertTrue(dropped.missedPreviews.contains { $0.contains("analytics") })
    }

    func testRawTranscriptIsNotAClaim() {
        let withoutSecret = gold.replacingOccurrences(of: "zephyr", with: "nothing")
        let score = SummaryAccuracy.score(candidate: withoutSecret, gold: gold)
        XCTAssertEqual(score.matched, score.total)
        XCTAssertFalse(score.missedPreviews.contains { $0.contains("zephyr") })
    }

    func testVaultFixtureScoresItself() throws {
        let vault = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("ObsidianVault")
        guard let fixture = SummaryGroundTruth.load(vault: vault) else {
            throw XCTSkip("Ground-truth meeting is not in \(vault.path)")
        }
        let score = SummaryAccuracy.score(candidate: fixture.goldSummary, gold: fixture.goldSummary)
        XCTAssertGreaterThanOrEqual(score.total, 8)
        XCTAssertEqual(score.matched, score.total, "missed \(score.missedPreviews)")
    }
}
