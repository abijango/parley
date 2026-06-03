import Foundation

/// Helpers for running the user's `process-meeting-transcript` skill headlessly
/// via `claude -p`. Pure building/parsing here; `NotesGenerator` owns the
/// `Process` lifecycle (so it can be cancelled).
///
/// Skills resolve through `/skill-name` in `-p` mode; `--permission-mode
/// acceptEdits` lets the otherwise-interactive skill write without prompting,
/// and `--output-format json` gives us a parseable result.
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

    /// Substitutes template tokens and appends an instruction to print the note
    /// path so we can open it afterwards.
    static func buildPrompt(
        template: String,
        transcriptURL: URL,
        destination: String,
        attendees: String
    ) -> String {
        let leaf = destination.split(separator: "/").last.map(String.init) ?? destination
        let prompt = template
            .replacingOccurrences(of: "{{file}}", with: transcriptURL.path)
            .replacingOccurrences(of: "{{destination}}", with: destination.isEmpty ? "(unspecified — choose the best folder)" : destination)
            .replacingOccurrences(of: "{{customer}}", with: leaf.isEmpty ? "(unspecified)" : leaf)
            .replacingOccurrences(of: "{{attendees}}", with: attendees.isEmpty ? "(none provided)" : attendees)
        return prompt + "\n\nWhen finished, print ONLY the absolute path of the note file you created or updated as the very last line of your output."
    }

    /// Re-process variant: same context, but instructs Claude to write the note
    /// to a fixed STAGING path instead of filing it into the vault, so the app can
    /// diff it against the existing note before committing.
    static func buildReprocessPrompt(
        template: String,
        transcriptURL: URL,
        destination: String,
        attendees: String,
        stagedNoteURL: URL
    ) -> String {
        let base = buildPrompt(template: template, transcriptURL: transcriptURL,
                               destination: destination, attendees: attendees)
        return base + """


        IMPORTANT — re-process mode: This transcript already has a note. Do NOT \
        file, move, or archive anything in the vault, and do NOT create or edit any \
        note other than the staging file. Write the full, finished note (frontmatter \
        + body, exactly as you would have filed it) to this absolute path, creating \
        the parent folder if needed:

        \(stagedNoteURL.path)

        Then print ONLY that path as the very last line of your output.
        """
    }

    /// Builds (does not start) a RAW `claude -p` process for the summary-comparison
    /// path: the prompt is fully self-contained, so NO skill, NO tools, and NO vault
    /// access (`--add-dir`/`--allowedTools` omitted). `--output-format text` returns the
    /// Markdown directly on stdout. stdin is the null device to skip the CLI's 3s
    /// "no stdin received" wait. Filing happens later via the Approve step, not here.
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
        process.arguments = [
            "-p", prompt,
            "--model", model,
            "--output-format", "text",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        return (process, stdout, stderr)
    }

    /// Builds (does not start) the configured `claude -p` process with attached
    /// stdout/stderr pipes. Throws `binaryNotFound` if the binary is missing.
    static func makeProcess(
        binaryPath: String,
        prompt: String,
        vaultPath: String,
        model: String
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw RunError.binaryNotFound(binaryPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-p", prompt,
            "--add-dir", vaultPath,
            "--permission-mode", "acceptEdits",
            "--allowedTools", "Read,Write,Edit,Skill,Bash",
            "--model", model,
            // Stream events so the UI can show live progress; stream-json in
            // print mode requires --verbose.
            "--output-format", "stream-json",
            "--verbose",
            // Speed: don't boot the user's MCP servers (playwright, supabase, …)
            // or persist a session — the notes skill needs none of that.
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        return (process, stdout, stderr)
    }

    /// Finds the last line that looks like an absolute path to a `.md` file.
    static func notePath(in text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/"), trimmed.lowercased().hasSuffix(".md") {
                return trimmed
            }
        }
        return nil
    }
}
