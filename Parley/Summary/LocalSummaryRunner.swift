import Foundation

/// App-wide owner of the local MLX summarizer. `SummaryService` and Settings both talk
/// to this singleton so the model is loaded once and shared across runs.
@MainActor
final class LocalSummaryRunner: ObservableObject {
    static let shared = LocalSummaryRunner()

    let manager = SummarizerManager()
    private lazy var engine = QwenLocalSummaryEngine(settings: AppSettings.shared, manager: manager)

    private init() {}

    var status: SummarizerManager.Status { manager.status }

    func summarize(prompt: String) async throws -> String {
        try await engine.summarize(prompt: prompt)
    }

    func unload() { manager.unload() }
}
