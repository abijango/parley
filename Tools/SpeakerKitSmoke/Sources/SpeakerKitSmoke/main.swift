import Foundation
import AVFoundation
import SpeakerKit
import WhisperKit

// Spike probe: load 16 kHz mono samples, run SpeakerKit diarization, and report the
// facts the integration plan needs — does the result expose per-speaker embeddings
// (and at what dimension), how fast is diarization (RTFx), and does cross-run matching
// work via nearestSpeakerCentroid. Usage: SpeakerKitSmoke <audio-file>

func loadMono16k(_ url: URL) -> [Float]? {
    guard let f = try? AVAudioFile(forReading: url) else { return nil }
    let fmt = f.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)),
          (try? f.read(into: buf)) != nil else { return nil }
    if fmt.sampleRate == 16_000, fmt.channelCount == 1, let ch = buf.floatChannelData {
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
    // Resample / downmix to 16 kHz mono.
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                     channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: fmt, to: outFmt) else { return nil }
    let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / fmt.sampleRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
    var fed = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return buf
    }
    guard err == nil, let ch = outBuf.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
}

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: SpeakerKitSmoke <audio-file>\n".utf8)); exit(1)
}
let url = URL(fileURLWithPath: args[1])
guard let samples = loadMono16k(url) else {
    FileHandle.standardError.write(Data("ERROR: could not load \(url.path)\n".utf8)); exit(1)
}
let seconds = Double(samples.count) / 16_000
print("SpeakerKitSmoke — \(url.lastPathComponent): \(samples.count) samples (~\(String(format: "%.1f", seconds))s @16k mono)")

do {
    let tLoad = Date()
    let sk = try await SpeakerKit()   // downloads + loads pyannote-v4 CoreML models on first run
    print(String(format: "models loaded in %.1fs", Date().timeIntervalSince(tLoad)))

    let t0 = Date()
    let result = try await sk.diarize(audioArray: samples)
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "diarized in %.2fs  (RTFx %.1fx)  speakers=%d  segments=%d",
                 dt, seconds / dt, result.speakerCount, result.segments.count))

    let cents = result.speakerCentroidEmbeddings
    let dims = Set(cents.values.map { $0.count }).sorted()
    print("centroid embeddings: \(cents.count) speaker(s); embedding dimension(s): \(dims)")

    for seg in result.segments.prefix(14) {
        let id = seg.speaker.speakerId.map(String.init) ?? "?"
        print(String(format: "  spk %@  [%.2f–%.2fs]", id, seg.startTime, seg.endTime))
    }

    // Cross-run matching demo: feed a speaker's own centroid back through the public
    // nearestSpeakerCentroid API (this is what cross-session voiceprint ID would use).
    if let (id0, c0) = cents.sorted(by: { $0.key < $1.key }).first,
       let m = result.nearestSpeakerCentroid(to: c0) {
        print("nearestSpeakerCentroid(centroid of spk \(id0)) → spk \(m.speakerId), distance \(String(format: "%.3f", m.distance))")
    }
    // ───── Full-pipeline validation (mirrors WhisperKitSpeakerKitEngine) ─────
    // WhisperKit word-level transcript + diarization-first attribution over the
    // SpeakerKit turns → the attributed transcript the engine would produce.
    let wk = try await WhisperKit()
    var wopts = DecodingOptions()
    wopts.wordTimestamps = true
    wopts.skipSpecialTokens = true
    let wresults = try await wk.transcribe(audioArray: samples, decodeOptions: wopts)
    struct Tok { let text: String; let start: Double; let end: Double }
    var toks: [Tok] = []
    for r in wresults { for seg in r.segments { for w in (seg.words ?? []) where !w.word.isEmpty {
        toks.append(Tok(text: w.word, start: Double(w.start), end: Double(w.end)))
    } } }
    let turns = result.segments.compactMap { seg -> (spk: String, start: Double, end: Double)? in
        guard let id = seg.speaker.speakerId else { return nil }
        return (String(id), Double(seg.startTime), Double(seg.endTime))
    }
    func spkAt(_ t: Double) -> String {
        for d in turns where t >= d.start && t <= d.end { return d.spk }
        var best: (String, Double)?
        for d in turns { let dist = Swift.min(abs(t - d.start), abs(t - d.end)); if dist < (best?.1 ?? .infinity) { best = (d.spk, dist) } }
        return best?.0 ?? "?"
    }
    var wg: [[Tok]] = []
    for t in toks { if wg.isEmpty || t.text.hasPrefix("\u{2581}") || t.text.hasPrefix(" ") { wg.append([t]) } else { wg[wg.count - 1].append(t) } }
    struct Line { var spk: String; var start: Double; var end: Double; var text: String }
    var lines: [Line] = []
    for w in wg {
        let spk = spkAt((w.first!.start + w.last!.end) / 2)
        let wt = w.map(\.text).joined()
        if var last = lines.last, last.spk == spk { last.end = w.last!.end; last.text += wt; lines[lines.count - 1] = last }
        else { lines.append(Line(spk: spk, start: w.first!.start, end: w.last!.end, text: wt)) }
    }
    print("\n[FULL PIPELINE — WhisperKit words + SpeakerKit turns → attribution] \(lines.count) lines:")
    for l in lines.prefix(16) {
        let txt = l.text.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
        print(String(format: "  Speaker %@  [%.1f–%.1fs]  %@", l.spk, l.start, l.end, String(txt.prefix(64))))
    }
    print("✅ probe complete")
} catch {
    FileHandle.standardError.write(Data("DIARIZE FAILED: \(error)\n".utf8)); exit(2)
}
