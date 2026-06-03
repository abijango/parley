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
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw SummaryError.generationFailed("Local model produced no output.") }
            return text
        } catch let e as SummaryError {
            throw e
        } catch {
            throw SummaryError.generationFailed(error.localizedDescription)
        }
    }
}
