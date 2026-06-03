import Foundation

/// Summary engine that runs the user's Claude CLI with the shared prompt but WITHOUT the
/// skill, tools, or vault access — a fair same-prompt comparison point. Reuses
/// `ClaudeRunner.makeRawSummaryProcess`. Does not file anything; the Approve step files
/// whichever engine's output the user picks.
@MainActor
final class ClaudeSummaryEngine: SummaryEngine {
    let kind = SummaryEngineKind.claude
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func availability() async -> SummaryAvailability {
        FileManager.default.isExecutableFile(atPath: settings.claudeBinaryPath)
            ? .available
            : .unavailable("Claude CLI not found at \(settings.claudeBinaryPath). Set its path in Settings → Notes.")
    }

    func summarize(prompt: String) async throws -> String {
        let binaryPath = settings.claudeBinaryPath
        let model = settings.claudeModel
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try ClaudeRunner.makeRawSummaryProcess(binaryPath: binaryPath, prompt: prompt, model: model)
        } catch {
            throw SummaryError.engineUnavailable(error.localizedDescription)
        }

        // Run off the main actor; read stdout fully (text output), then stderr, then exit.
        return try await Task.detached(priority: .userInitiated) {
            do {
                try built.process.run()
            } catch {
                throw SummaryError.generationFailed("Failed to launch claude: \(error.localizedDescription)")
            }
            let outData = built.stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = built.stderr.fileHandleForReading.readDataToEndOfFile()
            built.process.waitUntilExit()
            guard built.process.terminationStatus == 0 else {
                let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw SummaryError.generationFailed(err.isEmpty ? "claude exited with code \(built.process.terminationStatus)" : err)
            }
            let text = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw SummaryError.generationFailed("claude produced no output.") }
            return text
        }.value
    }
}
