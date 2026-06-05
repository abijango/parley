import Foundation
import AVFoundation

/// Post-meeting size reclaim: re-encodes a session's LPCM `.caf` archives to Apple
/// Lossless (ALAC) **in the same CAF container and filename**, so every stored path
/// keeps working — `meta.audio` points at `mic.caf` and the History "Detect speakers"
/// re-run derives `system.caf`/`mixed.caf` from it by name. All readers (playback,
/// FluidAudio's resampler, `AudioMix.loadMono16k`, `SessionStore.audioDuration`) go
/// through `AVAudioFile`, which decodes ALAC transparently.
///
/// Why not record compressed in the first place: ALAC needs its packet table written
/// at close, so a crash mid-recording loses the file, whereas LPCM-in-CAF is readable
/// up to the truncation point. That crash-safety only matters *while* recording — so
/// the archivers write Int16 LPCM live, and this runs once the offline pass is done
/// with the audio. ALAC is lossless: a later re-run sees bit-identical samples.
enum AudioCompactor {

    /// Re-encode every LPCM `.caf` directly inside `dir` to ALAC, in place. Files that
    /// are already compressed are skipped, so this is safe to call repeatedly (e.g.
    /// after a History re-run rebuilds `mixed.caf`). Blocking — call off the main actor.
    static func compactSession(_ dir: URL) {
        let fm = FileManager.default
        // Temp files are dot-hidden (`.mic.caf`); skipsHiddenFiles keeps them out of
        // the work list, and any stale one from a crashed compaction gets overwritten.
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        var before: Int64 = 0, after: Int64 = 0
        for url in entries where url.pathExtension == "caf" {
            guard let result = compact(url) else { continue }
            before += result.before
            after += result.after
        }
        guard before > 0 else { return }
        let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        AppLog.log("Compacted \(dir.lastPathComponent): \(f(before)) → \(f(after)) (ALAC)",
                   category: "audio")
    }

    /// ALAC-encode one file next to itself and atomically swap it in. Returns the
    /// byte sizes on success; nil if skipped (already compressed) or failed — the
    /// original is kept untouched on any failure.
    private static func compact(_ url: URL) -> (before: Int64, after: Int64)? {
        guard let reader = try? AVAudioFile(forReading: url),
              reader.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              reader.length > 0 else { return nil }
        // Same `.caf` extension so AVAudioFile picks the CAF container for the temp.
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent)
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        // Verify by REOPENING the temp: a compressed AVAudioFile's `length` is not
        // reliable until the writer is closed (deinit), so the on-disk frame count
        // is the only trustworthy signal that every sample made it across.
        guard transcode(reader, to: tmp),
              let written = try? AVAudioFile(forReading: tmp), written.length == reader.length else {
            try? fm.removeItem(at: tmp)
            AppLog.log("AudioCompactor: \(url.lastPathComponent) transcode failed — keeping LPCM",
                       category: "audio")
            return nil
        }
        let beforeBytes = fileSize(url), afterBytes = fileSize(tmp)
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            AppLog.log("AudioCompactor: swap failed for \(url.lastPathComponent): \(error.localizedDescription)",
                       category: "audio")
            return nil
        }
        return (beforeBytes, afterBytes)
    }

    /// Chunked LPCM → ALAC copy. Scoped so the writer deinits (flushing the ALAC
    /// packet table) before the caller reopens the temp to verify it. True means the
    /// copy loop fed every source frame in; the caller checks what reached disk.
    private static func transcode(_ reader: AVAudioFile, to tmp: URL) -> Bool {
        let fmt = reader.fileFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: Int(fmt.channelCount),
            AVEncoderBitDepthHintKey: 16,
        ]
        guard let writer = try? AVAudioFile(forWriting: tmp, settings: settings),
              reader.processingFormat == writer.processingFormat,
              let buf = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                         frameCapacity: 1 << 16) else { return false }
        var fed: AVAudioFramePosition = 0
        do {
            while reader.framePosition < reader.length {
                try reader.read(into: buf)
                if buf.frameLength == 0 { break }
                try writer.write(from: buf)
                fed += AVAudioFramePosition(buf.frameLength)
            }
        } catch { return false }
        return fed == reader.length
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
    }
}
