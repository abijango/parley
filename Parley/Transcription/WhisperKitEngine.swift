import Foundation

/// The original WhisperKit transcription path, wrapped behind `TranscriptionEngine`
/// with NO behaviour change: two `TrackPipeline`s (mic = "Me", system = "Remote")
/// feed a single serialized `TranscriptionService`, merged into one timeline by
/// `TranscriptMerger`. Transcription only — no speaker identification.
///
/// This is a verbatim relocation of the wiring that previously lived inline in
/// `RecordingController.launchCapture`/`stop`; the shared `ModelManager` is injected
/// so a preloaded model is reused exactly as before.
@MainActor
final class WhisperKitEngine: TranscriptionEngine {
    private let models: ModelManager
    private let settings: AppSettings
    private let service = TranscriptionService()
    private let merger = TranscriptMerger()
    private var micPipeline: TrackPipeline?
    private var systemPipeline: TrackPipeline?
    private var pipelineTasks: [Task<Void, Never>] = []

    var onSegmentsChanged: (([Segment]) -> Void)?

    init(models: ModelManager, settings: AppSettings) {
        self.models = models
        self.settings = settings
        merger.onChange = { [weak self] merged in self?.onSegmentsChanged?(merged) }
    }

    func confirmedTimeline() -> [Segment] { merger.confirmedTimeline() }
    func finalTimeline() -> [Segment] { merger.finalTimeline() }
    func seed(_ segments: [Segment]) { merger.seed(segments) }

    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        // Anchor both pipelines to the shared timeline (0 for a fresh start, or
        // the prior duration when resuming).
        let micPipeline = TrackPipeline(track: .me, ring: micRing, service: service, merger: merger, startElapsed: startElapsed)
        let systemPipeline = TrackPipeline(track: .remote, ring: systemRing, service: service, merger: merger, startElapsed: startElapsed)
        self.micPipeline = micPipeline
        self.systemPipeline = systemPipeline
        pipelineTasks = [
            Task { await micPipeline.run() },
            Task { await systemPipeline.run() },
        ]

        // Load the model in the background; pipelines hold audio until it's set.
        Task {
            if let kit = await models.prepare(settings.model) {
                await service.setModel(kit)
                AppLog.log("Model ready — live transcription active", category: "record")
            } else {
                AppLog.log("Model failed to load; capturing audio only (archive preserved, re-processable)", category: "record")
            }
        }
    }

    func stop() async {
        await micPipeline?.stop()
        await systemPipeline?.stop()
        await service.clear()   // release the recording-time model ref (frees on model switch)
        pipelineTasks.forEach { $0.cancel() }
        pipelineTasks = []
        micPipeline = nil
        systemPipeline = nil
    }
}
