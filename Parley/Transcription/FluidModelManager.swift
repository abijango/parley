import Foundation
import FluidAudio

/// Identity of a Fluid streaming load. Start only reuses a warmup session when
/// this matches the live Settings snapshot.
struct FluidPrepareKey: Equatable, Sendable {
    let profile: FluidAsrProfile
    let language: String
    let chunkMs: Int

    @MainActor
    static func current(settings: AppSettings) -> FluidPrepareKey {
        FluidPrepareKey(
            profile: FluidAsrBinding.profile(from: settings),
            language: settings.liveStreamingLanguage,
            chunkMs: settings.liveStreamingTier.rawValue)
    }
}

/// A loaded streaming ASR session held by `FluidModelManager` until live Start takes it.
enum FluidWarmSession {
    case unified(StreamingUnifiedAsrManager)
    case nemotron(StreamingNemotronMultilingualAsrManager)
}

/// Tracks the on-disk state of the FluidAudio (Parakeet) speech model and can
/// fetch it on demand — the FluidAudio counterpart to `ModelManager` (WhisperKit).
///
/// FluidAudio downloads/compiles its own CoreML bundles under Application Support;
/// this manager surfaces whether they're present and offers an explicit download,
/// so Settings can show a download/ready control instead of the Whisper list.
@MainActor
final class FluidModelManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case notDownloaded
        case downloading
        case loading
        case downloaded
        case failed(String)
    }

    @Published private(set) var status: Status = .unknown

    /// FluidAudio's on-disk model store (~/Library/Application Support/FluidAudio/Models), for display.
    static var modelsDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory() }

    /// `AsrModels.modelsExist(at:)` strips the last path component and re-appends
    /// the repo folder internally, so it expects a *repo-level* path under the
    /// models root — not the root itself. Probe with a placeholder leaf so the
    /// strip lands back on the models root.
    private static var presenceProbe: URL { modelsDirectory.appendingPathComponent("parakeet") }

    private var loadingTask: Task<FluidWarmSession?, Never>?
    private var warmed: FluidWarmSession?
    private var warmedKey: FluidPrepareKey?

    /// Check whether the Parakeet v3 ASR models are already on disk.
    func refreshPresence() {
        guard status != .downloading, status != .loading, loadingTask == nil, warmed == nil else { return }
        status = AsrModels.modelsExist(at: Self.presenceProbe, version: .v3) ? .downloaded : .notDownloaded
    }

    /// Load (and download if needed) the streaming ASR stack. Joins an in-flight
    /// load. Holds the session in RAM until `takePrepared` or `unload`.
    func prepare() async -> FluidWarmSession? {
        let key = FluidPrepareKey.current(settings: AppSettings.shared)
        if let warmed, warmedKey == key { return warmed }
        if let loadingTask { return await loadingTask.value }

        let task = Task { await self.load(key: key) }
        loadingTask = task
        let result = await task.value
        loadingTask = nil
        return result
    }

    /// Hand the warmed session to a live engine. Nil when the key no longer matches
    /// (Settings changed) or nothing was prepared.
    func takePrepared(matching key: FluidPrepareKey) async -> FluidWarmSession? {
        _ = await prepare()
        guard warmedKey == key, let session = warmed else {
            await discardWarmed()
            return nil
        }
        warmed = nil
        warmedKey = nil
        return session
    }

    func unload() async {
        guard loadingTask == nil else { return }
        await discardWarmed()
        refreshPresence()
        AppLog.log("FluidAudio streaming models unloaded (idle) — \(MemoryGuard.snapshot())", category: "model")
    }

    /// Settings download button. Same load as launch warmup.
    func download() {
        Task { _ = await prepare() }
    }

    private func load(key: FluidPrepareKey) async -> FluidWarmSession? {
        await discardWarmed()
        let onDisk = AsrModels.modelsExist(at: Self.presenceProbe, version: .v3)
        status = onDisk ? .loading : .downloading
        ModelManager.markCompiledLoadInProgress()
        AppLog.log("FluidAudio preparing streaming ASR (\(key.profile.rawValue)) — \(MemoryGuard.snapshot())", category: "model")
        do {
            let session: FluidWarmSession
            if key.profile == .parakeetUnified {
                let variant = FluidAsrRouting.unifiedStreamingVariant()
                let config = variant.unifiedConfig ?? UnifiedConfig()
                let unified = StreamingUnifiedAsrManager(config: config)
                try await unified.loadModels()
                session = .unified(unified)
                AppLog.log("FluidAudio Parakeet Unified streaming models loaded", category: "model")
            } else {
                let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: key.language, chunkMs: key.chunkMs)
                let nemotron = StreamingNemotronMultilingualAsrManager()
                try await nemotron.loadModels(from: dir)
                session = .nemotron(nemotron)
                AppLog.log("FluidAudio Nemotron streaming models loaded (\(key.chunkMs)ms, \(key.language))", category: "model")
            }
            ModelManager.markCompiledLoadFinished()
            warmed = session
            warmedKey = key
            status = .downloaded
            return session
        } catch {
            ModelManager.markCompiledLoadFinished()
            status = .failed(error.localizedDescription)
            AppLog.log("FluidAudio streaming prepare failed: \(error.localizedDescription)", category: "model")
            return nil
        }
    }

    private func discardWarmed() async {
        switch warmed {
        case .unified(let unified):
            await unified.cleanup()
        case .nemotron(let nemotron):
            await nemotron.cleanup()
        case nil:
            break
        }
        warmed = nil
        warmedKey = nil
    }
}
