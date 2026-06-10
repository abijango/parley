import Foundation

/// Generalised NDJSON-line parser for `claude -p --output-format stream-json` output.
/// Extracted from NotesGenerator's proven per-line parser so both NotesGenerator and
/// SummaryService share identical stream-event handling without coupling their call sites.
///
/// All methods are nonisolated so the parser can be called from any concurrency context
/// (Task.detached, DispatchQueue, etc.) without actor-hop overhead.
enum ClaudeStreamParser {

    /// Token/cost usage reported on the terminal `result` event. All token counts
    /// default to 0 when absent; `costUSD` is nil when the CLI omits `total_cost_usd`
    /// (e.g. some subscription paths). Carried out of the parser so the caller can
    /// tally what the app has spent.
    struct Usage: Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTokens: Int = 0
        var cacheReadTokens: Int = 0
        var costUSD: Double?
    }

    /// Parsed result for a single NDJSON line.
    struct Event: Equatable {
        /// Human-readable ticker lines derived from `assistant` blocks: tool-use
        /// summaries ("▸ Read: foo.md") and short text snippets. Empty when the line
        /// carries no displayable activity.
        var activityLines: [String] = []
        /// Streaming text delta from `stream_event` / `content_block_delta` lines.
        /// Empty for non-delta lines.
        var textDelta: String = ""
        /// The final response payload from `result` events. nil until a result line
        /// is seen; empty string is a valid (but empty) result.
        var resultText: String?
        /// True/false from the `result` event's `is_error` field. nil for non-result lines.
        var isError: Bool?
        /// Token/cost usage from the `result` event. nil for non-result lines and for
        /// result lines that carry no `usage` object.
        var usage: Usage?
    }

    // MARK: Line parsing

    /// Parse one NDJSON line (no trailing newline required). Returns an empty Event
    /// for malformed JSON or unknown event types — callers can safely ignore them.
    nonisolated static func parse(_ data: Data) -> Event {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return Event() }

        switch type {
        case "assistant":
            return parseAssistant(obj)

        case "result":
            // `is_error` may be a Bool directly, or encoded as subtype == "error".
            let isErr = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String) == "error")
            let text = obj["result"] as? String ?? ""
            return Event(resultText: text, isError: isErr, usage: parseUsage(obj))

        case "stream_event":
            // `--include-partial-messages` wraps streaming events in an outer
            // `{"type":"stream_event","event":{...}}` envelope.
            return parseStreamEvent(obj)

        default:
            return Event()
        }
    }

    // MARK: Section heading extraction

    /// Scans accumulated streamed text (text deltas joined in order) in reverse for
    /// the last Markdown heading at levels 1–3, then strips the leading `#` characters
    /// and surrounding whitespace.
    ///
    /// Returns nil when no heading is found (e.g. before Claude has written any
    /// structure). Callers use this to drive the "Writing <Section>…" ticker.
    nonisolated static func currentSection(in accumulated: String) -> String? {
        // Walk lines in reverse — stop at the first `#{1,3} ` prefix.
        let lines = accumulated.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("#") else { continue }
            // Require 1–3 hashes followed by a space.
            let hashes = trimmed.prefix(while: { $0 == "#" })
            guard hashes.count >= 1, hashes.count <= 3 else { continue }
            let afterHashes = trimmed.dropFirst(hashes.count)
            guard afterHashes.hasPrefix(" ") else { continue }
            let heading = afterHashes.trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
        return nil
    }

    // MARK: Private helpers

    /// Pulls the `usage` object and `total_cost_usd` off a `result` event. Returns nil
    /// when neither is present so non-usage result lines don't fabricate a zero tally.
    /// Token values are read as integers (JSON numbers decode to NSNumber); a missing
    /// field is treated as 0.
    private nonisolated static func parseUsage(_ obj: [String: Any]) -> Usage? {
        let usageObj = obj["usage"] as? [String: Any]
        let cost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue
        guard usageObj != nil || cost != nil else { return nil }
        func int(_ key: String) -> Int { (usageObj?[key] as? NSNumber)?.intValue ?? 0 }
        return Usage(
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheCreationTokens: int("cache_creation_input_tokens"),
            cacheReadTokens: int("cache_read_input_tokens"),
            costUSD: cost)
    }

    private nonisolated static func parseAssistant(_ obj: [String: Any]) -> Event {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return Event() }
        var lines: [String] = []
        for item in content {
            switch item["type"] as? String {
            case "tool_use":
                let name = item["name"] as? String ?? "tool"
                let input = item["input"] as? [String: Any] ?? [:]
                lines.append("▸ \(name)\(toolDetail(name, input))")
            case "text":
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lines.append(text.count > 120 ? String(text.prefix(120)) + "…" : text)
                }
            default:
                break
            }
        }
        return Event(activityLines: lines)
    }

    private nonisolated static func parseStreamEvent(_ obj: [String: Any]) -> Event {
        // Outer envelope: {"type":"stream_event","event":{...}}
        guard let event = obj["event"] as? [String: Any],
              (event["type"] as? String) == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              (delta["type"] as? String) == "text_delta",
              let text = delta["text"] as? String else { return Event() }
        return Event(textDelta: text)
    }

    /// Maps known Claude tool names to a short human-readable detail suffix, matching
    /// the formatting established in NotesGenerator's toolDetail helper.
    private nonisolated static func toolDetail(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "Read", "Write", "Edit":
            if let p = input["file_path"] as? String { return ": \((p as NSString).lastPathComponent)" }
        case "Bash":
            if let c = input["command"] as? String { return ": \(c.prefix(60))" }
        case "Skill":
            if let s = input["command"] as? String ?? input["name"] as? String { return ": \(s)" }
        default:
            break
        }
        return ""
    }
}
