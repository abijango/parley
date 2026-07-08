import Foundation

/// The original WhisperKit transcription path, wrapped behind `TranscriptionEngine`
/// with NO behaviour change at the transcript level: mic + system are mixed into
/// one stream and decoded by a single `TrackPipeline` (halving live ASR load versus
/// two serialized pipelines on one `TranscriptionService`). Segments are labelled
/// "Remote" (mixed audio); there is no per-track Me/Remote split in this engine.
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
    private let mixedRing = AudioRingBuffer(capacity: 16_000 * 60)
    private var mixerTask: Task<Void, Never>?
    private var livePipeline: TrackPipeline?
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
        let mixedRing = self.mixedRing
        mixerTask = Task.detached {
            while !Task.isCancelled {
                if let mixed = Self.mixLive(mic: micRing, system: systemRing), !mixed.isEmpty {
                    mixed.withUnsafeBufferPointer { mixedRing.write($0) }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let pipe = TrackPipeline(track: .remote, ring: mixedRing, service: service, merger: merger, startElapsed: startElapsed)
        livePipeline = pipe
        pipelineTasks = [Task { await pipe.run() }]

        Task {
            if let kit = await models.prepare(settings.model) {
                await service.setModel(kit)
                AppLog.log("Model ready — live transcription active (mixed mic+system)", category: "record")
            } else {
                AppLog.log("Model failed to load; capturing audio only (archive preserved, re-processable)", category: "record")
            }
        }
    }

    func stop() async {
        mixerTask?.cancel()
        mixerTask = nil
        await livePipeline?.stop()
        await service.clear()
        pipelineTasks.forEach { $0.cancel() }
        pipelineTasks = []
        livePipeline = nil
    }

    /// Sum mic + system rings into one mono buffer (mic-anchored clock), capped to ~1s
    /// per tick so a backlog drains gradually instead of stalling the mixer loop.
    nonisolated private static let maxMixSamplesPerTick = 16_000

    nonisolated private static func mixLive(mic: AudioRingBuffer, system: AudioRingBuffer) -> [Float]? {
        let n = min(mic.availableToRead, maxMixSamplesPerTick)
        guard n > 0 else { return nil }
        var micBuf = [Float](), sysBuf = [Float]()
        let rm = mic.read(maxCount: n, into: &micBuf)
        guard rm > 0 else { return nil }
        let rs = system.read(maxCount: rm, into: &sysBuf)
        var out = [Float](repeating: 0, count: rm)
        for i in 0..<rm { out[i] += micBuf[i] }
        for i in 0..<min(rs, rm) { out[i] += sysBuf[i] }
        for i in 0..<rm { out[i] = max(-1, min(1, out[i])) }
        return out
    }
}