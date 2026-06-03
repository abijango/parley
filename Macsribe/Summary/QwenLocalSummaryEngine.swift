import Foundation
import MLXLMCommon

/// Summary engine backed by a local Qwen model running on the GPU via MLX. Fully offline.
/// Uses `SummarizerManager` to download/load/hold the model, and a fresh `ChatSession`
/// per summary so runs don't share chat history. Does not file anything (Approve step does).
@MainActor
final class QwenLocalSummaryEngine: SummaryEngine {
    let kind = SummaryEngineKind.qwenLocal
    private let settings: AppSettings
    private let manager: SummarizerManager

    init(settings: AppSettings, manager: SummarizerManager) {
        self.settings = settings
        self.manager = manager
    }

    func availability() async -> SummaryAvailability {
        // MLX runs on any Apple Silicon Mac; the model downloads on first use.
        let id = settings.localSummaryModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .unavailable("Set a local model id in Settings → Summary.") }
        return .available
    }

    func summarize(prompt: String) async throws -> String {
        let modelId = settings.localSummaryModelId.trimmingCharacters(in: .whitespaces)
        guard !modelId.isEmpty else { throw SummaryError.engineUnavailable("No local model id set.") }
        guard let container = await manager.prepare(modelId: modelId) else {
            throw SummaryError.engineUnavailable(manager.failureReason ?? "Couldn't load the local model \(modelId).")
        }
        do {
            let session = ChatSession(container)
            let out = try await session.respond(to: prompt)
            let text = Self.stripReasoning(out)
            guard !text.isEmpty else { throw SummaryError.generationFailed("Local model produced no output.") }
            return text
        } catch let e as SummaryError {
            throw e
        } catch {
            throw SummaryError.generationFailed(error.localizedDescription)
        }
    }

    /// Qwen3 is a reasoning model: it emits a `<think>…</think>` block before the answer.
    /// Keep reasoning ON (better quality) but drop the block from the displayed note.
    /// Handles a normal block, an unclosed `<think>`, and a stray closing `</think>`.
    static func stripReasoning(_ text: String) -> String {
        var s = text
        if let start = s.range(of: "<think>") {
            if let end = s.range(of: "</think>", range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)   // unclosed → drop the rest
            }
        } else if let end = s.range(of: "</think>") {
            s.removeSubrange(s.startIndex..<end.upperBound)        // closing tag only
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
