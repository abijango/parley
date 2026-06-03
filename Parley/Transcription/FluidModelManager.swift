import Foundation
import FluidAudio

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

    /// Check whether the Parakeet v3 ASR models are already on disk.
    func refreshPresence() {
        guard status != .downloading else { return }
        status = AsrModels.modelsExist(at: Self.presenceProbe, version: .v3) ? .downloaded : .notDownloaded
    }

    /// Fetch the Parakeet v3 models to disk (download only, no load). Idempotent —
    /// skips files already present. The engine loads them at record time.
    /// `AsrModels.download` throws on failure, so no-throw means success.
    func download() {
        guard status != .downloading else { return }
        status = .downloading
        Task {
            do {
                _ = try await AsrModels.download(version: .v3)
                status = .downloaded
                AppLog.log("FluidAudio Parakeet v3 models downloaded/verified", category: "model")
            } catch {
                status = .failed(error.localizedDescription)
                AppLog.log("FluidAudio model download failed: \(error.localizedDescription)", category: "model")
            }
        }
    }
}
