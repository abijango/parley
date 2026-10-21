import Foundation

/// Result of the at-stop offline diarization pass, surfaced to the UI.
struct OfflinePassSummary: Sendable {
    let speakerCount: Int
    let relabeled: Bool
    let note: String
}

/// Fine-grained progress signals emitted during the offline pass. Callbacks may fire
/// from arbitrary threads at high rate; receivers throttle them and hop to MainActor.
enum EngineProgressEvent: Sendable, Equatable {
    case mixStarted, mixDone
    /// ASR fraction in 0…1; may fire many times per second.
    case asr(Double)
    /// Diarization fraction in 0…1.
    case diarization(Double)
    case asrDone, diarizationDone
    case attributeStarted, attributeDone
}
