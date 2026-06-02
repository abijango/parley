import Foundation
import AVFoundation
import FluidAudio

/// Self-contained native transcription engine powered entirely by FluidAudio.
///
/// Phase 2: live transcription only (no speaker labels yet). It mixes the mic and
/// system capture rings into a single 16 kHz mono stream and drives Parakeet via
/// `SlidingWindowAsrManager` (which keeps the multilingual v3 model — the EoU
/// streaming manager would use different, non-v3 models). Confirmed/volatile
/// updates map onto the existing `Segment` confirmed/tentative model.
///
/// Diarization + speaker identification are layered on in Phases 3–5; until then
/// every segment is tagged `.remote` as a neutral placeholder.
@MainActor
final class FluidAudioEngine: TranscriptionEngine {
    private let settings: AppSettings
    private let asr = SlidingWindowAsrManager()

    // Timeline state (main actor).
    private var seeded: [Segment] = []
    private var confirmed: [Segment] = []
    private var volatileTail: Segment?
    private var streamStart: Date?

    // Background work.
    private var loadTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var mixerTask: Task<Void, Never>?

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
        loadTask = nil; mixerTask = nil; updatesTask = nil
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

        // Mix both capture rings into one mono stream and feed the recognizer.
        // Anchored to whichever ring has more pending data; the shorter ring is
        // treated as silence for the gap (e.g. muted mic, or no system audio).
        let asr = self.asr
        mixerTask = Task.detached {
            while !Task.isCancelled {
                if let mixed = Self.mix(mic: micRing, system: systemRing), !mixed.isEmpty,
                   let buffer = Self.makeBuffer(mixed) {
                    await asr.streamAudio(buffer)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
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
        let seg = Segment(track: .remote, start: start, end: end, text: text, confirmed: update.isConfirmed)
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
