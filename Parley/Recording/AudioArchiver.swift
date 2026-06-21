import Foundation
import AVFoundation

/// Writes raw captured audio to a file (for archival, like the vault's
/// `Raw Transcripts/` mp3s). One archiver per track. Writes Int16 LPCM at the
/// source sample rate/channels — Whisper gets the resampled copy separately,
/// and `AudioCompactor` re-encodes the archive to ALAC after the meeting.
final class AudioArchiver {
    private let file: AVAudioFile
    /// Set when the source buffers' layout or sample rate differs from what
    /// `AVAudioFile.write` expects, so we convert each buffer before writing.
    /// Mutable so `updateSourceFormat(_:)` can rebuild it when the input device changes.
    private var converter: AVAudioConverter?
    private var loggedFailure = false
    private(set) var framesWritten: AVAudioFramePosition = 0

    // MARK: - Write staging

    /// Only needed once `append`'s converter can resample (after `updateSourceFormat`
    /// switches the input to a device whose rate differs from the file's): the SRC then
    /// emits non-power-of-2 frame counts (e.g. 4458/4459 from a 44100→48000 buffer).
    /// Writing those unaligned counts straight to `AVAudioFile.write(from:)` loses frames
    /// *per call* — a proportional deficit of ≈60 ms per 200 buffers at 44100→48000,
    /// which over a meeting would drift the recovered mic audio out of alignment with the
    /// system track. Staging and flushing in `flushSize` (power-of-2)-aligned chunks
    /// eliminates the loss. This is verified, not theorized: `AudioArchiverTests`
    /// `testAppend_crossRateConverter_preservesFrames` fails (loss > 50 ms) if `append`
    /// bypasses this staging and writes directly. The same-rate path (no SRC) is
    /// unaffected, but routing it through staging too keeps one code path.
    ///
    /// - Note: The staging buffer and `appendSilence` both write in the file's
    ///   processingFormat (non-interleaved Float32), so `flushSize` alignment avoids
    ///   the issue for silence writes too.
    private static let stagingCapacity = AVAudioFrameCount(32_768)  // ~0.68 s @ 48 kHz
    private static let flushSize = AVAudioFrameCount(4_096)

    private var stagingBuffer: AVAudioPCMBuffer?
    private var stagingFilled = AVAudioFrameCount(0)

    deinit {
        // Safety-net flush: `finalize()` should be called explicitly before release,
        // but deinit catches any case where that was omitted.
        flushRemainder()
    }

