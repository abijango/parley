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
            prompt,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        return (process, stdout, stderr)
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

    static func parseJSONResult(stdout: String) -> JSONResult {
        // Agent may print a log line before JSON — take the last `{…}` object.
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), case let r = parseJSONResult(data), r != .unparseable {
            return r
        }
        if let start = trimmed.lastIndex(of: "{"),
           let data = String(trimmed[start...]).data(using: .utf8) {
            return parseJSONResult(data)
        }
        return .unparseable
    }
}
