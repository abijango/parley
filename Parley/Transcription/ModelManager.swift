import Foundation
import WhisperKit
import CoreML

/// Load/preparation status for the active Whisper model.
enum ModelStatus: Equatable {
    case idle
    case downloading(Double)              // 0...1
    case loading(stage: String, fraction: Double)  // discrete load stages → coarse bar
    case ready
    case failed(String)
}

/// Owns the lifecycle of the WhisperKit model: download (to our own folder),
/// load, and expose status to the UI. A single loaded model is shared by both
/// track pipelines via `TranscriptionService`.
@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var status: ModelStatus = .idle
    @Published private(set) var loadedModel: WhisperModel?
    /// Set when the active model looks risky to load on this Mac right now (low
    /// RAM for the variant, or the system is already thrashing swap). Advisory
    /// only — we never block a load the user explicitly chose, just warn loudly.
    @Published private(set) var memoryAdvisory: String?

    /// Which model variants are present on disk (by raw repo name).
    @Published private(set) var downloadedModels: Set<String> = []
    /// In-progress downloads → fraction complete (0...1), keyed by raw repo name.
    @Published private(set) var downloadProgress: [String: Double] = [:]

    private(set) var whisperKit: WhisperKit?
    /// Compute mode the loaded model was built with — changing it forces a reload.
    private var loadedCompute: ComputeMode?
    /// In-flight load, so concurrent callers (launch preload + Start) share one load.
    private var loadingTask: Task<WhisperKit?, Never>?

    private static let repoSubpath = "models/argmaxinc/whisperkit-coreml"
    /// Set while a compute-graph load is in flight; if it's still set at next
    /// launch, the previous load crashed (e.g. a corrupt MPSGraph cache) → recover.
    private static let loadInProgressKey = "parley.modelLoadInProgress"

    init() {
        refreshDownloadedModels()
    }

    // MARK: Compiled-model cache (CoreML/MPSGraph) — crash recovery

    /// The OS-managed compiled-model cache for this app (`…/<bundleID>/com.apple.e5rt.e5bundlecache`).
    /// A corrupt/partial entry here makes CoreML/MPSGraph crash on load.
    static func compiledCacheURL() -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(bundleID).appendingPathComponent("com.apple.e5rt.e5bundlecache")
    }

    /// Deletes the compiled-model cache (it regenerates on the next load).
    static func clearCompiledCache() {
        guard let url = compiledCacheURL() else { return }
        try? FileManager.default.removeItem(at: url)
        AppLog.log("Cleared compiled-model cache: \(url.path)", category: "model")
    }

    /// Call once at launch BEFORE loading: if the last load never completed
    /// (the in-progress flag survived), it crashed mid-compile → clear the
    /// (likely corrupt) cache so this load starts clean instead of crash-looping.
    static func recoverFromCrashedLoadIfNeeded() {
        guard UserDefaults.standard.bool(forKey: loadInProgressKey) else { return }
        AppLog.log("Previous model load didn't finish (likely a crash) — clearing compiled cache to recover", category: "model")
        clearCompiledCache()
        UserDefaults.standard.set(false, forKey: loadInProgressKey)
    }

    // MARK: Download management

    /// Local folder WhisperKit downloads a variant into.
    func localFolder(for model: WhisperModel) -> URL {
        AppPaths.modelsDirectory
            .appendingPathComponent(Self.repoSubpath, isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        let folder = localFolder(for: model)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        return (contents?.isEmpty == false)
    }

    /// Rescans disk for which models are present.
    func refreshDownloadedModels() {
        downloadedModels = Set(WhisperModel.allCases.filter { isDownloaded($0) }.map { $0.rawValue })
    }

    func isDownloading(_ model: WhisperModel) -> Bool {
        downloadProgress[model.rawValue] != nil
    }

    /// Explicitly downloads a variant with progress, for Settings.
    func download(_ model: WhisperModel) async {
        guard downloadProgress[model.rawValue] == nil else { return }
        AppPaths.ensureDirectory(AppPaths.modelsDirectory)
        downloadProgress[model.rawValue] = 0
        let start = Date()
        AppLog.log("Download requested: \(model.rawValue) (\(model.approxSize))", category: "model")

        do {
            _ = try await WhisperKit.download(
                variant: model.rawValue,
                downloadBase: AppPaths.modelsDirectory,
                from: "argmaxinc/whisperkit-coreml"
            ) { progress in
                // progress callback may fire off the main actor → hop back.
                Task { @MainActor in
                    self.downloadProgress[model.rawValue] = progress.fractionCompleted
                }
            }
            downloadProgress[model.rawValue] = nil
            refreshDownloadedModels()
            AppLog.log("Download complete: \(model.rawValue) in \(Self.secs(start))s", category: "model")
        } catch {
            downloadProgress[model.rawValue] = nil
            status = .failed("Download failed: \(error.localizedDescription)")
            AppLog.log("Download failed: \(model.rawValue): \(error.localizedDescription)", category: "model")
        }
    }

    /// Ensures the requested model is downloaded and loaded. Idempotent: returns
    /// immediately if already loaded, and joins an in-flight load if one exists.
    func prepare(_ model: WhisperModel) async -> WhisperKit? {
        if loadedModel == model, loadedCompute == AppSettings.shared.computeMode, let whisperKit { return whisperKit }
        if let loadingTask { return await loadingTask.value }

        let task = Task { await self.load(model) }
        loadingTask = task
        let result = await task.value
        loadingTask = nil
        return result
    }

    /// Releases the loaded model to reclaim memory during a long idle period.
    /// The next `prepare` reloads it — fast on GPU (no ANE specialization), and
    /// recording starts capturing immediately while the reload runs, so nothing
    /// is lost. Skipped if a load is in flight or nothing is loaded.
    func unload() async {
        guard loadingTask == nil, let kit = whisperKit else { return }
        await kit.unloadModels()
        whisperKit = nil
        loadedModel = nil
        loadedCompute = nil
        status = .idle
        AppLog.log("Model unloaded (idle) to free memory — \(MemoryGuard.snapshot())", category: "model")
    }

    private func load(_ model: WhisperModel) async -> WhisperKit? {
        AppPaths.ensureDirectory(AppPaths.modelsDirectory)
        // Release any previously loaded model first so we don't hold two in
        // memory at once (and so switching models actually frees the old one).
        //
        // CRITICAL: just dropping the Swift reference (`whisperKit = nil`) does
        // NOT free the model — WhisperKit's CoreML sub-models (feature extractor,
        // audio encoder, text decoder) retain their compiled MLModel + Metal
        // buffers (~1 GB+) independent of the WhisperKit object. We must call
        // `unloadModels()` to release them; otherwise every reload (compute
        // toggle, model switch, cache reset, relaunch warmup) leaks the previous
        // instance and resident memory climbs into the tens of GB.
        if let old = whisperKit {
            await old.unloadModels()
            whisperKit = nil
            loadedModel = nil
            loadedCompute = nil
            AppLog.log("Unloaded previous model before reload (freed CoreML/Metal resources)", category: "model")
        }
        let compute = AppSettings.shared.computeMode
        let overallStart = Date()
        // Memory guard: snapshot RAM/swap and warn (don't block) if this load
        // looks likely to thrash or interrupt the compile on this machine.
        memoryAdvisory = MemoryGuard.advisory(for: model)
        AppLog.log("Preparing model \(model.rawValue) (\(model.approxSize)); compute=\(compute.rawValue); downloaded=\(isDownloaded(model)); \(MemoryGuard.snapshot())", category: "model")
        if let advisory = memoryAdvisory {
            AppLog.log("MEMORY ADVISORY — \(advisory)", category: "model")
        }

        do {
            // 1) Ensure present, with real byte progress (auto-download during
            //    load reports no bytes, so do it explicitly first if missing).
            if !isDownloaded(model) {
                status = .downloading(0)
                AppLog.log("Downloading \(model.rawValue)…", category: "model")
                let dlStart = Date()
                _ = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: AppPaths.modelsDirectory,
                    from: "argmaxinc/whisperkit-coreml"
                ) { progress in
                    Task { @MainActor in self.status = .downloading(progress.fractionCompleted) }
                }
                AppLog.log("Downloaded \(model.rawValue) in \(Self.secs(dlStart))s", category: "model")
                refreshDownloadedModels()
            }

            // 2) Build without auto load/prewarm so we can attach the state
            //    callback first, then drive + observe the load stages.
            status = .loading(stage: "Preparing…", fraction: 0.05)
            // Sentinel: if we crash during the compute-graph load below, this
            // flag survives and the next launch clears the corrupt cache.
            UserDefaults.standard.set(true, forKey: Self.loadInProgressKey)
            let config = WhisperKitConfig(
                model: model.rawValue,
                downloadBase: AppPaths.modelsDirectory,
                modelFolder: nil,
                computeOptions: Self.computeOptions(for: compute),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: false,
                download: true
            )
            let kit = try await WhisperKit(config)
            kit.modelStateCallback = { [weak self] _, newState in
                Task { @MainActor in self?.applyLoadState(newState) }
            }

            // On GPU there is no ANE specialization step, so skip prewarm (it only
            // pays off for the ANE) and just load — fast and no compile wait.
            if compute == .neuralEngine {
                let warmStart = Date()
                try await kit.prewarmModels()    // .prewarming → .prewarmed (ANE specialization)
                AppLog.log("Specialized \(model.rawValue) (ANE) in \(Self.secs(warmStart))s", category: "model")
            }

            let loadStart = Date()
            try await kit.loadModels()       // .loading → .loaded
            AppLog.log("Loaded \(model.rawValue) [\(compute.rawValue)] in \(Self.secs(loadStart))s (total \(Self.secs(overallStart))s)", category: "model")

            whisperKit = kit
            loadedModel = model
            loadedCompute = compute
            status = .ready
            UserDefaults.standard.set(false, forKey: Self.loadInProgressKey)   // clean load completed
            refreshDownloadedModels()
            return kit
        } catch {
            UserDefaults.standard.set(false, forKey: Self.loadInProgressKey)
            AppLog.log("Model \(model.rawValue) failed after \(Self.secs(overallStart))s: \(error.localizedDescription)", category: "model")
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    /// GPU avoids the Neural Engine entirely (no specialization compile);
    /// ANE matches WhisperKit's defaults (encoder/decoder on the ANE).
    private static func computeOptions(for mode: ComputeMode) -> ModelComputeOptions {
        switch mode {
        // WhisperKit 1.0 dropped the `prefillCompute` parameter from ModelComputeOptions.
        case .gpu:
            return ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                                       textDecoderCompute: .cpuAndGPU)
        case .neuralEngine:
            return ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine,
                                       textDecoderCompute: .cpuAndNeuralEngine)
        }
    }

    private static func secs(_ since: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(since))
    }

    /// Maps a WhisperKit load stage onto a coarse progress fraction + label.
    private func applyLoadState(_ state: ModelState) {
        if case .ready = status { return }   // already finished
        let mapped: (String, Double)?
        switch state {
        case .downloading: mapped = ("Downloading…", 0.10)
        case .downloaded:  mapped = ("Downloaded",  0.30)
        case .prewarming:  mapped = ("Specializing…", 0.50)
        case .prewarmed:   mapped = ("Specialized",  0.70)
        case .loading:     mapped = ("Loading…",     0.85)
        case .loaded:      mapped = ("Loaded",       1.0)
        case .unloading, .unloaded: mapped = nil
        }
        if let mapped { status = .loading(stage: mapped.0, fraction: mapped.1) }
    }

    /// Lists model variants available in the WhisperKit repo (for Settings).
    func availableRemoteModels() async -> [String] {
        (try? await WhisperKit.fetchAvailableModels()) ?? []
    }
}
