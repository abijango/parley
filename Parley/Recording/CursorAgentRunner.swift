import Foundation

/// Helpers for running `cursor agent -p` headlessly for meeting summaries.
/// Uses `--mode ask` (read-only) so the agent cannot edit the vault; the full
/// transcript is already embedded in the shared prompt (parity with Claude/Grok).
enum CursorAgentRunner {
    enum RunError: Error, LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let path):
                return "Cursor CLI not found at \(path). Set its path in Settings → Summary."
            case .launchFailed(let message):
                return "Failed to launch cursor agent: \(message)"
            }
        }
    }

    enum JSONResult: Equatable {
        case text(String)
        case error(String)
        case unparseable
    }

    /// Neutral cwd so the agent does not load the Parley repo's project skills.
    static let summaryWorkingDirectory = "/tmp"

    /// Builds (does not start) a headless `cursor agent -p --mode ask` process.
    static func makeRawSummaryProcess(
        binaryPath: String,
        prompt: String,
        model: String
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw RunError.binaryNotFound(binaryPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.currentDirectoryURL = URL(fileURLWithPath: summaryWorkingDirectory)
        // `cursor agent … <prompt>` — ask mode keeps it read-only; print+json for scripting.
        process.arguments = [
            "agent",
            "-p",
            "--mode", "ask",
            "--output-format", "json",
            "--model", model,
            "--trust",
            "--workspace", summaryWorkingDirectory,
            PromptStdin.argvPlaceholder,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try PromptStdin.attach(prompt, to: process)
        return (process, stdout, stderr)
    }

    /// Read-only vision pass: plan mode + vault workspace so the agent can open image files.
    static func makeVisionProcess(
        binaryPath: String,
        prompt: String,
        model: String,
        vaultPath: String
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw RunError.binaryNotFound(binaryPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.currentDirectoryURL = URL(fileURLWithPath: vaultPath)
        process.arguments = [
            "agent",
            "-p",
            "--mode", "plan",
            "--output-format", "json",
            "--model", model,
            "--trust",
            "--workspace", vaultPath,
            PromptStdin.argvPlaceholder,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try PromptStdin.attach(prompt, to: process)
        return (process, stdout, stderr)
    }

    /// Drop agent chatter before the Diagrams section.
    static func sanitizeDiagramText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "## Diagrams", options: .caseInsensitive) {
            return String(trimmed[range.lowerBound...])
        }
        return trimmed
    }

    /// Drop agent chatter before the first standard section heading.
    static func sanitizeNoteText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["## Attendees", "## Executive Summary"] {
            if let range = trimmed.range(of: marker, options: .caseInsensitive) {
                return String(trimmed[range.lowerBound...])
            }
        }
        return trimmed
    }

    /// Parse `cursor agent --output-format json` payload.
    /// Success: `{ "type":"result", "subtype":"success", "is_error":false, "result":"…" }`
    static func parseJSONResult(_ data: Data) -> JSONResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        return parseJSONResult(obj)
    }

    private static func parseJSONResult(_ obj: [String: Any]) -> JSONResult {
        if let isError = obj["is_error"] as? Bool, isError {
            let msg = (obj["result"] as? String)
                ?? (obj["message"] as? String)
                ?? "Cursor agent error"
            return .error(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let type = obj["type"] as? String, type == "error" {
            let msg = (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Cursor agent error"
            return .error(msg.isEmpty ? "Cursor agent error" : msg)
        }
        if let text = obj["result"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .unparseable : .text(trimmed)
        }
        // Some builds may use `text` like Grok.
        if let text = obj["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .unparseable : .text(trimmed)
        }
        return .unparseable
    }

    /// Extracts the last `{…}` JSON object from agent stdout (log lines may precede it).
    static func lastJSONObjectData(stdout: String) -> Data? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = trimmed.lastIndex(of: "{") else { return nil }
        return String(trimmed[start...]).data(using: .utf8)
    }

    /// Per-leg usage from a Cursor agent JSON payload. Nil when no `usage` object is present.
    static func parseUsage(_ data: Data) -> SummaryRunMetrics? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["usage"] as? [String: Any] else { return nil }
        var m = SummaryRunMetrics()
        m.inputTokens = usage["inputTokens"] as? Int ?? 0
        m.outputTokens = usage["outputTokens"] as? Int ?? 0
        m.cacheReadTokens = usage["cacheReadTokens"] as? Int ?? 0
        m.cacheWriteTokens = usage["cacheWriteTokens"] as? Int ?? 0
        if let apiMS = obj["duration_api_ms"] as? Int { m.apiDurationMS = apiMS }
        if let model = obj["model"] as? String { m.model = model }
        return m
    }

    static func parseUsage(stdout: String) -> SummaryRunMetrics? {
        guard let data = lastJSONObjectData(stdout: stdout) else { return nil }
        return parseUsage(data)
    }

    static func parseJSONResult(stdout: String) -> JSONResult {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), case let r = parseJSONResult(data), r != .unparseable {
            return r
        }
        guard let data = lastJSONObjectData(stdout: stdout) else { return .unparseable }
        return parseJSONResult(data)
    }
}
