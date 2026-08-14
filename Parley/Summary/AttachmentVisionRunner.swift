import Foundation

/// Runs a vision-only Cursor agent pass over meeting attachment images.
enum AttachmentVisionRunner {

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func trip() { lock.lock(); v = true; lock.unlock() }
        var tripped: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

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
        do { try built.process.run() }
        catch { return .failure("Failed to launch cursor agent: \(error.localizedDescription)") }

        let timedOut = TimeoutFlag()
        let timeout: TimeInterval = 600
        let watchdog = DispatchWorkItem {
            guard built.process.isRunning else { return }
            timedOut.trip()
            built.process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let stdoutData = built.stdout.fileHandleForReading.readDataToEndOfFile()
        built.stdout.fileHandleForReading.closeFile()
        let stderrData = built.stderr.fileHandleForReading.readDataToEndOfFile()
        built.stderr.fileHandleForReading.closeFile()
        built.process.waitUntilExit()
        watchdog.cancel()

        if timedOut.tripped {
            return .failure("Vision pass timed out after \(Int(timeout / 60)) min.")
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard built.process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail.isEmpty ? "Vision pass exited with code \(built.process.terminationStatus)" : detail)
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
