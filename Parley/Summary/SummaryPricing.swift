import Foundation

/// List-price token rates for estimated summary cost. Claude runs may carry a real
/// `reportedCostUSD` from the CLI; everything else is derived here.
enum SummaryPricing {
    private struct Rates {
        var inputPerM: Double
        var outputPerM: Double
        var cacheReadPerM: Double
    }

    // Verified 2026-07-27 against https://platform.claude.com/docs/en/about-claude/pricing
    // and https://docs.x.ai/developers/pricing and https://cursor.com/docs/models-and-pricing
    private static let table: [String: Rates] = [
        // Claude Code aliases / models
        "sonnet": Rates(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.30),
        "claude-sonnet-4-6": Rates(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.30),
        "claude-sonnet-4-5": Rates(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.30),
        "claude-sonnet-5": Rates(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.30),
        // Grok CLI
        "grok-4.5": Rates(inputPerM: 2.0, outputPerM: 6.0, cacheReadPerM: 0.50),
        "grok-4.6": Rates(inputPerM: 2.0, outputPerM: 6.0, cacheReadPerM: 0.50),
        // Cursor Agent backends (SummaryBackend.rawValue)
        "composer-2.5": Rates(inputPerM: 0.50, outputPerM: 2.50, cacheReadPerM: 0.20),
        "composer-2.5-fast": Rates(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.20),
        "cursor-grok-4.5-high": Rates(inputPerM: 2.0, outputPerM: 6.0, cacheReadPerM: 0.50),
        "cursor-grok-4.6-high-fast": Rates(inputPerM: 2.0, outputPerM: 6.0, cacheReadPerM: 0.50),
    ]

    /// Returns nil for unknown models so the UI shows tokens without a bogus dollar figure.
    static func estimate(_ metrics: SummaryRunMetrics) -> Double? {
        guard metrics.reportedCostUSD == nil else { return nil }
        guard let rates = table[metrics.model] else { return nil }
        let input = Double(metrics.inputTokens) / 1_000_000 * rates.inputPerM
        let output = Double(metrics.outputTokens) / 1_000_000 * rates.outputPerM
        let cacheRead = Double(metrics.cacheReadTokens) / 1_000_000 * rates.cacheReadPerM
        let total = input + output + cacheRead
        return total > 0 ? total : nil
    }

    static func resolvedCostUSD(_ metrics: SummaryRunMetrics) -> Double? {
        if let reported = metrics.reportedCostUSD, reported > 0 { return reported }
        return estimate(metrics)
    }

    static func isEstimated(_ metrics: SummaryRunMetrics) -> Bool {
        metrics.reportedCostUSD == nil
    }
}
