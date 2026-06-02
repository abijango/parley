import Foundation
import AVFoundation
import FluidAudio

/// Per-speaker summary for the at-stop "Assign speakers" review panel.
struct CallSpeakerSummary: Identifiable, Equatable {
    let id: String                 // diarization speakerId
    var resolvedName: String?      // mapped person, if named/identified
    let talkSeconds: TimeInterval
    let sampleStart: TimeInterval  // best (longest) segment, for play-sample
    let sampleEnd: TimeInterval
    let firstLine: String          // a snippet for context
}

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
    /// Saved voiceprints for cross-session auto-identification (nil = no matching).
    private let voiceprints: VoiceprintStore?
    private let identificationThreshold: Double
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
    /// Quality-gated per-speaker embeddings + speech duration, for identification + enrollment.
    private var speakerEmbeddings: [String: [[Float]]] = [:]
    private var speakerGatedSeconds: [String: TimeInterval] = [:]
    /// speakerId → resolved person name (auto-identified or manually assigned).
    private var resolvedNames: [String: String] = [:]
    private let minSegmentQuality: Float = 0.4
    private let minSecondsToAutoIdentify: TimeInterval = 8

    // Background work.
    private var loadTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var mixerTask: Task<Void, Never>?
    private var diarTask: Task<Void, Never>?

    /// 16 kHz mono — the format every FluidAudio model consumes.
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var onSegmentsChanged: (([Segment]) -> Void)?
    /// Fired when a speaker is auto-identified to a saved voiceprint (the person's name).
    var onSpeakerIdentified: ((String) -> Void)?

    init(settings: AppSettings, voiceprints: VoiceprintStore? = nil, identificationThreshold: Double = 0.6) {
        self.settings = settings
        self.voiceprints = voiceprints
        self.identificationThreshold = identificationThreshold
    }

    func confirmedTimeline() -> [Segment] { (seeded + confirmed).sorted { $0.start < $1.start } }
    func finalTimeline() -> [Segment] {
        (seeded + confirmed + (volatileTail.map { [$0] } ?? [])).sorted { $0.start < $1.start }
    }
    func seed(_ segments: [Segment]) { seeded = segments; publish() }

    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        let version: AsrModelVersion = settings.parakeetVersion == .v2 ? .v2 : .v3
        let clusterThreshold = Float(settings.diarizationThreshold)
        loadTask = Task { [weak self] in
            do {
                let models = try await AsrModels.downloadAndLoad(version: version)
                try await self?.asr.loadModels(models)
                try await self?.asr.startStreaming()
                AppLog.log("FluidAudio engine ready — Parakeet \(version) sliding-window streaming", category: "record")
                self?.beginConsumingAndMixing(micRing: micRing, systemRing: systemRing,
                                              startElapsed: startElapsed, clusterThreshold: clusterThreshold)
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

    private func beginConsumingAndMixing(micRing: AudioRingBuffer, systemRing: AudioRingBuffer,
                                         startElapsed: TimeInterval, clusterThreshold: Float) {
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
            guard let diar = try? await Self.makeDiarizer(clusterThreshold: clusterThreshold) else {
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
                     end: offset + TimeInterval($0.endTimeSeconds),
                     embedding: $0.embedding,
                     quality: $0.qualityScore)
                }
                guard !segs.isEmpty else { continue }
                await self?.ingestDiarization(segs)
            }
        }
    }

    /// Load diarization models and build a session-long manager (owned by the diarTask).
    nonisolated private static func makeDiarizer(clusterThreshold: Float) async throws -> DiarizerManager {
        let models = try await DiarizerModels.downloadIfNeeded()
        var config = DiarizerConfig()
        config.clusteringThreshold = clusterThreshold   // library default 0.7 over-merges; we default 0.6
        let diar = DiarizerManager(config: config)
        diar.initialize(models: models)
        return diar
    }

    /// Merge newly-diarized turns, accumulate quality-gated per-speaker embeddings,
    /// auto-identify against saved voiceprints, and re-attribute known segments.
    private func ingestDiarization(_ segs: [(speakerId: String, start: TimeInterval, end: TimeInterval, embedding: [Float], quality: Float)]) {
        for s in segs {
            diarSegments.append((s.speakerId, s.start, s.end))
            if s.quality >= minSegmentQuality, !s.embedding.isEmpty {
                speakerEmbeddings[s.speakerId, default: []].append(s.embedding)
                speakerGatedSeconds[s.speakerId, default: 0] += max(0, s.end - s.start)
            }
        }
        autoIdentify()
        confirmed = confirmed.map(assigningSpeaker)
        if let v = volatileTail { volatileTail = assigningSpeaker(v) }
        publish()
    }

    /// Match each not-yet-named speaker (with enough clean speech) against saved
    /// voiceprints; on a confident match, set the name and notify (for auto-add).
    private func autoIdentify() {
        guard let store = voiceprints else { return }
        for (id, embs) in speakerEmbeddings where resolvedNames[id] == nil {
            guard (speakerGatedSeconds[id] ?? 0) >= minSecondsToAutoIdentify, embs.count >= 2 else { continue }
            let centroid = VoiceprintStore.normalized(VoiceprintStore.mean(embs))
            if let m = store.match(centroid, threshold: identificationThreshold) {
                resolvedNames[id] = m.voiceprint.name
                AppLog.log("FluidAudio auto-identified a speaker as \(m.voiceprint.name) (score \(String(format: "%.2f", m.score)))", category: "record")
                onSpeakerIdentified?(m.voiceprint.name)
            }
        }
    }

    /// Return a copy of `seg` with its diarized `speakerId` (max-overlap turn) and the
    /// resolved `speakerName` if that speaker has been identified/named.
    private func assigningSpeaker(_ seg: Segment) -> Segment {
        guard let id = bestSpeaker(start: seg.start, end: seg.end) else { return seg }
        var s = seg; s.speakerId = id; s.speakerName = resolvedNames[id]; return s
    }

    private func bestSpeaker(start: TimeInterval, end: TimeInterval) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        for d in diarSegments {
            let overlap = min(end, d.end) - max(start, d.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (d.speakerId, overlap) }
        }
        return best?.id
    }

    // MARK: - Speaker naming (Phase 5)

    /// Distinct diarized speaker ids seen so far (stable, sorted) — for the review panel.
    func callSpeakerIds() -> [String] {
        var seen = Set<String>()
        for d in diarSegments { seen.insert(d.speakerId) }
        return seen.sorted()
    }

    func resolvedName(for id: String) -> String? { resolvedNames[id] }
    func gatedSeconds(for id: String) -> TimeInterval { speakerGatedSeconds[id] ?? 0 }

    /// Manually assign a name to a speaker: relabel their lines and return the
    /// speaker's centroid embedding for the caller to enroll (nil if no quality-gated
    /// audio was captured for them yet).
    @discardableResult
    func setSpeakerName(_ speakerId: String, as name: String) -> [Float]? {
        resolvedNames[speakerId] = name
        confirmed = confirmed.map(assigningSpeaker)
        if let v = volatileTail { volatileTail = assigningSpeaker(v) }
        publish()
        let embs = speakerEmbeddings[speakerId] ?? []
        guard !embs.isEmpty else { return nil }
        return VoiceprintStore.normalized(VoiceprintStore.mean(embs))
    }

    /// Per-speaker summaries for the at-stop review panel: total talk time, the
    /// longest segment (capped) for play-sample, and a first-line snippet.
    func speakerSummaries() -> [CallSpeakerSummary] {
        var talk: [String: TimeInterval] = [:]
        var longest: [String: (start: TimeInterval, end: TimeInterval)] = [:]
        for d in diarSegments {
            let dur = max(0, d.end - d.start)
            talk[d.speakerId, default: 0] += dur
            let cur = longest[d.speakerId]
            if cur == nil || dur > (cur!.end - cur!.start) { longest[d.speakerId] = (d.start, d.end) }
        }
        let all = finalTimeline()
        return talk.keys.sorted().map { id in
            let seg = longest[id] ?? (0, 0)
            let first = all.first(where: { $0.speakerId == id })?.text ?? ""
            return CallSpeakerSummary(
                id: id, resolvedName: resolvedNames[id], talkSeconds: talk[id] ?? 0,
                sampleStart: seg.start, sampleEnd: min(seg.end, seg.start + 6),
                firstLine: String(first.prefix(80)))
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
