import Foundation

/// Per-leg generation metrics. `wallClock` is always populated (measured by
/// Parley); every other field is best-effort and backend-dependent.
struct SummaryRunMetrics: Equatable, Codable, Sendable {
    var wallClock: TimeInterval = 0
    var apiDurationMS: Int?          // cursor's duration_api_ms; nil elsewhere
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var reasoningTokens: Int = 0     // grok only
    var reportedCostUSD: Double?     // claude's total_cost_usd; nil elsewhere
    var model: String = ""           // for price-table lookup

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    static func from(claude usage: ClaudeStreamParser.Usage?,
                     wallClock: TimeInterval,
                     model: String) -> SummaryRunMetrics {
        var m = SummaryRunMetrics(wallClock: wallClock, model: model)
        guard let usage else { return m }
        m.inputTokens = usage.inputTokens
        m.outputTokens = usage.outputTokens
        m.cacheWriteTokens = usage.cacheCreationTokens
        m.cacheReadTokens = usage.cacheReadTokens
        m.reportedCostUSD = usage.costUSD
        return m
    }

    static func merging(parsed: SummaryRunMetrics?,
                        wallClock: TimeInterval,
                        model: String) -> SummaryRunMetrics {
        var m = parsed ?? SummaryRunMetrics()
        m.wallClock = wallClock
        if m.model.isEmpty { m.model = model }
        return m
    }

    static func combined(_ writer: SummaryRunMetrics?, _ checker: SummaryRunMetrics?) -> SummaryRunMetrics? {
        switch (writer, checker) {
        case (nil, nil): return nil
        case (let w?, nil): return w
        case (nil, let c?): return c
        case (let w?, let c?):
            return SummaryRunMetrics(
                wallClock: w.wallClock + c.wallClock,
                inputTokens: w.inputTokens + c.inputTokens,
                outputTokens: w.outputTokens + c.outputTokens,
                cacheReadTokens: w.cacheReadTokens + c.cacheReadTokens,
                cacheWriteTokens: w.cacheWriteTokens + c.cacheWriteTokens,
                reasoningTokens: w.reasoningTokens + c.reasoningTokens,
                model: w.model.isEmpty ? c.model : w.model
            )
        }
    }
}

/// Compact display for summary run metrics in review panes and run pickers.
enum SummaryMetricsFormat {
    /// `1m 12s · 48.2k tokens · ~$0.031 est.` — omits cost when unknown.
    static func compactLine(metrics: SummaryRunMetrics?,
                            helpNote: String = "Estimated from token counts at list prices; subscription plans may differ.") -> (text: String, help: String)? {
        compactLine(writer: nil, checker: nil, single: metrics, helpNote: helpNote)
    }

    static func compactLine(writer: SummaryRunMetrics?,
                            checker: SummaryRunMetrics?,
                            helpNote: String = "Estimated from token counts at list prices; subscription plans may differ.") -> (text: String, help: String)? {
        compactLine(writer: writer, checker: checker, single: nil, helpNote: helpNote)
    }

    private static func compactLine(writer: SummaryRunMetrics?,
                                    checker: SummaryRunMetrics?,
                                    single: SummaryRunMetrics?,
                                    helpNote: String) -> (text: String, help: String)? {
        let metrics = single ?? SummaryRunMetrics.combined(writer, checker)
        guard let metrics else { return nil }
        var parts: [String] = []
        if metrics.wallClock > 0 {
            parts.append(SummaryDurationFormat.string(from: metrics.wallClock))
        }
        let tokens = metrics.totalTokens
        if tokens > 0 {
            parts.append(Self.tokenCount(tokens))
        }
        if let cost = Self.combinedCostUSD(writer: writer, checker: checker, single: single) {
            parts.append(Self.costClause(cost.value, estimated: cost.estimated))
        }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: " · "), helpNote)
    }

    /// Duration only — for run picker rows.
    static func durationSuffix(for run: SummaryRunRecord) -> String? {
        let total = combinedWallClock(run)
        guard total > 0 else { return nil }
        return " · \(SummaryDurationFormat.string(from: total))"
    }

    static func legBreakdown(writer: SummaryRunMetrics?, checker: SummaryRunMetrics?) -> String? {
        var lines: [String] = []
        if let w = writer, w.wallClock > 0 || w.totalTokens > 0 {
            lines.append("Writer: \(legSummary(w))")
        }
        if let c = checker, c.wallClock > 0 || c.totalTokens > 0 {
            lines.append("Checker: \(legSummary(c))")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func combinedWallClock(_ run: SummaryRunRecord) -> TimeInterval {
        let w = run.writerMetrics?.wallClock ?? 0
        let c = run.checkerMetrics?.wallClock ?? 0
        return w + c
    }

    private static func legSummary(_ m: SummaryRunMetrics) -> String {
        var parts: [String] = []
        if m.wallClock > 0 { parts.append(SummaryDurationFormat.string(from: m.wallClock)) }
        if m.totalTokens > 0 { parts.append(Self.tokenCount(m.totalTokens)) }
        if let cost = SummaryPricing.resolvedCostUSD(m) {
            parts.append(Self.costClause(cost, estimated: SummaryPricing.isEstimated(m)))
        }
        return parts.joined(separator: " · ")
    }

    private static func tokenCount(_ n: Int) -> String {
        if n >= 10_000 {
            let k = Double(n) / 1000.0
            return String(format: "%.1fk tokens", k)
        }
        return "\(n.formatted()) tokens"
    }

    private static func costClause(_ cost: Double, estimated: Bool) -> String {
        let s = cost < 0.01 ? String(format: "%.4f", cost) : String(format: "%.2f", cost)
        return estimated ? "~$\(s) est." : "$\(s)"
    }

    private static func combinedCostUSD(writer: SummaryRunMetrics?,
                                        checker: SummaryRunMetrics?,
                                        single: SummaryRunMetrics?) -> (value: Double, estimated: Bool)? {
        let legs: [SummaryRunMetrics]
        if let single { legs = [single] }
        else { legs = [writer, checker].compactMap { $0 } }
        let resolved = legs.compactMap { m -> (Double, Bool)? in
            guard let c = SummaryPricing.resolvedCostUSD(m) else { return nil }
            return (c, SummaryPricing.isEstimated(m))
        }
        guard !resolved.isEmpty else { return nil }
        return (resolved.map(\.0).reduce(0, +), resolved.contains(where: \.1))
    }
}
