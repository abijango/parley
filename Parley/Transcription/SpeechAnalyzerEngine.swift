import Foundation
import AVFoundation
import Speech
import CoreMedia
import FluidAudio

/// Apple SpeechAnalyzer ASR + FluidAudio diarization for speaker labeling.
///
/// Live: streams via `SpeechTranscriber` during capture plus incremental FluidAudio
/// diarization. Offline: whole-file SpeechAnalyzer pass + FluidAudio diarization,
/// attributed via `DiarizationAttribution`.
@MainActor
final class SpeechAnalyzerEngine: SpeakerCapableEngine {
    private let settings: AppSettings
    private let voiceprints: VoiceprintStore?
    private let identificationThreshold: Double

    // Live capture
    private let mixedRing = AudioRingBuffer(capacity: 16_000 * 60)
    private let diarRing = AudioRingBuffer(capacity: 16_000 * 60)
    private var mixerTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var diarTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    // Timeline state
    private var seeded: [Segment] = []
    private var liveSegments: [Segment] = []
    private var offlineSegments: [Segment]?
    private var offlineWords: [DiarizationAttribution.Token] = []
    private var turns: [DiarizationAttribution.Turn] = []
    private var speakerCentroids: [String: [Float]] = [:]
    private var gated: [String: TimeInterval] = [:]
    private var resolvedNames: [String: String] = [:]
    private var runIds: [String: UUID] = [:]
    private var diarSegments: [(speakerId: String, start: TimeInterval, end: TimeInterval)] = []
    private let minSecondsToEnroll: TimeInterval = 3
    /// Prior session duration on resume. Analyzer-local times start at 0 for this capture leg.
    private var sessionElapsed: TimeInterval = 0
    private var streamStart: Date?
    private var lastPublishTime = Date.distantPast
    private let publishMinInterval: TimeInterval = 1.0
    private var publishDeferredTask: Task<Void, Never>?

    var onSegmentsChanged: (([Segment]) -> Void)?
    var onSpeakerIdentified: ((String) -> Void)?
    var onOfflineProgress: (@Sendable (EngineProgressEvent) -> Void)?
    var mixedAudioURL: URL?
    var micArchiveURL: URL?
    var systemArchiveURL: URL?
    var forceOfflineAsr = false
    var speakerCountHint: Int? = nil

    var embeddingModelId: String { VoiceprintStore.embeddingModel }
    var embeddingDim: Int { VoiceprintStore.embeddingDim }

    init(settings: AppSettings, voiceprints: VoiceprintStore? = nil, identificationThreshold: Double = 0.6) {
        self.settings = settings
        self.voiceprints = voiceprints
        self.identificationThreshold = identificationThreshold
    }

    // MARK: TranscriptionEngine

    func confirmedTimeline() -> [Segment] {
        let base = offlineSegments ?? liveSegments
        return seeded + base.filter(\.confirmed)
    }

    func finalTimeline() -> [Segment] {
        let base = offlineSegments ?? liveSegments
        return seeded + base
    }

