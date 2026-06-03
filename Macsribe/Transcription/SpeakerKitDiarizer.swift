import Foundation
import SpeakerKit

/// Thin wrapper around Argmax SpeakerKit, hiding the SDK behind the shapes the rest
/// of Macsribe already uses (DiarizationAttribution.Turn + per-speaker centroid
/// embeddings). Keeps the SpeakerKit dependency isolated to one file.
@MainActor
final class SpeakerKitDiarizer {
    private var speakerKit: SpeakerKit?

    /// Diarization output normalized for our pipeline.
    struct Output {
        /// Speaker turns (speakerId as String to match our pipeline).
        let turns: [DiarizationAttribution.Turn]
        /// Per-speaker centroid embedding (256-d, pyannote-v3), keyed by speakerId.
        let centroids: [String: [Float]]
        let speakerCount: Int
        /// The raw result — needed for SpeakerKit's native word-level merge
        /// (`addSpeakerInfo(to:)`) and `nearestSpeakerCentroid(to:)`.
        let raw: DiarizationResult
    }

    /// Load (download-if-needed) the SpeakerKit CoreML models once.
    func ensureLoaded() async throws {
        if speakerKit == nil { speakerKit = try await SpeakerKit() }
    }

    func unload() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }

    /// Diarize 16 kHz mono samples → normalized turns + centroid embeddings.
    func diarize(_ samples: [Float]) async throws -> Output {
        try await ensureLoaded()
        guard let sk = speakerKit else { throw SpeakerKitDiarizerError.notLoaded }
        let result = try await sk.diarize(audioArray: samples)

        let turns: [DiarizationAttribution.Turn] = result.segments.compactMap { seg in
            guard let id = seg.speaker.speakerId else { return nil }
            return DiarizationAttribution.Turn(
                speakerId: String(id),
                start: TimeInterval(seg.startTime),
                end: TimeInterval(seg.endTime))
        }
        var centroids: [String: [Float]] = [:]
        for (id, vec) in result.speakerCentroidEmbeddings { centroids[String(id)] = vec }

        return Output(turns: turns, centroids: centroids,
                      speakerCount: result.speakerCount, raw: result)
    }
}

enum SpeakerKitDiarizerError: Error { case notLoaded }
