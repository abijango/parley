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
/// fetch it on demand.
///
/// FluidAudio downloads/compiles its own CoreML bundles under Application Support;
/// this manager surfaces whether they're present and offers an explicit download.
@MainActor
final class FluidModelManager: ObservableObject {
    /// Set while a compute-graph load is in flight; if it's still set at next
    /// launch, the previous load crashed (e.g. a corrupt MPSGraph cache) → recover.
    static let loadInProgressKey = "parley.modelLoadInProgress"
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

    /// The OS-managed compiled-model cache for this app (`…/<bundleID>/com.apple.e5rt.e5bundlecache`).
    static func compiledCacheURL() -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(bundleID).appendingPathComponent("com.apple.e5rt.e5bundlecache")
    }

    static func clearCompiledCache() {
        guard let url = compiledCacheURL() else { return }
        try? FileManager.default.removeItem(at: url)
        AppLog.log("Cleared compiled-model cache: \(url.path)", category: "model")
    }

    static func recoverFromCrashedLoadIfNeeded() {
        guard UserDefaults.standard.bool(forKey: loadInProgressKey) else { return }
        if AppInfo.isXCTestHost {
            markCompiledLoadFinished()
            return
        }
        AppLog.log("Previous model load didn't finish (likely a crash) — clearing compiled cache to recover", category: "model")
        clearCompiledCache()
        markCompiledLoadFinished()
    }

    static func markCompiledLoadInProgress() {
        if AppInfo.isXCTestHost { return }
        UserDefaults.standard.set(true, forKey: loadInProgressKey)
    }

    static func markCompiledLoadFinished() {
        UserDefaults.standard.set(false, forKey: loadInProgressKey)
    }

    static func noteGracefulShutdown() {
        markCompiledLoadFinished()
    }

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
        FluidModelManager.markCompiledLoadInProgress()
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
            FluidModelManager.markCompiledLoadFinished()
            warmed = session
            warmedKey = key
            status = .downloaded
            return session
        } catch {
            FluidModelManager.markCompiledLoadFinished()
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
