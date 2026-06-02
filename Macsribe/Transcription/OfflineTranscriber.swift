import Foundation
import AVFoundation
import WhisperKit

/// Transcribes a recorded audio file end-to-end (non-streaming) — the
/// authoritative recovery path. Because the `.caf` archive survives a hard crash
/// intact, re-running it through the model reconstructs the *complete* transcript
/// (no 15-second checkpoint gap), and the same helper powers a "re-process audio"
/// action from History.
enum OfflineTranscriber {
    /// Reads `caf`, resamples to 16 kHz mono, transcribes it with `kit`, and
    /// returns confirmed segments on the shared clock offset by `startElapsed`.
    /// Returns `[]` if the file is missing/empty/unreadable.
    static func transcribe(caf url: URL,
                           track: SpeakerTrack,
                           using kit: WhisperKit,
                           startElapsed: TimeInterval = 0) async -> [Segment] {
        guard FileManager.default.fileExists(atPath: url.path),
              let samples = decodeToWhisperSamples(url), !samples.isEmpty else { return [] }

        var options = DecodingOptions()
        options.withoutTimestamps = false
        options.wordTimestamps = false
        options.skipSpecialTokens = true
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            return results.flatMap { $0.segments }.compactMap { seg in
                let text = cleanText(seg.text)
                guard !text.isEmpty else { return nil }
                return Segment(track: track,
                               start: startElapsed + TimeInterval(seg.start),
                               end: startElapsed + TimeInterval(seg.end),
                               text: text, confirmed: true)
            }
        } catch {
            AppLog.log("Offline transcribe failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "record")
            return []
        }
    }

    /// Decodes the whole file to 16 kHz mono Float32 samples (Whisper's format).
    static func decodeToWhisperSamples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard let resampler = AudioResampler(inputFormat: format) else { return nil }
        var out: [Float] = []
        let chunkFrames: AVAudioFrameCount = 1 << 16   // 64k frames per read
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0 else { break }   // EOF
            if let floats = resampler.resample(buffer) { out.append(contentsOf: floats) }
        }
        return out
    }

    /// Strip any residual Whisper special/timestamp tokens (`<|…|>`).
    private static func cleanText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
