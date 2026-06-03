import Foundation
import AVFoundation
import WhisperKit

/// Second speaker-ID engine: WhisperKit for fast LIVE transcript text (track-labelled
/// "Me"/"Remote", same as `WhisperKitEngine`), then at stop an OFFLINE pass —
/// re-transcribe the clean mix with word timings, diarize it with SpeakerKit, and
/// attribute words to speakers (diarization-first). Cross-session voiceprints reuse
/// `VoiceprintStore`, tagged with SpeakerKit's `pyannote_v3` model so they don't
/// cross-match FluidAudio's `wespeaker_v2` prints. FluidAudio is left untouched.
@MainActor
final class WhisperKitSpeakerKitEngine: SpeakerCapableEngine {
    private let models: ModelManager
    private let settings: AppSettings
    private let voiceprints: VoiceprintStore?
    private let identificationThreshold: Double

    // Live WhisperKit wiring (mirrors WhisperKitEngine).
    private let service = TranscriptionService()
    private let merger = TranscriptMerger()
    private var micPipeline: TrackPipeline?
    private var systemPipeline: TrackPipeline?
    private var pipelineTasks: [Task<Void, Never>] = []

    private let diarizer = SpeakerKitDiarizer()

    // Offline-pass state (the attributed transcript supersedes the live one once set).
    private var offlineSegments: [Segment]?
    private var offlineWords: [DiarizationAttribution.Token] = []
    private var turns: [DiarizationAttribution.Turn] = []
    private var speakerCentroids: [String: [Float]] = [:]
    private var gated: [String: TimeInterval] = [:]
    private var resolvedNames: [String: String] = [:]
    private var runIds: [String: UUID] = [:]
    private let minSecondsToEnroll: TimeInterval = 3

    // MARK: SpeakerCapableEngine surface
    var onSegmentsChanged: (([Segment]) -> Void)?
    var onSpeakerIdentified: ((String) -> Void)?
    var mixedAudioURL: URL?
    var micArchiveURL: URL?
    var systemArchiveURL: URL?
    var forceOfflineAsr = false   // this engine always offline-transcribes; kept for protocol parity
    var embeddingModelId: String { VoiceprintStore.speakerKitEmbeddingModel }
    var embeddingDim: Int { 256 }

    init(models: ModelManager, settings: AppSettings,
         voiceprints: VoiceprintStore? = nil, identificationThreshold: Double = 0.6) {
        self.models = models
        self.settings = settings
        self.voiceprints = voiceprints
        self.identificationThreshold = identificationThreshold
        merger.onChange = { [weak self] merged in
            guard let self, self.offlineSegments == nil else { return }   // live until the offline pass relabels
            self.onSegmentsChanged?(merged)
        }
    }

