import Foundation

/// Result of the at-stop offline diarization pass, surfaced to the UI.
struct OfflinePassSummary: Sendable {
    let speakerCount: Int
    let relabeled: Bool
    let note: String
}

/// Fine-grained progress signals emitted during the offline pass. Callbacks may fire
/// from arbitrary threads at high rate; receivers throttle them and hop to MainActor.
/// Engines that cannot report a signal simply leave `onOfflineProgress` unset — the UI
/// degrades to an indeterminate shimmer for those stages.
enum EngineProgressEvent: Sendable, Equatable {
    case mixStarted, mixDone
    /// ASR fraction in 0…1; may fire many times per second.
    case asr(Double)
    /// Diarization fraction in 0…1; true `Progress.fractionCompleted` from SpeakerKit.
    case diarization(Double)
    case asrDone, diarizationDone
    case attributeStarted, attributeDone
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

    /// Optional progress callback for the UI's per-stage bar. Set by the service before
    /// `runOfflinePass()`; cleared by the service after. The callback fires at high rate
    /// from arbitrary threads — receivers (JobProgressRelay) do their own throttling.
    var onOfflineProgress: (@Sendable (EngineProgressEvent) -> Void)? { get set }

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
    /// Per-speaker centroid embeddings (for persisting a review cache + later voiceprint
    /// enrolment without re-running the pass). Empty for speakers with too little speech.
    func centroidsByID() -> [String: [Float]]
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

    /// Expected number of speakers (e.g. accepted attendee count) — an optional
    /// clustering hint for the offline pass. nil = let the diarizer decide.
    var speakerCountHint: Int? { get set }
    /// Raw diarized turns from the last offline pass (empty if diarization didn't run).
    func diarizedTurns() -> [DiarizationAttribution.Turn]
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

    // FluidAudio keeps its turn model in an internal struct type rather than
    // DiarizationAttribution.Turn, so it exposes no turns for fallback attribution.
    func diarizedTurns() -> [DiarizationAttribution.Turn] { [] }

    // FluidAudio does not emit fine-grained stage events; the UI shows an indeterminate
    // shimmer for its stages. A no-op computed var satisfies the protocol requirement
    // without any internal state or behaviour change.
    var onOfflineProgress: (@Sendable (EngineProgressEvent) -> Void)? {
        get { nil }
        set { }
    }
}
