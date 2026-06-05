import Foundation
import AVFoundation

/// Writes raw captured audio to a file (for archival, like the vault's
/// `Raw Transcripts/` mp3s). One archiver per track. Writes Int16 LPCM at the
/// source sample rate/channels — Whisper gets the resampled copy separately,
/// and `AudioCompactor` re-encodes the archive to ALAC after the meeting.
final class AudioArchiver {
    private let file: AVAudioFile
    /// Set when the source buffers' layout differs from what `AVAudioFile.write`
    /// expects, so we convert each buffer before writing.
    private let converter: AVAudioConverter?
    private var loggedFailure = false
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(url: URL, format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Caller passes a .caf or .wav URL; AVAudioFile infers from settings.
        // Archive as 16-bit integer LPCM, not the source's Float32: the capture
        // pipeline hands us Float32 because that's AVAudioEngine's *processing*
        // representation, not the hardware's fidelity — archiving it doubles the
        // file for no audible gain (~1.4 GB/h for a stereo system tap). Int16
        // LPCM-in-CAF stays crash-safe (readable up to a truncation point);
        // AVAudioFile converts from the float processing format on write.
        let archiveSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: archiveSettings)
        // `AVAudioFile.write(from:)` requires buffers in the file's processingFormat
        // (standard deinterleaved float). A CoreAudio process-tap delivers buffers in
        // its native layout — often interleaved — which write() rejects. Because we
        // swallow write errors, that left the system archive empty (header only) while
        // the mic track (already deinterleaved from AVAudioEngine) wrote fine. When the
        // source format differs from the file's processing format, convert per buffer.
        converter = (format != file.processingFormat)
            ? AVAudioConverter(from: format, to: file.processingFormat)
            : nil
    }

    /// Appends a buffer. Called from the capture path; swallows write errors so
    /// a transient archive failure never kills the live transcription.
    func append(_ buffer: AVAudioPCMBuffer) {
        let toWrite: AVAudioPCMBuffer
        if let converter {
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: buffer.frameLength) else { return }
            do {
                // Same sample rate (file derives from the source format), so this is a
                // one-shot layout/interleave conversion — no resampling block needed.
                try converter.convert(to: converted, from: buffer)
            } catch {
                logOnce("convert failed: \(error.localizedDescription)"); return
            }
            toWrite = converted
        } else {
            toWrite = buffer
        }
        do {
            try file.write(from: toWrite)
            framesWritten += AVAudioFramePosition(toWrite.frameLength)
        } catch {
            logOnce("write failed: \(error.localizedDescription)")
        }
    }

    /// Log only the first failure per track — the capture path runs on a real-time
    /// thread; a per-buffer log would flood.
    private func logOnce(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        AppLog.log("AudioArchiver \(file.url.lastPathComponent): \(message)", category: "audio")
    }
}