    // MARK: TranscriptionEngine (live)
    func confirmedTimeline() -> [Segment] { offlineSegments ?? merger.confirmedTimeline() }
    func finalTimeline() -> [Segment] { offlineSegments ?? merger.finalTimeline() }
    func seed(_ segments: [Segment]) { merger.seed(segments) }

    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        let mic = TrackPipeline(track: .me, ring: micRing, service: service, merger: merger, startElapsed: startElapsed)
        let sys = TrackPipeline(track: .remote, ring: systemRing, service: service, merger: merger, startElapsed: startElapsed)
        micPipeline = mic
        systemPipeline = sys
        pipelineTasks = [Task { await mic.run() }, Task { await sys.run() }]
        Task {
            if let kit = await models.prepare(settings.model) {
                await service.setModel(kit)
                AppLog.log("Model ready — live transcription active (WhisperKit + SpeakerKit)", category: "record")
            } else {
                AppLog.log("Model failed to load; capturing audio only (archive preserved, re-processable)", category: "record")
            }
        }
    }

    func stop() async {
        await micPipeline?.stop()
        await systemPipeline?.stop()
        await service.clear()
        pipelineTasks.forEach { $0.cancel() }
        pipelineTasks = []
        micPipeline = nil
        systemPipeline = nil
        await diarizer.unload()
    }

    // MARK: Offline pass
    func runOfflinePass() async -> OfflinePassSummary {
        let started = Date()
        AppLog.log("SpeakerKit offline pass started…", category: "record")
        guard let url = mixedAudioURL else {
            return OfflinePassSummary(speakerCount: callSpeakerIds().count, relabeled: false,
                                      note: "Offline pass skipped — no audio")
        }
        let mic = micArchiveURL, sys = systemArchiveURL
        let built = await Task.detached { AudioMix.buildCleanMix(mic: mic, system: sys, output: url) }.value
        guard let samples = AudioMix.loadMono16k(url), !samples.isEmpty else {
            AppLog.log("SpeakerKit offline pass: couldn't read clean mix (built=\(built))", category: "record")
            return OfflinePassSummary(speakerCount: 0, relabeled: false, note: "Offline pass: no audio")
        }

        offlineWords = await transcribeWords(samples)
        if offlineWords.isEmpty {
            AppLog.log("SpeakerKit offline pass: WhisperKit produced no word timings — keeping live transcript", category: "record")
        }

        if let out = try? await diarizer.diarize(samples) {
            turns = out.turns
            speakerCentroids = out.centroids
            var g: [String: TimeInterval] = [:]
            for t in turns { g[t.speakerId, default: 0] += max(0, t.end - t.start) }
            gated = g
            AppLog.log("SpeakerKit diar: \(out.speakerCount) speaker(s), \(turns.count) turns", category: "record")
        } else {
            AppLog.log("SpeakerKit diarization failed — keeping unattributed transcript", category: "record")
        }

        autoIdentify()
        rederive()
        publish()

        let elapsed = Date().timeIntervalSince(started)
        let n = callSpeakerIds().count
        let suffix = offlineWords.isEmpty ? " · transcript unchanged (ASR pass empty)" : ""
        return OfflinePassSummary(speakerCount: n, relabeled: !turns.isEmpty && !offlineWords.isEmpty,
                                  note: "Speaker detection complete · \(n) speaker\(n == 1 ? "" : "s") · \(String(format: "%.1fs", elapsed))\(suffix)")
    }

    /// Re-transcribe the clean mix with WhisperKit word timestamps → attribution tokens.
    private func transcribeWords(_ samples: [Float]) async -> [DiarizationAttribution.Token] {
        guard let kit = await models.prepare(settings.model) else { return [] }
        var opts = DecodingOptions()
        opts.wordTimestamps = true
        opts.withoutTimestamps = false
        opts.skipSpecialTokens = true
        guard let results = try? await kit.transcribe(audioArray: samples, decodeOptions: opts) else { return [] }
        var toks: [DiarizationAttribution.Token] = []
        for r in results {
            for seg in r.segments {
                for w in (seg.words ?? []) where !w.word.isEmpty {
                    toks.append(.init(text: w.word, start: TimeInterval(w.start), end: TimeInterval(w.end)))
                }
            }
        }
        return toks
    }

    private func rederive() {
        guard !offlineWords.isEmpty else { offlineSegments = nil; return }
        offlineSegments = DiarizationAttribution.segments(
            tokens: offlineWords, turns: turns, resolvedNames: resolvedNames, runIds: &runIds)
    }

    private func publish() { onSegmentsChanged?(finalTimeline()) }

    /// Match each unnamed speaker (with enough speech) against saved voiceprints.
    private func autoIdentify() {
        guard let store = voiceprints else { return }
        for (id, centroid) in speakerCentroids where resolvedNames[id] == nil && !centroid.isEmpty {
            guard (gated[id] ?? 0) >= settings.minSpeechToIdentify else { continue }
            if let m = store.match(centroid, threshold: identificationThreshold, model: embeddingModelId) {
                resolvedNames[id] = m.voiceprint.name
                AppLog.log("SpeakerKit auto-identified a speaker as \(m.voiceprint.name) (score \(String(format: "%.2f", m.score)))", category: "record")
                onSpeakerIdentified?(m.voiceprint.name)
            }
        }
    }

    // MARK: Review surface
    // Derive the speaker set from the ATTRIBUTED segments (same source as
    // speakerSummaries) so the review count never lists a turn that won no words.
    func callSpeakerIds() -> [String] { Array(Set((offlineSegments ?? []).compactMap { $0.speakerId })).sorted() }
    func resolvedName(for id: String) -> String? { resolvedNames[id] }
    func gatedSeconds(for id: String) -> TimeInterval { gated[id] ?? 0 }

    @discardableResult
    func setSpeakerName(_ speakerId: String, as name: String) -> [Float]? {
        resolvedNames[speakerId] = name
        rederive()
        publish()
        // Only enrol from a non-empty centroid with enough gated speech (mirrors FluidAudio).
        guard let c = speakerCentroids[speakerId], !c.isEmpty,
              (gated[speakerId] ?? 0) >= minSecondsToEnroll else { return nil }
        return c
    }

    func repAudioSample(for speakerId: String) async -> [Float]? {
        guard let url = mixedAudioURL else {
            AppLog.log("repAudioSample: no mixed.caf", category: "record"); return nil
        }
        let segs = (offlineSegments ?? []).filter { $0.speakerId == speakerId }
        guard let rep = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else {
            AppLog.log("repAudioSample: no segments for speaker \(speakerId)", category: "record"); return nil
        }
        let start = max(0, rep.start), end = min(rep.end, start + 4)
        return await Task.detached {
            guard let all = AudioMix.loadMono16k(url) else { return nil }
            let s = Int(start * 16_000), e = min(all.count, Int(end * 16_000))
            guard s >= 0, s < e else { return nil }
            return Array(all[s..<e])
        }.value
    }

    func speakerSummaries() -> [CallSpeakerSummary] {
        var byId: [String: [Segment]] = [:]
        for s in (offlineSegments ?? []) where s.speakerId != nil {
            byId[s.speakerId!, default: []].append(s)
        }
        return byId.keys.sorted().map { id in
            let segs = byId[id] ?? []
            let talk = segs.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            let rep = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
            return CallSpeakerSummary(
                id: id, resolvedName: resolvedNames[id], talkSeconds: talk,
                sampleStart: rep?.start ?? 0,
                sampleEnd: rep.map { min($0.end, $0.start + 8) } ?? 0,
                firstLine: String((rep?.text ?? "").prefix(100)))
        }
    }
}
