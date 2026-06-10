import Foundation

/// Classifies a failed `claude` subprocess result to detect that the failure is an
/// **authentication** problem (not logged in, expired credentials, no/invalid API key)
/// rather than a transient error. Lets `SummaryService` give an actionable "log in"
/// message and flip the connection badge instead of surfacing a raw "exited with code 1".
///
/// Like `ClaudeUsageLimit`, detection is pure, unit-testable, and only inspects output
/// on a **non-zero exit**. The phrase set is kept **disjoint** from
/// `ClaudeUsageLimit.phrases` so a usage/rate limit is never misread as an auth failure
/// (the caller checks usage limits first, but the disjointness keeps each detector honest).
enum ClaudeAuthError {
    /// Phrases (case-insensitive) that indicate an auth/credential failure. Deliberately
    /// specific — broad words like "expired" alone are avoided so a transcript or unrelated
    /// error can't be misclassified.
    static let phrases = [
        "invalid api key", "no api key", "api key not found",
        "not logged in", "please run /login", "run `claude login`", "claude login",
        "please log in", "sign in to claude",
        "authentication", "authenticationerror", "unauthorized", "401", "403", "forbidden",
        "oauth token", "token has expired", "session expired", "credentials expired",
        "credit balance is too low", "insufficient credit",
    ]

    /// Returns the matched phrase when the failure looks like an auth problem, else nil.
    /// Only considers non-zero exits.
    static func detect(stdout: String, stderr: String, exitCode: Int32) -> String? {
        guard exitCode != 0 else { return nil }
        let lower = (stderr + "\n" + stdout).lowercased()
        return phrases.first(where: { lower.contains($0) })
    }
}
