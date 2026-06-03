import Foundation

/// Abstraction over a live transcription backend.
///
/// `RecordingController` owns capture, persistence, crash recovery, and finalize;
/// an engine consumes the two capture rings and produces the merged transcript
/// timeline. Two implementations exist:
///   • `WhisperKitEngine` — the original path (transcription only, no speaker ID).
///   • `FluidAudioEngine`  — native Parakeet ASR + on-device speaker identification.
///
/// The engine is chosen per recording session from `AppSettings.transcriptionEngine`;
/// there is no mid-session switching.
@MainActor
protocol TranscriptionEngine: AnyObject {
    /// Called on the main actor whenever the merged timeline changes.
    var onSegmentsChanged: (([Segment]) -> Void)? { get set }

    /// Confirmed (stable) segments — journaled live for near-zero-loss crash recovery.
    func confirmedTimeline() -> [Segment]
    /// Confirmed PLUS the trailing tentative tail — used when finalizing on stop.
    func finalTimeline() -> [Segment]

    /// Seed prior segments (resume): shown immediately and included on finalize.
    func seed(_ segments: [Segment])

    /// Begin transcribing from the capture rings, anchored at `startElapsed`
    /// (shared-clock seconds: 0 for a fresh start, prior duration on resume).
    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval)

    /// Stop transcription and release the recording-time model reference.
    func stop() async
}
