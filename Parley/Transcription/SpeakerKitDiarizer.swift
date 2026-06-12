import Foundation
import SpeakerKit

/// Thin wrapper around Argmax SpeakerKit, hiding the SDK behind the shapes the rest
/// of Parley already uses (DiarizationAttribution.Turn + per-speaker centroid
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
    ///
    /// - Parameters:
    ///   - clusterThreshold: Maps to `PyannoteDiarizationOptions.clusterDistanceThreshold`.
    ///     Lower values split clusters more aggressively (more speakers); higher values merge
    ///     similar voices. SpeakerKit's internal default is 0.6 — passing `nil` preserves
    ///     that exact behavior.
    ///   - expectedSpeakers: Maps to `PyannoteDiarizationOptions.numberOfSpeakers`.
    ///     **Hard constraint** — SpeakerKit will produce exactly this many clusters, which
    ///     can suppress genuine variation or force artificial splits if wrong. Only pass this
    ///     when the attendee count comes from user-accepted meeting metadata; never infer it.
    ///   - progress: Optional callback receiving 0…1 progress fractions from SpeakerKit's
    ///     `Progress.fractionCompleted`. Fires at high rate; callers throttle downstream.
    func diarize(_ samples: [Float],
                 clusterThreshold: Double? = nil,
                 expectedSpeakers: Int? = nil,
                 progress: (@Sendable (Double) -> Void)? = nil) async throws -> Output {
        try await ensureLoaded()
        guard let sk = speakerKit else { throw SpeakerKitDiarizerError.notLoaded }

        let options: PyannoteDiarizationOptions? = (clusterThreshold != nil || expectedSpeakers != nil)
            ? PyannoteDiarizationOptions(
                numberOfSpeakers: expectedSpeakers,
                clusterDistanceThreshold: clusterThreshold.map { Float($0) })
            : nil

        if let opts = options {
            let threshStr = opts.clusterDistanceThreshold.map { String(format: "%.2f", $0) } ?? "default"
            let speakersStr = opts.numberOfSpeakers.map { String($0) } ?? "default"
            AppLog.log("SpeakerKit diarize: threshold=\(threshStr), expectedSpeakers=\(speakersStr)", category: "record")
        } else {
            AppLog.log("SpeakerKit diarize: defaults", category: "record")
        }

        // SpeakerKit's progressCallback delivers a Foundation `Progress` object; extract
        // `fractionCompleted` and forward it as a plain Double to stay framework-agnostic.
        let progressCallback: (@Sendable (Progress) -> Void)? = progress.map { cb in
            { p in cb(p.fractionCompleted) }
        }
        let result = try await sk.diarize(audioArray: samples, options: options,
                                          progressCallback: progressCallback)

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

    /// Embed a single-speaker enrollment clip into the `pyannote_v3` space — the
    /// SpeakerKit counterpart to `FluidAudioEngine.embeddings(forClip:)`. Runs
    /// diarization on the clip and returns the DOMINANT speaker's centroid (the clip
    /// is one person, but background noise can spawn minor clusters, so pick the
    /// speaker with the most speech). Returns nil for a too-short clip or if no
    /// embedding could be derived.
    ///
    /// Reuses the already-loaded SpeakerKit model, so a batch caller should keep one
    /// diarizer alive across all clips and `unload()` once at the end (the model load
    /// is expensive — never per-clip).
    func embedding(forClip samples: [Float], clusterThreshold: Double? = nil) async -> [Float]? {
        guard samples.count >= 16_000 else { return nil }   // < 1 s is too short to embed
        guard let out = try? await diarize(samples, clusterThreshold: clusterThreshold) else { return nil }
        // Dominant speaker = most total speech in the clip.
        var talk: [String: TimeInterval] = [:]
        for t in out.turns { talk[t.speakerId, default: 0] += max(0, t.end - t.start) }
        guard let dominant = talk.max(by: { $0.value < $1.value })?.key,
              let centroid = out.centroids[dominant], !centroid.isEmpty else { return nil }
        return centroid
    }
}

enum SpeakerKitDiarizerError: Error { case notLoaded }
