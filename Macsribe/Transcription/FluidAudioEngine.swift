import Foundation
import AVFoundation
import FluidAudio

/// Self-contained native transcription engine powered entirely by FluidAudio.
///
/// Mixes the mic + system capture rings into a single 16 kHz mono stream and runs
/// everything from that one buffer: Parakeet ASR via `SlidingWindowAsrManager`
/// (multilingual v3) plus pyannote/WeSpeaker diarization via `DiarizerManager`.
///
/// Phase 3: each transcript segment is attributed to a diarized speaker ("Speaker N")
/// by maximum timestamp overlap. Mapping a speaker to a known person (voiceprints)
/// is Phase 4–5; `track` stays `.remote` as a neutral placeholder for the source.
@MainActor
final class FluidAudioEngine: TranscriptionEngine {
    private let settings: AppSettings
    // `.streaming` (11s chunks, low latency) — `.default` uses 15s chunks and
    // won't emit anything until ~15s of audio, which reads as "no transcript".
    private let asr = SlidingWindowAsrManager(config: .streaming)

    /// The same mixed audio fed to ASR, buffered for the diarizer (drained in chunks).
    private let diarRing = AudioRingBuffer(capacity: 16_000 * 60)

    // Timeline state (main actor).
    private var seeded: [Segment] = []
    private var confirmed: [Segment] = []
    private var volatileTail: Segment?
    private var streamStart: Date?
    /// Diarized speaker turns on the session timeline (speakerId + start/end seconds).
    private var diarSegments: [(speakerId: String, start: TimeInterval, end: TimeInterval)] = []

    // Background work.
    private var loadTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var mixerTask: Task<Void, Never>?
    private var diarTask: Task<Void, Never>?

    /// 16 kHz mono — the format every FluidAudio model consumes.
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var onSegmentsChanged: (([Segment]) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func confirmedTimeline() -> [Segment] { (seeded + confirmed).sorted { $0.start < $1.start } }
    func finalTimeline() -> [Segment] {
        (seeded + confirmed + (volatileTail.map { [$0] } ?? [])).sorted { $0.start < $1.start }
    }
    func seed(_ segments: [Segment]) { seeded = segments; publish() }

    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        let version: AsrModelVersion = settings.parakeetVersion == .v2 ? .v2 : .v3
        loadTask = Task { [weak self] in
            do {
                let models = try await AsrModels.downloadAndLoad(version: version)
                try await self?.asr.loadModels(models)
                try await self?.asr.startStreaming()
                AppLog.log("FluidAudio engine ready — Parakeet \(version) sliding-window streaming", category: "record")
                self?.beginConsumingAndMixing(micRing: micRing, systemRing: systemRing, startElapsed: startElapsed)
            } catch {
                AppLog.log("FluidAudio engine failed to start: \(error.localizedDescription); capturing audio only (archive preserved)", category: "record")
            }
        }
    }

    func stop() async {
        loadTask?.cancel()
        mixerTask?.cancel()
        updatesTask?.cancel()
        diarTask?.cancel()
        loadTask = nil; mixerTask = nil; updatesTask = nil; diarTask = nil
        _ = try? await asr.finish()
        await asr.cleanup()
    }

    // MARK: - Consume updates + feed mixed audio

    private func beginConsumingAndMixing(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        streamStart = Date()

        // Map the sliding-window confirmed/volatile updates onto our Segment model.
        updatesTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.asr.transcriptionUpdates
            for await update in stream {
                if Task.isCancelled { break }
                self.apply(update, startElapsed: startElapsed)
            }
        }

