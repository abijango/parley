import Foundation

/// Runs a vision-only Cursor agent pass over meeting attachment images.
enum AttachmentVisionRunner {

    enum Outcome: Equatable {
        case success(String)
        case failure(String)
    }

    /// Analyzes attachments with a Cursor agent in read-only plan mode (vault workspace).
    static func analyze(attachments: [MeetingAttachment],
                        vault: URL,
                        backend: SummaryBackend,
                        cursorBinary: String) -> Outcome {
        guard backend.isCursorAgent, let model = backend.cursorModelID else {
            return .failure("Attachment vision requires a Cursor agent backend (Composer or Cursor Grok).")
        }
        guard !attachments.isEmpty else { return .failure("No attachments to analyze.") }
        let prompt = AttachmentVisionPromptBuilder.build(attachments: attachments, vault: vault)
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try CursorAgentRunner.makeVisionProcess(
                binaryPath: cursorBinary, prompt: prompt, model: model, vaultPath: vault.path)
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let timeout: TimeInterval = 600
        let output: ProcessOutput
        do {
            output = try ProcessRun.run(built.process, stdout: built.stdout, stderr: built.stderr, timeout: timeout)
        } catch {
            return .failure("Failed to launch cursor agent: \(error.localizedDescription)")
        }
        if output.timedOut {
            return .failure("Vision pass timed out after \(Int(timeout / 60)) min.")
        }

        let stdout = output.stdoutText
        let stderr = output.stderrText

        guard output.exitCode == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail.isEmpty ? "Vision pass exited with code \(output.exitCode)" : detail)
        }

        let text: String
        if let data = CursorAgentRunner.lastJSONObjectData(stdout: stdout) {
            switch CursorAgentRunner.parseJSONResult(data) {
            case .text(let t): text = CursorAgentRunner.sanitizeDiagramText(t)
            case .error(let msg): return .failure(msg)
            case .unparseable: text = CursorAgentRunner.sanitizeDiagramText(stdout)
            }
        } else {
            text = CursorAgentRunner.sanitizeDiagramText(stdout)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Vision pass returned empty output.") }
        return .success(trimmed)
    }
}