    /// Flushes all staged frames to disk. Call before releasing the archiver (e.g., at
    /// session end) to ensure the file is complete. Safe to call multiple times.
    func finalize() {
        flushRemainder()
    }

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
        stagingBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: Self.stagingCapacity
        )
        stagingBuffer?.frameLength = 0
    }

    /// Rebuilds the converter to accept audio from a new input device.
    ///
    /// The output file format never changes — new-device audio is resampled into the
    /// existing file's format. Call this when the input device changes, before resuming
    /// writes. Resets the one-time failure log flag so errors from the new converter are
    /// visible.
    ///
    /// Flushes any pending staged data before swapping the converter, so the format
    /// boundary is clean.
    func updateSourceFormat(_ newFormat: AVAudioFormat) {
        // Flush staged data that was produced by the old converter before switching.
        flushRemainder()
        loggedFailure = false
        guard newFormat != file.processingFormat else {
            // New device is already in the file's processing format — no converter needed.
            converter = nil
            return
        }
        let newConverter = AVAudioConverter(from: newFormat, to: file.processingFormat)
        if newConverter == nil {
            logOnce("updateSourceFormat: AVAudioConverter(from:\(newFormat) to:\(file.processingFormat)) returned nil — keeping old converter")
            return
        }
        converter = newConverter
    }

    /// Pads the archive with silence (zero-filled samples at the file's sample rate).
    ///
    /// `AudioMix` overlays the mic and system tracks by sample index from sample 0,
    /// so every missing mic sample shifts all subsequent mic audio earlier. Padding the
    /// gap preserves temporal alignment after a device-change recovery.
    ///
    /// Chunked at ≤1 s buffers to avoid a large allocation for long outages.
    /// Silence goes through the staging path to maintain write-alignment.
    func appendSilence(seconds: Double) {
        guard seconds > 0 else { return }
        let fileRate = file.processingFormat.sampleRate
        var remaining = Int64(round(seconds * fileRate))
        let chunkSize = Int64(fileRate)   // ≤1 s per chunk

        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, chunkSize))
            guard let silenceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frames
            ) else { break }
            // A fresh buffer has frameLength == 0; set it explicitly.
            silenceBuffer.frameLength = frames
            // Zero the channel data — don't rely on the allocator zeroing it.
            for ch in 0..<Int(file.processingFormat.channelCount) {
                if let ptr = silenceBuffer.floatChannelData?[ch] {
                    memset(ptr, 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }
            stageAndFlush(silenceBuffer)
            remaining -= Int64(frames)
        }
        // After all silence is staged, flush any partial staging block so the next
        // real-audio write starts from a clean boundary.
        flushRemainder()
    }

    /// Appends a buffer. Called from the capture path; swallows write errors so
    /// a transient archive failure never kills the live transcription.
    func append(_ buffer: AVAudioPCMBuffer) {
        let toWrite: AVAudioPCMBuffer
        if let converter {
            // Use the block-based convert form so AVAudioConverter can perform
            // sample-rate conversion when the new device's rate differs from the file's.
            // The one-shot `convert(to:from:)` overload only does layout/interleave
            // conversion and throws for SRC — it must not be used here.
            let fileRate = file.processingFormat.sampleRate
            let inputRate = converter.inputFormat.sampleRate
            // Scale capacity by the rate ratio; add slack for rounding.
            let outCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * (fileRate / inputRate)
            ) + 16
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: outCapacity
            ) else { return }
            var consumedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if consumedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumedInput = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                logOnce("convert failed: \(conversionError?.localizedDescription ?? "unknown")")
                return
            }
            toWrite = converted
        } else {
            toWrite = buffer
        }
        stageAndFlush(toWrite)
    }

    // MARK: - Staging internals

    /// Copies `src` into the staging buffer, flushing aligned chunks to disk whenever
    /// the staging buffer accumulates >= `flushSize` frames.
    private func stageAndFlush(_ src: AVAudioPCMBuffer) {
        guard let staging = stagingBuffer else {
            // Fallback: no staging buffer (allocation failure at init) — write directly.
            writeDirectly(src)
            return
        }
        let channelCount = Int(file.processingFormat.channelCount)
        var srcOffset = AVAudioFrameCount(0)
        let srcFrames = src.frameLength

        while srcOffset < srcFrames {
            let canFit = Self.stagingCapacity - stagingFilled
            let toCopy = min(srcFrames - srcOffset, canFit)

            for ch in 0..<channelCount {
                guard let dstPtr = staging.floatChannelData?[ch],
                      let srcPtr = src.floatChannelData?[ch] else { continue }
                dstPtr.advanced(by: Int(stagingFilled))
                    .initialize(from: srcPtr.advanced(by: Int(srcOffset)), count: Int(toCopy))
            }
            stagingFilled += toCopy
            srcOffset += toCopy

            // Flush as many flushSize-aligned blocks as are ready.
            while stagingFilled >= Self.flushSize {
                flushBlock()
            }
        }
    }

    /// Flushes exactly `flushSize` frames from the front of the staging buffer.
    private func flushBlock() {
        guard let staging = stagingBuffer, stagingFilled >= Self.flushSize else { return }
        let channelCount = Int(file.processingFormat.channelCount)

        guard let block = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: Self.flushSize
        ) else { return }
        block.frameLength = Self.flushSize

        for ch in 0..<channelCount {
            guard let dst = block.floatChannelData?[ch],
                  let src = staging.floatChannelData?[ch] else { continue }
            dst.initialize(from: src, count: Int(Self.flushSize))
        }
        writeDirectly(block)

        // Shift remaining staging data to the front.
        // Use memmove (not initialize(from:)) — source and destination overlap in the
        // same buffer so initialize's non-overlap precondition would be violated.
        let remaining = stagingFilled - Self.flushSize
        if remaining > 0 {
            for ch in 0..<channelCount {
                guard let ptr = staging.floatChannelData?[ch] else { continue }
                memmove(ptr, ptr.advanced(by: Int(Self.flushSize)),
                        Int(remaining) * MemoryLayout<Float>.size)
            }
        }
        stagingFilled = remaining
    }

    /// Flushes any staging data that hasn't yet reached `flushSize`.
    /// Call at `updateSourceFormat` (format boundary) and `appendSilence` (after silence).
    private func flushRemainder() {
        guard let staging = stagingBuffer, stagingFilled > 0 else { return }
        let channelCount = Int(file.processingFormat.channelCount)

        guard let remainder = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: stagingFilled
        ) else { return }
        remainder.frameLength = stagingFilled

        for ch in 0..<channelCount {
            guard let dst = remainder.floatChannelData?[ch],
                  let src = staging.floatChannelData?[ch] else { continue }
            dst.initialize(from: src, count: Int(stagingFilled))
        }
        writeDirectly(remainder)
        stagingFilled = 0
    }

    /// Writes a buffer directly to disk, updating `framesWritten`.
    private func writeDirectly(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
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