        // Mix both capture rings into one mono stream; feed the recognizer AND
        // buffer the same samples for the diarizer. Anchored to whichever ring has
        // more pending data; the shorter ring is treated as silence for the gap.
        let asr = self.asr
        let diarRing = self.diarRing
        mixerTask = Task.detached {
            var fedSamples = 0
            var lastLogged = 0
            while !Task.isCancelled {
                if let mixed = Self.mix(mic: micRing, system: systemRing), !mixed.isEmpty,
                   let buffer = Self.makeBuffer(mixed) {
                    await asr.streamAudio(buffer)
                    mixed.withUnsafeBufferPointer { diarRing.write($0) }
                    fedSamples += mixed.count
                    if fedSamples - lastLogged >= 16_000 * 5 {   // ~every 5s of audio
                        lastLogged = fedSamples
                        AppLog.log("FluidAudio fed ~\(fedSamples / 16_000)s of audio to ASR", category: "record")
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        // Diarize in ~10s chunks on a long-lived DiarizerManager so in-session
        // speaker ids stay consistent; rebase each chunk's times by its start offset.
        diarTask = Task.detached { [weak self] in
            guard let diar = try? await Self.makeDiarizer() else {
                AppLog.log("FluidAudio diarizer failed to initialize — transcript will have no speaker labels", category: "record")
                return
            }
            let chunkSamples = 16_000 * 10
            var processed = 0
            var scratch = [Float]()
            while !Task.isCancelled {
                guard diarRing.availableToRead >= chunkSamples else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let n = diarRing.read(maxCount: chunkSamples, into: &scratch)
                guard n > 0 else { continue }
                let offset = startElapsed + TimeInterval(processed) / 16_000
                processed += n
                guard let result = try? diar.performCompleteDiarization(Array(scratch.prefix(n)), sampleRate: 16_000)
                else { continue }
                let segs = result.segments.map {
                    (speakerId: $0.speakerId,
                     start: offset + TimeInterval($0.startTimeSeconds),
                     end: offset + TimeInterval($0.endTimeSeconds))
                }
                guard !segs.isEmpty else { continue }
                await self?.ingestDiarization(segs)
            }
        }
    }

    /// Load diarization models and build a session-long manager (owned by the diarTask).
    nonisolated private static func makeDiarizer() async throws -> DiarizerManager {
        let models = try await DiarizerModels.downloadIfNeeded()
        let diar = DiarizerManager(config: DiarizerConfig())   // clusteringThreshold 0.7 default; tunable
        diar.initialize(models: models)
        return diar
    }

    /// Merge newly-diarized turns and re-attribute known transcript segments.
    private func ingestDiarization(_ segs: [(speakerId: String, start: TimeInterval, end: TimeInterval)]) {
        diarSegments.append(contentsOf: segs)
        confirmed = confirmed.map(assigningSpeaker)
        if let v = volatileTail { volatileTail = assigningSpeaker(v) }
        publish()
    }

    /// Return a copy of `seg` with its `speakerId` set to the diarized speaker whose
    /// turn overlaps it most (unchanged if no diarized turn overlaps yet).
    private func assigningSpeaker(_ seg: Segment) -> Segment {
        guard let id = bestSpeaker(start: seg.start, end: seg.end) else { return seg }
        var s = seg; s.speakerId = id; return s
    }

    private func bestSpeaker(start: TimeInterval, end: TimeInterval) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        for d in diarSegments {
            let overlap = min(end, d.end) - max(start, d.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (d.speakerId, overlap) }
        }
        return best?.id
    }

    /// Drain both rings and sum sample-wise into one mono buffer.
    nonisolated private static func mix(mic: AudioRingBuffer, system: AudioRingBuffer) -> [Float]? {
        let n = max(mic.availableToRead, system.availableToRead)
        guard n > 0 else { return nil }
        var micBuf = [Float](), sysBuf = [Float]()
        let rm = mic.read(maxCount: n, into: &micBuf)
        let rs = system.read(maxCount: n, into: &sysBuf)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<rm { out[i] += micBuf[i] }
        for i in 0..<rs { out[i] += sysBuf[i] }
        for i in 0..<n { out[i] = max(-1, min(1, out[i])) }   // soft clip the summed signal
        return out
    }

    nonisolated private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { pcm.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return pcm
    }

    private func apply(_ update: SlidingWindowTranscriptionUpdate, startElapsed: TimeInterval) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let start = update.tokenTimings.first.map { startElapsed + $0.startTime } ?? elapsedNow(startElapsed)
        let end = update.tokenTimings.last.map { startElapsed + $0.endTime } ?? start
        // Attribute to a diarized speaker now if one already overlaps; otherwise it
        // stays unlabeled until diarization catches up (ingestDiarization re-attributes).
        let seg = Segment(track: .remote, start: start, end: end, text: text,
                          confirmed: update.isConfirmed, speakerId: bestSpeaker(start: start, end: end))
        // Log metadata only — never transcript content (it lands in a persistent
        // log file; meeting speech is sensitive).
        AppLog.log("FluidAudio update (\(update.isConfirmed ? "confirmed" : "volatile")): \(text.count) chars", category: "record")
        if update.isConfirmed {
            confirmed.append(seg)
            volatileTail = nil
        } else {
            volatileTail = seg
        }
        publish()
    }

    private func elapsedNow(_ startElapsed: TimeInterval) -> TimeInterval {
        startElapsed + Date().timeIntervalSince(streamStart ?? Date())
    }

    private func publish() {
        onSegmentsChanged?(finalTimeline())
    }
}