    func seed(_ segments: [Segment]) {
        seeded = segments
        publish(immediate: true)
    }

    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        sessionElapsed = startElapsed
        streamStart = Date()
        let mixedRing = self.mixedRing
        let diarRing = self.diarRing
        mixerTask = Task.detached {
            while !Task.isCancelled {
                if let mixed = Self.mixLive(mic: micRing, system: systemRing), !mixed.isEmpty {
                    mixed.withUnsafeBufferPointer { mixedRing.write($0) }
                    mixed.withUnsafeBufferPointer { diarRing.write($0) }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        Task { await self.startLiveTranscription() }
        startIncrementalDiarization()
    }

    func stop() async {
        mixerTask?.cancel(); mixerTask = nil
        feedTask?.cancel(); feedTask = nil
        resultsTask?.cancel(); resultsTask = nil
        diarTask?.cancel(); diarTask = nil
        publishDeferredTask?.cancel(); publishDeferredTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await analyzer.cancelAndFinishNow()
        }
        analysisTask?.cancel()
        analysisTask = nil
        analyzer = nil
        if let locale = transcriber?.selectedLocales.first {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        transcriber = nil
    }

    // MARK: Offline pass

    func runOfflinePass() async -> OfflinePassSummary {
        let started = Date()
        AppLog.log("SpeechAnalyzer offline pass started…", category: "record")
        let progressCB = onOfflineProgress
        progressCB?(.mixStarted)

        guard let url = mixedAudioURL else {
            return OfflinePassSummary(speakerCount: callSpeakerIds().count, relabeled: false,
                                      note: "Offline pass skipped — no audio")
        }

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
            let built = await CancellableDetached.run { AudioMix.buildCleanMix(mic: mic, system: sys, output: url) }
            AppLog.log("SpeechAnalyzer offline pass: rebuilt clean mix (built=\(built))", category: "record")
        }
        guard let samples = AudioMix.loadMono16k(url), !samples.isEmpty else {
            return OfflinePassSummary(speakerCount: 0, relabeled: false, note: "Offline pass: no audio")
        }
        progressCB?(.mixDone)

        let localeID = settings.speechLocale
        let threshold = settings.diarizationThreshold
        let hint = speakerCountHint
        let concurrentStart = Date()

        async let asrWords = Self.transcribeFile(
            url: url, localeIdentifier: localeID,
            progress: progressCB.map { cb in { f in cb(.asr(f)) } })
        async let diarOut = Self.diarizeLogged(
            samples: samples, clusterThreshold: Float(threshold),
            expectedSpeakers: hint,
            progress: progressCB.map { cb in { f in cb(.diarization(f)) } })

        let (words, diarResult) = await (asrWords, diarOut)
        AppLog.log("SpeechAnalyzer offline pass: concurrent ASR+diar finished in \(String(format: "%.1fs", Date().timeIntervalSince(concurrentStart)))", category: "record")

        offlineWords = words
        if let out = diarResult {
            turns = out.turns
            speakerCentroids = out.centroids
            gated = out.gatedSeconds
            AppLog.log("SpeechAnalyzer diar: \(Set(turns.map(\.speakerId)).count) speaker(s), \(turns.count) turns", category: "record")
        }

        progressCB?(.attributeStarted)
        autoIdentify()
        rederive()
        publish(immediate: true)
        progressCB?(.attributeDone)

        let elapsed = Date().timeIntervalSince(started)
        let n = callSpeakerIds().count
        let suffix = offlineWords.isEmpty ? " · transcript unchanged (ASR pass empty)" : ""
        return OfflinePassSummary(speakerCount: n, relabeled: !turns.isEmpty && !offlineWords.isEmpty,
                                  note: "Speaker detection complete · \(n) speaker\(n == 1 ? "" : "s") · \(String(format: "%.1fs", elapsed))\(suffix)")
    }

    func diarizedTurns() -> [DiarizationAttribution.Turn] { turns }

    // MARK: Review surface

    func callSpeakerIds() -> [String] {
        let fromSegs = (offlineSegments ?? []).compactMap { $0.speakerId }
        if !fromSegs.isEmpty { return Array(Set(fromSegs)).sorted() }
        return Array(Set(turns.map(\.speakerId))).sorted()
    }

    func resolvedName(for id: String) -> String? { resolvedNames[id] }
    func gatedSeconds(for id: String) -> TimeInterval { gated[id] ?? 0 }
    func centroidsByID() -> [String: [Float]] { speakerCentroids }

    @discardableResult
    func setSpeakerName(_ speakerId: String, as name: String) -> [Float]? {
        resolvedNames[speakerId] = name
        rederive()
        publish(immediate: true)
        guard let c = speakerCentroids[speakerId], !c.isEmpty,
              (gated[speakerId] ?? 0) >= minSecondsToEnroll else { return nil }
        return c
    }

    func repAudioSample(for speakerId: String) async -> [Float]? {
        guard let url = mixedAudioURL else { return nil }
        let start: TimeInterval
        let end: TimeInterval
        let segs = (offlineSegments ?? []).filter { $0.speakerId == speakerId }
        if let rep = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            start = max(0, rep.start); end = min(rep.end, start + 4)
        } else if let rep = turns.filter({ $0.speakerId == speakerId })
            .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            start = max(0, rep.start); end = min(rep.end, start + 4)
        } else { return nil }
        return await Task.detached {
            guard let all = AudioMix.loadMono16k(url) else { return nil }
            let s = Int(start * 16_000), e = min(all.count, Int(end * 16_000))
            guard s >= 0, s < e else { return nil }
            return Array(all[s..<e])
        }.value
    }

    func speakerSummaries() -> [CallSpeakerSummary] {
        let segments = offlineSegments ?? liveSegments
        if !segments.isEmpty {
            var byId: [String: [Segment]] = [:]
            for s in segments where s.speakerId != nil { byId[s.speakerId!, default: []].append(s) }
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
        return turns.map { t in
            CallSpeakerSummary(
                id: t.speakerId, resolvedName: resolvedNames[t.speakerId],
                talkSeconds: gated[t.speakerId] ?? max(0, t.end - t.start),
                sampleStart: t.start, sampleEnd: min(t.end, t.start + 8), firstLine: "")
        }.sorted { $0.id < $1.id }
    }

    // MARK: Live transcription

    private func startLiveTranscription() async {
        guard SpeechTranscriber.isAvailable else {
            AppLog.log("SpeechAnalyzer: SpeechTranscriber unavailable on this device", category: "record")
            return
        }
        guard let locale = await SpeechAssetManager.resolvedLocale(for: settings.speechLocale) else {
            AppLog.log("SpeechAnalyzer: locale \(settings.speechLocale) unsupported", category: "record")
            return
        }
        // Keep the locale warm for the session — without this, installed assets can
        // still produce an empty results stream on some machines.
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            AppLog.log("SpeechAnalyzer: locale reserve failed: \(error.localizedDescription)", category: "record")
        }
        let tr = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        transcriber = tr
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
                try await request.downloadAndInstall()
            } else {
                AppLog.log("SpeechAnalyzer: locale assets already installed (\(locale.identifier(.bcp47)))", category: "record")
            }
        } catch {
            AppLog.log("SpeechAnalyzer: locale asset install failed: \(error.localizedDescription)", category: "record")
            return
        }
        let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [tr], considering: natural) else {
            AppLog.log("SpeechAnalyzer: no compatible audio format", category: "record")
            return
        }
        AppLog.log(
            "SpeechAnalyzer analyzer format: \(format.sampleRate)Hz/\(format.channelCount)ch/\(Self.formatLabel(format))",
            category: "record")
        let an = SpeechAnalyzer(modules: [tr])
        analyzer = an
        do {
            try await an.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            streamContinuation = continuation
            // Consume results and feed audio *before* start — start() runs until the
            // input stream ends, so awaiting it here would block the whole live path.
            consumeLiveResults(tr)
            startFeedingAnalyzer(format: format, continuation: continuation)
            analysisTask = Task {
                do {
                    try await an.start(inputSequence: stream)
                } catch {
                    AppLog.log("SpeechAnalyzer live session ended: \(error.localizedDescription)", category: "record")
                }
            }
            AppLog.log("SpeechAnalyzer live transcription active (\(locale.identifier(.bcp47)))", category: "record")
        } catch {
            AppLog.log("SpeechAnalyzer live start failed: \(error.localizedDescription)", category: "record")
        }
    }

    private func startFeedingAnalyzer(format: AVAudioFormat,
                                      continuation: AsyncStream<AnalyzerInput>.Continuation) {
        let ring = mixedRing
        feedTask = Task.detached {
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            // Reuse one converter across the session — AVAudioConverter keeps SRC state.
            let converter: AVAudioConverter? = {
                if format.sampleRate == srcFormat.sampleRate,
                   format.channelCount == srcFormat.channelCount,
                   format.commonFormat == srcFormat.commonFormat,
                   format.isInterleaved == srcFormat.isInterleaved {
                    return nil
                }
                return AVAudioConverter(from: srcFormat, to: format)
            }()
            if converter == nil,
               !(format.sampleRate == 16_000 && format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32) {
                AppLog.log("SpeechAnalyzer: AVAudioConverter(from:16k float → analyzer) returned nil", category: "record")
            }
            let chunk = 16_000 / 4   // 250 ms at 16 kHz
            var fedSamples = 0
            var lastLogged = 0
            var convertFailures = 0
            var sampleCursor: Int64 = 0
            while !Task.isCancelled {
                var buf = [Float]()
                let n = ring.read(maxCount: chunk, into: &buf)
                if n > 0 {
                    let samples = Array(buf.prefix(n))
                    if let pcm = Self.makePCMBuffer(samples: samples, format: format,
                                                    sourceFormat: srcFormat, converter: converter) {
                        let start = CMTime(value: sampleCursor, timescale: 16_000)
                        continuation.yield(AnalyzerInput(buffer: pcm, bufferStartTime: start))
                        sampleCursor += Int64(n)
                        fedSamples += n
                        if fedSamples - lastLogged >= 16_000 * 5 {
                            lastLogged = fedSamples
                            AppLog.log("SpeechAnalyzer fed ~\(fedSamples / 16_000)s of audio to ASR", category: "record")
                        }
                    } else {
                        convertFailures += 1
                        if convertFailures == 1 || convertFailures % 25 == 0 {
                            AppLog.log("SpeechAnalyzer PCM convert failed (\(convertFailures)×)", category: "record")
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func consumeLiveResults(_ tr: SpeechTranscriber) {
        resultsTask = Task {
            var count = 0
            do {
                for try await result in tr.results {
                    count += 1
                    if count == 1 || count % 20 == 0 {
                        let preview = String(result.text.characters).prefix(60)
                        AppLog.log(
                            "SpeechAnalyzer result #\(count) final=\(result.isFinal) chars=\(preview.count) “\(preview)”",
                            category: "record")
                    }
                    await self.ingestLiveResult(result)
                }
                AppLog.log("SpeechAnalyzer live results stream finished (\(count) results)", category: "record")
            } catch {
                AppLog.log("SpeechAnalyzer live results ended after \(count): \(error.localizedDescription)", category: "record")
            }
        }
    }

    private func ingestLiveResult(_ result: SpeechTranscriber.Result) {
        let tokens = SpeechAnalyzerSessionClock.tokens(Self.tokens(from: result), offset: sessionElapsed)
        if !tokens.isEmpty {
            ingestLiveTokens(tokens, confirmed: result.isFinal)
            return
        }
        // Fallback when word timings are missing — still show the text live.
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let start = SpeechAnalyzerSessionClock.time(CMTimeGetSeconds(result.range.start), offset: sessionElapsed)
        let end = start + max(CMTimeGetSeconds(result.range.duration), 0.01)
        let seg = Segment(track: .remote, start: start, end: end, text: text, confirmed: result.isFinal)
        if result.isFinal {
            liveSegments = dropTrailingUnconfirmed(liveSegments)
            liveSegments = mergeLiveSegments(liveSegments, [seg])
        } else {
            liveSegments = dropTrailingUnconfirmed(liveSegments) + [seg]
        }
        publish(immediate: true)
    }

    private func ingestLiveTokens(_ tokens: [DiarizationAttribution.Token], confirmed: Bool) {
        guard !tokens.isEmpty else { return }
        let attrTurns = diarSegments.map {
            DiarizationAttribution.Turn(speakerId: $0.speakerId, start: $0.start, end: $0.end)
        }
        var newSegs = DiarizationAttribution.segments(
            tokens: tokens, turns: attrTurns, resolvedNames: resolvedNames, runIds: &runIds)
        guard !newSegs.isEmpty else { return }
        for i in newSegs.indices { newSegs[i].confirmed = confirmed }
        if confirmed {
            liveSegments = dropTrailingUnconfirmed(liveSegments)
            liveSegments = mergeLiveSegments(liveSegments, newSegs)
        } else {
            liveSegments = dropTrailingUnconfirmed(liveSegments) + newSegs
        }
        publish(immediate: !confirmed)
    }

    private func dropTrailingUnconfirmed(_ segments: [Segment]) -> [Segment] {
        guard let lastConfirmed = segments.lastIndex(where: \.confirmed) else { return [] }
        return Array(segments[...lastConfirmed])
    }

    private func mergeLiveSegments(_ existing: [Segment], _ incoming: [Segment]) -> [Segment] {
        guard let last = existing.last, let first = incoming.first, last.end <= first.start + 0.05 else {
            return existing + incoming
        }
        return existing + incoming
    }

    // MARK: Incremental diarization (live)

    private func startIncrementalDiarization() {
        let threshold = Float(settings.diarizationThreshold)
        let ring = diarRing
        let sessionOffset = sessionElapsed
        diarTask = Task.detached {
            guard let diar = try? await FluidAudioEngine.makeDiarizerForExport(clusterThreshold: threshold) else {
                AppLog.log("SpeechAnalyzer live diarizer failed to initialize — in-call naming unavailable until stop", category: "record")
                return
            }
            let chunk = 16_000 * 10
            var processed = 0
            while !Task.isCancelled {
                var buf = [Float]()
                // Wait until we have a useful chunk; don't drain tiny leftovers that
                // would never reach the 5 s diarization floor.
                guard ring.availableToRead >= 16_000 * 5 else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let n = ring.read(maxCount: chunk, into: &buf)
                guard n >= 16_000 * 5 else { continue }
                let offset = SpeechAnalyzerSessionClock.diarizationStart(
                    processedSamples: processed, offset: sessionOffset)
                processed += n
                guard let result = try? diar.performCompleteDiarization(
                    Array(buf.prefix(n)), sampleRate: 16_000) else { continue }
                // Rebase chunk-local times onto the session timeline (same as FluidAudio).
                let segs = result.segments.map {
                    (speakerId: $0.speakerId,
                     start: offset + TimeInterval($0.startTimeSeconds),
                     end: offset + TimeInterval($0.endTimeSeconds))
                }
                guard !segs.isEmpty else { continue }
                await MainActor.run { self.mergeDiarSegments(segs) }
            }
        }
    }

    private func mergeDiarSegments(_ incoming: [(speakerId: String, start: TimeInterval, end: TimeInterval)]) {
        diarSegments.append(contentsOf: incoming)
        diarSegments.sort { $0.start < $1.start }
        if diarSegments.count > 400 { diarSegments.removeFirst(diarSegments.count - 400) }
        if !liveSegments.isEmpty, offlineSegments == nil {
            // Re-attribute current live text when diarization catches up.
            let tokens = liveSegments.flatMap { seg -> [DiarizationAttribution.Token] in
                [.init(text: seg.text, start: seg.start, end: seg.end)]
            }
            let attrTurns = diarSegments.map {
                DiarizationAttribution.Turn(speakerId: $0.speakerId, start: $0.start, end: $0.end)
            }
            liveSegments = DiarizationAttribution.segments(
                tokens: tokens, turns: attrTurns, resolvedNames: resolvedNames, runIds: &runIds)
            publish(immediate: false)
        }
    }

    // MARK: Private helpers

    private func rederive() {
        guard !offlineWords.isEmpty else { offlineSegments = nil; return }
        offlineSegments = DiarizationAttribution.segments(
            tokens: offlineWords, turns: turns, resolvedNames: resolvedNames, runIds: &runIds)
    }

    private func autoIdentify() {
        guard let store = voiceprints else { return }
        for (id, centroid) in speakerCentroids where resolvedNames[id] == nil && !centroid.isEmpty {
            guard (gated[id] ?? 0) >= settings.minSpeechToIdentify else { continue }
            if let m = store.match(centroid, threshold: identificationThreshold, model: embeddingModelId) {
                resolvedNames[id] = m.voiceprint.name
                onSpeakerIdentified?(m.voiceprint.name)
            }
        }
    }

    private func publish(immediate: Bool) {
        let now = Date()
        if immediate || now.timeIntervalSince(lastPublishTime) >= publishMinInterval {
            lastPublishTime = now
            publishDeferredTask?.cancel()
            onSegmentsChanged?(finalTimeline())
        } else {
            publishDeferredTask?.cancel()
            publishDeferredTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.publishMinInterval ?? 0.2) * 1_000_000_000)
                await MainActor.run { self?.publish(immediate: true) }
            }
        }
    }

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

    nonisolated private static func formatLabel(_ format: AVAudioFormat) -> String {
        switch format.commonFormat {
        case .pcmFormatFloat32: return "f32"
        case .pcmFormatFloat64: return "f64"
        case .pcmFormatInt16: return "i16"
        case .pcmFormatInt32: return "i32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }

    /// Build an analyzer-compatible PCM buffer from 16 kHz mono float samples.
    /// Always creates the source as float32 first; converts only when the analyzer
    /// format differs. The previous path assumed `floatChannelData` on the
    /// *destination* format and silently dropped every buffer when Speech asked
    /// for int16 (or any non-float) layout.
    nonisolated private static func makePCMBuffer(
        samples: [Float],
        format: AVAudioFormat,
        sourceFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let srcPtr = srcBuf.floatChannelData?[0] else { return nil }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { srcPtr[i] = samples[i] }

        guard let converter else {
            // Destination matches source — hand the float32 buffer through.
            return srcBuf
        }

        let ratio = format.sampleRate / sourceFormat.sampleRate
        let cap = AVAudioFrameCount(Double(samples.count) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return srcBuf
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Extract timed words from a SpeechTranscriber result.
    ///
    /// Apple SpeechAttributedString runs are whole words (not SentencePiece
    /// pieces). Trimming each run and feeding them to `DiarizationAttribution`
    /// without a leading-space / ▁ boundary glued them into
    /// `Thescreenitselfis…`. We keep a leading space on every word after the
    /// first so reconstruct + speaker attribution treat them as separate words.
    nonisolated private static func tokens(from result: SpeechTranscriber.Result) -> [DiarizationAttribution.Token] {
        let attrText = result.text
        var out: [DiarizationAttribution.Token] = []
        for run in attrText.runs {
            let slice = attrText[run.range]
            let raw = String(slice.characters)
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }

            let start: TimeInterval
            let end: TimeInterval
            if let timeRange = slice.audioTimeRange {
                start = CMTimeGetSeconds(timeRange.start)
                end = start + max(CMTimeGetSeconds(timeRange.duration), 0.01)
            } else if out.isEmpty {
                // Untimed run at the head of the result — use the result range.
                start = CMTimeGetSeconds(result.range.start)
                end = start + max(CMTimeGetSeconds(result.range.duration), 0.01)
            } else {
                // Untimed interior run — park it just after the previous token.
                start = out[out.count - 1].end
                end = start + 0.05
            }

            // Leading space = word boundary for DiarizationAttribution (Apple has no ▁).
            let marked = out.isEmpty ? word : " " + word
            out.append(.init(text: marked, start: start, end: end))
        }
        if out.isEmpty {
            let text = String(attrText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let start = CMTimeGetSeconds(result.range.start)
            let end = start + max(CMTimeGetSeconds(result.range.duration), 0.01)
            out.append(.init(text: text, start: start, end: end))
        }
        return out
    }

    nonisolated private static func transcribeFile(
        url: URL,
        localeIdentifier: String,
        progress: (@Sendable (Double) -> Void)?
    ) async -> [DiarizationAttribution.Token] {
        guard let locale = await SpeechAssetManager.resolvedLocale(for: localeIdentifier) else {
            progress?(1); return []
        }
        let tr = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [tr]) {
            try? await request.downloadAndInstall()
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [tr], finishAfterFile: true)
            _ = analyzer
            var tokens: [DiarizationAttribution.Token] = []
            var count = 0
            for try await result in tr.results where result.isFinal {
                tokens.append(contentsOf: Self.tokens(from: result))
                count += 1
                progress?(min(1.0, Double(count) / 50.0))
            }
            progress?(1)
            AppLog.log("SpeechAnalyzer file ASR: \(tokens.count) token(s) from \(count) final result(s)", category: "record")
            return tokens
        } catch {
            AppLog.log("SpeechAnalyzer file ASR failed: \(error.localizedDescription)", category: "record")
            progress?(1)
            return []
        }
    }

    private struct DiarOutput: Sendable {
        let turns: [DiarizationAttribution.Turn]
        let centroids: [String: [Float]]
        let gatedSeconds: [String: TimeInterval]
    }

    nonisolated private static func diarizeLogged(
        samples: [Float],
        clusterThreshold: Float,
        expectedSpeakers: Int?,
        progress: (@Sendable (Double) -> Void)?
    ) async -> DiarOutput? {
        _ = expectedSpeakers   // FluidAudio diarizer uses clustering threshold only
        progress?(0)
        guard let snap = await FluidAudioEngine.diarizeRecording(
            samples: samples, clusterThreshold: clusterThreshold) else {
            progress?(1)
            return nil
        }
        progress?(1)
        return DiarOutput(turns: snap.turns, centroids: snap.centroids, gatedSeconds: snap.gatedSeconds)
    }
}

/// Maps SpeechAnalyzer-local times (this capture leg starts at 0) onto the session clock.
/// Resume passes the prior duration as `offset`. File ASR stays at local 0 and does not use this.
enum SpeechAnalyzerSessionClock {
    static func time(_ local: TimeInterval, offset: TimeInterval) -> TimeInterval {
        offset + local
    }

    static func tokens(
        _ tokens: [DiarizationAttribution.Token],
        offset: TimeInterval
    ) -> [DiarizationAttribution.Token] {
        guard offset != 0 else { return tokens }
        return tokens.map {
            DiarizationAttribution.Token(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        }
    }

    static func diarizationStart(
        processedSamples: Int,
        offset: TimeInterval,
        sampleRate: Int = 16_000
    ) -> TimeInterval {
        offset + TimeInterval(processedSamples) / TimeInterval(sampleRate)
    }
}
