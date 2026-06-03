import Foundation

/// Result of the at-stop offline diarization pass, surfaced to the UI.
struct OfflinePassSummary: Sendable {
    let speakerCount: Int
    let relabeled: Bool
    let note: String
}

/// A `TranscriptionEngine` that also produces speaker diarization + the at-stop
/// review surface. Both `FluidAudioEngine` and `WhisperKitSpeakerKitEngine` conform,
/// so `RecordingController` drives the offline-pass / review / voiceprint flow against
/// this protocol rather than a concrete engine. FluidAudio conforms via the extension
/// below (its source file is left untouched).
@MainActor
protocol SpeakerCapableEngine: TranscriptionEngine {
    /// Fired when a speaker is auto-identified to a saved voiceprint (the person's name).
    var onSpeakerIdentified: ((String) -> Void)? { get set }

    /// Clean mixed file + per-track archives, set before `start()`; used by the offline
    /// pass for diarization, playback, and clip extraction.
    var mixedAudioURL: URL? { get set }
    var micArchiveURL: URL? { get set }
    var systemArchiveURL: URL? { get set }
    /// Force the offline transcript pass even without live streaming units (History re-process).
    var forceOfflineAsr: Bool { get set }

    /// Run the authoritative whole-recording diarization (+ transcript) pass at stop.
    func runOfflinePass() async -> OfflinePassSummary

    /// Per-speaker summaries for the at-stop "Assign speakers" review.
    func speakerSummaries() -> [CallSpeakerSummary]
    /// Manually name a speaker; returns their centroid embedding to enrol (nil if too little audio).
    @discardableResult func setSpeakerName(_ speakerId: String, as name: String) -> [Float]?
    /// Short representative clip of a speaker's longest turn (for voiceprint retention).
    func repAudioSample(for speakerId: String) async -> [Float]?
    func resolvedName(for id: String) -> String?
    func callSpeakerIds() -> [String]
    func gatedSeconds(for id: String) -> TimeInterval

    /// Embedding model id/dimension this engine's centroids belong to — used to tag
    /// enrolled voiceprints so they only match this engine's recordings.
    var embeddingModelId: String { get }
    var embeddingDim: Int { get }
}

/// FluidAudio already implements every member except the protocol's `runOfflinePass()`
/// name (it has `finalizeDiarization()`); adapt it here without editing FluidAudioEngine.
extension FluidAudioEngine: SpeakerCapableEngine {
    func runOfflinePass() async -> OfflinePassSummary {
        let s = await finalizeDiarization()
        return OfflinePassSummary(speakerCount: s.speakerCount, relabeled: s.relabeled, note: s.note)
    }
    var embeddingModelId: String { VoiceprintStore.embeddingModel }   // wespeaker_v2
    var embeddingDim: Int { VoiceprintStore.embeddingDim }            // 256
}
