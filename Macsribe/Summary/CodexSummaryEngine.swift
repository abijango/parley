import Foundation

/// Summary engine that shells out to the OpenAI Codex CLI's non-interactive `codex exec`
/// (the `claude -p` analogue). Runs read-only, outside any git repo, with no session
/// persistence, in a throwaway working dir, and captures ONLY the final message via
/// `-o <file>`. The model is whatever the user's `~/.codex/config.toml` is set to (so the
/// app doesn't hardcode it); an optional model override can be set in Settings. Like the
/// Claude engine, it doesn't file anything — the Approve step files the chosen output.
@MainActor
final class CodexSummaryEngine: SummaryEngine {
    let kind = SummaryEngineKind.codex
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func availability() async -> SummaryAvailability {
        FileManager.default.isExecutableFile(atPath: settings.codexBinaryPath)
            ? .available
            : .unavailable("Codex CLI not found at \(settings.codexBinaryPath). Set its path in Settings → Summary.")
    }

    func summarize(prompt: String) async throws -> String {
        let binary = settings.codexBinaryPath
        let model = settings.codexModel.trimmingCharacters(in: .whitespaces)
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw SummaryError.engineUnavailable("Codex CLI not found at \(binary).")
        }

        return try await Task.detached(priority: .userInitiated) {
            let workDir = FileManager.default.temporaryDirectory
            let outURL = workDir.appendingPathComponent("codex-summary-\(UUID().uuidString).md")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            var args = ["exec",
                        "-s", "read-only",
                        "--skip-git-repo-check",
                        "--ephemeral",
                        "--color", "never",
                        "-C", workDir.path,
                        "-o", outURL.path]
            if !model.isEmpty { args += ["-m", model] }
            args.append(prompt)
            process.arguments = args
            // GUI apps inherit a minimal PATH; give codex a normal one for any helpers it spawns.
            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do { try process.run() }
            catch { throw SummaryError.generationFailed("Failed to launch codex: \(error.localizedDescription)") }

            // Drain both pipes to avoid filling the buffer, then wait.
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: outURL) }

            let note = (try? String(contentsOf: outURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0, !note.isEmpty { return note }

            let combined = (String(data: errData, encoding: .utf8) ?? "")
                + "\n" + (String(data: outData, encoding: .utf8) ?? "")
            throw SummaryError.generationFailed(Self.friendlyError(combined, exit: process.terminationStatus))
        }.value
    }

    /// Map common Codex failures to actionable messages.
    private nonisolated static func friendlyError(_ output: String, exit: Int32) -> String {
        let lower = output.lowercased()
        if lower.contains("not supported when using codex with a chatgpt account") {
            return "Codex rejected the model for your account. Set a supported model in Settings → Summary (e.g. gpt-5.5)."
        }
        if lower.contains("tokenrefreshfailed") || lower.contains("client id and client secret")
            || lower.contains("not logged in") || lower.contains("unauthorized") {
            return "Codex isn't authenticated. Run `codex login` in a terminal, then retry."
        }
        // Otherwise surface the last non-empty error line.
        if let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) {
            return String(line.prefix(240))
        }
        return "codex exec failed (exit \(exit))."
    }
}
