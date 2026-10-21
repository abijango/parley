import Foundation

/// Builds the headless `claude -p` process for the summary path. The prompt is
/// fully self-contained, so no skill, no tools, and no vault access; it goes on
/// stdin, not argv.
enum ClaudeRunner {
    enum RunError: Error, LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let path):
                return "Claude CLI not found at \(path). Set its path in Settings → Notes."
            case .launchFailed(let message):
                return "Failed to launch claude: \(message)"
            }
        }
    }

    /// Builds (does not start) a streaming `claude -p` process with
    /// `--output-format stream-json --verbose --include-partial-messages` so callers
    /// can parse NDJSON events and drive a live-activity ticker.
    static func makeRawSummaryStreamProcess(
        binaryPath: String,
        prompt: String,
        model: String
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw RunError.binaryNotFound(binaryPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-p", PromptStdin.argvPlaceholder,
            "--model", model,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try PromptStdin.attach(prompt, to: process)
        return (process, stdout, stderr)
    }
}
