import Foundation
import AVFoundation

/// Engine-agnostic clean-mix + 16 kHz mono loading for the offline diarization pass.
///
/// Ported from `FluidAudioEngine`'s private clean-mix logic (intentionally duplicated,
/// not refactored, so the FluidAudio path stays untouched). Unlike FluidAudio's
/// version it resamples via AVFoundation rather than FluidAudio's `AudioConverter`, so
/// the WhisperKit + SpeakerKit engine doesn't depend on the FluidAudio package.
enum AudioMix {

    /// 16 kHz mono Float32 — the format SpeakerKit (and pyannote) consume.
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Decode any audio file to 16 kHz mono Float samples (resampling/downmixing as
    /// needed). Returns nil if the file can't be read.
    static func loadMono16k(_ url: URL) -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let f = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = f.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: inBuf)) != nil else { return nil }
        if inFmt.sampleRate == 16_000, inFmt.channelCount == 1, let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }
        guard let conv = AVAudioConverter(from: inFmt, to: format) else { return nil }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / inFmt.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    /// Sum the archived mic + system tracks into one clean 16 kHz mono file, peak-
    /// normalized to ~-3 dBFS so it's audible and gives the diarizer a strong signal.
    @discardableResult
    static func buildCleanMix(mic: URL?, system: URL?, output: URL) -> Bool {
        let m = mic.flatMap(loadMono16k) ?? []
        let s = system.flatMap(loadMono16k) ?? []
        let n = max(m.count, s.count)
        guard n > 0 else { return false }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<m.count { out[i] += m[i] }
        for i in 0..<s.count { out[i] += s[i] }
        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        if peak > 0.0001 {
            let gain = min(20, 0.7 / peak)
            if gain > 1 { for i in 0..<n { out[i] *= gain } }
        }
        for i in 0..<n { out[i] = max(-1, min(1, out[i])) }
        guard let buffer = makeBuffer(out),
              let file = try? AVAudioFile(forWriting: output, settings: format.settings) else { return false }
        do { try file.write(from: buffer); return true } catch { return false }
    }

    static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { pcm.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return pcm
    }
}
