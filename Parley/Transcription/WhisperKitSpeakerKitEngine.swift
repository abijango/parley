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

    // Live WhisperKit wiring. SINGLE mixed stream (not two tracks): mic + system are
    // summed into one ring and decoded by ONE pipeline, halving the live ASR load —
    // the live "Me/Remote" split is discarded at stop anyway, where SpeakerKit
    // relabels by speaker. Live uses the fast `liveModel`; offline uses `model`.
    private let service = TranscriptionService()
    private let merger = TranscriptMerger()
    private let mixedRing = AudioRingBuffer(capacity: 16_000 * 60)
    private var mixerTask: Task<Void, Never>?
    private var livePipeline: TrackPipeline?
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
    /// Optional per-stage progress sink. Set by `OfflineProcessingService` before
    /// `runOfflinePass()`; cleared after. The relay handles its own throttling.
    var onOfflineProgress: (@Sendable (EngineProgressEvent) -> Void)?
    var mixedAudioURL: URL?
    var micArchiveURL: URL?
    var systemArchiveURL: URL?
    var forceOfflineAsr = false   // this engine always offline-transcribes; kept for protocol parity
    var embeddingModelId: String { VoiceprintStore.speakerKitEmbeddingModel }
    var embeddingDim: Int { 256 }

    /// Clustering hint forwarded to diarize() in runOfflinePass().
    var speakerCountHint: Int? = nil

    /// Raw turns from the last offline pass (empty if diarization didn't run).
    func diarizedTurns() -> [DiarizationAttribution.Turn] { turns }

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
        // Offline-only mode: skip ALL live wiring (no mixer, no pipeline, no live-model
        // warm-up). The capture layer still archives mic/system to disk, so the offline
        // pass at stop has its audio and produces the full attributed transcript.
        guard settings.liveTranscriptEnabled else {
            AppLog.log("Offline-only mode — capturing audio; transcript generated at stop (WhisperKit \(settings.model.rawValue) + SpeakerKit)", category: "record")
            return
        }
        // Mix mic + system into one ring (mic-anchored real-time clock), feed ONE pipeline.
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
            if let kit = await models.prepare(settings.liveModel) {
                await service.setModel(kit)
                AppLog.log("Model ready — live transcription active (WhisperKit \(settings.liveModel.rawValue) + SpeakerKit)", category: "record")
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
        await diarizer.unload()
    }

    /// Sum the mic + system rings into one mono buffer, anchored to the mic ring as the
    /// real-time clock (the mic tap runs continuously at 16 kHz even during silence).
    nonisolated private static func mixLive(mic: AudioRingBuffer, system: AudioRingBuffer) -> [Float]? {
        let n = mic.availableToRead
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

    // MARK: Offline pass
    func runOfflinePass() async -> OfflinePassSummary {
        let started = Date()
        AppLog.log("SpeakerKit offline pass started…", category: "record")

        // Capture the callback once so the rest of the method uses a consistent ref,
        // and closures below capture only this Sendable value, not engine state.
        let progressCB = onOfflineProgress
        progressCB?(.mixStarted)

        guard let url = mixedAudioURL else {
            return OfflinePassSummary(speakerCount: callSpeakerIds().count, relabeled: false,
                                      note: "Offline pass skipped — no audio")
        }

        // Reuse an already-valid mix rather than rebuilding it every pass. A truncated
        // mix from a crashed earlier run fails the duration check and gets rebuilt.
        let mic = micArchiveURL, sys = systemArchiveURL
        let shouldRebuild: Bool = {
            guard FileManager.default.fileExists(atPath: url.path),
                  let mixFile = try? AVAudioFile(forReading: url),
                  let micFile = mic.flatMap({ try? AVAudioFile(forReading: $0) }) else { return true }
            let mixDur = Double(mixFile.length) / mixFile.fileFormat.sampleRate
            let micDur = Double(micFile.length) / micFile.fileFormat.sampleRate
            return abs(mixDur - micDur) > 1.0
        }()
        if shouldRebuild {
            let built = await Task.detached { AudioMix.buildCleanMix(mic: mic, system: sys, output: url) }.value
            AppLog.log("SpeakerKit offline pass: rebuilt clean mix (built=\(built))", category: "record")
        } else {
            AppLog.log("SpeakerKit offline pass: reusing existing clean mix (duration matched)", category: "record")
        }

        guard let samples = AudioMix.loadMono16k(url), !samples.isEmpty else {
            AppLog.log("SpeakerKit offline pass: couldn't read clean mix", category: "record")
            return OfflinePassSummary(speakerCount: 0, relabeled: false, note: "Offline pass: no audio")
        }
        progressCB?(.mixDone)

        // ASR and diarization both only READ samples — run them concurrently to cut the
        // ~3-4 min sequential wall time for a 1h call roughly in half.
        let concurrentStart = Date()
        let hint = speakerCountHint
        let threshold = settings.diarizationThreshold

        async let asrTask = transcribeWords(samples, progressCB: progressCB)
        async let diarTask = diarizeLogged(samples, clusterThreshold: threshold,
                                           expectedSpeakers: hint, progressCB: progressCB)

        let (words, diarResult) = await (asrTask, diarTask)

        let bothElapsed = Date().timeIntervalSince(concurrentStart)
        AppLog.log("SpeakerKit offline pass: concurrent ASR+diar finished in \(String(format: "%.1fs", bothElapsed))", category: "record")

        offlineWords = words
        if offlineWords.isEmpty {
            AppLog.log("SpeakerKit offline pass: WhisperKit produced no word timings — keeping live transcript", category: "record")
        }

        if let out = diarResult {
            turns = out.turns
            speakerCentroids = out.centroids
            var g: [String: TimeInterval] = [:]
            for t in turns { g[t.speakerId, default: 0] += max(0, t.end - t.start) }
            gated = g
            AppLog.log("SpeakerKit diar: \(out.speakerCount) speaker(s), \(turns.count) turns", category: "record")
        } else {
            AppLog.log("SpeakerKit diarization failed — keeping unattributed transcript", category: "record")
        }

        progressCB?(.attributeStarted)
        autoIdentify()
        rederive()
        publish()
        progressCB?(.attributeDone)

        // The offline transcribe loaded the heavier `model`; if live transcription is on,
        // swap the fast live model back in (background, non-blocking) so the NEXT recording
        // starts instantly. In offline-only mode there's no live model to warm — leave the
        // heavy model loaded so the next offline pass reuses it.
        if settings.liveTranscriptEnabled, settings.liveModel != settings.model {
            Task { [models, settings] in _ = await models.prepare(settings.liveModel) }
        }

        let elapsed = Date().timeIntervalSince(started)
        let n = callSpeakerIds().count
        let suffix = offlineWords.isEmpty ? " · transcript unchanged (ASR pass empty)" : ""
        return OfflinePassSummary(speakerCount: n, relabeled: !turns.isEmpty && !offlineWords.isEmpty,
                                  note: "Speaker detection complete · \(n) speaker\(n == 1 ? "" : "s") · \(String(format: "%.1fs", elapsed))\(suffix)")
    }

    /// Call the diarizer and return its output, absorbing any thrown error into a log line
    /// so it can be used as an `async let` binding that returns an optional.
    /// Emits `.diarizationDone` in BOTH the success and catch paths so the relay's
    /// "done-side counts as 1.0" rule keeps the bar moving even on failure.
    private func diarizeLogged(_ samples: [Float],
                               clusterThreshold: Double?,
                               expectedSpeakers: Int?,
                               progressCB: (@Sendable (EngineProgressEvent) -> Void)?) async -> SpeakerKitDiarizer.Output? {
        let t = Date()
        do {
            let out = try await diarizer.diarize(
                samples,
                clusterThreshold: clusterThreshold,
                expectedSpeakers: expectedSpeakers,
                progress: progressCB.map { cb in { f in cb(.diarization(f)) } })
            progressCB?(.diarizationDone)
            AppLog.log("SpeakerKit diar stage: \(String(format: "%.1fs", Date().timeIntervalSince(t)))", category: "record")
            return out
        } catch {
            progressCB?(.diarizationDone)   // failure counts as completion so the bar can advance
            AppLog.log("SpeakerKit diarization failed: \(error.localizedDescription) (\(String(format: "%.1fs", Date().timeIntervalSince(t))))", category: "record")
            return nil
        }
    }

    /// Re-transcribe the clean mix with WhisperKit word timestamps → attribution tokens.
    /// Errors from `kit.transcribe` are logged rather than swallowed so a failing pass
    /// is diagnosable in the log (previously `try?` discarded the error silently).
    ///
    /// Hooks `kit.segmentDiscoveryCallback` to emit `.asr` fraction events. The callback
    /// is cleared with `defer` — WhisperKit's kit instance is shared via `ModelManager`
    /// and a stale closure must not leak into the next live session.
    private func transcribeWords(_ samples: [Float],
                                 progressCB: (@Sendable (EngineProgressEvent) -> Void)?) async -> [DiarizationAttribution.Token] {
        guard let kit = await models.prepare(settings.model) else {
            progressCB?(.asrDone)
            return []
        }
        // Capture as locals so the closure captures only Sendable values, not `self`.
        let cb = progressCB
        let duration = Double(samples.count) / 16_000

        // Map WhisperKit segment discoveries to an ASR fraction. The last segment's end
        // time relative to total audio duration gives a monotone 0…1 progress signal.
        // `defer` clears the callback so no reference to this offline pass leaks into the
        // next recording's live transcription (the kit is reused via ModelManager).
        defer { kit.segmentDiscoveryCallback = nil }
        if let cb {
            kit.segmentDiscoveryCallback = { segments in
                guard let maxEnd = segments.map({ Double($0.end) }).max() else { return }
                cb(.asr(min(1.0, maxEnd / max(duration, 1.0))))
            }
        }

        var opts = DecodingOptions()
        opts.wordTimestamps = true
        opts.withoutTimestamps = false
        opts.skipSpecialTokens = true
        // VAD chunking is the difference between the offline pass decoding the
        // ENTIRE recording sequentially (silence included) and decoding only the
        // speech regions, in parallel. Without a strategy WhisperKit takes the
        // single-window sequential path; `.vad` splits on silence and fans the
        // chunks out across `concurrentWorkerCount` workers. Word timings stay
        // absolute — the chunker re-bases each chunk's word start/end by its seek
        // offset (TranscriptionUtilities.updateSegmentTimings) — so diarization
        // attribution, which aligns words to turns by absolute time, is unaffected.
        //
        // 4 workers (WhisperKit's own CLI default), NOT 0 (unbounded): this pass
        // runs concurrently with SpeakerKit diarization, and both share the one
        // Neural Engine — fanning out every chunk at once would just thrash it.
        opts.chunkingStrategy = .vad
        opts.concurrentWorkerCount = 4
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: samples, decodeOptions: opts)
        } catch {
            progressCB?(.asrDone)
            AppLog.log("Offline ASR failed: \(error.localizedDescription)", category: "record")
            return []
        }
        var toks: [DiarizationAttribution.Token] = []
        for r in results {
            for seg in r.segments {
                for w in (seg.words ?? []) where !w.word.isEmpty {
                    toks.append(.init(text: w.word, start: TimeInterval(w.start), end: TimeInterval(w.end)))
                }
            }
        }
        // Log token count and end time so coverage-guard rejections are diagnosable.
        if !toks.isEmpty {
            let span = toks.last.map { String(format: "%.1fs", $0.end) } ?? "?"
            AppLog.log("Offline ASR: \(toks.count) tokens, span \(span)", category: "record")
        }
        progressCB?(.asrDone)
        return toks
    }

    private func rederive() {
        guard !offlineWords.isEmpty else { offlineSegments = nil; return }
        offlineSegments = DiarizationAttribution.segments(
            tokens: offlineWords, turns: turns, resolvedNames: resolvedNames, runIds: &runIds)
    }

    private func publish() { onSegmentsChanged?(finalTimeline()) }

    /// Match each unnamed speaker (with enough speech) against saved voiceprints.
    /// On a near-miss (enough speech but no match), log the best-scoring candidate so
    /// over-clustering failures are diagnosable without changing matching behavior.
    private func autoIdentify() {
        guard let store = voiceprints else { return }
        for (id, centroid) in speakerCentroids where resolvedNames[id] == nil && !centroid.isEmpty {
            guard (gated[id] ?? 0) >= settings.minSpeechToIdentify else { continue }
            if let m = store.match(centroid, threshold: identificationThreshold, model: embeddingModelId) {
                resolvedNames[id] = m.voiceprint.name
                AppLog.log("SpeakerKit auto-identified Speaker \(id) as \(m.voiceprint.name) (score \(String(format: "%.2f", m.score)))", category: "record")
                onSpeakerIdentified?(m.voiceprint.name)
            } else {
                // Threshold of -1 returns the best candidate regardless of score, letting
                // us report near-misses without changing the actual match gate.
                if let best = store.match(centroid, threshold: -1, model: embeddingModelId) {
                    AppLog.log("Speaker \(id): no voiceprint match (best: \(best.voiceprint.name) at \(String(format: "%.2f", best.score)), threshold \(String(format: "%.2f", identificationThreshold)))", category: "record")
                } else {
                    AppLog.log("Speaker \(id): no voiceprint match (no enrolled prints for model \(embeddingModelId))", category: "record")
                }
            }
        }
    }

    // MARK: Review surface

    /// Speaker ids from attributed segments when available; falls back to the diarized
    /// turns so a failed ASR pass doesn't hide speakers from the review panel.
    func callSpeakerIds() -> [String] {
        let fromSegs = (offlineSegments ?? []).compactMap { $0.speakerId }
        if !fromSegs.isEmpty { return Array(Set(fromSegs)).sorted() }
        return Array(Set(turns.map { $0.speakerId })).sorted()
    }
    func resolvedName(for id: String) -> String? { resolvedNames[id] }
    func gatedSeconds(for id: String) -> TimeInterval { gated[id] ?? 0 }

    func centroidsByID() -> [String: [Float]] { speakerCentroids }

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
        // Prefer the longest attributed segment; fall back to the longest diarized turn
        // when ASR failed so voiceprint enrolment still works after a failed ASR pass.
        let start: TimeInterval
        let end: TimeInterval
        let segs = (offlineSegments ?? []).filter { $0.speakerId == speakerId }
        if let rep = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            start = max(0, rep.start)
            end = min(rep.end, start + 4)
        } else if let rep = turns.filter({ $0.speakerId == speakerId })
                                  .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            start = max(0, rep.start)
            end = min(rep.end, start + 4)
        } else {
            AppLog.log("repAudioSample: no segments or turns for speaker \(speakerId)", category: "record"); return nil
        }
        return await Task.detached {
            guard let all = AudioMix.loadMono16k(url) else { return nil }
            let s = Int(start * 16_000), e = min(all.count, Int(end * 16_000))
            guard s >= 0, s < e else { return nil }
            return Array(all[s..<e])
        }.value
    }

    func speakerSummaries() -> [CallSpeakerSummary] {
        // Segment-based path: attributed segments exist → use them (full text + accurate timing).
        let segments = offlineSegments ?? []
        if !segments.isEmpty {
            var byId: [String: [Segment]] = [:]
            for s in segments where s.speakerId != nil {
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

        // Turn-based fallback: ASR failed but diarization succeeded. Derive talk time
        // from the gated dict and the sample window from the speaker's longest turn so
        // voiceprint enrolment and the review panel still work. firstLine is empty
        // (no transcribed text is available for this path).
        guard !turns.isEmpty else { return [] }
        let speakerIds = Array(Set(turns.map { $0.speakerId })).sorted()
        return speakerIds.map { id in
            let talk = gated[id] ?? 0
            let rep = turns.filter { $0.speakerId == id }
                           .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
            return CallSpeakerSummary(
                id: id, resolvedName: resolvedNames[id], talkSeconds: talk,
                sampleStart: rep?.start ?? 0,
                sampleEnd: rep.map { min($0.end, $0.start + 8) } ?? 0,
                firstLine: "")
        }
    }
}
