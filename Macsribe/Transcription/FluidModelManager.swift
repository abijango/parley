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

    /// FluidAudio's on-disk model store (~/Library/Application Support/FluidAudio/Models).
    static var modelsDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory() }

    /// Check whether the Parakeet v3 ASR models are already on disk.
    func refreshPresence() {
        guard status != .downloading else { return }
        status = AsrModels.modelsExist(at: Self.modelsDirectory) ? .downloaded : .notDownloaded
    }

    /// Fetch the Parakeet v3 models to disk (download only, no load). Idempotent —
    /// skips files already present. The engine loads them at record time.
    func download() {
        guard status != .downloading else { return }
        status = .downloading
        Task {
            do {
                _ = try await AsrModels.download(version: .v3)
                status = AsrModels.modelsExist(at: Self.modelsDirectory)
                    ? .downloaded : .failed("Download did not complete")
                AppLog.log("FluidAudio Parakeet v3 models present after download", category: "model")
            } catch {
                status = .failed(error.localizedDescription)
                AppLog.log("FluidAudio model download failed: \(error.localizedDescription)", category: "model")
            }
        }
    }
}
