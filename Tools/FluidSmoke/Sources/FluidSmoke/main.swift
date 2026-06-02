import Foundation
import FluidAudio

// Phase-1 smoke test: prove FluidAudio's Parakeet ASR + diarization (with
// per-segment 256-d embeddings) run on this machine against a known WAV.
// Usage: swift run FluidSmoke [path-to-16k-mono-wav]

let defaultWav = "Fixtures/two-speakers.wav"
let wavPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultWav
let url = URL(fileURLWithPath: wavPath)

guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write(Data("ERROR: WAV not found at \(url.path)\n".utf8))
    exit(1)
}

func line(_ s: String = "") { print(s) }
line("FluidSmoke — input: \(url.lastPathComponent)")
line(String(repeating: "=", count: 60))

// Decode once to 16 kHz mono Float32 for the diarizer (ASR takes the URL directly).
let converter = AudioConverter()
let samples: [Float]
do {
    samples = try converter.resampleAudioFile(url)
} catch {
    FileHandle.standardError.write(Data("ERROR: AudioConverter failed: \(error)\n".utf8))
    exit(1)
}
line("Decoded \(samples.count) samples (~\(String(format: "%.1f", Double(samples.count) / 16000.0))s @16kHz mono)")

// ───────────────────────────── ASR (Parakeet TDT v3) ─────────────────────────────
line("\n[1/2] ASR — Parakeet TDT 0.6b v3 (multilingual)")
do {
    let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(asrModels)

    var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(url, decoderState: &decoderState)

    line("  text: \"\(result.text)\"")
    line(String(format: "  confidence: %.3f   audio: %.1fs   proc: %.2fs   RTFx: %.1fx",
                result.confidence, result.duration, result.processingTime, result.rtfx))
    if let timings = result.tokenTimings, !timings.isEmpty {
        line("  token timings: \(timings.count) tokens; first 8:")
        for t in timings.prefix(8) {
            line(String(format: "    %@  [%.2f–%.2fs]  conf %.2f",
                        t.token.replacingOccurrences(of: "\u{2581}", with: "·"), t.startTime, t.endTime, t.confidence))
        }
    } else {
        line("  token timings: NONE returned")
    }
} catch {
    FileHandle.standardError.write(Data("  ASR FAILED: \(error)\n".utf8))
    exit(2)
}

// ───────────────────────────── Diarization + embeddings ─────────────────────────────
// Optional arg 2 = clusteringThreshold override (default 0.7).
let threshold = CommandLine.arguments.count > 2 ? Float(CommandLine.arguments[2]) ?? 0.7 : 0.7
line("\n[2/2] Diarization — pyannote segmentation + WeSpeaker embeddings (clusteringThreshold \(threshold))")

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return .nan }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return dot / (na.squareRoot() * nb.squareRoot())
}

do {
    let diarModels = try await DiarizerModels.downloadIfNeeded()
    var config = DiarizerConfig()
    config.clusteringThreshold = threshold
    let diarizer = DiarizerManager(config: config)
    diarizer.initialize(models: diarModels)

    let result = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)
    let speakers = Set(result.segments.map(\.speakerId)).sorted()
    line("  distinct speakers: \(speakers.count)  → \(speakers.joined(separator: ", "))")
    line("  segments: \(result.segments.count)  (embedding dim: \(result.segments.first?.embedding.count ?? 0))")
    for seg in result.segments {
        line(String(format: "    %@  [%.2f–%.2fs]  dur %.2fs  quality %.2f",
                    seg.speakerId, seg.startTimeSeconds, seg.endTimeSeconds, seg.durationSeconds, seg.qualityScore))
    }
    // Diagnostic: pairwise cosine between segment embeddings. If cross-speaker
    // pairs are ~0.9 the embeddings can't separate these voices; if they're low
    // but still clustered together, the threshold is the problem.
    let segs = result.segments
    if segs.count > 1 {
        line("  pairwise cosine (segment embeddings):")
        var header = "        "
        for j in segs.indices { header += String(format: "  s%-4d", j) }
        line(header)
        for i in segs.indices {
            var row = String(format: "    s%-3d", i)
            for j in segs.indices { row += String(format: "  %.2f ", cosine(segs[i].embedding, segs[j].embedding)) }
            line(row)
        }
    }

    // Phase 4 acceptance demo: mirror VoiceprintStore — enroll one speaker from its
    // QUALITY-GATED segments (centroid of L2-normalized embeddings), then verify a
    // held-out clip of that speaker MATCHES above threshold while the other is REJECTED.
    // (Gating mirrors brief constraint #2: low-quality clips pollute a voiceprint —
    // the 0.21-quality tail in this clip doesn't even match its own speaker.)
    let idThreshold: Float = 0.6
    let minQuality: Float = 0.4
    var bySpeaker: [String: [(emb: [Float], q: Float)]] = [:]
    for seg in segs { bySpeaker[seg.speakerId, default: []].append((seg.embedding, seg.qualityScore)) }
    func l2(_ v: [Float]) -> [Float] { let n = v.reduce(Float(0)) { $0 + $1*$1 }.squareRoot(); return n > 0 ? v.map { $0/n } : v }
    func centroid(_ embs: [[Float]]) -> [Float] {
        var acc = [Float](repeating: 0, count: embs[0].count)
        for v in embs { for i in v.indices { acc[i] += v[i] } }
        return l2(acc.map { $0 / Float(embs.count) })
    }
    if let enrolled = bySpeaker.first(where: { $0.value.filter { $0.q >= minQuality }.count >= 2 }) {
        let good = enrolled.value.filter { $0.q >= minQuality }.sorted { $0.q > $1.q }
        let heldOut = good[0].emb                       // best-quality clip, held out
        let c = centroid(good.dropFirst().map(\.emb))   // enroll on the rest
        line("\n[ID demo] enrolled speaker \(enrolled.key) from \(good.count - 1) quality-gated segment(s) (q≥\(minQuality)); threshold \(idThreshold)")
        let selfScore = cosine(c, heldOut)
        line(String(format: "  held-out SAME speaker %@: cosine %.2f → %@",
                    enrolled.key, selfScore, selfScore >= idThreshold ? "MATCH ✅" : "miss ❌"))
        for (spk, vals) in bySpeaker where spk != enrolled.key {
            let s = vals.filter { $0.q >= minQuality }.map { cosine(c, $0.emb) }.max() ?? (vals.map { cosine(c, $0.emb) }.max() ?? .nan)
            line(String(format: "  other speaker %@: best cosine %.2f → %@",
                        spk, s, s >= idThreshold ? "FALSE MATCH ❌" : "rejected ✅"))
        }
    } else {
        line("\n[ID demo] skipped — no speaker has ≥2 quality-gated segments")
    }
} catch {
    FileHandle.standardError.write(Data("  DIARIZATION FAILED: \(error)\n".utf8))
    exit(3)
}

line("\n✅ Smoke test complete — both ASR and diarization produced output.")
