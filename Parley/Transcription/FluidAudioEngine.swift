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
/// everything from that one buffer: live Parakeet ASR via the multilingual
/// Nemotron `StreamingNemotronMultilingualAsrManager` (cache-aware true streaming,
/// ~one-chunk latency) plus pyannote/WeSpeaker diarization via `DiarizerManager`.
/// The accurate, token-timed final transcript is produced by the offline TDT v3
/// batch re-pass at stop (`offlineTranscribe`).
///
/// Display segments are DERIVED from ASR "units" (each with per-token timings) and
/// the diarization timeline: every token is attributed to the diarized speaker whose
/// turn overlaps it, and consecutive same-speaker tokens are grouped into a segment.
/// This re-splits a chunk per speaker — and re-splits retroactively as diarization
/// catches up — so rapid back-and-forth within one ASR chunk no longer collapses
/// onto a single speaker. Phases 4–5 layer voiceprint identification on top.
@MainActor
final class FluidAudioEngine: TranscriptionEngine {
    private let settings: AppSettings
    /// Saved voiceprints for cross-session auto-identification (nil = no matching).
    private let voiceprints: VoiceprintStore?
    private let identificationThreshold: Double
    /// Clean mixed file built at stop from the archived tracks (used for the final
    /// diarization + play-sample + retained clips). Set before `start()`.
    var mixedAudioURL: URL?
    /// Archived per-track captures (continuous, glitch-free) summed into the clean mix.
    var micArchiveURL: URL?
    var systemArchiveURL: URL?
    /// Force the offline batch-ASR re-pass regardless of the user setting — used when
    /// re-processing an already-recorded call from History (there are no streaming
    /// units, so the batch pass is the only source of transcript text + timings).
    var forceOfflineAsr = false
    /// Accepted for SpeakerCapableEngine conformance; not forwarded to FluidAudio's
    /// DiarizerManager (which uses its own clusteringThreshold from settings).
    var speakerCountHint: Int? = nil
    // Live ASR is the multilingual Nemotron cache-aware STREAMING model — true
    // low-latency (~one chunk) transcription. The old `SlidingWindowAsrManager`
    // floored at chunk+right (~13s) because it re-ran a *batch* model over
    // overlapping windows; this carries encoder state forward and emits within a
    // chunk. The chunk tier + language come from settings at load time.
    private let asr = StreamingNemotronMultilingualAsrManager()

    /// The same mixed audio fed to ASR, buffered for the diarizer (drained in chunks).
    private let diarRing = AudioRingBuffer(capacity: 16_000 * 60)

    // Raw ASR output, kept with token timings so display segments can be derived.
    private struct Tok { let text: String; let start: TimeInterval; let end: TimeInterval }
    private struct ASRUnit { let id: UUID; let tokens: [Tok]; let text: String; let confirmed: Bool }
    private var seeded: [Segment] = []
    private var confirmedUnits: [ASRUnit] = []
    private var volatileUnit: ASRUnit?
    /// Live-streaming segmentation state. The streaming model emits a single
    /// growing transcript with NO per-token timings, so we slice it into units on
    /// a fixed wall-clock cadence: `liveCommittedChars` is how much of the
    /// cumulative text has been promoted to `confirmedUnits`, and `liveSegStart`
    /// is the timeline position where the current volatile span began. Audio is
    /// fed in real time, so the wall clock ≈ audio time — accurate enough for live
    /// diarization attribution. The offline TDT v3 re-pass replaces all of this
    /// with token-timed units at stop.
    private var liveCommittedChars = 0
    private var liveSegStart: TimeInterval = 0
    private let liveConfirmInterval: TimeInterval = 6
    /// Stable ids for derived sub-segments (keyed by unit + speaker + start) so
    /// re-splitting doesn't churn SwiftUI identities or the recovery journal.
    private var runIds: [String: UUID] = [:]
    private var streamStart: Date?

    /// Diarized speaker turns on the session timeline (speakerId + start/end seconds).
    private var diarSegments: [(speakerId: String, start: TimeInterval, end: TimeInterval)] = []
    /// Quality-gated per-speaker embeddings + speech duration, for identification + enrollment.
    private var speakerEmbeddings: [String: [[Float]]] = [:]
    private var speakerGatedSeconds: [String: TimeInterval] = [:]
    /// speakerId → resolved person name (auto-identified or manually assigned).
    private var resolvedNames: [String: String] = [:]
    private let minSegmentQuality: Float = 0.4
    private let minSecondsToEnroll: TimeInterval = 3

    // Background work.
    private var loadTask: Task<Void, Never>?
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

    // MARK: - Derived timeline

    func confirmedTimeline() -> [Segment] { derive(confirmedUnits, volatile: nil) }
    func finalTimeline() -> [Segment] { derive(confirmedUnits, volatile: volatileUnit) }
    func seed(_ segments: [Segment]) { seeded = segments; publish() }

