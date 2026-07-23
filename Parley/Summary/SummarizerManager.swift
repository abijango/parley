import Foundation
import MLXLMCommon

/// Owns the lifecycle of the local MLX summarization model — download, load, hold, and
/// unload — mirroring `ModelManager` (WhisperKit). Holds a reusable `ModelContainer` so
/// repeated summaries don't reload weights; `unload()` frees the GPU memory when idle.
/// Runs on the GPU via MLX (NOT the ANE — see the plan's ANE note).
@MainActor
final class SummarizerManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case loading
        case ready(String)         // loaded model id
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var loadedModelId: String?

    private var container: ModelContainer?
    private var loadingTask: Task<ModelContainer?, Never>?
    private let downloader = HFModelDownloader()

    var isReady: Bool { if case .ready = status { return true }; return false }
    var failureReason: String? { if case .failed(let m) = status { return m }; return nil }

    /// Load (downloading on first use) `modelId`. Idempotent: returns the held container if
    /// it's the same model, and joins an in-flight load instead of starting a second.
    func prepare(modelId: String) async -> ModelContainer? {
        if let container, loadedModelId == modelId { return container }
        if let loadingTask { return await loadingTask.value }
        let task = Task { await self.load(modelId) }
        loadingTask = task
        let result = await task.value
        loadingTask = nil
        return result
    }

    private func load(_ modelId: String) async -> ModelContainer? {
        container = nil
        loadedModelId = nil
        status = .downloading(0)
        AppLog.log("Summary(Qwen): loading \(modelId)…", category: "summary")
        do {
            // Download the files ourselves (bypassing the Hub's flaky Xet client), then load
            // MLX from the local directory so it never re-fetches via Xet.
            let dir = AppPaths.summaryModelsDirectory.appendingPathComponent(modelId, isDirectory: true)
            let resolved = try await downloader.ensureModel(id: modelId, in: dir) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    if fraction < 1 { self.status = .downloading(fraction) }
                }
            }
            status = .loading
            AppLog.log("Summary(Qwen): files ready, loading weights from \(resolved.lastPathComponent)…", category: "summary")
            let loaded = try await loadModelContainer(configuration: ModelConfiguration(directory: resolved))
            container = loaded
            loadedModelId = modelId
            status = .ready(modelId)
            AppLog.log("Summary(Qwen): model ready — \(modelId)", category: "summary")
            return loaded
        } catch {
            status = .failed(error.localizedDescription)
            AppLog.log("Summary(Qwen): load failed — \(error.localizedDescription)", category: "summary")
            return nil
        }
    }

    /// Drop the model and free its GPU memory. The next `prepare` reloads it.
    func unload() {
        guard loadingTask == nil else { return }
        container = nil
        loadedModelId = nil
        status = .idle
        AppLog.log("Summary(Qwen): model unloaded", category: "summary")
    }
}
