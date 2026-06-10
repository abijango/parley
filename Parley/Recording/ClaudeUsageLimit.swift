import Foundation

/// Classifies a `claude` subprocess result to detect that we've hit a usage / rate
/// limit, so the summary queue can PAUSE instead of burning through a backlog with N
/// more doomed runs. Pure and unit-testable — no process spawning here.
///
/// Detection is deliberately conservative: it only inspects output on a **non-zero
/// exit**, so a successful summary whose transcript happens to mention "rate limit"
/// never trips it.
enum ClaudeUsageLimit {
    /// A detected usage/rate-limit trip. `resumeAt` is a best-effort parse of when the
    /// limit lifts (nil ⇒ caller falls back to exponential backoff).
    struct Trip: Equatable {
        var resumeAt: Date?
        var matchedPhrase: String
    }

    /// Phrases (case-insensitive) that indicate a usage/rate limit rather than a normal
    /// failure. Kept broad on purpose — a false "limited" classification just pauses the
    /// queue (recoverable), whereas a missed one burns usage. Internal (not private) so
    /// `ClaudeAuthErrorTests` can assert this set stays disjoint from the auth phrases.
    static let phrases = [
        "usage limit", "rate limit", "rate-limit", "429", "too many requests",
        "overloaded", "quota", "exceeded your", "resets at", "retry-after",
        "retry after", "try again later", "capacity",
    ]

    /// Classify subprocess output. Returns a `Trip` when it looks like a usage/rate
    /// limit, else nil. Only considers non-zero exits.
    static func detect(stdout: String, stderr: String, exitCode: Int32) -> Trip? {
        guard exitCode != 0 else { return nil }
        let haystack = (stderr + "\n" + stdout)
        let lower = haystack.lowercased()
        guard let phrase = phrases.first(where: { lower.contains($0) }) else { return nil }
        return Trip(resumeAt: parseResumeAt(haystack, lower: lower), matchedPhrase: phrase)
    }

    /// Best-effort extraction of a resume time from the message. Handles, in order:
    /// `retry-after: <seconds>`, "resets at <ISO-8601>", and "in N minutes|hours".
    /// `now` is injected for testability (defaults to current time at call site).
    static func parseResumeAt(_ text: String, lower: String, now: Date = Date()) -> Date? {
        // retry-after: 60   (seconds)
        if let r = lower.range(of: "retry-after") ?? lower.range(of: "retry after") {
            let tail = lower[r.upperBound...]
            if let secs = firstInt(in: tail) { return now.addingTimeInterval(TimeInterval(secs)) }
        }
        // resets at 2026-06-09T15:40:00Z  (ISO-8601)
        if let r = lower.range(of: "resets at") ?? lower.range(of: "reset at") {
            // Pull the ISO token from the ORIGINAL-case text at the same offset.
            let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
            let tail = String(text.dropFirst(offset))
            if let date = firstISODate(in: tail) { return date }
        }
        // in 5 minutes / in 2 hours / 30 minutes
        if let mins = amount(before: "minute", in: lower) { return now.addingTimeInterval(Double(mins) * 60) }
        if let hrs = amount(before: "hour", in: lower) { return now.addingTimeInterval(Double(hrs) * 3600) }
        return nil
    }

    // MARK: Parsing helpers

    private static func firstInt<S: StringProtocol>(in s: S) -> Int? {
        var digits = ""
        var started = false
        for ch in s {
            if ch.isNumber { digits.append(ch); started = true }
            else if started { break }
        }
        return Int(digits)
    }

    /// The integer immediately preceding a unit word, e.g. "5" in "in 5 minutes".
    private static func amount(before unit: String, in lower: String) -> Int? {
        guard let r = lower.range(of: unit) else { return nil }
        let head = lower[lower.startIndex..<r.lowerBound]
        // Walk back over whitespace then collect trailing digits.
        let trimmed = head.reversed().drop(while: { $0 == " " })
        var digits = ""
        for ch in trimmed {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(String(digits.reversed()))
    }

    private static func firstISODate<S: StringProtocol>(in s: S) -> Date? {
        // Grab the first whitespace-delimited token that looks like a date-time.
        let tokenSub = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," || $0 == "." })
            .first(where: { $0.contains("-") && ($0.contains("T") || $0.contains(":")) })
        guard let tokenSub else { return nil }
        let token = String(tokenSub)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: token) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: token) { return d }
        // Fall back to a couple of common explicit formats.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            df.dateFormat = fmt
            if let d = df.date(from: token) { return d }
        }
        return nil
    }
}