    /// Derive display segments. When a diarization timeline exists, attribution is
    /// DIARIZATION-FIRST: the diarized turns are authoritative for who/when, and ASR
    /// words are grouped onto them. Without diarization yet, falls back to plain ASR
    /// units (track-labelled).
    private func derive(_ confirmed: [ASRUnit], volatile: ASRUnit?) -> [Segment] {
        guard !diarSegments.isEmpty else {
            return build(units: confirmed + (volatile.map { [$0] } ?? []))
        }
        var out = seeded
        out.append(contentsOf: diarizationFirst(confirmed))
        // Keep the in-progress tail as a SINGLE stable row (splitting it each update
        // caused the earlier flicker); label it by the speaker at its midpoint.
        if let v = volatile, let f = v.tokens.first, let l = v.tokens.last {
            let spk = speakerAt((f.start + l.end) / 2)
            out.append(Segment(id: v.id, track: .remote, start: f.start, end: l.end, text: v.text,
                               confirmed: false, speakerId: spk, speakerName: spk.flatMap { resolvedNames[$0] }))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Build segments from ALL confirmed tokens + the diarization timeline: group
    /// tokens into whole words (▁ marks a word start, so a speaker change never cuts a
    /// word), assign each word the diarized speaker at its midpoint, and merge
    /// consecutive same-speaker words into one segment. Operates globally (across ASR
    /// units), so a speaker's turn isn't fragmented by ASR pause boundaries.
    private func diarizationFirst(_ units: [ASRUnit]) -> [Segment] {
        let toks = units.flatMap { $0.tokens }.sorted { $0.start < $1.start }
        guard !toks.isEmpty else { return [] }
        var words: [[Tok]] = []
        for t in toks {
            if words.isEmpty || Self.isWordStart(t.text) { words.append([t]) }
            else { words[words.count - 1].append(t) }
        }
        var runs: [(spk: String?, toks: [Tok])] = []
        for w in words {
            let spk = speakerAt((w.first!.start + w.last!.end) / 2)
            if var last = runs.last, last.spk == spk {
                last.toks.append(contentsOf: w); runs[runs.count - 1] = last
            } else {
                runs.append((spk, w))
            }
        }
        return runs.compactMap { run -> Segment? in
            guard let first = run.toks.first, let last = run.toks.last else { return nil }
            let text = Self.reconstruct(run.toks.map(\.text))
            guard !text.isEmpty else { return nil }
            // Stable id keyed by run start (NOT speaker) so resolving a name later
            // doesn't churn the row identity.
            let key = "df@\(Int(first.start * 100))"
            let id = runIds[key] ?? { let u = UUID(); runIds[key] = u; return u }()
            return Segment(id: id, track: .remote, start: first.start, end: last.end, text: text,
                           confirmed: true, speakerId: run.spk, speakerName: run.spk.flatMap { resolvedNames[$0] })
        }
    }

    /// The diarized speaker active at time `t`: the turn containing it, else the turn
    /// with the NEAREST BOUNDARY. (A long turn's midpoint is far from its edges, so
    /// nearest-midpoint mis-assigned gap words to distant long turns — the smearing
    /// that mixed speakers within a line. Boundary distance fixes it.)
    private func speakerAt(_ t: TimeInterval) -> String? {
        guard !diarSegments.isEmpty else { return nil }
        for d in diarSegments where t >= d.start && t <= d.end { return d.speakerId }
        var best: (id: String, dist: TimeInterval)?
        for d in diarSegments {
            let dist = min(abs(t - d.start), abs(t - d.end))
            if dist < (best?.dist ?? .greatestFiniteMagnitude) { best = (d.speakerId, dist) }
        }
        return best?.id
    }

    /// Derive display segments: seeded segments + each ASR unit split into runs of
    /// consecutive same-speaker tokens.
    private func build(units: [ASRUnit]) -> [Segment] {
        var out = seeded
        for unit in units { out.append(contentsOf: segments(for: unit)) }
        return out.sorted { $0.start < $1.start }
    }

    private func segments(for unit: ASRUnit) -> [Segment] {
        guard let firstTok = unit.tokens.first, let lastTok = unit.tokens.last else { return [] }

        // The volatile (in-progress) tail changes on every update, so keep it as a
        // SINGLE row with a STABLE id — sub-splitting it would churn SwiftUI
        // identities each update (the reported flicker). It gets properly split once
        // it's confirmed.
        if !unit.confirmed {
            let spk = speakerNear(start: firstTok.start, end: lastTok.end)
            return [Segment(id: unit.id, track: .remote, start: firstTok.start, end: lastTok.end,
                            text: unit.text, confirmed: false,
                            speakerId: spk, speakerName: spk.flatMap { resolvedNames[$0] })]
        }

        // Group subword tokens into whole WORDS so a speaker change never cuts a word
        // in half. A word starts on ▁ (streaming ASR) OR a leading space (the offline
        // batch ASR marks word boundaries with a space, not ▁).
        var words: [[Tok]] = []
        for t in unit.tokens {
            if words.isEmpty || Self.isWordStart(t.text) { words.append([t]) }
            else { words[words.count - 1].append(t) }
        }
        // Assign each word a speaker (filling gaps with the nearest turn), then group
        // consecutive same-speaker words into runs.
        var runs: [(speaker: String?, words: [[Tok]])] = []
        for w in words {
            let spk = speakerNear(start: w.first!.start, end: w.last!.end)
            if var last = runs.last, last.speaker == spk {
                last.words.append(w); runs[runs.count - 1] = last
            } else {
                runs.append((spk, [w]))
            }
        }
        let singleRun = runs.count == 1
        return runs.compactMap { run -> Segment? in
            let toks = run.words.flatMap { $0 }
            guard let first = toks.first, let last = toks.last else { return nil }
            let text = singleRun ? unit.text : Self.reconstruct(toks.map(\.text))
            guard !text.isEmpty else { return nil }
            // Key by unit + run start only (NOT speaker): resolving a run's speaker
            // later must not change the row identity, or it re-renders/flickers.
            let key = "\(unit.id.uuidString)@\(Int(first.start * 100))"
            let id = runIds[key] ?? {
                let u = UUID(); runIds[key] = u; return u
            }()
            return Segment(id: id, track: .remote, start: first.start, end: last.end,
                           text: text, confirmed: unit.confirmed,
                           speakerId: run.speaker, speakerName: run.speaker.flatMap { resolvedNames[$0] })
        }
    }

    /// Speaker overlapping `[start, end]`; if none (a diarization gap), the nearest
    /// turn by midpoint — so gap tokens join a real speaker instead of falling back
    /// to the "Remote" track label.
    private func speakerNear(start: TimeInterval, end: TimeInterval) -> String? {
        if let s = bestSpeaker(start: start, end: end) { return s }
        guard !diarSegments.isEmpty else { return nil }
        let mid = (start + end) / 2
        return diarSegments.min(by: {
            abs((($0.start + $0.end) / 2) - mid) < abs((($1.start + $1.end) / 2) - mid)
        })?.speakerId
    }

    /// A token begins a new word if it starts with the SentencePiece ▁ marker
    /// (streaming ASR) or a literal leading space (the offline batch ASR uses spaces,
    /// not ▁ — relying only on ▁ collapsed every offline token into one "word").
    private static func isWordStart(_ text: String) -> Bool {
        text.hasPrefix("\u{2581}") || text.hasPrefix(" ")
    }

    /// Rebuild readable text from SentencePiece subword tokens (▁ marks word starts).
    private static func reconstruct(_ tokens: [String]) -> String {
        tokens.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split streaming text into one `Tok` per word, spreading the wall-clock span
    /// evenly and tagging each with the ▁ word-start marker. The streaming model
    /// emits no per-token timings, so these positions are approximations — but
    /// they let `diarizationFirst` split a unit ACROSS speakers and attribute each
    /// word to the diarized turn at its midpoint, exactly as it does for the
    /// offline token-timed transcript. Without per-word tokens every unit collapses
    /// into one ▁-less "word" and the whole live history lands on a single speaker.
    /// The offline TDT v3 re-pass replaces these with real timings at stop.
    private static func wordToks(_ text: String, start: TimeInterval, end: TimeInterval) -> [Tok] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let step = max(0, end - start) / Double(words.count)
        return words.enumerated().map { i, w in
            let s = start + step * Double(i)
            let e = i == words.count - 1 ? end : start + step * Double(i + 1)
            return Tok(text: "\u{2581}" + w, start: s, end: e)
        }
    }

    // MARK: - Lifecycle

    func start(micRing: AudioRingBuffer, systemRing: AudioRingBuffer, startElapsed: TimeInterval) {
        let clusterThreshold = Float(settings.diarizationThreshold)
        let chunkMs = settings.liveStreamingTier.rawValue
        let language = settings.liveStreamingLanguage
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Download (cached after first run) + load the multilingual streaming
                // variant for the chosen tier/language, then route its cumulative
                // partial transcript into the live timeline via the callback.
                let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: language, chunkMs: chunkMs)
                try await self.asr.loadModels(from: dir)
                await self.asr.setPartialCallback { [weak self] text in
                    Task { @MainActor in self?.applyPartial(text, startElapsed: startElapsed) }
                }
                AppLog.log("FluidAudio engine ready — Nemotron multilingual streaming (\(chunkMs)ms, \(language))", category: "record")
                self.beginConsumingAndMixing(micRing: micRing, systemRing: systemRing,
                                             startElapsed: startElapsed, clusterThreshold: clusterThreshold)
            } catch {
                AppLog.log("FluidAudio engine failed to start: \(error.localizedDescription); capturing audio only (archive preserved)", category: "record")
            }
        }
    }

    func stop() async {
        loadTask?.cancel()
        mixerTask?.cancel()
        diarTask?.cancel()
        loadTask = nil; mixerTask = nil; diarTask = nil
        _ = try? await asr.finish()
        await asr.cleanup()
    }

    // MARK: - Consume updates + feed mixed audio

    private func beginConsumingAndMixing(micRing: AudioRingBuffer, systemRing: AudioRingBuffer,
                                         startElapsed: TimeInterval, clusterThreshold: Float) {
        streamStart = Date()
        liveSegStart = startElapsed

        // Mix both capture rings into one mono stream; feed the recognizer AND
        // buffer the same samples for the diarizer. The streaming ASR delivers its
        // running transcript via the partial callback set in `start()`.
        let asr = self.asr
        let diarRing = self.diarRing
        mixerTask = Task.detached {
            var fedSamples = 0
            var lastLogged = 0
            while !Task.isCancelled {
                if let mixed = Self.mix(mic: micRing, system: systemRing), !mixed.isEmpty {
                    // `process(samples:)` appends the 16 kHz mix and drains every
                    // complete chunk through the encoder (firing the partial
                    // callback); the diarizer reads the same samples.
                    try? await asr.process(samples: mixed)
                    mixed.withUnsafeBufferPointer { diarRing.write($0) }
                    fedSamples += mixed.count
                    if fedSamples - lastLogged >= 16_000 * 5 {
                        lastLogged = fedSamples
                        AppLog.log("FluidAudio fed ~\(fedSamples / 16_000)s of audio to ASR", category: "record")
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // The clean mixed.caf is built from the archived tracks at stop, not here.
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
        config.clusteringThreshold = clusterThreshold
        // NOTE: leave the segmentation params (minSpeechDuration / minSilenceGap) at
        // their library defaults. Lowering minSpeechDuration produced segments too
        // short for reliable speaker embeddings, which degraded clustering (the
        // dominant voice split in two while the quieter speaker was absorbed). This is
        // the diarization behavior that separated speakers correctly.
        let diar = DiarizerManager(config: config)
        diar.initialize(models: models)
        return diar
    }

    /// Pairwise cosine similarity of each speaker's mean embedding, e.g. "1~2=0.88".
    /// High (~0.8+) means the "speakers" are nearly the same voice (over-split / not
    /// separable); low (~0.3–0.5) means they're distinct.
    nonisolated private static func clusterSimilarityLog(_ segs: [Seg]) -> String {
        var byId: [String: [[Float]]] = [:]
        for s in segs where !s.emb.isEmpty { byId[s.id, default: []].append(s.emb) }
        let ids = byId.keys.sorted()
        guard ids.count >= 2 else { return "n/a" }
        let cents = ids.map { normalize(meanVector(byId[$0]!)) }
        var parts: [String] = []
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                parts.append("\(ids[i])~\(ids[j])=\(String(format: "%.2f", dotProduct(cents[i], cents[j])))")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Per-speaker talk-time summary for diagnostics, e.g. "2 speaker(s): 0=28s 1=104s".
    nonisolated private static func speakerBreakdown(_ segs: [Seg]) -> String {
        var talk: [String: TimeInterval] = [:]
        for s in segs { talk[s.id, default: 0] += max(0, s.end - s.start) }
        let parts = talk.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.0fs", $0.value))" }
        return "\(talk.count) speaker(s): \(parts.joined(separator: " "))"
    }

    // Pure vector helpers (local so they're callable from nonisolated static code).
    nonisolated private static func normalize(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }
    nonisolated private static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0; for i in 0..<a.count { s += a[i] * b[i] }; return s
    }
    nonisolated private static func meanVector(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first, !vs.isEmpty else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for v in vs where v.count == acc.count { for i in 0..<acc.count { acc[i] += v[i] } }
        return acc.map { $0 / Float(vs.count) }
    }

    /// Compute fresh embeddings from a retained enrollment clip (raw 16 kHz mono
    /// Float samples) using the CURRENT diarization embedding model. Used to
    /// re-enroll a voiceprint after a model upgrade — regenerating the vectors from
    /// the kept audio instead of re-recording. Returns the clip's segment embeddings
    /// (a single speaker), or nil if none could be derived.
    nonisolated static func embeddings(forClip samples: [Float], clusterThreshold: Float) async -> [[Float]]? {
        guard samples.count >= 16_000 else { return nil }   // < 1 s is too short to embed
        guard let diar = try? await makeDiarizer(clusterThreshold: clusterThreshold),
              let result = try? diar.performCompleteDiarization(samples, sampleRate: 16_000) else { return nil }
        let embs = result.segments.filter { !$0.embedding.isEmpty }.map { $0.embedding }
        return embs.isEmpty ? nil : embs
    }

    /// Merge newly-diarized turns, accumulate quality-gated per-speaker embeddings,
    /// auto-identify against saved voiceprints, then re-derive segments.
    private func ingestDiarization(_ segs: [(speakerId: String, start: TimeInterval, end: TimeInterval, embedding: [Float], quality: Float)]) {
        for s in segs {
            diarSegments.append((s.speakerId, s.start, s.end))
            if s.quality >= minSegmentQuality, !s.embedding.isEmpty {
                speakerEmbeddings[s.speakerId, default: []].append(s.embedding)
                speakerGatedSeconds[s.speakerId, default: 0] += max(0, s.end - s.start)
            }
        }
        autoIdentify()
        publish()
    }

    /// Match each not-yet-named speaker (with enough clean speech) against saved
    /// voiceprints; on a confident match, set the name and notify (for auto-add).
    ///
    /// `verbose` emits a per-speaker diagnostic — why each speaker did or didn't
    /// match (gating, best candidate + score vs threshold, or no comparable print).
    /// Passed `true` only from the offline finalize pass (one-shot, the
    /// authoritative identification) so the live path doesn't spam the log each
    /// 10s chunk. Matching behavior is unchanged: `match(threshold: 0)` returns the
    /// best comparable print and we apply `identificationThreshold` ourselves.
    private func autoIdentify(verbose: Bool = false) {
        guard let store = voiceprints else { return }
        for (id, embs) in speakerEmbeddings where resolvedNames[id] == nil {
            let gated = speakerGatedSeconds[id] ?? 0
            guard gated >= settings.minSpeechToIdentify, embs.count >= 2 else {
                if verbose {
                    AppLog.log("FluidAudio id-skip speaker \(id): \(String(format: "%.1f", gated))s gated, \(embs.count) quality emb (need ≥\(String(format: "%.0f", settings.minSpeechToIdentify))s & ≥2 emb)", category: "record")
                }
                continue
            }
            let centroid = VoiceprintStore.normalized(VoiceprintStore.mean(embs))
            guard let best = store.match(centroid, threshold: 0) else {
                if verbose {
                    AppLog.log("FluidAudio id-try speaker \(id) (\(String(format: "%.1f", gated))s): no comparable voiceprint to score against (none enrolled in the wespeaker_v2 space)", category: "record")
                }
                continue
            }
            if verbose {
                let pass = best.score >= identificationThreshold
                AppLog.log("FluidAudio id-try speaker \(id) (\(String(format: "%.1f", gated))s, \(embs.count) emb): best=\(best.voiceprint.name) \(String(format: "%.2f", best.score)) vs threshold \(String(format: "%.2f", identificationThreshold)) → \(pass ? "MATCH" : "below threshold")", category: "record")
            }
            guard best.score >= identificationThreshold else { continue }
            resolvedNames[id] = best.voiceprint.name
            AppLog.log("FluidAudio auto-identified a speaker as \(best.voiceprint.name) (score \(String(format: "%.2f", best.score)))", category: "record")
            onSpeakerIdentified?(best.voiceprint.name)
            // Backfill a retained clip for a known voice that has none yet
            // (works at the end-of-call pass, when mixed.caf is readable).
            if best.voiceprint.audioSample == nil {
                let vpId = best.voiceprint.id
                let sid = id
                Task { [weak self] in
                    guard let self, let clip = await self.repAudioSample(for: sid) else { return }
                    self.voiceprints?.attachAudioSample(to: vpId, samples: clip)
                }
            }
        }
    }

    /// At stop: re-diarize the WHOLE mixed recording in one pass — a consistent
    /// global speaker set (unlike the incremental chunks, which drift / over-split
    /// on hard audio) — and replace the live labels. This is the authoritative
    /// labeling used for the final transcript and the review panel.
    /// Result of the offline pass, surfaced to the UI so the user sees that it ran,
    /// how long it took, and what it changed.
    struct FinalizeSummary: Sendable {
        let speakerCount: Int
        let relabeled: Bool
        let note: String
    }

    @discardableResult
    func finalizeDiarization() async -> FinalizeSummary {
        let startedAt = Date()
        AppLog.log("FluidAudio offline diarization pass started…", category: "record")
        guard let url = mixedAudioURL else {
            await backfillClips()
            return FinalizeSummary(speakerCount: callSpeakerIds().count, relabeled: false,
                                   note: "Offline pass skipped — no audio")
        }
        let mic = micArchiveURL, sys = systemArchiveURL
        let threshold = Float(settings.diarizationThreshold)
        let doAsr = settings.offlineAsrRepass || forceOfflineAsr
        let version: AsrModelVersion = settings.parakeetVersion == .v2 ? .v2 : .v3
        // One detached pass: build the clean mix, resample once, then run the
        // diarizer AND (optionally) the batch ASR over the same samples.
        let pass: OfflinePassResult = await Task.detached {
            // Build a CLEAN mixed file from the archived tracks (the live per-tick
            // mixer is glitchy — fine for streaming ASR, bad for diarization + playback).
            let built = Self.buildCleanMix(mic: mic, system: sys, output: url)
            guard let samples = try? AudioConverter().resampleAudioFile(url), !samples.isEmpty else {
                AppLog.log("finalizeDiarization: couldn't read clean mix (built=\(built))", category: "record")
                return OfflinePassResult(segs: nil, tokens: nil)
            }
            // Diarization (independent of ASR — one failing doesn't block the other).
            // Plain whole-file diarization with library-default segmentation — the
            // behavior that separated speakers reliably. No forced re-clustering.
            var segs: [Seg]?
            if let diar = try? await Self.makeDiarizer(clusterThreshold: threshold),
               let result = try? diar.performCompleteDiarization(samples, sampleRate: 16_000) {
                let mapped = result.segments.map {
                    Seg(id: $0.speakerId, start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds), emb: $0.embedding, q: $0.qualityScore)
                }
                AppLog.log("finalize: diar \(Self.speakerBreakdown(mapped)) | sims \(Self.clusterSimilarityLog(mapped))", category: "record")
                segs = mapped
            } else {
                AppLog.log("finalizeDiarization: diarization unavailable (init or run failed)", category: "record")
            }
            // Higher-accuracy offline transcript (full-context batch Parakeet).
            let tokens = doAsr ? await Self.offlineTranscribe(samples: samples, version: version) : nil
            return OfflinePassResult(segs: segs, tokens: tokens)
        }.value

        // Apply the offline transcript first (replaces the streaming units), so the
        // re-derived segments pick up the fresh diarization labels below.
        var repassed = false
        if let tokens = pass.tokens, !tokens.isEmpty {
            applyOfflineUnits(tokens)
            repassed = true
        }

        // The diarizer can come back empty on quiet/hard audio. Fall back to the
        // live (chunked) labels — but STILL retain voice clips now that mixed.caf
        // exists (clips can't be captured mid-call, before the clean mix is built).
        guard let segs = pass.segs, !segs.isEmpty else {
            AppLog.log("finalizeDiarization: no final segments — keeping live labels", category: "record")
            publish()
            await backfillClips()
            let n = callSpeakerIds().count
            let suffix = repassed ? " · transcript re-passed" : ""
            return FinalizeSummary(speakerCount: n, relabeled: repassed,
                                   note: "Offline pass: kept live labels · \(n) speaker\(n == 1 ? "" : "s")\(suffix)")
        }
        // Time-ordered so the diarization-first attribution scans turns in order.
        diarSegments = segs.map { ($0.id, $0.start, $0.end) }.sorted { $0.start < $1.start }
        var emb: [String: [[Float]]] = [:]
        var secs: [String: TimeInterval] = [:]
        for s in segs where s.q >= minSegmentQuality && !s.emb.isEmpty {
            emb[s.id, default: []].append(s.emb)
            secs[s.id, default: 0] += max(0, s.end - s.start)
        }
        speakerEmbeddings = emb
        speakerGatedSeconds = secs
        autoIdentify(verbose: true)   // re-applies known names by voice (ids may differ from the live pass)
        publish()        // re-renders the transcript with the cleaned-up speaker labels
        await backfillClips()
        let n = Set(segs.map(\.id)).count
        let elapsed = Date().timeIntervalSince(startedAt)
        let repassNote = repassed ? " · transcript re-passed" : ""
        AppLog.log("FluidAudio final diarization: \(n) speaker(s)\(repassed ? " + offline ASR re-pass" : "") in \(String(format: "%.1fs", elapsed))", category: "record")
        return FinalizeSummary(speakerCount: n, relabeled: true,
                               note: "Offline Speaker Detection complete · \(n) speaker\(n == 1 ? "" : "s")\(repassNote) · \(String(format: "%.1fs", elapsed))")
    }

    private struct Seg: Sendable { let id: String; let start: TimeInterval; let end: TimeInterval; let emb: [Float]; let q: Float }
    private struct TokTiming: Sendable { let text: String; let start: TimeInterval; let end: TimeInterval }
    private struct OfflinePassResult: Sendable { let segs: [Seg]?; let tokens: [TokTiming]? }

    /// Batch (full-context) Parakeet transcription of the whole recording — more
    /// accurate than the 11 s sliding-window stream. Returns token-level timings, or
    /// nil on failure (the caller keeps the streaming transcript). Runs off-main.
    nonisolated private static func offlineTranscribe(samples: [Float], version: AsrModelVersion) async -> [TokTiming]? {
        do {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            var state = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)
            let result = try await mgr.transcribe(samples, decoderState: &state)
            await mgr.cleanup()
            if let timings = result.tokenTimings, !timings.isEmpty {
                return timings.map { TokTiming(text: $0.token, start: $0.startTime, end: $0.endTime) }
            }
            // No token timings — fall back to one span covering the whole clip.
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return [TokTiming(text: text, start: 0, end: TimeInterval(samples.count) / 16_000)]
        } catch {
            AppLog.log("finalizeDiarization: offline ASR re-pass failed: \(error.localizedDescription)", category: "record")
            return nil
        }
    }

    /// Replace the streaming ASR units with the offline transcript. Tokens are split
    /// into units on pauses (>0.8 s) so the final transcript breaks into readable
    /// utterances; `segments(for:)` then splits each unit by diarized speaker.
    private func applyOfflineUnits(_ tokens: [TokTiming]) {
        var units: [ASRUnit] = []
        var cur: [Tok] = []
        var lastEnd: TimeInterval?
        func flush() {
            defer { cur = [] }
            guard !cur.isEmpty else { return }
            let text = Self.reconstruct(cur.map(\.text))
            guard !text.isEmpty else { return }
            units.append(ASRUnit(id: UUID(), tokens: cur, text: text, confirmed: true))
        }
        for t in tokens {
            if let le = lastEnd, t.start - le > 0.8 { flush() }
            cur.append(Tok(text: t.text, start: t.start, end: t.end))
            lastEnd = t.end
        }
        flush()
        guard !units.isEmpty else { return }
        confirmedUnits = units
        volatileUnit = nil
        runIds.removeAll()   // fresh, stable ids for the final transcript
    }

    /// After stop (mixed.caf now exists), retain a short voice clip for every
    /// resolved speaker that doesn't have one yet — covers both auto-identified
    /// and manually-named speakers. Clips can't be captured mid-call because the
    /// clean mixed file is only built at stop.
    private func backfillClips() async {
        guard let store = voiceprints else { return }
        for (sid, name) in resolvedNames {
            guard let vp = store.voiceprint(named: name), vp.audioSample == nil else { continue }
            if let clip = await repAudioSample(for: sid) {
                store.attachAudioSample(to: vp.id, samples: clip)
                AppLog.log("Backfilled voice clip for \(name) (\(clip.count) samples)", category: "record")
            }
        }
    }

    /// The diarized speaker whose turn overlaps `[start, end]` most (nil if none yet).
    private func bestSpeaker(start: TimeInterval, end: TimeInterval) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        for d in diarSegments {
            let overlap = min(end, d.end) - max(start, d.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (d.speakerId, overlap) }
        }
        return best?.id
    }

    /// Drain both rings and sum into one mono buffer, ANCHORED to the mic ring as the
    /// real-time clock (the mic tap runs continuously at 16 kHz even during silence).
    /// Reading the system ring up to the mic's count keeps the mixed stream at true
    /// real-time length — `max()` + zero-pad would over-count when the rings are out
    /// of phase, stretching the ASR timeline out of sync with the clean mixed file.
    nonisolated private static func mix(mic: AudioRingBuffer, system: AudioRingBuffer) -> [Float]? {
        let n = mic.availableToRead
        guard n > 0 else { return nil }
        var micBuf = [Float](), sysBuf = [Float]()
        let rm = mic.read(maxCount: n, into: &micBuf)
        guard rm > 0 else { return nil }
        let rs = system.read(maxCount: rm, into: &sysBuf)   // up to mic's count; system excess waits
        var out = [Float](repeating: 0, count: rm)
        for i in 0..<rm { out[i] += micBuf[i] }
        for i in 0..<min(rs, rm) { out[i] += sysBuf[i] }
        for i in 0..<rm { out[i] = max(-1, min(1, out[i])) }   // soft clip the summed signal
        return out
    }

    /// Sum the archived mic + system tracks (both continuous from capture start) into
    /// one clean 16 kHz mono file — no per-tick discontinuities, unlike the live mixer.
    nonisolated private static func buildCleanMix(mic: URL?, system: URL?, output: URL) -> Bool {
        let converter = AudioConverter()
        func decode(_ url: URL?) -> [Float] {
            guard let url, FileManager.default.fileExists(atPath: url.path),
                  let samples = try? converter.resampleAudioFile(url) else { return [] }
            return samples
        }
        let m = decode(mic), s = decode(system)
        let n = max(m.count, s.count)
        guard n > 0 else { return false }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<m.count { out[i] += m[i] }
        for i in 0..<s.count { out[i] += s[i] }
        // A mic capture of an acoustic re-recording is often very quiet. That both
        // makes playback inaudible AND starves the whole-file diarizer's speech
        // detection (it returns 0 segments while the chunked live pass — catching
        // louder bursts — finds speakers). Peak-normalize the summed mix to ~-3 dBFS
        // so the saved file is audible and the offline pass has a strong enough
        // signal to segment. Gain is capped so a near-silent file isn't amplified
        // into noise.
        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        if peak > 0.0001 {
            let gain = min(20, 0.7 / peak)
            if gain > 1 { for i in 0..<n { out[i] *= gain } }
        }
        for i in 0..<n { out[i] = max(-1, min(1, out[i])) }
        guard let buffer = makeBuffer(out),
              let file = try? AVAudioFile(forWriting: output, settings: mixFileSettings) else { return false }
        do { try file.write(from: buffer); return true } catch { return false }
    }

    /// `mixed.caf` on-disk format: Int16 LPCM (half the Float32 size, inaudible for
    /// speech). The in-memory pipeline stays Float32 (`format`); AVAudioFile converts
    /// on write. `AudioCompactor` later re-encodes the file to ALAC in place.
    private static let mixFileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    nonisolated private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { pcm.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return pcm
    }

    /// Consume a cumulative partial transcript from the streaming ASR. The text is
    /// the FULL running transcript so far (no per-token timings, no confirmation
    /// concept); keep the newest portion as the volatile tail and promote older
    /// text to confirmed units on a fixed wall-clock cadence so the live view
    /// scrolls instead of growing one unbounded line. The offline TDT v3 re-pass
    /// replaces all of these units with token-timed ones at stop.
    private func applyPartial(_ rawText: String, startElapsed: TimeInterval) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = elapsedNow(startElapsed)

        // The model occasionally shortens the transcript (a late re-decode); if it
        // drops below what we've already committed, restart tracking so the
        // committed-prefix offset stays valid.
        if text.count < liveCommittedChars {
            liveCommittedChars = 0
            confirmedUnits.removeAll()
            runIds.removeAll()
            liveSegStart = startElapsed
        }

        let startIdx = text.index(text.startIndex, offsetBy: min(liveCommittedChars, text.count))
        let tail = String(text[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return }

        // Once the volatile span has accumulated for ~liveConfirmInterval seconds,
        // promote it to a confirmed unit stamped with its wall-clock span and start
        // a fresh span. A single Tok per unit (no sub-token timings) means each unit
        // attributes to one diarized speaker at its midpoint — coarse but fine live.
        if now - liveSegStart >= liveConfirmInterval {
            let unit = ASRUnit(id: UUID(),
                               tokens: Self.wordToks(tail, start: liveSegStart, end: now),
                               text: tail, confirmed: true)
            confirmedUnits.append(unit)
            liveCommittedChars = text.count
            liveSegStart = now
            volatileUnit = nil
            AppLog.log("FluidAudio streaming: confirmed \(tail.count) chars", category: "record")
        } else {
            // Reuse the volatile unit's id across updates so the in-progress row
            // keeps a stable identity (content updates in place).
            volatileUnit = ASRUnit(id: volatileUnit?.id ?? UUID(),
                                   tokens: Self.wordToks(tail, start: liveSegStart, end: now),
                                   text: tail, confirmed: false)
        }
        publish()
    }

    private func elapsedNow(_ startElapsed: TimeInterval) -> TimeInterval {
        startElapsed + Date().timeIntervalSince(streamStart ?? Date())
    }

    private func publish() { onSegmentsChanged?(finalTimeline()) }

    // MARK: - Speaker naming (Phase 5)

    func callSpeakerIds() -> [String] {
        var seen = Set<String>()
        for d in diarSegments { seen.insert(d.speakerId) }
        return seen.sorted()
    }
    func resolvedName(for id: String) -> String? { resolvedNames[id] }
    func gatedSeconds(for id: String) -> TimeInterval { speakerGatedSeconds[id] ?? 0 }

    /// Per-speaker centroids built from quality-gated embeddings (same rule as
    /// `setSpeakerName`), for persisting a review cache so assignment needs no re-run.
    func centroidsByID() -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for (id, embs) in speakerEmbeddings
        where !embs.isEmpty && (speakerGatedSeconds[id] ?? 0) >= minSecondsToEnroll {
            out[id] = VoiceprintStore.normalized(VoiceprintStore.mean(embs))
        }
        return out
    }

    /// Manually assign a name to a speaker: relabel their lines (via re-derive) and
    /// return the speaker's centroid embedding for the caller to enroll (nil if no
    /// quality-gated audio was captured for them yet).
    @discardableResult
    func setSpeakerName(_ speakerId: String, as name: String) -> [Float]? {
        resolvedNames[speakerId] = name
        publish()
        // Only enroll a voiceprint from enough clean, quality-gated speech — don't
        // pollute the store with a centroid built from a tiny/low-quality clip.
        let embs = speakerEmbeddings[speakerId] ?? []
        guard !embs.isEmpty, (speakerGatedSeconds[speakerId] ?? 0) >= minSecondsToEnroll else { return nil }
        return VoiceprintStore.normalized(VoiceprintStore.mean(embs))
    }

    /// Extract a short (<=4s) audio clip of a speaker's longest segment from the
    /// archived mixed recording — retained with the voiceprint for re-enrollment.
    func repAudioSample(for speakerId: String) async -> [Float]? {
        guard let url = mixedAudioURL, FileManager.default.fileExists(atPath: url.path) else {
            AppLog.log("repAudioSample: no mixed.caf at \(mixedAudioURL?.path ?? "nil")", category: "record"); return nil
        }
        let segs = finalTimeline().filter { $0.speakerId == speakerId }
        guard let rep = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else {
            AppLog.log("repAudioSample: no segments for speaker \(speakerId)", category: "record"); return nil
        }
        let start = max(0, rep.start)
        let end = min(rep.end, start + 4)
        let clip = await Task.detached { () -> [Float]? in
            guard let all = try? AudioConverter().resampleAudioFile(url) else { return nil }
            let s = Int(start * 16_000), e = min(all.count, Int(end * 16_000))
            guard s >= 0, s < e else { return nil }
            return Array(all[s..<e])
        }.value
        AppLog.log("repAudioSample: speaker \(speakerId) → \(clip?.count ?? 0) samples [\(String(format: "%.1f–%.1fs", start, end))]", category: "record")
        return clip
    }

    /// Per-speaker summaries for the review panel. The snippet text AND the
    /// play-sample come from the SAME (longest) transcript segment, so the audio
    /// you hear matches the line you see.
    func speakerSummaries() -> [CallSpeakerSummary] {
        var byId: [String: [Segment]] = [:]
        for s in finalTimeline() where s.speakerId != nil {
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
