import XCTest
@testable import Parley

/// Unit coverage for ClaudeAuthError: auth-failure phrases match on non-zero exits,
/// success exits never match, and the phrase set stays disjoint from
/// ClaudeUsageLimit's so a usage/rate limit is never misread as an auth problem.
final class ClaudeAuthErrorTests: XCTestCase {

    func testZeroExitNeverMatches() {
        XCTAssertNil(ClaudeAuthError.detect(
            stdout: "Invalid API key — please run /login", stderr: "", exitCode: 0))
    }

    func testInvalidApiKeyMatches() {
        let m = ClaudeAuthError.detect(stdout: "Error: Invalid API key", stderr: "", exitCode: 1)
        XCTAssertEqual(m, "invalid api key")
    }

    func testNotLoggedInMatchesFromStderr() {
        let m = ClaudeAuthError.detect(
            stdout: "", stderr: "You are not logged in. Run `claude login`.", exitCode: 1)
        XCTAssertNotNil(m)
    }

    func testUnauthorizedMatches() {
        XCTAssertNotNil(ClaudeAuthError.detect(stdout: "401 Unauthorized", stderr: "", exitCode: 1))
    }

    func testCreditBalanceMatches() {
        XCTAssertEqual(
            ClaudeAuthError.detect(stdout: "Your credit balance is too low", stderr: "", exitCode: 1),
            "credit balance is too low")
    }

    func testPlainFailureDoesNotMatch() {
        // A generic crash / unrelated error is not an auth problem.
        XCTAssertNil(ClaudeAuthError.detect(
            stdout: "Segmentation fault", stderr: "claude exited with code 139", exitCode: 139))
    }

    // MARK: Disjointness from usage-limit detection

    func testUsageLimitPhrasesAreNotClassifiedAsAuth() {
        // Every usage-limit phrase must NOT trip the auth detector.
        for phrase in ClaudeUsageLimit.phrases {
            let text = "Claude error: \(phrase) encountered."
            XCTAssertNil(
                ClaudeAuthError.detect(stdout: text, stderr: "", exitCode: 1),
                "usage-limit phrase '\(phrase)' must not be read as an auth error")
        }
    }

    func testAuthPhrasesAreNotClassifiedAsUsageLimit() {
        // And every auth phrase must NOT trip the usage-limit detector.
        for phrase in ClaudeAuthError.phrases {
            let text = "Claude error: \(phrase) encountered."
            XCTAssertNil(
                ClaudeUsageLimit.detect(stdout: text, stderr: "", exitCode: 1),
                "auth phrase '\(phrase)' must not be read as a usage limit")
        }
    }
}
