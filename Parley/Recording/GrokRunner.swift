import Foundation

/// Helpers for running the Grok CLI headlessly via `grok -p` for meeting summaries.
/// Pure building/parsing here; `SummaryService` owns the `Process` lifecycle.
///
/// Mirrors the Claude raw-summary path: a fully self-contained prompt, no vault tools,
/// stdout JSON (`.text`) as the note body. stdin is the null device.
enum GrokRunner {
    enum RunError: Error, LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let path):
                return "Grok CLI not found at \(path). Set its path in Settings → Summary."
            case .launchFailed(let message):
                return "Failed to launch grok: \(message)"
            }
        }
    }

    /// Outcome of parsing a `grok --output-format json` response body.
    enum JSONResult: Equatable {
        case text(String)
        case error(String)
        case unparseable
    }

    /// Built-in tools to strip for headless summary — transcript + contacts are already
    /// embedded in the prompt; file/shell access only invites agent narration (e.g. the
    /// `process-meeting-transcript` skill's "find the transcript on disk" steps).
    static let summaryDisallowedTools =
        "Agent,run_terminal_cmd,web_search,web_fetch,search_replace,write,image_gen,image_edit," +
        "Read,Grep,Glob,LS,list_dir,Bash,Skill"

    /// Extra system rules for headless summary — keeps the user prompt template identical
    /// across backends while steering Grok away from skill-style file hunting.
    static let summaryRules =
        "Headless meeting-summary mode. The user prompt embeds the COMPLETE transcript " +
        "under TRANSCRIPT: — do not search for, read, or open any files. " +
        "Output ONLY the finished Markdown note. Begin with ## Attendees. " +
        "No preamble, planning, or process narration."

    /// Neutral cwd so Grok does not load the Parley repo's project skills/instructions.
    static let summaryWorkingDirectory = "/tmp"

    /// Builds (does not start) a raw `grok -p` process for the summary path.
    /// Tool use is stripped so the model only returns markdown from the embedded prompt
    /// (parity with Claude's no-tools raw summary).
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
        process.arguments = [
            "-p", prompt,
            "-m", model,
            "--output-format", "json",
            "--no-subagents",
            "--no-memory",
            "--disable-web-search",
            "--max-turns", "1",
            "--permission-mode", "dontAsk",
            "--cwd", summaryWorkingDirectory,
            "--rules", summaryRules,
            // Keep the agent from writing the vault / running shell — transcript is
            // already in the prompt; we only want markdown on stdout.
            "--disallowed-tools", summaryDisallowedTools,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        return (process, stdout, stderr)
    }

    /// Grok sometimes prefixes agent narration ("Searching for the full transcript…")
    /// before the note even when tools are disabled. Drop everything before the first
    /// standard section heading.
    static func sanitizeNoteText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["## Attendees", "## Executive Summary"] {
            if let range = trimmed.range(of: marker, options: .caseInsensitive) {
                return String(trimmed[range.lowerBound...])
            }
        }
        return trimmed
    }

    /// Parse a Grok headless JSON payload.
    /// Success: `{ "text": "…", "stopReason": "EndTurn", … }`
    /// Failure: `{ "type": "error", "message": "…" }`
    static func parseJSONResult(_ data: Data) -> JSONResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        if let type = obj["type"] as? String, type == "error" {
            let msg = (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Grok error"
            return .error(msg.isEmpty ? "Grok error" : msg)
        }
        if let text = obj["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .unparseable : .text(trimmed)
        }
        return .unparseable
    }

    /// Convenience for string stdout.
    static func parseJSONResult(stdout: String) -> JSONResult {
        guard let data = stdout.data(using: .utf8) else { return .unparseable }
        // Grok may print a trailing newline; trim is fine for JSONSerialization.
        return parseJSONResult(data)
    }
}
